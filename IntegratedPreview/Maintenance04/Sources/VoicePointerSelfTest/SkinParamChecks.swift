import Foundation
import VoicePointerCore

/// Skin editor parameter checks: the shipped manifest, store defaults and clamping, function-constant
/// coverage, overall-size limits, persistence and the "no manifest" fallback. Pure Foundation; the
/// manifest is read from the source tree (this executable has no app bundle).
@MainActor
enum SkinParamChecks {
    static func run() -> [String] {
        var failures: [String] = []
        let manifest: SkinParamManifest
        do {
            manifest = try SkinParamManifest.load(from: manifestURL())
        } catch {
            return ["skin_params.json must decode: \(error)"]
        }
        failures += checkManifest(manifest)
        failures += checkRawManifest()
        failures += checkStoreDefaults(manifest)
        failures += checkClamping(manifest)
        failures += checkConstants(manifest)
        failures += checkHudScale(manifest)
        failures += checkPresetsAndPersistence(manifest)
        failures += checkNotifications(manifest)
        failures += checkSyntheticManifests()
        failures += checkFailureModes(manifest)
        failures += checkSelectionMigration()
        return failures
    }

    // MARK: Fixtures

    private static func manifestURL() -> URL {
        // .../Maintenance04/Sources/VoicePointerSelfTest/SkinParamChecks.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/HUDShaders/skin_params.json")
    }

    private static func makeDefaults() -> (defaults: UserDefaults, name: String)? {
        let name = "VoicePointerSelfTest.SkinParams.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        return (defaults, name)
    }

    // MARK: Manifest

    private static func checkManifest(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        expect(manifest.version == 1, "manifest version must be 1")
        expect(manifest.hudScale.minimum == 0.7 && manifest.hudScale.maximum == 1.5,
               "hudScale range must be 0.7...1.5")
        expect(manifest.hudScale.defaultValue == 1, "hudScale default must be 1")
        expect(manifest.skins["astra"] != nil && manifest.skins["blackhole"] != nil,
               "manifest must describe astra and blackhole")

        var indexOwner: [Int: String] = [:]
        for (skinKey, skin) in manifest.skins {
            expect(!skin.params.isEmpty, "\(skinKey) must have parameters")
            expect(!skin.title.isEmpty, "\(skinKey) must have a title")
            let keys = skin.params.map(\.key)
            expect(Set(keys).count == keys.count, "\(skinKey) parameter keys must be unique")
            let indices = skin.params.map(\.index)
            expect(Set(indices).count == indices.count, "\(skinKey) constant indices must be unique")
            for definition in skin.params {
                let name = "\(skinKey).\(definition.key)"
                if let other = indexOwner[definition.index], other != skinKey {
                    failures.append("\(name) reuses constant index \(definition.index) of \(other)")
                }
                indexOwner[definition.index] = skinKey
                expect(definition.minimum < definition.maximum, "\(name) range must be non-empty")
                expect(definition.step > 0, "\(name) step must be positive")
                expect(!definition.group.isEmpty && !definition.label.isEmpty, "\(name) needs a group and a label")
                expect(definition.clamped(definition.defaultValue)?.isClose(to: definition.defaultValue, tolerance: 0) == true,
                       "\(name) default must lie inside its range and match its type")
            }
            expect(!skin.presetKeys.isEmpty, "\(skinKey) must have presets")
            for presetKey in skin.presetKeys {
                expect(skin.presetNames[presetKey] != nil, "\(skinKey) preset \(presetKey) needs a display name")
                expect(skin.presets[presetKey] != nil, "\(skinKey) preset \(presetKey) must exist")
            }
            expect(Set(skin.presetKeys).count == skin.presetKeys.count, "\(skinKey) preset keys must be unique")
            expect(Set(skin.groups).count == skin.groups.count && !skin.groups.isEmpty, "\(skinKey) groups must be unique")
        }
        return failures
    }

    /// Reads the JSON without the decoder, so a typo the decoder would tolerate (an unknown preset key, a
    /// default outside its range, a repeated index) still fails here.
    private static func checkRawManifest() -> [String] {
        var failures: [String] = []
        func number(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let data = try? Data(contentsOf: manifestURL()),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let skins = root["skins"] as? [String: Any] else {
            return ["skin_params.json must be a JSON object with a skins table"]
        }
        var indexOwner: [Int: String] = [:]
        for (skinKey, value) in skins {
            guard let skin = value as? [String: Any], let params = skin["params"] as? [[String: Any]] else {
                failures.append("\(skinKey) must have a params array")
                continue
            }
            var ranges: [String: (lower: Double, upper: Double)] = [:]
            var seenIndices = Set<Int>()
            for p in params {
                guard let key = p["key"] as? String, let index = p["index"] as? Int, let type = p["type"] as? String else {
                    failures.append("\(skinKey) has a parameter without key, index or type")
                    continue
                }
                let name = "\(skinKey).\(key)"
                if !seenIndices.insert(index).inserted { failures.append("\(name) repeats index \(index)") }
                if let other = indexOwner[index], other != skinKey { failures.append("\(name) shares index \(index) with \(other)") }
                indexOwner[index] = skinKey
                if type == "float" {
                    guard let lo = number(p["min"]), let hi = number(p["max"]), let def = number(p["default"]) else {
                        failures.append("\(name) needs numeric min, max and default")
                        continue
                    }
                    ranges[key] = (lo, hi)
                    if def < lo || def > hi { failures.append("\(name) default \(def) is outside \(lo)...\(hi)") }
                } else if type == "float3" {
                    ranges[key] = (0, 1)
                    let def = (p["default"] as? [Any])?.map { number($0) }
                    if def?.count != 3 || def?.contains(where: { $0 == nil }) == true {
                        failures.append("\(name) default must be three numbers")
                    }
                } else {
                    failures.append("\(name) has unknown type \(type)")
                }
            }
            let presets = skin["presets"] as? [String: Any] ?? [:]
            for (presetKey, presetValue) in presets {
                guard let values = presetValue as? [String: Any] else {
                    failures.append("\(skinKey) preset \(presetKey) must be an object")
                    continue
                }
                for (key, raw) in values {
                    guard let range = ranges[key] else {
                        failures.append("\(skinKey) preset \(presetKey) names unknown parameter \(key)")
                        continue
                    }
                    let components: [Double] = (raw as? [Any])?.compactMap { number($0) } ?? number(raw).map { [$0] } ?? []
                    if components.isEmpty || components.contains(where: { $0 < range.lower || $0 > range.upper }) {
                        failures.append("\(skinKey) preset \(presetKey) value for \(key) is missing or outside \(range.lower)...\(range.upper)")
                    }
                }
            }
        }
        return failures
    }

    // MARK: Store

    private static func checkStoreDefaults(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }
        let store = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        for (skinKey, skin) in manifest.skins {
            if !store.hasParams(skinKey) { failures.append("\(skinKey) must report parameters") }
            if store.hudScale(skinKey) != manifest.hudScale.defaultValue { failures.append("\(skinKey) hudScale must default to the manifest") }
            if !store.isAtDefaults(skinKey) { failures.append("\(skinKey) must start at defaults") }
            if store.activePreset(skinKey) == nil { failures.append("\(skinKey) factory values must match one preset") }
            for definition in skin.params where store.value(skinKey, definition.key) != definition.defaultValue {
                failures.append("\(skinKey).\(definition.key) store default must equal the manifest default")
            }
        }
        if store.value("astra", "noSuchParameter") != nil || store.value("noSuchSkin", "skyRadius") != nil {
            failures.append("unknown skins and parameters must return nil")
        }
        if store.hasParams("classic") { failures.append("skins outside the manifest must report no parameters") }
        return failures
    }

    private static func checkClamping(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }
        let store = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        guard let skin = manifest.skins["astra"],
              let scalar = skin.params.first(where: { $0.kind == .float }),
              let color = skin.params.first(where: { $0.kind == .float3 }) else {
            return ["astra must have a float and a float3 parameter"]
        }

        store.set("astra", scalar.key, .float(scalar.minimum - 1000))
        expect(store.float("astra", scalar.key) == scalar.minimum, "values below the minimum must clamp up")
        store.set("astra", scalar.key, .float(scalar.maximum + 1000))
        expect(store.float("astra", scalar.key) == scalar.maximum, "values above the maximum must clamp down")
        let mid = (scalar.minimum + scalar.maximum) / 2
        store.set("astra", scalar.key, .float(mid))
        expect(store.float("astra", scalar.key) == mid, "in-range values must be kept as they are")
        store.set("astra", scalar.key, .float(.nan))
        store.set("astra", scalar.key, .float(.infinity))
        store.set("astra", scalar.key, .vec3(0, 0, 0))
        expect(store.float("astra", scalar.key) == mid, "non-finite values and values of the wrong shape must be ignored")

        store.set("astra", color.key, .vec3(-5, 0.5, 9))
        if let c = store.vec3("astra", color.key) {
            expect(c.0 == color.minimum && c.1 == 0.5 && c.2 == color.maximum, "colour components must clamp to the range")
        } else {
            failures.append("a colour parameter must read back as three components")
        }
        store.set("astra", color.key, .float(0.3))
        expect(store.float("astra", color.key) == nil, "a scalar must not replace a colour")

        store.set("noSuchSkin", scalar.key, .float(1))
        store.set("astra", "noSuchParameter", .float(1))
        expect(store.value("astra", "noSuchParameter") == nil, "unknown parameters must stay unknown")
        return failures
    }

    private static func checkConstants(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }
        let store = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        for (skinKey, skin) in manifest.skins {
            let constants = store.functionConstants(skinKey)
            expect(constants.count == skin.params.count, "\(skinKey): one function constant per parameter")
            expect(constants.map(\.index) == skin.params.map(\.index).sorted(), "\(skinKey): constants must be in index order and cover every index")
            for constant in constants {
                guard let definition = skin.params.first(where: { $0.index == constant.index }) else {
                    failures.append("\(skinKey): constant \(constant.index) has no parameter")
                    continue
                }
                expect(constant.key == definition.key, "\(skinKey).\(definition.key): constant carries its key")
                switch (definition.kind, constant.value, definition.defaultValue) {
                case (.float, .float(let f), .float(let d)):
                    expect(f == Float(d), "\(skinKey).\(definition.key): default value must reach the constant")
                case (.float3, .float3(let v), .vec3(let x, let y, let z)):
                    expect(v == SIMD3<Float>(Float(x), Float(y), Float(z)), "\(skinKey).\(definition.key): colour components must keep their order")
                default:
                    failures.append("\(skinKey).\(definition.key): constant type must match the parameter type")
                }
            }
        }

        guard let skin = manifest.skins["astra"], let scalar = skin.params.first(where: { $0.kind == .float }) else {
            return failures + ["astra must have a float parameter"]
        }
        let before = SkinFunctionConstant.fingerprint(store.functionConstants("astra"))
        expect(before == SkinFunctionConstant.fingerprint(store.functionConstants("astra")), "the fingerprint must be stable")
        guard let original = store.float("astra", scalar.key) else {
            return failures + ["a float parameter must read back as a number"]
        }
        let delta = (scalar.maximum - scalar.minimum) / 4
        let other = original + delta <= scalar.maximum ? original + delta : original - delta
        store.set("astra", scalar.key, .float(other))
        let changed = SkinFunctionConstant.fingerprint(store.functionConstants("astra"))
        expect(changed != before, "changing a value must change the fingerprint")
        store.set("astra", scalar.key, .float(original))
        expect(SkinFunctionConstant.fingerprint(store.functionConstants("astra")) == before, "restoring a value must restore the fingerprint")
        return failures
    }

    private static func checkHudScale(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }
        let store = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        store.setHudScale("astra", 0.1)
        expect(store.hudScale("astra") == 0.7, "hudScale must clamp up to 0.7")
        store.setHudScale("astra", 9)
        expect(store.hudScale("astra") == 1.5, "hudScale must clamp down to 1.5")
        store.setHudScale("astra", 1.23)
        expect(store.hudScale("astra") == 1.23, "hudScale must keep in-range values")
        store.setHudScale("astra", .nan)
        expect(store.hudScale("astra") == 1.23, "a non-finite hudScale must be ignored")
        expect(store.hudScale("blackhole") == 1, "hudScale is per skin")
        store.setHudScale("classic", 1.4)
        expect(store.hudScale("classic") == 1, "skins outside the manifest keep scale 1")

        // A stored value written by another version must still be clamped on read.
        let blob = Data(#"{"blackhole":{"params":{},"hudScale":9.0},"astra":{"params":{"skyRadius":1000},"hudScale":0.01}}"#.utf8)
        temp.defaults.set(blob, forKey: SkinParamStore.defaultsKey)
        let reloaded = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        expect(reloaded.hudScale("blackhole") == 1.5 && reloaded.hudScale("astra") == 0.7, "stored hudScale must clamp on read")
        if let radius = manifest.skins["astra"]?.definition(forKey: "skyRadius") {
            expect(reloaded.float("astra", "skyRadius") == radius.maximum, "stored parameters must clamp on read")
        }
        return failures
    }

    private static func checkPresetsAndPersistence(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }
        let store = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        for (skinKey, skin) in manifest.skins {
            for presetKey in skin.presetKeys {
                guard let preset = skin.presets[presetKey] else { continue }
                expect(store.applyPreset(skinKey, presetKey), "\(skinKey): preset \(presetKey) must apply")
                expect(store.activePreset(skinKey) == presetKey, "\(skinKey): applied preset \(presetKey) must be the active one")
                for definition in skin.params {
                    let wanted = preset[definition.key] ?? definition.defaultValue
                    expect(store.value(skinKey, definition.key) == wanted, "\(skinKey).\(definition.key): preset value must be applied")
                }
            }
            expect(!store.applyPreset(skinKey, "noSuchPreset"), "\(skinKey): an unknown preset must be refused")
        }

        guard let skin = manifest.skins["astra"], let scalar = skin.params.first(where: { $0.kind == .float }) else {
            return failures + ["astra must have a float parameter"]
        }
        store.resetToDefaults("astra")
        expect(store.isAtDefaults("astra"), "reset must restore the defaults")
        store.setHudScale("astra", 1.3)
        store.set("astra", scalar.key, .float(scalar.maximum))
        expect(store.activePreset("astra") == nil || scalar.defaultValue == .float(scalar.maximum),
               "editing a value must leave the preset (custom)")
        expect(!store.isAtDefaults("astra"), "edited values are not the defaults")
        store.flush()

        let restored = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        expect(restored.float("astra", scalar.key) == scalar.maximum, "values must persist")
        expect(restored.hudScale("astra") == 1.3, "the overall size must persist")
        restored.resetToDefaults("astra")
        expect(restored.isAtDefaults("astra") && restored.hudScale("astra") == manifest.hudScale.defaultValue,
               "reset must restore values and size")
        let afterReset = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        expect(afterReset.isAtDefaults("astra"), "a reset must persist")
        return failures
    }

    private final class NotificationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String] = []
        func record(_ key: String?) { lock.withLock { keys.append(key ?? "?") } }
        var all: [String] { lock.withLock { keys } }
    }

    private static func checkNotifications(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }
        guard let skin = manifest.skins["astra"], let scalar = skin.params.first(where: { $0.kind == .float }),
              let presetKey = skin.presetKeys.first else { return ["astra needs a float parameter and a preset"] }
        let store = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        let log = NotificationLog()
        let token = NotificationCenter.default.addObserver(forName: .skinParamsDidChange, object: nil, queue: nil) { note in
            log.record(note.object as? String)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // A value that differs from the current one, so the first set is a real change.
        let target = store.float("astra", scalar.key) == scalar.maximum ? scalar.minimum : scalar.maximum
        store.set("astra", scalar.key, .float(target))
        store.set("astra", scalar.key, .float(target))
        store.setHudScale("astra", 1.2)
        store.applyPreset("astra", presetKey)
        store.resetToDefaults("astra")
        store.set("astra", scalar.key, .float(.nan))
        store.set("noSuchSkin", scalar.key, .float(1))
        if log.all != ["astra", "astra", "astra", "astra"] {
            failures.append("changes must post one notification each, and no-ops none (got \(log.all))")
        }
        return failures
    }

    // MARK: Synthetic manifests and failure modes

    private static let syntheticManifest = """
    {
     "version": 1,
     "host": {"hudScale": {"min": 0.7, "max": 1.5, "step": 0.01, "default": 1.0}},
     "skins": {
      "demo": {
       "title": "Demo",
       "presetNames": {"zeta": "Z", "alpha": "A", "mid": "M"},
       "params": [
        {"key": "a", "index": 5, "group": "G", "label": "A", "type": "float", "min": 0, "max": 10, "step": 1, "unit": "pt", "default": 4},
        {"key": "c", "index": 6, "group": "G", "label": "C", "type": "float3", "default": [0.1, 0.2, 0.3]}
       ],
       "presets": {"alpha": {"a": 1}, "mid": {"a": 5, "c": [1, 1, 1]}, "zeta": {"a": 9}}
      }
     }
    }
    """

    private static func checkSyntheticManifests() -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        do {
            let manifest = try SkinParamManifest.decode(Data(syntheticManifest.utf8))
            let skin = manifest.skins["demo"]
            expect(skin?.presetKeys == ["zeta", "alpha", "mid"], "presets must keep the order presetNames lists them (got \(skin?.presetKeys ?? []))")
            expect(skin?.presetTitle("zeta") == "Z" && skin?.presetTitle("other") == "other", "preset titles fall back to the key")
            expect(skin?.params.map(\.index) == [5, 6] && skin?.groups == ["G"], "params and groups keep manifest order")
            expect(skin?.definition(forKey: "c")?.defaultValue == .vec3(0.1, 0.2, 0.3), "colour defaults decode as three components")
            expect(skin?.definition(forKey: "c")?.minimum == 0 && skin?.definition(forKey: "c")?.maximum == 1, "colours default to the 0...1 range")
            expect(skin?.presets["mid"]?["c"] == .vec3(1, 1, 1), "preset colours decode")
        } catch {
            failures.append("the synthetic manifest must decode: \(error)")
        }

        let broken: [(String, String, String)] = [
            ("repeated constant index", "\"index\": 6", "\"index\": 5"),
            ("unknown type", "\"float3\"", "\"float4\""),
            ("float without max", "\"max\": 10, ", ""),
            ("unsupported version", "\"version\": 1", "\"version\": 2"),
            ("two-component colour", "[0.1, 0.2, 0.3]", "[0.1, 0.2]"),
            ("scalar default for a colour", "\"default\": [0.1, 0.2, 0.3]", "\"default\": 0.5"),
            ("empty range", "\"min\": 0, \"max\": 10", "\"min\": 3, \"max\": 3"),
        ]
        for (name, target, replacement) in broken {
            let text = syntheticManifest.replacingOccurrences(of: target, with: replacement)
            expect(text != syntheticManifest, "fixture for \(name) must change the text")
            expect((try? SkinParamManifest.decode(Data(text.utf8))) == nil, "a manifest with \(name) must be rejected")
        }
        expect((try? SkinParamManifest.decode(Data("not json".utf8))) == nil, "garbage must be rejected")
        expect((try? SkinParamManifest.decode(Data())) == nil, "an empty file must be rejected")
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-\(UUID().uuidString).json")
        expect((try? SkinParamManifest.load(from: missing)) == nil, "a missing file must be rejected")

        let values: [SkinParamValue] = [.float(2.5), .vec3(0.1, 0.2, 0.3)]
        for value in values {
            let data = try? JSONEncoder().encode([value])
            let back = data.flatMap { try? JSONDecoder().decode([SkinParamValue].self, from: $0) }
            expect(back == [value], "parameter values must survive a JSON round trip")
        }
        return failures
    }

    private static func checkFailureModes(_ manifest: SkinParamManifest) -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        guard let temp = makeDefaults() else { return ["temporary UserDefaults suite unavailable"] }
        defer { temp.defaults.removePersistentDomain(forName: temp.name) }

        // No manifest: the feature is off and every answer is neutral.
        let off = SkinParamStore(manifest: nil, defaults: temp.defaults)
        off.set("astra", "skyRadius", .float(50))
        off.setHudScale("astra", 1.4)
        expect(!off.isAvailable && !off.hasParams("astra"), "a store without a manifest reports no parameters")
        expect(off.value("astra", "skyRadius") == nil && off.functionConstants("astra").isEmpty, "a store without a manifest has no values")
        expect(off.hudScale("astra") == 1 && off.activePreset("astra") == nil && off.isAtDefaults("astra"), "a store without a manifest keeps scale 1")
        expect(!off.applyPreset("astra", "astra"), "a store without a manifest applies no preset")

        // A corrupt saved blob is ignored, not fatal.
        temp.defaults.set(Data("garbage".utf8), forKey: SkinParamStore.defaultsKey)
        let recovered = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        expect(recovered.isAtDefaults("astra") && recovered.isAtDefaults("blackhole"), "a corrupt saved blob falls back to defaults")
        recovered.setHudScale("astra", 1.1)
        recovered.flush()
        let reread = SkinParamStore(manifest: manifest, defaults: temp.defaults)
        expect(reread.hudScale("astra") == 1.1, "saving after a corrupt blob must write a valid one")
        return failures
    }

    /// The Astra default: selected once, and a skin chosen afterwards is never overridden. The keys are the ones
    /// HUDSkinPreferences uses (`hud.skin.v1`, `hud.skin.astraDefault.v1`).
    private static func checkSelectionMigration() -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        let selectionKey = "hud.skin.v1"
        let flagKey = "hud.skin.astraDefault.v1"
        guard let upgraded = makeDefaults(), let fresh = makeDefaults() else {
            return ["temporary UserDefaults suite unavailable"]
        }
        defer {
            upgraded.defaults.removePersistentDomain(forName: upgraded.name)
            fresh.defaults.removePersistentDomain(forName: fresh.name)
        }

        // An existing install with another skin selected.
        upgraded.defaults.set("liquidMetal", forKey: selectionKey)
        let first = SkinSelectionMigration.selectOnce(
            "astra", selectionKey: selectionKey, flagKey: flagKey, defaults: upgraded.defaults)
        expect(first, "the first run must select Astra")
        expect(upgraded.defaults.string(forKey: selectionKey) == "astra" && upgraded.defaults.bool(forKey: flagKey),
               "the first run must save Astra and set the flag")
        upgraded.defaults.set("classic", forKey: selectionKey)
        let second = SkinSelectionMigration.selectOnce(
            "astra", selectionKey: selectionKey, flagKey: flagKey, defaults: upgraded.defaults)
        expect(!second, "a later run must not migrate again")
        expect(upgraded.defaults.string(forKey: selectionKey) == "classic", "a skin chosen after the migration must be kept")

        // A fresh install with no saved choice.
        expect(fresh.defaults.string(forKey: selectionKey) == nil, "a fresh suite starts with no skin")
        let firstFresh = SkinSelectionMigration.selectOnce(
            "astra", selectionKey: selectionKey, flagKey: flagKey, defaults: fresh.defaults)
        expect(firstFresh && fresh.defaults.string(forKey: selectionKey) == "astra", "a fresh install must start on Astra")
        return failures
    }
}
