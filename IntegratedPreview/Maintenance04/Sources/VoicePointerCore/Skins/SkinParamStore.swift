import Foundation

public extension Notification.Name {
    /// Posted on the main thread after a skin's parameters or size changed. `object` is the skin key (a String).
    static let skinParamsDidChange = Notification.Name("VoicePointerSkinParamsDidChange")
}

/// One Metal function-constant value, ready to be specialised into a pipeline.
public struct SkinFunctionConstant: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case float(Float)
        case float3(SIMD3<Float>)
    }

    public let index: Int
    public let key: String
    public let value: Value

    /// A stable text key for a set of constants, used to cache specialised pipelines.
    public static func fingerprint(_ constants: [SkinFunctionConstant]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(constants.count)
        for constant in constants {
            switch constant.value {
            case .float(let x):
                parts.append("\(constant.index)=\(String(x.bitPattern, radix: 16))")
            case .float3(let v):
                let bits = [v.x, v.y, v.z].map { String($0.bitPattern, radix: 16) }
                parts.append("\(constant.index)=\(bits.joined(separator: "/"))")
            }
        }
        return parts.joined(separator: ",")
    }
}

/// What is persisted per skin (UserDefaults `hud.skinParams.v1`, one JSON blob for all skins).
struct SkinParamSaved: Codable, Equatable, Sendable {
    var params: [String: SkinParamValue] = [:]
    var hudScale: Double?
    /// The preset the values were last based on.
    var base: String?
}

/// Per-skin parameter values and overall size, persisted in UserDefaults.
///
/// Missing values fall back to the manifest default and every value is clamped to its range, so a
/// hand-edited or older blob can never produce an out-of-range constant. With no manifest (missing
/// or corrupt resource) nothing is tunable and every query returns the neutral answer.
@MainActor
public final class SkinParamStore {
    public static let shared = SkinParamStore()
    public static let defaultsKey = "hud.skinParams.v1"
    private static let saveDelay: Duration = .milliseconds(300)

    public let manifest: SkinParamManifest?
    private let defaults: UserDefaults
    private var saved: [String: SkinParamSaved]
    private var saveTask: Task<Void, Never>?

    public init(manifest: SkinParamManifest? = SkinParamManifest.loadBundled(), defaults: UserDefaults = .standard) {
        self.manifest = manifest
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            if let decoded = try? JSONDecoder().decode([String: SkinParamSaved].self, from: data) {
                saved = decoded
            } else {
                saved = [:]
                RuntimeTrace.record("skin params: saved values unreadable, using defaults")
            }
        } else {
            saved = [:]
        }
    }

    // MARK: Queries

    public var isAvailable: Bool { manifest != nil }

    public func hasParams(_ skinKey: String) -> Bool {
        guard let skin = manifest?.skins[skinKey] else { return false }
        return !skin.params.isEmpty
    }

    public func skin(_ skinKey: String) -> SkinParamManifest.Skin? { manifest?.skins[skinKey] }

    /// The effective value (saved, else default), clamped. nil for an unknown skin or parameter.
    public func value(_ skinKey: String, _ paramKey: String) -> SkinParamValue? {
        guard let definition = manifest?.skins[skinKey]?.definition(forKey: paramKey) else { return nil }
        return effective(skinKey, definition)
    }

    public func float(_ skinKey: String, _ paramKey: String) -> Double? {
        if case .float(let x)? = value(skinKey, paramKey) { return x }
        return nil
    }

    public func vec3(_ skinKey: String, _ paramKey: String) -> (Double, Double, Double)? {
        if case .vec3(let x, let y, let z)? = value(skinKey, paramKey) { return (x, y, z) }
        return nil
    }

    private func effective(_ skinKey: String, _ definition: SkinParamDefinition) -> SkinParamValue {
        if let stored = saved[skinKey]?.params[definition.key], let clamped = definition.clamped(stored) {
            return clamped
        }
        return definition.defaultValue
    }

    /// Overall size of the disc for this skin; 1 for skins without a manifest entry.
    public func hudScale(_ skinKey: String) -> Double {
        guard let manifest, manifest.skins[skinKey] != nil else { return 1 }
        let spec = manifest.hudScale
        let raw = saved[skinKey]?.hudScale ?? spec.defaultValue
        guard raw.isFinite else { return spec.defaultValue }
        return Swift.min(Swift.max(raw, spec.minimum), spec.maximum)
    }

    /// The preset whose values equal the current ones, or nil when the values are custom.
    public func activePreset(_ skinKey: String) -> String? {
        guard let skin = manifest?.skins[skinKey] else { return nil }
        for presetKey in skin.presetKeys {
            guard let preset = skin.presets[presetKey] else { continue }
            let matches = skin.params.allSatisfy { definition in
                let target = preset[definition.key] ?? definition.defaultValue
                return effective(skinKey, definition).isClose(to: target)
            }
            if matches { return presetKey }
        }
        return nil
    }

    /// True when every value and the size equal the manifest defaults.
    public func isAtDefaults(_ skinKey: String) -> Bool {
        guard let skin = manifest?.skins[skinKey] else { return true }
        let same = skin.params.allSatisfy { effective(skinKey, $0).isClose(to: $0.defaultValue) }
        return same && abs(hudScale(skinKey) - (manifest?.hudScale.defaultValue ?? 1)) <= 1e-9
    }

    /// The function constants for `skinKey`, one per parameter, in index order.
    public func functionConstants(_ skinKey: String) -> [SkinFunctionConstant] {
        guard let skin = manifest?.skins[skinKey] else { return [] }
        var out: [SkinFunctionConstant] = []
        out.reserveCapacity(skin.params.count)
        for definition in skin.params.sorted(by: { $0.index < $1.index }) {
            switch effective(skinKey, definition) {
            case .float(let x):
                out.append(SkinFunctionConstant(index: definition.index, key: definition.key, value: .float(Float(x))))
            case .vec3(let x, let y, let z):
                out.append(SkinFunctionConstant(
                    index: definition.index, key: definition.key,
                    value: .float3(SIMD3<Float>(Float(x), Float(y), Float(z)))))
            }
        }
        return out
    }

    // MARK: Changes

    /// Sets one parameter. A value of the wrong shape or a non-finite number is ignored; anything else is clamped.
    public func set(_ skinKey: String, _ paramKey: String, _ newValue: SkinParamValue) {
        guard let definition = manifest?.skins[skinKey]?.definition(forKey: paramKey),
              let clamped = definition.clamped(newValue) else { return }
        if effective(skinKey, definition).isClose(to: clamped, tolerance: 0) { return }
        var entry = saved[skinKey] ?? SkinParamSaved()
        entry.params[paramKey] = clamped
        saved[skinKey] = entry
        didChange(skinKey)
    }

    /// Sets the overall size, clamped to the manifest's range (0.7 ... 1.5 for the shipped manifest).
    public func setHudScale(_ skinKey: String, _ newValue: Double) {
        guard let manifest, manifest.skins[skinKey] != nil, newValue.isFinite else { return }
        let clamped = Swift.min(Swift.max(newValue, manifest.hudScale.minimum), manifest.hudScale.maximum)
        if clamped == hudScale(skinKey) { return }
        var entry = saved[skinKey] ?? SkinParamSaved()
        entry.hudScale = clamped
        saved[skinKey] = entry
        didChange(skinKey)
    }

    /// Replaces every parameter with the preset's values (parameters the preset omits get their default).
    /// The overall size is not part of a preset. Returns false for an unknown skin or preset.
    @discardableResult
    public func applyPreset(_ skinKey: String, _ presetKey: String) -> Bool {
        guard let skin = manifest?.skins[skinKey], let preset = skin.presets[presetKey] else { return false }
        var entry = saved[skinKey] ?? SkinParamSaved()
        var params: [String: SkinParamValue] = [:]
        for definition in skin.params {
            let wanted = preset[definition.key] ?? definition.defaultValue
            params[definition.key] = definition.clamped(wanted) ?? definition.defaultValue
        }
        entry.params = params
        entry.base = presetKey
        saved[skinKey] = entry
        didChange(skinKey)
        flush()
        return true
    }

    /// Back to the shipped look: every parameter and the overall size return to the manifest defaults.
    public func resetToDefaults(_ skinKey: String) {
        guard manifest?.skins[skinKey] != nil else { return }
        saved[skinKey] = nil
        didChange(skinKey)
        flush()
    }

    private func didChange(_ skinKey: String) {
        NotificationCenter.default.post(name: .skinParamsDidChange, object: skinKey)
        scheduleSave()
    }

    // MARK: Persistence

    /// Writes any pending change now (window close, app quit).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        writeNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.writeNow()
        }
    }

    private func writeNow() {
        if saved.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(saved) else {
            RuntimeTrace.record("skin params: could not encode saved values")
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
