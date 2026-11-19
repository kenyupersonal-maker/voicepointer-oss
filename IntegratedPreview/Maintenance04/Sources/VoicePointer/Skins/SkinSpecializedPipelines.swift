import Foundation
@preconcurrency import Metal
import VoicePointerCore

// Pipelines for skins with tunable parameters (Astra, black hole).
//
// The shader library is compiled once. A tunable skin's fragment function reads its parameters from
// Metal function constants, so every distinct set of values needs its own specialised function and
// pipeline. Both are created with the asynchronous Metal APIs (nothing here waits on the GPU or the
// compiler service), rebuilds are coalesced, and the pipeline being drawn is replaced only when the
// new one is ready. A failed rebuild keeps the old pipeline.

/// Metal objects are not Sendable, but they are safe to hand over between the threads Metal calls back
/// on. A completion handler passes them on inside this box instead of capturing them.
struct HUDMetalBox<Value>: @unchecked Sendable {
    let value: Value
}

enum HUDPipelineBuilder {
    /// One render pass of a skin: the vertex and fragment function names in the library.
    struct PassSpec: Sendable, Equatable {
        let vertex: String
        let fragment: String
        var key: String { vertex + "|" + fragment }
    }

    /// Specialises the pass's fragment function with `constants` and builds its render pipeline, both
    /// asynchronously. `completion` runs on a Metal thread: a pipeline state, or nil and a message.
    static func build(
        device: HUDMetalBox<any MTLDevice>,
        library: HUDMetalBox<any MTLLibrary>,
        pass: PassSpec,
        constants: HUDMetalBox<MTLFunctionConstantValues>,
        completion: @escaping @Sendable (HUDMetalBox<(any MTLRenderPipelineState)?>, String?) -> Void
    ) {
        library.value.makeFunction(
            name: pass.fragment,
            constantValues: constants.value,
            completionHandler: { @Sendable fragmentFunction, error in
                guard let fragmentFunction else {
                    completion(HUDMetalBox(value: nil), Self.message(error, fallback: "specialised function unavailable"))
                    return
                }
                guard let vertexFunction = library.value.makeFunction(name: pass.vertex) else {
                    completion(HUDMetalBox(value: nil), "vertex function missing: \(pass.vertex)")
                    return
                }
                let pipelineDescriptor = Self.descriptor(
                    vertex: vertexFunction, fragment: fragmentFunction, label: pass.key)
                device.value.makeRenderPipelineState(
                    descriptor: pipelineDescriptor,
                    completionHandler: { @Sendable state, error in
                        completion(HUDMetalBox(value: state), Self.message(error, fallback: "pipeline unavailable"))
                    })
            })
    }

    /// The premultiplied-over descriptor every HUD shader pipeline uses.
    static func descriptor(
        vertex: any MTLFunction, fragment: any MTLFunction, label: String
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return descriptor
    }

    private static func message(_ error: (any Error)?, fallback: String) -> String {
        String((error?.localizedDescription ?? fallback).prefix(1000))
    }
}

/// Builds, caches and hands out the specialised pipelines. Main-actor state; only the Metal work runs elsewhere.
@MainActor
final class HUDSpecializedPipelines {
    struct Job {
        let id: HUDSkinID
        let skinKey: String
        let passes: [HUDPipelineBuilder.PassSpec]
        let constants: [SkinFunctionConstant]
        let fingerprint: String
        let device: any MTLDevice
        let library: any MTLLibrary
        var cacheKey: String { skinKey + "|" + fingerprint }
    }

    private struct Build {
        let job: Job
        var remaining: Int
        var results: [String: any MTLRenderPipelineState] = [:]
        var failure: String?
    }

    /// A skin's first pipeline is ready (`first`), or a later rebuild replaced it.
    var onActivated: (@MainActor (HUDSkinID, _ first: Bool) -> Void)?
    /// A build failed. `hasActive` says whether an older pipeline keeps the skin drawing.
    var onFailed: (@MainActor (HUDSkinID, _ message: String, _ hasActive: Bool) -> Void)?

    /// Pause between one build finishing and the next starting, so a dragged slider does not keep the compiler busy.
    private static let cooldown: Duration = .milliseconds(120)
    private static let cacheLimit = 6

    private var activeFingerprint: [HUDSkinID: String] = [:]
    private var activeByKey: [String: any MTLRenderPipelineState] = [:]
    private var cache: [String: [String: any MTLRenderPipelineState]] = [:]
    private var cacheOrder: [String] = []
    private var failedKeys: Set<String> = []
    private var inFlight: [HUDSkinID: Build] = [:]
    private var pending: [HUDSkinID: Job] = [:]
    private var timers: [HUDSkinID: Task<Void, Never>] = [:]

    /// The pipeline being drawn for `vertex|fragment`, nil until the first build finishes.
    func pipeline(forKey key: String) -> (any MTLRenderPipelineState)? { activeByKey[key] }

    func isActive(_ id: HUDSkinID) -> Bool { activeFingerprint[id] != nil }

    /// Asks for `job`'s pipelines after `delay`. The newest request wins, and at most one build per skin runs at a time.
    func request(_ job: Job, after delay: Duration) {
        pending[job.id] = job
        scheduleStart(job.id, after: delay)
    }

    private func scheduleStart(_ id: HUDSkinID, after delay: Duration) {
        guard timers[id] == nil else { return }
        timers[id] = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.timers[id] = nil
            self.startPending(id)
        }
    }

    private func startPending(_ id: HUDSkinID) {
        guard inFlight[id] == nil, let job = pending[id] else { return }
        pending[id] = nil
        if activeFingerprint[id] == job.fingerprint || failedKeys.contains(job.cacheKey) { return }
        if let cached = cache[job.cacheKey] {
            activate(job, pipelines: cached)
            return
        }
        launch(job)
    }

    private func launch(_ job: Job) {
        let id = job.id
        let fingerprint = job.fingerprint
        inFlight[id] = Build(job: job, remaining: job.passes.count)
        let device = HUDMetalBox<any MTLDevice>(value: job.device)
        let library = HUDMetalBox<any MTLLibrary>(value: job.library)
        let values = HUDMetalBox<MTLFunctionConstantValues>(value: SkinFunctionConstant.metalValues(job.constants))
        for pass in job.passes {
            let key = pass.key
            HUDPipelineBuilder.build(device: device, library: library, pass: pass, constants: values) { [weak self] state, failure in
                Task { @MainActor [weak self] in
                    self?.finishPass(id: id, fingerprint: fingerprint, key: key, state: state.value, failure: failure)
                }
            }
        }
    }

    private func finishPass(
        id: HUDSkinID, fingerprint: String, key: String,
        state: (any MTLRenderPipelineState)?, failure: String?
    ) {
        guard var build = inFlight[id], build.job.fingerprint == fingerprint else { return }
        if let state {
            build.results[key] = state
        } else if build.failure == nil {
            build.failure = failure ?? "unknown pipeline error"
        }
        build.remaining -= 1
        guard build.remaining <= 0 else {
            inFlight[id] = build
            return
        }
        inFlight[id] = nil
        if let message = build.failure {
            failedKeys.insert(build.job.cacheKey)
            onFailed?(id, message, activeFingerprint[id] != nil)
        } else {
            activate(build.job, pipelines: build.results)
        }
        if pending[id] != nil { scheduleStart(id, after: Self.cooldown) }
    }

    private func activate(_ job: Job, pipelines: [String: any MTLRenderPipelineState]) {
        let first = activeFingerprint[job.id] == nil
        activeFingerprint[job.id] = job.fingerprint
        for (key, state) in pipelines { activeByKey[key] = state }
        cache[job.cacheKey] = pipelines
        cacheOrder.removeAll { $0 == job.cacheKey }
        cacheOrder.append(job.cacheKey)
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
        onActivated?(job.id, first)
    }
}
