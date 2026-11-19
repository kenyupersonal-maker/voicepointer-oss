import Foundation
import CoreAudio
import CryptoKit
import CAudioMeterSupport

public enum InputDeviceClass: String, Sendable { case builtin, bluetooth, continuity, usb, aggregate, other, unknown }
extension InputDeviceClass {
    public var captureLogClass: String {
        switch self { case .builtin, .bluetooth, .usb, .aggregate: rawValue; default: "other" }
    }
}
public enum InputDevicePolicy: String, CaseIterable, Sendable { case auto, system, pinned }
public struct InputDevice: Equatable, Sendable {
    public let id: UInt32
    public let key: String
    public let name: String // UI only. Never included in diagnostics.
    public let kind: InputDeviceClass
    public let nominalRate: Double
    public let muted: Bool?
    /// RAM-only selector for a fresh UID-to-ID lookup. Never persisted or logged.
    public let captureUID: String
    public init(id: UInt32, key: String, name: String, kind: InputDeviceClass,
                nominalRate: Double = 0, muted: Bool? = nil, captureUID: String = "") {
        self.id = id; self.key = key; self.name = name; self.kind = kind
        self.nominalRate = nominalRate; self.muted = muted
        self.captureUID = captureUID
    }
}
public struct InputDeviceResolution: Sendable {
    public let chosen: InputDevice?
    public let fallback: InputDevice?
    public let systemDefault: InputDevice?
    public let policy: InputDevicePolicy
    public let reason: String
    public let pinnedMissing: Bool
}
public enum InputDeviceResolver {
    public static func resolve(devices: [InputDevice], defaultID: UInt32, policy: InputDevicePolicy,
                               pinnedKey: String? = nil) -> InputDeviceResolution {
        let system = devices.first { $0.id == defaultID }
        let builtin = devices.first { $0.kind == .builtin }
        let avoidWireless = system?.kind == .bluetooth || system?.kind == .continuity
        let automatic = avoidWireless ? (builtin ?? system) : (system ?? builtin)
        let pinned = devices.first { $0.key == pinnedKey }
        let chosen: InputDevice?
        switch policy { case .auto: chosen = automatic; case .system: chosen = system ?? builtin; case .pinned: chosen = pinned ?? automatic }
        let candidates = policy == .auto && chosen?.id == builtin?.id ? [system, builtin] : [builtin, system]
        let fallback = candidates.compactMap { $0 }.first { $0.id != chosen?.id }
        let reason = policy == .pinned && pinned == nil ? "pinnedMissing"
            : policy == .auto && avoidWireless && builtin != nil ? (system?.kind == .bluetooth ? "bluetoothDefault" : "continuityDefault") : "selected"
        return .init(chosen: chosen, fallback: fallback, systemDefault: system, policy: policy,
                     reason: reason, pinnedMissing: policy == .pinned && pinned == nil)
    }
}

/// Consumers take a short snapshot lock only. CoreAudio IO and property listeners
/// are confined to a separate queue, never waited on by a gesture or an opener.
public enum InputDeviceInventory {
    public static let changed = Notification.Name("VoicePointerInputInventoryChanged")
    public static func start() { _ = InputDeviceInventoryCache.shared }
    public static func waitUntilReady() async { await InputDeviceInventoryCache.shared.waitUntilReady() }
    public static func read() -> (devices: [InputDevice], defaultID: UInt32) { InputDeviceInventoryCache.shared.snapshot() }
    public static func defaultInputID() -> UInt32 { read().defaultID }
    public static func nominalRate(_ id: UInt32) -> Double {
        read().devices.first { $0.id == id }?.nominalRate ?? 0
    }
    public static func hasInputStreams(_ id: UInt32) -> Bool {
        read().devices.contains { $0.id == id }
    }
    public static func diagnosticFields(for id: UInt32) -> String {
        let cached = read()
        guard let device = cached.devices.first(where: { $0.id == (id == 0 ? cached.defaultID : id) }) else {
            return "deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown"
        }
        let muted = device.muted.map { $0 ? "true" : "false" } ?? "unknown"
        return "deviceClass=\(device.kind.rawValue) deviceID=\(device.key) hardwareRate=\(String(format: "%.0f", device.nominalRate)) muted=\(muted)"
    }
}

private final class InputDeviceInventoryCache: @unchecked Sendable {
    static let shared = InputDeviceInventoryCache()
    private let snapshotLock = NSLock()
    private var cached: (devices: [InputDevice], defaultID: UInt32) = ([], 0)
    private let queue = VPCAudioControlQueue()
    private var listener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(UInt32, AudioObjectPropertyAddress)] = []
    private var listenedIDs: Set<UInt32> = []

    private init() {
        queue.async { [self] in
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            listener = block
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                var property = Self.address(selector)
                _ = AudioObjectAddPropertyListenerBlock(UInt32(kAudioObjectSystemObject), &property, queue, block)
            }
            refresh()
        }
    }
    func snapshot() -> (devices: [InputDevice], defaultID: UInt32) { snapshotLock.withLock { cached } }
    func waitUntilReady() async {
        // A startup/probe may suspend for the first background read. Normal
        // consumers never dispatch_sync to this queue or hold its IO lock.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
    private func refresh() {
        let next = Self.readHardware()
        updateDeviceListeners(next.devices)
        let didChange = snapshotLock.withLock { () -> Bool in
            let changed = cached.defaultID != next.defaultID || cached.devices != next.devices
            cached = next
            return changed
        }
        if didChange { NotificationCenter.default.post(name: InputDeviceInventory.changed, object: nil) }
    }
    private func updateDeviceListeners(_ devices: [InputDevice]) {
        let ids = Set(devices.map(\.id))
        guard ids != listenedIDs, let listener else { return }
        for (id, stored) in deviceListeners {
            var property = stored
            _ = AudioObjectRemovePropertyListenerBlock(id, &property, queue, listener)
        }
        deviceListeners.removeAll(keepingCapacity: true)
        listenedIDs = ids
        for id in ids {
            for (selector, input) in [(kAudioDevicePropertyNominalSampleRate, false),
                                      (kAudioDevicePropertyDeviceIsAlive, false),
                                      (kAudioDevicePropertyStreams, true), (kAudioDevicePropertyStreamFormat, true),
                                      (kAudioDevicePropertyMute, true)] {
                var property = Self.address(selector, input: input)
                if AudioObjectHasProperty(id, &property),
                   AudioObjectAddPropertyListenerBlock(id, &property, queue, listener) == noErr {
                    deviceListeners.append((id, property))
                }
            }
        }
    }
    private static func address(_ selector: AudioObjectPropertySelector, input: Bool = false) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: input ? kAudioDevicePropertyScopeInput : kAudioObjectPropertyScopeGlobal,
              mElement: kAudioObjectPropertyElementMain)
    }
    private static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T {
        var property = address(selector), result = initial, size = UInt32(MemoryLayout<T>.size)
        _ = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) }
        return result
    }
    private static func text(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var property = address(selector), value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) }
        return result == noErr ? value as String : ""
    }
    private static func readHardware() -> (devices: [InputDevice], defaultID: UInt32) {
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(UInt32(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return ([], 0) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return ([], 0) }
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(UInt32(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return ([], 0) }
        let devices = ids.compactMap { id -> InputDevice? in
            var streams = address(kAudioDevicePropertyStreams, input: true), bytes: UInt32 = 0
            guard scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0,
                  AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let transport = scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            let kind: InputDeviceClass
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: kind = .builtin
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = .bluetooth
            case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: kind = .continuity
            case kAudioDeviceTransportTypeUSB: kind = .usb
            case kAudioDeviceTransportTypeAggregate: kind = .aggregate
            default: kind = .other
            }
            let uid = text(id, kAudioDevicePropertyDeviceUID)
            let key = SHA256.hash(data: Data(uid.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let rate = scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            var muteProperty = address(kAudioDevicePropertyMute, input: true), mute: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            let hasMute = AudioObjectHasProperty(id, &muteProperty) &&
                AudioObjectGetPropertyData(id, &muteProperty, 0, nil, &muteSize, &mute) == noErr
            return .init(id: id, key: key, name: text(id, kAudioObjectPropertyName), kind: kind,
                nominalRate: rate.isFinite && rate > 0 && rate <= 768_000 ? rate : 0,
                muted: hasMute ? mute != 0 : nil, captureUID: uid)
        }
        return (devices, scalar(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0)))
    }
}

public final class InputDeviceRuntime: @unchecked Sendable {
    public static let shared = InputDeviceRuntime()
    public static let changed = Notification.Name("VoicePointerInputDeviceChanged")
    public static let notice = Notification.Name("VoicePointerInputDeviceNotice")
    public static let policyKey = "inputMicrophonePolicy"
    public static let pinnedKey = "inputMicrophonePinnedHash"
    /// A callback timeout has no hardware OSStatus; report its numeric timeout code.
    public static let noCallbacksStatus = ETIMEDOUT
    private let lock = NSLock()
    private var current: InputDeviceResolution?
    private var fallbackUsed = false
    private var missingNotified = false
    private var failureDefaultID: UInt32?
    private var failedSelectionKeys: Set<String> = []
    private var failureDeviceList: Set<String> = []
    private var usableFallbackKey: String?
    private var pendingFallbackKey: String?
    private let inventory: @Sendable () -> (devices: [InputDevice], defaultID: UInt32)
    private let preferences: @Sendable () -> (InputDevicePolicy, String?)
    public init(inventory: @escaping @Sendable () -> (devices: [InputDevice], defaultID: UInt32) = InputDeviceInventory.read,
                preferences: @escaping @Sendable () -> (InputDevicePolicy, String?) = {
                    (InputDevicePolicy(rawValue: UserDefaults.standard.string(forKey: InputDeviceRuntime.policyKey) ?? "auto") ?? .auto,
                     UserDefaults.standard.string(forKey: InputDeviceRuntime.pinnedKey))
                }) { self.inventory = inventory; self.preferences = preferences }
    public func beginIntent(resetFallback: Bool = true, policyOverride: InputDevicePolicy? = nil, pinnedOverride: String? = nil) {
        let inventory = inventory(), stored = preferences()
        let policy = policyOverride ?? stored.0, pinned = pinnedOverride ?? stored.1
        var value = InputDeviceResolver.resolve(devices: inventory.devices, defaultID: inventory.defaultID,
            policy: policy, pinnedKey: pinned)
        let retainedFailure = lock.withLock { () -> String? in
            let list = Set(inventory.devices.map { "\($0.key):\($0.id)" })
            if failureDefaultID != inventory.defaultID || failureDeviceList != list {
                failureDefaultID = inventory.defaultID; failureDeviceList = list
                failedSelectionKeys.removeAll(); usableFallbackKey = nil; pendingFallbackKey = nil
            }
            return value.chosen.map { failedSelectionKeys.contains($0.key) } == true ? usableFallbackKey : nil
        }
        if let retainedFailure, let usable = inventory.devices.first(where: { $0.key == retainedFailure }) {
            value = .init(chosen: usable, fallback: nil, systemDefault: value.systemDefault,
                policy: value.policy, reason: "retainedFallback", pinnedMissing: value.pinnedMissing)
        }
        if value.chosen.map({ candidate in lock.withLock { failedSelectionKeys.contains(candidate.key) } }) == true {
            let next = [value.fallback, value.systemDefault].compactMap { $0 }
                .first { candidate in !lock.withLock { failedSelectionKeys.contains(candidate.key) } }
            value = .init(chosen: next, fallback: nil, systemDefault: value.systemDefault,
                policy: value.policy, reason: next == nil ? "failedUnavailable" : "retainedFallback", pinnedMissing: value.pinnedMissing)
        }
        if !resetFallback, let retained = lock.withLock({ fallbackUsed ? current?.chosen : nil }),
           inventory.devices.contains(where: { $0.id == retained.id }),
           !lock.withLock({ failedSelectionKeys.contains(retained.key) }) {
            value = .init(chosen: retained, fallback: nil, systemDefault: value.systemDefault,
                policy: value.policy, reason: "retainedFallback", pinnedMissing: false)
        }
        lock.withLock { current = value; if resetFallback { fallbackUsed = value.reason == "retainedFallback" } }
        RuntimeTrace.record("capture_route phase=select policy=\(policy.rawValue) default=\(value.systemDefault?.kind.rawValue ?? "unknown") chosen=\(value.chosen?.kind.rawValue ?? "unknown") reason=\(value.reason)")
        if value.pinnedMissing, !lock.withLock({ let old = missingNotified; missingNotified = true; return old }) {
            postNotice("选定的麦克风不在，先用\(value.chosen?.kind == .builtin ? "电脑麦克风" : "可用麦克风")")
        }
        if value.reason == "retainedFallback", value.chosen?.kind == .bluetooth {
            postNotice("这次用的是耳机麦克风")
        }
    }
    public func selection() -> InputDeviceResolution {
        if lock.withLock({ current == nil }) { beginIntent() }
        return lock.withLock { current! }
    }
    public func fallback(reason: String, atMs: UInt64) -> InputDevice? {
        let old = selection()
        markInputFailed()
        guard let next = old.fallback, inventory().devices.contains(where: { $0.id == next.id }),
              !lock.withLock({ failedSelectionKeys.contains(next.key) }) else { return nil }
        let allowed = lock.withLock { () -> Bool in
            guard !fallbackUsed, current?.chosen?.key == old.chosen?.key else { return false }
            fallbackUsed = true
            failureDefaultID = old.systemDefault?.id ?? 0
            usableFallbackKey = nil
            pendingFallbackKey = next.key
            current = .init(chosen: next, fallback: nil, systemDefault: old.systemDefault, policy: old.policy,
                            reason: reason, pinnedMissing: false)
            return true
        }
        guard allowed else { return nil }
        let finiteReason = reason == "allZero" ? "allZero" : reason == "noCallbacks" ? "noCallbacks" : "startFailed"
        RuntimeTrace.record("capture fallback from=\(old.chosen?.kind.captureLogClass ?? "other") to=\(next.kind.captureLogClass) reason=\(finiteReason)")
        NotificationCenter.default.post(name: Self.changed, object: nil)
        postNotice(next.kind == .bluetooth ? "这次用的是耳机麦克风"
            : next.kind == .builtin ? "麦克风没声音，已换用电脑麦克风" : "麦克风没声音，已换用候补麦克风")
        return next
    }
    private func postNotice(_ text: String) { NotificationCenter.default.post(name: Self.notice, object: nil, userInfo: ["message": text]) }
    public func confirmInputOpened(deviceID: UInt32, selectionKey: String? = nil) {
        lock.withLock {
            guard deviceID != 0,
                  current?.chosen?.id == deviceID || current?.chosen?.key == selectionKey,
                  let pendingFallbackKey,
                  current?.chosen?.key == pendingFallbackKey else { return }
            usableFallbackKey = pendingFallbackKey; self.pendingFallbackKey = nil
        }
    }
    public func markInputFailed() {
        lock.withLock {
            if let key = current?.chosen?.key { failedSelectionKeys.insert(key) }
            if usableFallbackKey == current?.chosen?.key { usableFallbackKey = nil }
            pendingFallbackKey = nil
        }
    }
    public func invalidateFallback() { lock.withLock { usableFallbackKey = nil; pendingFallbackKey = nil } }
    public func reportOpenFailure() {
        markInputFailed()
        invalidateFallback()
        postNotice("麦克风打不开：到 系统设置 → 声音 → 输入，选 MacBook 麦克风")
    }
}
