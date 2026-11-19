import AppKit
@preconcurrency import Metal
import QuartzCore
import VoicePointerCore

// MARK: - Uniforms

/// Mirrors `struct U` in Shaders/prelude.metal.h (80 bytes). Keep field order and types in sync.
struct HUDShaderUniforms: Sendable {
    var res: SIMD2<Float> = .zero       // drawable size, pixels
    var anchor: SIMD2<Float> = .zero    // anchor, pixels, origin bottom-left
    var scale: Float = 2                // pixels per point
    var time: Float = 0
    var phase: Float = 0
    var level: Float = 0
    var peak: Float = 0
    var aim: Float = 0
    /// Since 0.5.94: the snapped aim (see ShaderSkin.snap), not the raw pointer progress. No shader read the old value.
    var aimRaw: Float = 0
    var appear: Float = 0
    var send: Float = 0
    var cancel: Float = 0
    var fade: Float = 0
    var dark: Float = 0
    var coreOnly: Float = 0
    var reduce: Float = 0
    var contrast: Float = 0
    var seed: Float = 0
}

// MARK: - Styles

enum ShaderPass: Sendable {
    /// Fullscreen triangle; the String is the skin name `<name>` (`skin_<name>` in skin_*.hsl).
    case fullscreen(String)
    /// Point sprites; `part_<name>` / `partColor_<name>` in skin_*.hsl, drawn `count` times.
    case particles(String, Int)
}

struct ShaderStyle: Sendable {
    let id: HUDSkinID
    let passes: [ShaderPass]
    let sendDuration: Double
    let cancelDuration: Double
    let keepDuration: Double
    /// How this skin draws its Send / Cancel labels (each skin has its own).
    let labels: HUDLabelStyle

    init(
        id: HUDSkinID, passes: [ShaderPass],
        sendDuration: Double, cancelDuration: Double, keepDuration: Double,
        labels: HUDLabelStyle = .standard
    ) {
        self.id = id
        self.passes = passes
        self.sendDuration = sendDuration
        self.cancelDuration = cancelDuration
        self.keepDuration = keepDuration
        self.labels = labels
    }

    static func style(for id: HUDSkinID) -> ShaderStyle? {
        switch id {
        // 玻璃珠, 火苗, 3D 玻璃, 液滴融合 and 镜面铬 are retired (2026-11-10); their skin_*.hsl files stay unused.
        case .classic, .liquidGlass, .frosted, .miniDisc, .miniMorph, .waterDrop, .flame, .glassDisc, .frostDisc, .metaballs,
             .liquidChrome, .ripple:
            return nil
        case .astra:
            return ShaderStyle(id: id, passes: [.fullscreen("astra")], sendDuration: 0.50, cancelDuration: 0.45, keepDuration: 0.24, labels: .cosmic)
        case .liquidMetal:
            return ShaderStyle(id: id, passes: [.fullscreen("liquidmetal")], sendDuration: 0.42, cancelDuration: 0.34, keepDuration: 0.22, labels: .metal)
        case .dither:
            return ShaderStyle(id: id, passes: [.fullscreen("dither")], sendDuration: 0.45, cancelDuration: 0.40, keepDuration: 0.22, labels: .pixel)
        case .blackHole:
            return ShaderStyle(id: id, passes: [.fullscreen("blackhole")], sendDuration: 0.50, cancelDuration: 0.45, keepDuration: 0.24, labels: .cosmic)
        case .particles:
            return ShaderStyle(id: id, passes: [.fullscreen("particlesglow"), .particles("particles", 1600)], sendDuration: 0.55, cancelDuration: 0.45, keepDuration: 0.24, labels: .particle)
        case .inkSprite:
            return ShaderStyle(id: id, passes: [.fullscreen("inksprite")], sendDuration: 0.50, cancelDuration: 0.50, keepDuration: 0.24, labels: .ink)
        case .bubble:
            return ShaderStyle(id: id, passes: [.fullscreen("bubble")], sendDuration: 0.60, cancelDuration: 0.35, keepDuration: 0.24, labels: .bubble)
        case .ferrofluid:
            return ShaderStyle(id: id, passes: [.fullscreen("ferro")], sendDuration: 0.45, cancelDuration: 0.40, keepDuration: 0.22, labels: .chrome)
        case .voiceLine:
            return ShaderStyle(id: id, passes: [.fullscreen("voiceline")], sendDuration: 0.42, cancelDuration: 0.40, keepDuration: 0.22, labels: .line)
        case .plasma:
            return ShaderStyle(id: id, passes: [.fullscreen("plasma")], sendDuration: 0.50, cancelDuration: 0.45, keepDuration: 0.24, labels: .chrome)
        }
    }

    /// Every shader entry name used by any style (unique), for wrapper generation.
    static var allShaderNames: [(name: String, particles: Bool)] {
        var seen = Set<String>()
        var out: [(name: String, particles: Bool)] = []
        for id in HUDSkinID.allCases {
            guard let style = style(for: id) else { continue }
            for pass in style.passes {
                let entry: (name: String, particles: Bool)
                switch pass {
                case .fullscreen(let name): entry = (name: name, particles: false)
                case .particles(let name, _): entry = (name: name, particles: true)
                }
                if seen.insert((entry.particles ? "p:" : "f:") + entry.name).inserted {
                    out.append(entry)
                }
            }
        }
        return out
    }
}

// MARK: - Bundled library and asynchronously prepared pipelines

extension Notification.Name {
    /// Posted on the main thread after every compile attempt and when a pipeline fails to build.
    static var hudShaderLibraryDidChange: Notification.Name { Notification.Name("HUDShaderLibraryDidChange") }
}

@MainActor
final class HUDShaderLibrary: NSObject {
    static let shared = HUDShaderLibrary()

    let device: (any MTLDevice)?
    let queue: (any MTLCommandQueue)?
    private var library: (any MTLLibrary)?
    /// Bounded diagnostic text; nil when compilation and requested pipelines are healthy.
    private(set) var lastError: String?

    private let shaderFolder: URL?
    private var compilationStarted = false
    private var compilationFailed = false
    private var availableFunctions: Set<String> = []
    private var pipelines: [String: any MTLRenderPipelineState] = [:]
    private var requestedStyles: Set<HUDSkinID> = []
    private var buildingStyles: Set<HUDSkinID> = []
    private var readyStyles: Set<HUDSkinID> = []
    private var failedStyles: Set<HUDSkinID> = []
    private var remainingPipelines: [HUDSkinID: Int] = [:]
    private var diagnosticKeys: Set<String> = []
    private var diagnosticMessages: [String] = []
    /// Skins with tunable parameters (Astra, black hole) draw with specialised pipelines built from the
    /// parameter store's values (SkinSpecializedPipelines.swift); every other skin uses `pipelines`.
    private let specialized: HUDSpecializedPipelines
    private var paramObserver: (any NSObjectProtocol)?
    /// Quiet time after the last parameter change before a rebuild starts, so a dragged slider issues one build.
    private static let parameterDebounce: Duration = .milliseconds(80)

    private struct PipelineRequest {
        let key: String
        let descriptor: MTLRenderPipelineDescriptor
    }

    private struct ShaderProgram {
        let source: String
        let functions: Set<String>
    }

    private override init() {
        let dev = MTLCreateSystemDefaultDevice()
        device = dev
        queue = dev?.makeCommandQueue()
        shaderFolder = Bundle.main.resourceURL?.appendingPathComponent("HUDShaders", isDirectory: true)
        specialized = HUDSpecializedPipelines()
        super.init()
        specialized.onActivated = { [weak self] id, first in
            self?.specializedDidActivate(id, first: first)
        }
        specialized.onFailed = { [weak self] id, message, hasActive in
            self?.specializedDidFail(id, message: message, hasActive: hasActive)
        }
        paramObserver = NotificationCenter.default.addObserver(
            forName: .skinParamsDidChange, object: nil, queue: nil
        ) { [weak self] notification in
            let skinKey = notification.object as? String
            Task { @MainActor [weak self] in
                self?.skinParamsDidChange(skinKey: skinKey)
            }
        }
    }

    /// Starts one background compile after app startup. Only the selected skin's
    /// pipelines are prepared until the chooser asks for live previews.
    func prepareAtStartup(selected: HUDSkinID) {
        if selected.isShaderSkin { requestedStyles.insert(selected) }
        beginCompilationIfNeeded()
    }

    func prepare(_ id: HUDSkinID) {
        guard id.isShaderSkin, !readyStyles.contains(id), !failedStyles.contains(id),
              !compilationFailed else { return }
        requestedStyles.insert(id)
        if library != nil { buildPipelines(for: id) }
        else { beginCompilationIfNeeded() }
    }

    func preparePreviews() {
        for id in HUDSkinID.shaderSkins { prepare(id) }
    }

    func isPrepared(_ id: HUDSkinID) -> Bool { readyStyles.contains(id) }

    private func beginCompilationIfNeeded() {
        guard !compilationStarted, !compilationFailed else { return }
        compilationStarted = true
        guard let device else {
            failCompilation(tag: "no-device", message: "Metal device unavailable")
            return
        }
        guard let folder = shaderFolder else {
            failCompilation(tag: "no-resource-folder", message: "Bundled HUDShaders resource folder unavailable")
            return
        }
        guard MemoryLayout<HUDShaderUniforms>.stride == 80 else {
            failCompilation(tag: "uniform-layout", message: "Shader uniform layout mismatch")
            return
        }

        guard let program = makeShaderProgram(in: folder) else {
            failCompilation(tag: "invalid-resources", message: "Bundled HUD shader source files are incomplete")
            return
        }
        let functions = program.functions
        device.makeLibrary(source: program.source, options: MTLCompileOptions()) { [weak self] library, error in
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let library else {
                    self.failCompilation(
                        tag: "compile",
                        message: String((failure ?? "Unknown Metal compiler error").prefix(1000))
                    )
                    return
                }
                self.library = library
                self.availableFunctions = functions
                for id in self.requestedStyles { self.buildPipelines(for: id) }
                self.publish()
            }
        }
    }

    private func makeShaderProgram(in folder: URL) -> ShaderProgram? {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let skinFiles = listing.filter { $0.hasPrefix("skin_") && $0.hasSuffix(".hsl") }.sorted()
        // 0.5.84 shipped without skin_glassdisc.hsl (it was missing from the resource list) and the old exact file
        // count turned every shader skin into 「预览暂不可用」. A missing file now only takes its own skins down: their
        // functions are not generated and those styles fail alone below.
        guard !skinFiles.isEmpty else { return nil }
        let files = ["prelude.metal.h", "common.hsl"] + skinFiles
        var source = ""
        for name in files {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            source += "#line 1 \"\(name)\"\n" + text + "\n"
        }

        var wrappers = "#line 1 \"generated-wrappers\"\n"
        var functions: Set<String> = ["v_full", "f_points"]
        for entry in ShaderStyle.allShaderNames {
            let name = entry.name
            if entry.particles {
                guard Self.defines(source, "part_" + name), Self.defines(source, "partColor_" + name) else { continue }
                wrappers += Self.particleWrapper(name)
                functions.insert("v_" + name)
            } else {
                guard Self.defines(source, "skin_" + name) else { continue }
                wrappers += Self.fullscreenWrapper(name)
                functions.insert("f_" + name)
            }
        }
        return ShaderProgram(source: source + wrappers, functions: functions)
    }

    private func buildPipelines(for id: HUDSkinID) {
        guard requestedStyles.contains(id), !readyStyles.contains(id), !failedStyles.contains(id),
              !buildingStyles.contains(id) else { return }
        guard let device, let library, let style = ShaderStyle.style(for: id) else {
            failStyle(id, message: "Shader pipeline preparation unavailable")
            return
        }
        if usesSpecialization(id) {
            buildSpecialized(id)
            return
        }
        if id.needsParamManifest {
            failStyle(id, message: "Skin parameter manifest unavailable")
            return
        }

        var requests: [PipelineRequest] = []
        for pass in style.passes {
            let vertex: String
            let fragment: String
            switch pass {
            case .fullscreen(let name):
                vertex = "v_full"
                fragment = "f_" + name
            case .particles(let name, _):
                vertex = "v_" + name
                fragment = "f_points"
            }
            guard availableFunctions.contains(vertex), availableFunctions.contains(fragment),
                  let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                failStyle(id, message: "Shader entry point missing")
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "\(vertex)|\(fragment)"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let color: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            requests.append(PipelineRequest(key: vertex + "|" + fragment, descriptor: descriptor))
        }

        guard !requests.isEmpty else {
            failStyle(id, message: "Shader style has no render pipelines")
            return
        }
        buildingStyles.insert(id)
        remainingPipelines[id] = requests.count
        for request in requests {
            let key = request.key
            device.makeRenderPipelineState(descriptor: request.descriptor) { [weak self] state, error in
                let failure = error?.localizedDescription
                Task { @MainActor [weak self] in
                    self?.finishPipeline(key, state: state, failure: failure, for: id)
                }
            }
        }
    }

    private func finishPipeline(
        _ key: String,
        state: (any MTLRenderPipelineState)?,
        failure: String?,
        for id: HUDSkinID
    ) {
        if let state {
            pipelines[key] = state
        } else {
            failStyle(id, message: String((failure ?? "Unknown pipeline error").prefix(1000)))
        }
        let remaining = max(0, (remainingPipelines[id] ?? 1) - 1)
        remainingPipelines[id] = remaining
        guard remaining == 0 else { return }
        remainingPipelines[id] = nil
        buildingStyles.remove(id)
        if !failedStyles.contains(id) {
            readyStyles.insert(id)
            NotificationCenter.default.post(name: .hudShaderLibraryDidChange, object: id)
        }
        publish()
    }

    private func failCompilation(tag: String, message: String) {
        compilationFailed = true
        recordFailure(tag: tag, message: message)
        requestedStyles.forEach { failedStyles.insert($0) }
        publish()
    }

    private func failStyle(_ id: HUDSkinID, message: String) {
        failedStyles.insert(id)
        recordFailure(tag: "pipeline-\(id.rawValue)", message: message)
        publish()
    }

    private func recordFailure(tag: String, message: String) {
        guard diagnosticKeys.insert(tag).inserted else { return }
        if diagnosticMessages.count < 8 { diagnosticMessages.append("\(tag): \(message)") }
        RuntimeTrace.record("hud shader fallback \(tag): \(message)")
    }

    /// Returns a prepared premultiplied-over pipeline. It never compiles on the render path.
    /// A tunable skin returns the specialised pipeline that is current now; a rebuild for new
    /// parameter values replaces it only once the new one is ready, so drawing never stops.
    func pipeline(vertex: String, fragment: String) -> (any MTLRenderPipelineState)? {
        let key = vertex + "|" + fragment
        return specialized.pipeline(forKey: key) ?? pipelines[key]
    }

    // MARK: Tunable skins

    /// True when `id` is built from the parameter store's values rather than as a plain pipeline.
    private func usesSpecialization(_ id: HUDSkinID) -> Bool {
        id.paramSkinKey != nil && SkinParamStore.shared.hasParams(id)
    }

    private func buildSpecialized(_ id: HUDSkinID) {
        guard let job = specializedJob(for: id) else {
            failStyle(id, message: "Shader entry point missing")
            return
        }
        buildingStyles.insert(id)
        specialized.request(job, after: .zero)
    }

    /// The pipelines `id` needs, specialised with the store's current values; nil when an entry point is missing.
    private func specializedJob(for id: HUDSkinID) -> HUDSpecializedPipelines.Job? {
        guard let device, let library, let style = ShaderStyle.style(for: id),
              let skinKey = id.paramSkinKey else { return nil }
        var passes: [HUDPipelineBuilder.PassSpec] = []
        for pass in style.passes {
            let spec: HUDPipelineBuilder.PassSpec
            switch pass {
            case .fullscreen(let name):
                spec = HUDPipelineBuilder.PassSpec(vertex: "v_full", fragment: "f_" + name)
            case .particles(let name, _):
                spec = HUDPipelineBuilder.PassSpec(vertex: "v_" + name, fragment: "f_points")
            }
            guard availableFunctions.contains(spec.vertex), availableFunctions.contains(spec.fragment) else {
                return nil
            }
            passes.append(spec)
        }
        guard !passes.isEmpty else { return nil }
        let constants = SkinParamStore.shared.functionConstants(skinKey)
        return HUDSpecializedPipelines.Job(
            id: id, skinKey: skinKey, passes: passes, constants: constants,
            fingerprint: SkinFunctionConstant.fingerprint(constants), device: device, library: library)
    }

    /// A parameter changed: rebuild that skin's pipelines in the background once the values settle.
    private func skinParamsDidChange(skinKey: String?) {
        guard library != nil, let skinKey, let id = HUDSkinID.skin(forParamKey: skinKey),
              usesSpecialization(id), readyStyles.contains(id) || buildingStyles.contains(id),
              let job = specializedJob(for: id) else { return }
        specialized.request(job, after: Self.parameterDebounce)
    }

    private func specializedDidActivate(_ id: HUDSkinID, first: Bool) {
        buildingStyles.remove(id)
        guard first else { return }
        readyStyles.insert(id)
        NotificationCenter.default.post(name: .hudShaderLibraryDidChange, object: id)
        publish()
    }

    private func specializedDidFail(_ id: HUDSkinID, message: String, hasActive: Bool) {
        buildingStyles.remove(id)
        if hasActive {
            // The pipeline being drawn stays; only the new values could not be built.
            recordFailure(tag: "params-\(id.rawValue)", message: message)
            publish()
        } else {
            failStyle(id, message: message)
        }
    }

    // MARK: Private

    private static func defines(_ source: String, _ name: String) -> Bool {
        source.range(of: "\\b" + name + "\\s*\\(", options: .regularExpression) != nil
    }

    private func publish() {
        let text = String(diagnosticMessages.joined(separator: "\n").prefix(4000))
        lastError = text.isEmpty ? nil : text
        NotificationCenter.default.post(name: .hudShaderLibraryDidChange, object: nil)
    }

    private static func fullscreenWrapper(_ n: String) -> String {
        """
        fragment float4 f_\(n)(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
            float2 fc = float2(in.pos.x, u.res.y - in.pos.y);
            float2 p = (fc - u.anchor) / u.scale;
            return skin_\(n)(p, u);
        }

        """
    }

    private static func particleWrapper(_ n: String) -> String {
        """
        vertex PV v_\(n)(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
            float4 ps = part_\(n)(int(vid), u);
            float2 px = u.anchor + ps.xy * u.scale;
            PV o; o.pos = float4(px / u.res * 2.0 - 1.0, 0.0, 1.0);
            o.size = max(ps.z * u.scale, 1.0);
            o.color = partColor_\(n)(int(vid), u);
            return o;
        }

        """
    }
}

// MARK: - Metal view (layer-hosting CAMetalLayer, driven by the view's display link)

/// Counts frames the GPU has not finished yet. Metal's completion handler runs
/// on its own thread, so the count is guarded by a lock.
private final class HUDFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var generation = 0

    func tryEnter(limit: Int) -> Bool {
        lock.withLock {
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }
    }

    func leave() {
        lock.withLock { inFlight = max(0, inFlight - 1) }
    }

    /// Frames queued before a `stop()` are dropped instead of waiting for a drawable that nobody wants.
    var currentGeneration: Int { lock.withLock { generation } }

    func isCurrent(_ candidate: Int) -> Bool { lock.withLock { generation == candidate } }

    func invalidate() { lock.withLock { generation &+= 1 } }
}

private struct HUDFrameDraw {
    let state: any MTLRenderPipelineState
    let type: MTLPrimitiveType
    let count: Int
}

/// One frame for the render queue. Command queues and pipeline states may be used from any thread, and the
/// layer is only ever asked for a drawable there, which Metal allows from any thread.
private struct HUDFrameJob: @unchecked Sendable {
    let layer: CAMetalLayer
    let queue: any MTLCommandQueue
    let draws: [HUDFrameDraw]
    let uniforms: HUDShaderUniforms
    let gate: HUDFrameGate
    let generation: Int
}

/// Notes drawable waits that would have frozen the main thread: one line per two seconds at most.
private final class HUDDrawableWaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine: UInt64 = 0
    private var suppressed = 0

    func note(nanoseconds: UInt64, gotDrawable: Bool) {
        guard nanoseconds >= 100_000_000 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let skipped: Int? = lock.withLock {
            guard now &- lastLine >= 2_000_000_000 else {
                suppressed += 1
                return nil
            }
            lastLine = now
            let others = suppressed
            suppressed = 0
            return others
        }
        guard let skipped else { return }
        RuntimeTrace.record("hud drawable wait ms=\(nanoseconds / 1_000_000) got=\(gotDrawable) alsoWaited=\(skipped)")
    }
}

/// Draws HUD frames on the view's own serial queue so the main thread never waits for a drawable.
///
/// `CAMetalLayer.nextDrawable()` waits, up to a second, whenever the compositor is not handing drawables back
/// (a busy GPU, a window nobody can see). Called on the main thread that froze the HUD and every gesture with it:
/// the hang samples of an idle app on 2026-09-30 had 25-75% of the main thread inside it, even with the frame
/// gate below, because the gate counts frames the GPU has not finished and not drawables the compositor has
/// not returned. Here the wait costs only that view's queue its time (one queue per view, so a preview that
/// cannot get a drawable never holds up the real HUD); a frame that gets no drawable is dropped, frames queued
/// before a `stop()` are skipped, and the gate keeps the main thread from piling up more work behind it.
private enum HUDFrameRenderer {
    private static let waits = HUDDrawableWaitLog()

    static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "com.kenyu.voicepointer.hud-render", qos: .userInteractive, autoreleaseFrequency: .workItem)
    }

    static func submit(_ job: HUDFrameJob, on queue: DispatchQueue) {
        queue.async { render(job) }
    }

    private static func render(_ job: HUDFrameJob) {
        guard job.gate.isCurrent(job.generation) else {
            job.gate.leave()
            return
        }
        let asked = DispatchTime.now().uptimeNanoseconds
        let drawable = job.layer.nextDrawable()
        waits.note(nanoseconds: DispatchTime.now().uptimeNanoseconds &- asked, gotDrawable: drawable != nil)
        guard let drawable else {
            job.gate.leave()
            return
        }
        let pass = MTLRenderPassDescriptor()
        let target: MTLRenderPassColorAttachmentDescriptor = pass.colorAttachments[0]
        target.texture = drawable.texture
        target.loadAction = .clear
        target.storeAction = .store
        target.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let commands = job.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            job.gate.leave()
            return
        }
        var u = job.uniforms
        let length = MemoryLayout<HUDShaderUniforms>.stride
        for draw in job.draws {
            encoder.setRenderPipelineState(draw.state)
            encoder.setVertexBytes(&u, length: length, index: 0)
            encoder.setFragmentBytes(&u, length: length, index: 0)
            encoder.drawPrimitives(type: draw.type, vertexStart: 0, vertexCount: draw.count)
        }
        encoder.endEncoding()
        let gate = job.gate
        commands.addCompletedHandler { @Sendable _ in gate.leave() }  // Metal thread: must not inherit MainActor
        commands.present(drawable)
        commands.commit()
    }
}

@MainActor
final class ShaderHUDView: NSView {
    let metalLayer = CAMetalLayer()
    var passes: [ShaderPass] = []
    var uniforms = HUDShaderUniforms()
    /// Overall size of the skin this view draws (see `HUDLayout.clampedScale`). The view is that many times
    /// larger than the normal panel, and the shader's coordinates are scaled by the same factor.
    var layoutScale: CGFloat = 1
    /// Called once per frame with dt (seconds) before rendering; the owner updates `uniforms` here.
    var onFrame: (@MainActor (Double) -> Void)?

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// Preferred frame rate; settings previews can run slower than the live HUD.
    var frameRate: Float = 60 {
        didSet {
            guard frameRate != oldValue, link != nil else { return }
            stopLink()
            startLink()
        }
    }
    private var renderingRequested = false
    /// At most two frames queued or with the GPU. The drawable is asked for on the render queue
    /// (`HUDFrameRenderer`), never on the main thread: waiting for it there froze the HUD and the gesture
    /// handling with it (hang samples 2026-09-29 and 2026-09-30: 25-97% of the main thread inside `nextDrawable`).
    private let frameGate = HUDFrameGate()
    private let renderQueue = HUDFrameRenderer.makeQueue()
    /// What the layer was last given. The main thread never reads them back from the layer: a layer whose
    /// `nextDrawable()` is waiting on another thread can hold its lock against such a read.
    private var drawableSizeCache = CGSize.zero
    private var contentsScaleCache: CGFloat = 1
    private var loadWindowStart: CFTimeInterval = 0
    private var renderedTicks = 0
    private var skippedTicks = 0
    private var calmWindows = 0
    private var reducedForLoad = false

    private var effectiveFrameRate: Float { reducedForLoad ? min(frameRate, 30) : frameRate }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = metalLayer          // layer-hosting: assign the layer before wantsLayer
        wantsLayer = true
        metalLayer.device = HUDShaderLibrary.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3
        updateDrawableSize()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        if renderingRequested, window != nil { startLink() } else { stopLink() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    /// Requests rendering while visible. A later window attachment starts the link.
    func start() {
        renderingRequested = true
        startLink()
    }

    /// Explicitly stops the display link even when the containing panel stays attached.
    func stop() {
        renderingRequested = false
        stopLink()
    }

    private func startLink() {
        guard link == nil, renderingRequested, window != nil else { return }
        let l = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        let fps = min(max(effectiveFrameRate, 10), 120)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: max(fps, 30), preferred: fps)
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
    }

    private func stopLink() {
        frameGate.invalidate()
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        loadWindowStart = 0
        renderedTicks = 0
        skippedTicks = 0
        calmWindows = 0
        reducedForLoad = false
    }

    /// Under sustained GPU load (a heavy skin, or the app being typed into keeping
    /// the GPU busy) render at 30 fps; back to the preferred rate after ten calm
    /// seconds. Each HUD appearance starts again at the preferred rate.
    private func noteTick(rendered: Bool) {
        if rendered { renderedTicks += 1 } else { skippedTicks += 1 }
        let now = CACurrentMediaTime()
        if loadWindowStart == 0 { loadWindowStart = now }
        guard now - loadWindowStart >= 1 else { return }
        let total = renderedTicks + skippedTicks
        let skippedShare = total > 0 ? Double(skippedTicks) / Double(total) : 0
        renderedTicks = 0
        skippedTicks = 0
        loadWindowStart = now
        if !reducedForLoad {
            guard frameRate > 30, skippedShare > 0.2 else { return }
            reducedForLoad = true
            calmWindows = 0
            applyLinkRate()
            RuntimeTrace.record("hud gpu busy skipped=\(Int(skippedShare * 100))% fps=30")
        } else {
            calmWindows = skippedShare == 0 ? calmWindows + 1 : 0
            guard calmWindows >= 10 else { return }
            reducedForLoad = false
            applyLinkRate()
            RuntimeTrace.record("hud gpu calm fps=\(Int(frameRate))")
        }
    }

    private func applyLinkRate() {
        let fps = min(max(effectiveFrameRate, 10), 120)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: max(fps, 30), preferred: fps)
    }

    private func updateDrawableSize() {
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
        guard size != drawableSizeCache || s != contentsScaleCache else { return }
        drawableSizeCache = size
        contentsScaleCache = s
        Anim.quiet {
            metalLayer.contentsScale = s
            metalLayer.drawableSize = size
        }
    }

    @objc private func displayLinkFired(_ sender: CADisplayLink) {
        let now = sender.targetTimestamp
        let dt = lastTimestamp > 0 ? min(max(now - lastTimestamp, 0), 0.1) : 1.0 / 60
        lastTimestamp = now
        onFrame?(dt)
        render()
    }

    private func render() {
        let lib = HUDShaderLibrary.shared
        guard let queue = lib.queue else { return }
        let size = drawableSizeCache
        guard size.width >= 1, size.height >= 1 else { return }

        // The view covers the panel from its origin, so the anchor is HUDLayout.anchor(scale:) in view points.
        // `scale` is pixels per point; the shader works in normal-size points, so it also carries the overall size.
        let layout = HUDLayout.clampedScale(layoutScale)
        let scale = Float(contentsScaleCache)
        let panelAnchor = HUDLayout.anchor(scale: layout)
        let anchor = CGPoint(x: panelAnchor.x - frame.minX, y: panelAnchor.y - frame.minY)
        uniforms.res = SIMD2<Float>(Float(size.width), Float(size.height))
        uniforms.scale = scale * Float(layout)
        uniforms.anchor = SIMD2<Float>(Float(anchor.x) * scale, Float(anchor.y) * scale)

        var draws: [HUDFrameDraw] = []
        for pass in passes {
            switch pass {
            case .fullscreen(let name):
                if let state = lib.pipeline(vertex: "v_full", fragment: "f_" + name) {
                    draws.append(HUDFrameDraw(state: state, type: .triangle, count: 3))
                }
            case .particles(let name, let count):
                if count > 0, let state = lib.pipeline(vertex: "v_" + name, fragment: "f_points") {
                    draws.append(HUDFrameDraw(state: state, type: .point, count: count))
                }
            }
        }

        guard !draws.isEmpty else { return }
        guard frameGate.tryEnter(limit: 2) else {
            noteTick(rendered: false)
            return
        }
        HUDFrameRenderer.submit(HUDFrameJob(
            layer: metalLayer, queue: queue, draws: draws, uniforms: uniforms,
            gate: frameGate, generation: frameGate.currentGeneration
        ), on: renderQueue)
        noteTick(rendered: true)
    }
}

// MARK: - Labels (each skin styles its own Send / Cancel)

struct HUDRGBA: Sendable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) {
        self.r = CGFloat(r) / 255; self.g = CGFloat(g) / 255; self.b = CGFloat(b) / 255; self.a = a
    }
    static func white(_ a: CGFloat) -> HUDRGBA { HUDRGBA(255, 255, 255, a) }
    static func black(_ a: CGFloat) -> HUDRGBA { HUDRGBA(0, 0, 0, a) }
    func mix(_ o: HUDRGBA, _ t: CGFloat) -> HUDRGBA {
        let k = min(max(t, 0), 1)
        var c = self
        c.r += (o.r - r) * k; c.g += (o.g - g) * k; c.b += (o.b - b) * k; c.a += (o.a - a) * k
        return c
    }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var key: Int {
        let q = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return ((q(r) * 256 + q(g)) * 256 + q(b)) * 256 + q(a)
    }
}

struct HUDLabelPalette: Sendable {
    var base: HUDRGBA        // resting text
    var halo: HUDRGBA        // resting legibility halo (shadow)
    var send: HUDRGBA        // text when Send is aimed
    var sendGlow: HUDRGBA    // glow when Send is aimed (the label becomes a lamp)
    var cancel: HUDRGBA
    var cancelGlow: HUDRGBA
}

struct HUDLabelStyle: Sendable {
    enum Face: Sendable { case text, rounded, mono, serif }
    /// Labels follow a circle of this radius around the anchor; nil = straight labels `offset` above / below.
    var arcRadius: CGFloat?
    var offset: CGFloat = 76
    var size: CGFloat = 13
    var weight: CGFloat = 0          // NSFont.Weight raw value
    var face: Face = .text
    var kern: CGFloat = 0.3
    var uppercase = false
    var aimScale: CGFloat = 1.10
    var restGlow: CGFloat = 4.5      // halo radius at rest
    var aimGlow: CGFloat = 7         // glow radius when aimed
    var light: HUDLabelPalette
    var dark: HUDLabelPalette

    func font() -> NSFont {
        let w = NSFont.Weight(rawValue: weight)
        switch face {
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: w)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: w)
            if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: w)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .text: return NSFont.systemFont(ofSize: size, weight: w)
        }
    }

    /// The same style drawn `k` times larger: radii, offsets, font size, tracking and glow radii scale together.
    func scaled(by k: CGFloat) -> HUDLabelStyle {
        guard k != 1 else { return self }
        var out = self
        out.arcRadius = arcRadius.map { $0 * k }
        out.offset = offset * k
        out.size = size * k
        out.kern = kern * k
        out.restGlow = restGlow * k
        out.aimGlow = aimGlow * k
        return out
    }

    private static let sendGreenL = HUDRGBA(24, 150, 68, 1), sendGreenD = HUDRGBA(92, 232, 140, 1)
    private static let cancelRedL = HUDRGBA(214, 58, 64, 1), cancelRedD = HUDRGBA(255, 120, 120, 1)

    /// The original straight labels (other shader skins until they get their own).
    static let standard = HUDLabelStyle(
        arcRadius: nil,
        light: HUDLabelPalette(base: .black(0.45), halo: .white(0.9), send: sendGreenL, sendGlow: HUDRGBA(52, 199, 89, 0.55),
                               cancel: .black(0.85), cancelGlow: .white(0.9)),
        dark: HUDLabelPalette(base: .white(0.62), halo: .black(0.9), send: sendGreenD, sendGlow: HUDRGBA(74, 222, 128, 0.6),
                              cancel: .white(0.95), cancelGlow: .black(0.9)))

    /// Liquid metal: engraved small caps close around the drop; the aimed label turns into a coloured lamp.
    static let metal = HUDLabelStyle(
        arcRadius: 44, size: 10.5, weight: 0.3, kern: 1.6, uppercase: true, aimScale: 1.12,
        restGlow: 4, aimGlow: 8,
        light: HUDLabelPalette(base: HUDRGBA(60, 64, 74, 0.72), halo: .white(0.95), send: sendGreenL, sendGlow: HUDRGBA(60, 230, 120, 0.85),
                               cancel: cancelRedL, cancelGlow: HUDRGBA(255, 90, 90, 0.75)),
        dark: HUDLabelPalette(base: HUDRGBA(206, 212, 224, 0.78), halo: .black(0.85), send: sendGreenD, sendGlow: HUDRGBA(70, 255, 140, 0.9),
                              cancel: cancelRedD, cancelGlow: HUDRGBA(255, 80, 80, 0.8)))

    /// Glass bead: light, airy lowercase close to the bead.
    static let glass = HUDLabelStyle(
        arcRadius: 44, size: 11.5, weight: 0.23, kern: 0.9, aimScale: 1.12,
        restGlow: 4.5, aimGlow: 8,
        light: HUDLabelPalette(base: HUDRGBA(40, 52, 72, 0.62), halo: .white(0.95), send: sendGreenL, sendGlow: HUDRGBA(60, 230, 120, 0.8),
                               cancel: cancelRedL, cancelGlow: HUDRGBA(255, 90, 90, 0.7)),
        dark: HUDLabelPalette(base: HUDRGBA(214, 228, 246, 0.74), halo: .black(0.85), send: sendGreenD, sendGlow: HUDRGBA(70, 255, 140, 0.85),
                              cancel: cancelRedD, cancelGlow: HUDRGBA(255, 80, 80, 0.75)))

    /// 小球 glass discs: the glass bead's lettering, round the larger disc.
    static let glassDisc = HUDLabelStyle(
        arcRadius: 60, size: 12, weight: 0.23, kern: 0.9, aimScale: 1.12,
        restGlow: 4.5, aimGlow: 8,
        light: HUDLabelPalette(base: HUDRGBA(40, 52, 72, 0.62), halo: .white(0.95), send: sendGreenL, sendGlow: HUDRGBA(60, 230, 120, 0.8),
                               cancel: cancelRedL, cancelGlow: HUDRGBA(255, 90, 90, 0.7)),
        dark: HUDLabelPalette(base: HUDRGBA(214, 228, 246, 0.74), halo: .black(0.85), send: sendGreenD, sendGlow: HUDRGBA(70, 255, 140, 0.85),
                              cancel: cancelRedD, cancelGlow: HUDRGBA(255, 80, 80, 0.75)))

    static let chrome = HUDLabelStyle(
        arcRadius: 55, size: 10.5, weight: 0.3, kern: 1.8, uppercase: true,
        light: HUDLabelPalette(base: .black(0.55), halo: .white(0.95), send: sendGreenL, sendGlow: HUDRGBA(52, 199, 89, 0.7),
                               cancel: cancelRedL, cancelGlow: HUDRGBA(255, 90, 90, 0.6)),
        dark: HUDLabelPalette(base: .white(0.68), halo: .black(0.9), send: sendGreenD, sendGlow: HUDRGBA(74, 222, 128, 0.8),
                              cancel: cancelRedD, cancelGlow: HUDRGBA(255, 80, 80, 0.7)))

    /// Black hole: wide-tracked champagne small caps on the dark field around the hole (same in light and dark).
    /// Send lights up white-gold like the disk; Cancel turns to cold starlight.
    private static let cosmicPalette = HUDLabelPalette(
        base: HUDRGBA(255, 214, 160, 0.62), halo: .black(0.6), send: HUDRGBA(255, 240, 210, 1), sendGlow: HUDRGBA(255, 176, 70, 0.95),
        cancel: HUDRGBA(226, 232, 248, 1), cancelGlow: HUDRGBA(120, 140, 200, 0.6))
    static let cosmic = HUDLabelStyle(
        arcRadius: 47, size: 10, weight: 0.3, kern: 2.6, uppercase: true, aimScale: 1.08,
        restGlow: 3, aimGlow: 9,
        light: cosmicPalette, dark: cosmicPalette)

    static let pixel = HUDLabelStyle(
        arcRadius: 60, size: 10, weight: 0.4, face: .mono, kern: 1.2, uppercase: true,
        light: HUDLabelPalette(base: .black(0.60), halo: .white(0.95), send: HUDRGBA(18, 140, 60, 1), sendGlow: .white(0.95),
                               cancel: HUDRGBA(190, 40, 40, 1), cancelGlow: .white(0.95)),
        dark: HUDLabelPalette(base: .white(0.72), halo: .black(0.95), send: HUDRGBA(102, 245, 150, 1), sendGlow: HUDRGBA(60, 200, 110, 0.6),
                              cancel: HUDRGBA(255, 120, 120, 1), cancelGlow: HUDRGBA(200, 60, 60, 0.5)))

    static let candy = HUDLabelStyle(
        arcRadius: 60, size: 12, weight: 0.3, face: .rounded, kern: 0.6,
        light: HUDLabelPalette(base: HUDRGBA(120, 70, 110, 0.55), halo: .white(0.95), send: HUDRGBA(232, 90, 40, 1), sendGlow: HUDRGBA(255, 170, 80, 0.7),
                               cancel: HUDRGBA(120, 80, 200, 1), cancelGlow: HUDRGBA(170, 130, 255, 0.6)),
        dark: HUDLabelPalette(base: HUDRGBA(255, 210, 230, 0.66), halo: .black(0.9), send: HUDRGBA(255, 190, 120, 1), sendGlow: HUDRGBA(255, 150, 70, 0.8),
                              cancel: HUDRGBA(190, 160, 255, 1), cancelGlow: HUDRGBA(140, 100, 255, 0.7)))

    /// 沙: plain black / white lettering like the grains (the earlier 粒子 lettering was blue).
    static let particle = HUDLabelStyle(
        arcRadius: 60, size: 10.5, weight: 0.23, kern: 2.0, uppercase: true,
        light: HUDLabelPalette(base: .black(0.55), halo: .white(0.95), send: sendGreenL, sendGlow: .white(0.95),
                               cancel: cancelRedL, cancelGlow: .white(0.95)),
        dark: HUDLabelPalette(base: .white(0.70), halo: .black(0.9), send: sendGreenD, sendGlow: HUDRGBA(60, 200, 110, 0.5),
                              cancel: cancelRedD, cancelGlow: HUDRGBA(200, 60, 60, 0.4)))

    /// 声线: light lowercase close round the ring.
    static let line = HUDLabelStyle(
        arcRadius: 46, size: 11.5, weight: 0.23, kern: 0.9, aimScale: 1.10,
        restGlow: 4, aimGlow: 7,
        light: HUDLabelPalette(base: .black(0.50), halo: .white(0.95), send: sendGreenL, sendGlow: HUDRGBA(60, 230, 120, 0.7),
                               cancel: cancelRedL, cancelGlow: HUDRGBA(255, 90, 90, 0.6)),
        dark: HUDLabelPalette(base: .white(0.70), halo: .black(0.85), send: sendGreenD, sendGlow: HUDRGBA(70, 255, 140, 0.8),
                              cancel: cancelRedD, cancelGlow: HUDRGBA(255, 80, 80, 0.7)))

    /// 0.5.105 (Ken: the labels looked coarse; thin, small, capitals are fine; ink colours: Send a dark gold, Cancel a
    /// dark vermilion instead of the green and the bright red): light serif capitals, smaller and spaced out.
    static let ink = HUDLabelStyle(
        arcRadius: 60, size: 10.5, weight: NSFont.Weight.light.rawValue, face: .serif, kern: 2.2, uppercase: true,
        aimScale: 1.06,
        light: HUDLabelPalette(base: .black(0.50), halo: .white(0.95), send: HUDRGBA(150, 112, 42, 1), sendGlow: .white(0.95),
                               cancel: HUDRGBA(166, 44, 30, 1), cancelGlow: .white(0.95)),
        dark: HUDLabelPalette(base: .white(0.66), halo: .black(0.9), send: HUDRGBA(214, 178, 104, 1), sendGlow: HUDRGBA(170, 130, 60, 0.35),
                              cancel: HUDRGBA(222, 100, 76, 1), cancelGlow: HUDRGBA(160, 48, 36, 0.35)))

    static let bubble = HUDLabelStyle(
        arcRadius: 50, size: 12, weight: 0.23, face: .rounded, kern: 0.5,
        light: HUDLabelPalette(base: HUDRGBA(60, 90, 140, 0.55), halo: .white(0.95), send: HUDRGBA(24, 150, 68, 1), sendGlow: HUDRGBA(120, 230, 170, 0.6),
                               cancel: HUDRGBA(214, 58, 64, 1), cancelGlow: HUDRGBA(255, 150, 150, 0.5)),
        dark: HUDLabelPalette(base: HUDRGBA(200, 225, 255, 0.66), halo: .black(0.9), send: HUDRGBA(120, 255, 190, 1), sendGlow: HUDRGBA(90, 220, 160, 0.7),
                              cancel: HUDRGBA(255, 150, 150, 1), cancelGlow: HUDRGBA(220, 80, 80, 0.6)))

    static let ember = HUDLabelStyle(
        arcRadius: 58, size: 10.5, weight: 0.3, kern: 2.0, uppercase: true,
        light: HUDLabelPalette(base: HUDRGBA(120, 60, 20, 0.58), halo: .white(0.95), send: HUDRGBA(220, 110, 10, 1), sendGlow: HUDRGBA(255, 180, 60, 0.9),
                               cancel: HUDRGBA(90, 90, 100, 1), cancelGlow: .white(0.9)),
        dark: HUDLabelPalette(base: HUDRGBA(255, 200, 150, 0.66), halo: .black(0.9), send: HUDRGBA(255, 220, 150, 1), sendGlow: HUDRGBA(255, 150, 40, 0.95),
                              cancel: HUDRGBA(170, 170, 180, 1), cancelGlow: .black(0.9)))
}

/// One label: glyph layers laid out on a circle around the anchor (or on a straight line), inside a
/// container that scales about the anchor, so "aim" makes the label grow slightly and move outward.
@MainActor
private final class HUDLabelLine {
    let container = CALayer()
    private var glyphs: [CATextLayer] = []
    private var colorKey = -1
    private var glowKey = -1

    /// `scale` is the skin's overall size: the label is built for the enlarged panel, with a larger font.
    init(text: String, top: Bool, style unscaledStyle: HUDLabelStyle, scale: CGFloat = 1) {
        let k = HUDLayout.clampedScale(scale)
        let style = unscaledStyle.scaled(by: k)
        let size = HUDLayout.panelSize(scale: k)
        let a = HUDLayout.anchor(scale: k)
        container.bounds = CGRect(origin: .zero, size: size)
        container.anchorPoint = CGPoint(x: a.x / size.width, y: a.y / size.height)
        container.position = a
        let font = style.font()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: style.kern]
        let chars = (style.uppercase ? text.uppercased() : text).map { String($0) }
        let advances = chars.map { ($0 as NSString).size(withAttributes: attrs).width }
        let total = advances.reduce(0, +) - style.kern
        let height = ceil(font.ascender - font.descender) + 2
        var cursor = -total / 2
        for (i, ch) in chars.enumerated() {
            let adv = advances[i]
            let mid = cursor + (adv - style.kern) / 2
            let g = CATextLayer()
            g.string = ch
            g.font = font
            g.fontSize = font.pointSize
            g.alignmentMode = .center
            g.bounds = CGRect(x: 0, y: 0, width: ceil(adv) + 6, height: height)
            g.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            g.shadowOffset = .zero
            if let r = style.arcRadius {
                // glyph centre on the circle; baseline tangent (reads left→right on top and bottom)
                // explicit types: an untyped ternary around `.pi` sends the type checker into a very long search
                let half: CGFloat = CGFloat.pi / 2
                let theta: CGFloat = top ? half - mid / r : mid / r - half
                let rot: CGFloat = top ? theta - half : theta + half
                g.position = CGPoint(x: a.x + cos(theta) * r, y: a.y + sin(theta) * r)
                g.transform = CATransform3DMakeRotation(rot, 0, 0, 1)
            } else {
                let y = a.y + (top ? style.offset : -style.offset)
                g.position = CGPoint(x: a.x + mid, y: y)
            }
            container.addSublayer(g)
            glyphs.append(g)
            cursor += adv
        }
    }

    func setScale(_ scale: CGFloat) {
        container.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    func setContentsScale(_ s: CGFloat) { glyphs.forEach { $0.contentsScale = s } }

    func setColor(_ c: HUDRGBA) {
        guard c.key != colorKey else { return }
        colorKey = c.key
        let cg = c.cg
        glyphs.forEach { $0.foregroundColor = cg }
    }

    func setGlow(_ c: HUDRGBA, radius: CGFloat) {
        let key = c.key &* 31 &+ Int(radius * 8)
        guard key != glowKey else { return }
        glowKey = key
        let cg = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        for g in glyphs {
            g.shadowColor = cg
            g.shadowOpacity = Float(c.a)
            g.shadowRadius = radius
        }
    }
}

@MainActor
final class ShaderLabels {
    private let style: HUDLabelStyle
    private var sendLine: HUDLabelLine
    private var cancelLine: HUDLabelLine
    private var env = HUDEnvironment()
    /// The skin's overall size, and the backing scale last applied to the glyph layers.
    private var layoutScale: CGFloat = 1
    private var pixelScale: CGFloat = 2
    private weak var host: CALayer?

    init(style: HUDLabelStyle) {
        self.style = style
        sendLine = HUDLabelLine(text: "Send", top: true, style: style)
        cancelLine = HUDLabelLine(text: "Cancel", top: false, style: style)
        sendLine.container.opacity = 0
        cancelLine.container.opacity = 0
    }

    func install(in host: CALayer) {
        self.host = host
        host.addSublayer(sendLine.container)
        host.addSublayer(cancelLine.container)
    }

    /// Rebuilds both labels for an overall size of `requested` (font, radii and glow sizes scale together).
    /// Used while the HUD is hidden.
    func setLayoutScale(_ requested: CGFloat) {
        let scale = HUDLayout.clampedScale(requested)
        guard abs(scale - layoutScale) > 0.0005 else { return }
        layoutScale = scale
        sendLine.container.removeFromSuperlayer()
        cancelLine.container.removeFromSuperlayer()
        sendLine = HUDLabelLine(text: "Send", top: true, style: style, scale: scale)
        cancelLine = HUDLabelLine(text: "Cancel", top: false, style: style, scale: scale)
        sendLine.container.opacity = 0
        cancelLine.container.opacity = 0
        Anim.quiet {
            sendLine.setContentsScale(pixelScale)
            cancelLine.setContentsScale(pixelScale)
        }
        if let host {
            host.addSublayer(sendLine.container)
            host.addSublayer(cancelLine.container)
        }
    }

    func apply(_ environment: HUDEnvironment, scale: CGFloat) {
        env = environment
        pixelScale = scale
        Anim.quiet {
            sendLine.setContentsScale(scale)
            cancelLine.setContentsScale(scale)
        }
    }

    /// `send` / `cancel` are the smoothed aim progress per side (0...1); `motion` is 0 with reduce motion.
    func update(send s: CGFloat, cancel c: CGFloat, motion: CGFloat, sendOpacity: CGFloat, cancelOpacity: CGFloat, hidden: Bool) {
        let pal = env.isDark ? style.dark : style.light
        var base = pal.base
        if env.increaseContrast { base.a = min(1, base.a + 0.25) }
        Anim.quiet {
            sendLine.container.isHidden = hidden
            cancelLine.container.isHidden = hidden
            sendLine.setScale(1 + (style.aimScale - 1) * s * motion)
            cancelLine.setScale(1 + (style.aimScale - 1) * c * motion)
            sendLine.setColor(base.mix(pal.send, s))
            cancelLine.setColor(base.mix(pal.cancel, c))
            sendLine.setGlow(pal.halo.mix(pal.sendGlow, s), radius: (style.restGlow + (style.aimGlow - style.restGlow) * s) * layoutScale)
            cancelLine.setGlow(pal.halo.mix(pal.cancelGlow, c), radius: (style.restGlow + (style.aimGlow - style.restGlow) * c) * layoutScale)
            sendLine.container.opacity = Float(min(max(sendOpacity, 0), 1))
            cancelLine.container.opacity = Float(min(max(cancelOpacity, 0), 1))
        }
    }
}

// MARK: - Skin (generic, driven by a ShaderStyle)

/// One step of a critically damped spring, x'' = ω²(target − x) − 2ωx', solved exactly (stable for any dt).
private func springStep(_ x: Double, _ v: Double, target: Double, omega w: Double, dt: Double) -> (Double, Double) {
    let c1 = x - target
    let c2 = v + w * c1
    let e = exp(-w * dt)
    return (target + (c1 + c2 * dt) * e, (c2 - w * (c1 + c2 * dt)) * e)
}

@MainActor
final class ShaderSkin: HUDSkin {
    let view: NSView
    let style: ShaderStyle
    private let gpu: ShaderHUDView
    private let overlay: HUDLayerView
    private let labels: ShaderLabels
    private var env = HUDEnvironment()
    private var coreOnly = false
    private var released = false
    private var releaseKind: HUDRelease?
    private var releaseDuration: Double = 0
    private var releaseStart: CFTimeInterval = 0
    private var feedbackActive = false
    private var toast: NSView?

    // Inputs
    private var levelIn: Double = 0
    private var pointer = HUDPointer()
    /// 2026-11-10 (Ken): a shape turning into the Send / Cancel symbol is not scrubbed by the pointer. Once the pointer
    /// crosses into Send or Cancel (the same committed classifier that lights the labels and decides the release) the
    /// change plays through on its own in `snapDuration`, and it plays back when the pointer leaves. -1…1, linear in time;
    /// the shaders ease it.
    /// 0.5.96 (Ken: going from Send straight to Cancel had to play all the way back to the middle first, far too long):
    /// the two sides are separate amounts, each 0…1. One falls while the other rises, so a change of side takes one
    /// duration and a shader can go from whatever shape it is in straight toward the other symbol.
    private var snapSend: Double = 0
    private var snapCancel: Double = 0
    /// 声纹's dots walk into the symbol one after another, which needs longer than a shape that simply changes.
    private var snapDuration: Double { style.id == .voiceLine ? 0.80 : 0.30 }
    /// Going from one side straight to the other (Ken, 2026-11-10: only this should be quick; the walk from the ring
    /// to a symbol keeps its own time).
    private let snapSwitchDuration: Double = 0.26

    // Per-frame state
    private var time: Double = 0
    private var level: Double = 0
    private var levelSlow: Double = 0
    private var peak: Double = 0
    private var phase: Double = 0
    private var aim: Double = 0
    private var aimVelocity: Double = 0
    private var aimTarget: Double = 0
    private var appear: Double = 0
    private var appearVelocity: Double = 0
    private var appearTarget: Double = 0
    private var releaseT: Double = 0
    private var send: Double = 0
    private var cancel: Double = 0
    private var fade: Double = 0
    private var feedbackT: Double = 0
    private var seed: Float = 0

    private var scale: CGFloat { view.window?.backingScaleFactor ?? 2 }

    /// Overall size of this skin, 1 = normal (see `setLayoutScale`).
    private(set) var layoutScale: CGFloat = 1

    init?(id: HUDSkinID) {
        guard let s = ShaderStyle.style(for: id) else { return nil }
        let rect = NSRect(origin: .zero, size: HUDLayout.panelSize)
        let root = NSView(frame: rect)
        root.wantsLayer = true
        let g = ShaderHUDView(frame: rect)
        g.passes = s.passes
        let o = HUDLayerView(frame: rect)
        let l = ShaderLabels(style: s.labels)
        l.install(in: o.host)
        root.addSubview(g)
        root.addSubview(o)
        style = s
        gpu = g
        overlay = o
        labels = l
        view = root
        gpu.onFrame = { [weak self] dt in self?.advance(dt) }
    }

    /// Preview frame rate (settings gallery); the live HUD defaults to 60.
    func setFrameRate(_ fps: Float) { gpu.frameRate = fps }

    /// Overall size (1 = normal): resizes the view tree to `HUDLayout.panelSize(scale:)`, rebuilds the labels
    /// and scales the shader's coordinates. It applies when the HUD appears, never while a gesture runs.
    func setLayoutScale(_ requested: CGFloat) {
        let layout = HUDLayout.clampedScale(requested)
        guard abs(layout - layoutScale) > 0.0005 else { return }
        layoutScale = layout
        let size = HUDLayout.panelSize(scale: layout)
        view.setFrameSize(size)
        let rect = NSRect(origin: .zero, size: size)
        gpu.frame = rect
        overlay.frame = rect
        gpu.layoutScale = layout
        labels.setLayoutScale(layout)
        labels.apply(env, scale: scale)
        updateLabels()
    }

    // MARK: HUDSkin

    func apply(_ environment: HUDEnvironment) {
        env = environment
        labels.apply(environment, scale: scale)
        writeUniforms()
        updateLabels()
    }

    func present(coreOnly: Bool) {
        self.coreOnly = coreOnly
        released = false
        releaseKind = nil
        releaseDuration = 0
        feedbackActive = false
        toast?.removeFromSuperview()
        toast = nil
        view.alphaValue = 1

        levelIn = 0
        pointer = HUDPointer()
        time = 0
        level = 0
        levelSlow = 0
        peak = 0
        phase = 0
        aim = 0
        aimVelocity = 0
        aimTarget = 0
        snapSend = 0
        snapCancel = 0
        appearTarget = 1
        appear = env.reduceMotion ? 1 : 0
        appearVelocity = 0
        releaseT = 0
        send = 0
        cancel = 0
        fade = 0
        feedbackT = 0
        seed = Float.random(in: 0..<1)

        labels.apply(env, scale: scale)
        writeUniforms()
        updateLabels()
        gpu.start()
    }

    func update(level: CGFloat) {
        guard !released else { return }
        levelIn = Double(min(max(level, 0), 1))
    }

    func update(pointer: HUDPointer) {
        guard !released else { return }
        self.pointer = pointer
    }

    func stopRendering() { gpu.stop() }

    func release(_ action: HUDRelease, completion: @escaping @MainActor () -> Void) {
        guard !released else { return }
        released = true
        releaseKind = action
        releaseT = 0
        releaseStart = CACurrentMediaTime()
        levelIn = 0
        if env.reduceMotion {
            releaseDuration = 0.12
        } else {
            switch action {
            case .send: releaseDuration = style.sendDuration
            case .cancel: releaseDuration = style.cancelDuration
            case .keep: releaseDuration = style.keepDuration
            }
        }
        Anim.after(releaseDuration + 0.03) { [weak self] in
            guard let self else { return }
            self.gpu.stop()
            completion()
        }
    }

    func showFeedback(_ message: String, completion: @escaping @MainActor () -> Void) {
        released = true
        feedbackActive = true
        feedbackT = 0
        levelIn = 0
        toast?.removeFromSuperview()
        let t = HUDGlassToast.make(message: message, center: HUDLayout.anchor(scale: layoutScale), layoutScale: layoutScale)
        view.addSubview(t)
        toast = t
        HUDGlassToast.fadeIn(t)
        Anim.after(2.2) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.view.animator().alphaValue = 0
            }
            Anim.after(0.21) { [weak self] in
                guard let self else { return }
                self.gpu.stop()
                completion()
            }
        }
    }

    // MARK: Frame

    private func advance(_ rawDt: Double) {
        let dt = rawDt
        let reduce = env.reduceMotion
        time += dt

        // Voice level: fast follower, slow follower, transient envelope.
        level += (levelIn - level) * (1 - exp(-dt / 0.05))
        levelSlow += (level - levelSlow) * (1 - exp(-dt / 0.35))
        peak = max(peak * exp(-dt / 0.25), min(1, max(0, level - levelSlow) * 2.5))
        phase += dt * (reduce ? 0.25 : (0.55 + 1.6 * level))

        // Aim: signed continuous progress (+ = Send / up), frozen once released.
        if !released {
            let p = Double(pointer.progress)
            aimTarget = coreOnly ? 0 : (pointer.dy >= 0 ? p : -p)
        }
        var sendTarget = snapSend > 0.5 ? 1.0 : 0.0, cancelTarget = snapCancel > 0.5 ? 1.0 : 0.0
        if let kind = releaseKind {
            sendTarget = kind == .send ? 1 : 0
            cancelTarget = kind == .cancel ? 1 : 0
        } else if !released {
            sendTarget = !coreOnly && pointer.aim == .send ? 1 : 0
            cancelTarget = !coreOnly && pointer.aim == .cancel ? 1 : 0
        }
        if reduce {
            snapSend = sendTarget
            snapCancel = cancelTarget
        } else {
            let switching = (sendTarget > 0.5 && snapCancel > 0.001) || (cancelTarget > 0.5 && snapSend > 0.001)
            let stepMax = dt / (switching ? min(snapSwitchDuration, snapDuration) : snapDuration)
            snapSend += min(max(sendTarget - snapSend, -stepMax), stepMax)
            snapCancel += min(max(cancelTarget - snapCancel, -stepMax), stepMax)
        }
        if reduce {
            aim = aimTarget
            aimVelocity = 0
        } else {
            (aim, aimVelocity) = springStep(aim, aimVelocity, target: aimTarget, omega: 18, dt: dt)
            if abs(aim) > 1 {
                aim = aim > 0 ? 1 : -1
                aimVelocity = 0
            }
        }

        // Presence.
        if reduce {
            appear = appearTarget
            appearVelocity = 0
        } else {
            (appear, appearVelocity) = springStep(appear, appearVelocity, target: appearTarget, omega: 22, dt: dt)
            appear = min(max(appear, 0), 1)
        }

        // Release / feedback progress.
        if let kind = releaseKind {
            // Never lag the wall clock (dt is clamped after stalls); completion is wall-clock timed.
            releaseT = max(releaseT + dt, CACurrentMediaTime() - releaseStart)
            let p = min(1, releaseT / max(releaseDuration, 0.001))
            if reduce {
                fade = p
            } else {
                switch kind {
                case .send: send = p
                case .cancel: cancel = p
                case .keep: fade = p
                }
            }
        }
        if feedbackActive {
            feedbackT += dt
            fade = min(1, feedbackT / 0.18)
        }

        writeUniforms()
        updateLabels()
    }

    private func writeUniforms() {
        var u = gpu.uniforms
        u.time = Float(time)
        u.phase = Float(phase)
        u.level = Float(level)
        u.peak = Float(peak)
        u.aim = Float(aim)
        // Both amounts in the one spare float: the Send amount in thousandths as the integer part, the Cancel amount
        // (0…0.999) as the fraction. common.hsl's snapSend / snapCancel take them apart.
        u.aimRaw = Float((snapSend * 1000).rounded(.down) + min(snapCancel, 0.999))
        u.appear = Float(appear)
        u.send = Float(send)
        u.cancel = Float(cancel)
        u.fade = Float(fade)
        u.dark = env.isDark ? 1 : 0
        u.coreOnly = coreOnly ? 1 : 0
        u.reduce = env.reduceMotion ? 1 : 0
        u.contrast = env.increaseContrast ? 1 : 0
        u.seed = seed
        gpu.uniforms = u
    }

    private func updateLabels() {
        let s = max(aim, 0)
        let c = max(-aim, 0)
        var sendMul = 1.0
        var cancelMul = 1.0
        if let kind = releaseKind {
            let span = max(min(0.15, releaseDuration), 0.001)
            let generic = 1 - min(1, releaseT / span)
            cancelMul = generic
            if kind == .send && !env.reduceMotion {
                // The Send label stays lit for the first 40% of a send release, then fades.
                sendMul = 1 - min(1, max(0, releaseT - 0.4 * releaseDuration) / span)
            } else {
                sendMul = generic
            }
        }
        if feedbackActive {
            sendMul *= 1 - fade
            cancelMul *= 1 - fade
        }
        labels.update(
            send: CGFloat(s),
            cancel: CGFloat(c),
            motion: env.reduceMotion ? 0 : 1,
            sendOpacity: CGFloat(appear * (1 - 0.75 * c) * sendMul),
            cancelOpacity: CGFloat(appear * (1 - 0.75 * s) * cancelMul),
            hidden: coreOnly
        )
    }
}
