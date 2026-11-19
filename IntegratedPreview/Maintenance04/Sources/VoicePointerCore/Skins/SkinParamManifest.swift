import Foundation

// Tunable shader parameters. The bundled Resources/HUDShaders/skin_params.json is the source of
// truth: each parameter is a Metal function constant (`index`), edited in the skin editor and
// specialised into the pipeline by the app. Pure Foundation; no UI or Metal types live here.

/// One parameter value: a scalar, or three components (colours are sRGB 0...1, no gamma).
public enum SkinParamValue: Sendable, Equatable, Codable {
    case float(Double)
    case vec3(Double, Double, Double)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .float(number)
            return
        }
        let numbers = try container.decode([Double].self)
        guard numbers.count == 3 else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected a number or an array of three numbers")
        }
        self = .vec3(numbers[0], numbers[1], numbers[2])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .float(let value): try container.encode(value)
        case .vec3(let x, let y, let z): try container.encode([x, y, z])
        }
    }

    /// True when both values have the same shape and every component differs by at most `tolerance`.
    public func isClose(to other: SkinParamValue, tolerance: Double = 1e-6) -> Bool {
        switch (self, other) {
        case (.float(let a), .float(let b)):
            return abs(a - b) <= tolerance
        case (.vec3(let a1, let a2, let a3), .vec3(let b1, let b2, let b3)):
            return abs(a1 - b1) <= tolerance && abs(a2 - b2) <= tolerance && abs(a3 - b3) <= tolerance
        default:
            return false
        }
    }
}

public struct SkinParamDefinition: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case float
        case float3
    }

    public let key: String
    /// Metal function-constant index.
    public let index: Int
    public let kind: Kind
    public let group: String
    public let label: String
    public let hint: String
    /// Float range. A float3 parameter clamps every component to the same range (0...1 unless the manifest says otherwise).
    public let minimum: Double
    public let maximum: Double
    public let step: Double
    public let unit: String
    public let defaultValue: SkinParamValue

    /// Clamps `value` into this parameter's range. nil when the shape does not match `kind` or a component is not finite.
    public func clamped(_ value: SkinParamValue) -> SkinParamValue? {
        Self.clamp(value, kind: kind, lower: minimum, upper: maximum)
    }

    fileprivate static func clamp(_ value: SkinParamValue, kind: Kind, lower: Double, upper: Double) -> SkinParamValue? {
        func limit(_ v: Double) -> Double { Swift.min(Swift.max(v, lower), upper) }
        switch (kind, value) {
        case (.float, .float(let x)):
            guard x.isFinite else { return nil }
            return .float(limit(x))
        case (.float3, .vec3(let x, let y, let z)):
            guard x.isFinite, y.isFinite, z.isFinite else { return nil }
            return .vec3(limit(x), limit(y), limit(z))
        default:
            return nil
        }
    }
}

// MARK: - Manifest

public struct SkinParamManifest: Sendable {
    public struct HudScaleSpec: Sendable, Equatable {
        public let label: String
        public let hint: String
        public let minimum: Double
        public let maximum: Double
        public let step: Double
        public let defaultValue: Double
    }

    public struct Skin: Sendable {
        public let key: String
        public let title: String
        public let params: [SkinParamDefinition]
        /// Group names in order of first appearance in `params`.
        public let groups: [String]
        /// Preset keys in the order the manifest lists `presetNames` (the order of the chips).
        public internal(set) var presetKeys: [String]
        public let presetNames: [String: String]
        public let presets: [String: [String: SkinParamValue]]

        public func definition(forKey key: String) -> SkinParamDefinition? {
            params.first { $0.key == key }
        }

        public func params(inGroup group: String) -> [SkinParamDefinition] {
            params.filter { $0.group == group }
        }

        public func presetTitle(_ key: String) -> String { presetNames[key] ?? key }
    }

    public static let resourceFolderName = "HUDShaders"
    public static let resourceFileName = "skin_params.json"

    public let version: Int
    public let hudScale: HudScaleSpec
    public internal(set) var skins: [String: Skin]

    static func invalid(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: message))
    }
}

// MARK: - JSON shape (file-private; the public types above are what the app sees)

private struct RawManifest: Decodable {
    struct HudScale: Decodable {
        var label: String?
        var hint: String?
        var min: Double
        var max: Double
        var step: Double?
        var defaultValue: Double
        enum CodingKeys: String, CodingKey {
            case label, hint, min, max, step
            case defaultValue = "default"
        }
    }

    struct Host: Decodable { var hudScale: HudScale }

    struct Param: Decodable {
        var key: String
        var index: Int
        var type: String
        var group: String?
        var label: String?
        var hint: String?
        var min: Double?
        var max: Double?
        var step: Double?
        var unit: String?
        var defaultValue: SkinParamValue
        enum CodingKeys: String, CodingKey {
            case key, index, type, group, label, hint, min, max, step, unit
            case defaultValue = "default"
        }
    }

    struct Skin: Decodable {
        var title: String
        var presetNames: [String: String]?
        var params: [Param]
        var presets: [String: [String: SkinParamValue]]?
    }

    var version: Int
    var host: Host
    var skins: [String: Skin]
}

// MARK: - Decoding and validation

extension SkinParamManifest: Decodable {
    public init(from decoder: any Decoder) throws {
        let raw = try RawManifest(from: decoder)
        guard raw.version == 1 else { throw Self.invalid("unsupported manifest version \(raw.version)") }
        let h = raw.host.hudScale
        guard h.min > 0, h.max >= h.min, h.defaultValue >= h.min, h.defaultValue <= h.max else {
            throw Self.invalid("hudScale range is inconsistent")
        }
        var built: [String: Skin] = [:]
        for (skinKey, rawSkin) in raw.skins {
            built[skinKey] = try Skin(key: skinKey, raw: rawSkin)
        }
        version = raw.version
        hudScale = HudScaleSpec(
            label: h.label ?? "", hint: h.hint ?? "",
            minimum: h.min, maximum: h.max, step: h.step ?? 0.01, defaultValue: h.defaultValue)
        skins = built
    }
}

extension SkinParamManifest.Skin {
    fileprivate init(key: String, raw: RawManifest.Skin) throws {
        var seenKeys = Set<String>()
        var seenIndices = Set<Int>()
        var built: [SkinParamDefinition] = []
        var groupOrder: [String] = []
        for p in raw.params {
            let name = "\(key).\(p.key)"
            guard !p.key.isEmpty, seenKeys.insert(p.key).inserted else {
                throw SkinParamManifest.invalid("\(name): empty or duplicate parameter key")
            }
            guard p.index >= 0, seenIndices.insert(p.index).inserted else {
                throw SkinParamManifest.invalid("\(name): negative or duplicate index \(p.index)")
            }
            guard let kind = SkinParamDefinition.Kind(rawValue: p.type) else {
                throw SkinParamManifest.invalid("\(name): unknown type '\(p.type)'")
            }
            let lower: Double
            let upper: Double
            switch kind {
            case .float:
                guard let lo = p.min, let hi = p.max else {
                    throw SkinParamManifest.invalid("\(name): float parameter needs min and max")
                }
                lower = lo
                upper = hi
            case .float3:
                lower = p.min ?? 0
                upper = p.max ?? 1
            }
            guard lower.isFinite, upper.isFinite, upper > lower else {
                throw SkinParamManifest.invalid("\(name): bad range")
            }
            guard let normalizedDefault = SkinParamDefinition.clamp(
                p.defaultValue, kind: kind, lower: lower, upper: upper) else {
                throw SkinParamManifest.invalid("\(name): default does not match type \(p.type)")
            }
            let group = p.group ?? ""
            if !groupOrder.contains(group) { groupOrder.append(group) }
            let declaredStep = p.step ?? 0
            built.append(SkinParamDefinition(
                key: p.key, index: p.index, kind: kind, group: group,
                label: p.label ?? p.key, hint: p.hint ?? "",
                minimum: lower, maximum: upper,
                step: declaredStep > 0 ? declaredStep : (upper - lower) / 100,
                unit: p.unit ?? "", defaultValue: normalizedDefault))
        }

        var presetTable: [String: [String: SkinParamValue]] = [:]
        for (presetKey, values) in raw.presets ?? [:] {
            var clean: [String: SkinParamValue] = [:]
            for definition in built {
                if let value = values[definition.key], let clamped = definition.clamped(value) {
                    clean[definition.key] = clamped
                }
            }
            presetTable[presetKey] = clean
        }

        self.key = key
        title = raw.title
        params = built
        groups = groupOrder
        presetKeys = presetTable.keys.sorted()
        presetNames = raw.presetNames ?? [:]
        presets = presetTable
    }
}

// MARK: - Loading

extension SkinParamManifest {
    /// Decodes `data`, then puts each skin's presets in the order its `presetNames` object lists them
    /// (a decoded JSON object has no order).
    public static func decode(_ data: Data) throws -> SkinParamManifest {
        var manifest = try JSONDecoder().decode(SkinParamManifest.self, from: data)
        manifest.applyDeclaredPresetOrder(from: data)
        return manifest
    }

    public static func load(from url: URL) throws -> SkinParamManifest {
        try decode(Data(contentsOf: url))
    }

    /// The manifest bundled with the app, or nil (with a trace line) when it is missing or corrupt.
    /// The editor and the tunable skins stay off in that case; nothing else in the app depends on it.
    public static func loadBundled(bundle: Bundle = .main) -> SkinParamManifest? {
        guard let folder = bundle.resourceURL?.appendingPathComponent(resourceFolderName, isDirectory: true) else {
            RuntimeTrace.record("skin params unavailable: no resource folder")
            return nil
        }
        do {
            return try load(from: folder.appendingPathComponent(resourceFileName))
        } catch {
            RuntimeTrace.record("skin params unavailable: \(String(error.localizedDescription.prefix(160)))")
            return nil
        }
    }

    fileprivate mutating func applyDeclaredPresetOrder(from data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for skinKey in Array(skins.keys) {
            guard let skin = skins[skinKey], !skin.presetNames.isEmpty,
                  let declared = Self.declaredPresetOrder(skinKey: skinKey, in: text) else { continue }
            let known = Set(skin.presetKeys)
            var ordered: [String] = []
            for key in declared where known.contains(key) && !ordered.contains(key) { ordered.append(key) }
            for key in skin.presetKeys where !ordered.contains(key) { ordered.append(key) }
            skins[skinKey]?.presetKeys = ordered
        }
    }

    /// Keys of `skins.<skinKey>.presetNames` in file order, found by scanning the raw text.
    fileprivate static func declaredPresetOrder(skinKey: String, in text: String) -> [String]? {
        guard let skinsRange = keyRange("skins", in: text, from: text.startIndex),
              let skinRange = keyRange(skinKey, in: text, from: skinsRange.upperBound),
              let namesRange = keyRange("presetNames", in: text, from: skinRange.upperBound),
              let open = text[namesRange.upperBound...].firstIndex(of: "{") else { return nil }
        // presetNames maps string to string, so the string tokens alternate key, value, key, value ...
        var tokens: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for ch in text[text.index(after: open)...] {
            if inString {
                if escaped {
                    current.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                    tokens.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == "}" {
                break
            }
        }
        return stride(from: 0, to: tokens.count, by: 2).map { tokens[$0] }
    }

    /// The first `"name"` at or after `start` that is followed by a colon, i.e. used as an object key.
    fileprivate static func keyRange(_ name: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        let needle = "\"" + name + "\""
        var cursor = start
        while cursor < text.endIndex, let found = text.range(of: needle, range: cursor..<text.endIndex) {
            var after = found.upperBound
            while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
            if after < text.endIndex, text[after] == ":" { return found }
            cursor = found.upperBound
        }
        return nil
    }
}
