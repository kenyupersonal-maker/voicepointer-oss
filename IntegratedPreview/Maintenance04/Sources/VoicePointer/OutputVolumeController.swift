import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import VoicePointerCore

/// The only bridge from the pure ducking policy to the default macOS output.
/// Its methods run on the MainActor; delayed tasks carry policy generations.
@MainActor
final class OutputVolumeController {
    static let shared = OutputVolumeController()
    static let enabledKey = "VoicePointer.OutputDucking.Enabled"
    static let ratioKey = "VoicePointer.OutputDucking.Ratio"
    private static let recoveryKey = "VoicePointer.OutputDucking.Recovery.v1"

    var onUnsupported: (@MainActor () -> Void)?

    private let clock = MainDuckingClock()
    private lazy var policy = OutputDuckingPolicy(
        scheduler: clock,
        trace: { RuntimeTrace.record($0) },
        persist: { [weak self] record in self?.saveRecovery(record) },
        unsupported: { [weak self] in self?.onUnsupported?() }
    )
    private var devicesByUID: [String: CoreAudioDuckingDevice] = [:]
    private var started = false
    private var hardwareListeners: [AudioObjectPropertyListenerBlock] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var globalKeys: Any?
    private var localKeys: Any?

    private init() {}

    /// Called after RuntimeTrace initializes at normal app startup, not by isolated self-tests.
    func start() {
        guard !started else { return }
        started = true
        installHardwareListener(kAudioHardwarePropertyDefaultOutputDevice)
        installHardwareListener(kAudioHardwarePropertyDevices)
        let notifications = NSWorkspace.shared.notificationCenter
        sleepObserver = notifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A queued Task may never run before the system sleeps; restore inline on main.
            MainActor.assumeIsolated { self?.policy.forceRestore() }
        }
        wakeObserver = notifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tryRecovery() }
        }
        // subtype 8: NX_KEYTYPE_SOUND_UP=0, SOUND_DOWN=1, MUTE=7.
        // Observation only; no event is swallowed and no new permission is requested.
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard Self.isVolumeKey(event) else { return }
            Task { @MainActor [weak self] in self?.policy.userChanged() }
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            if Self.isVolumeKey(event) {
                Task { @MainActor [weak self] in self?.policy.userChanged() }
            }
            return event
        }
        tryRecovery()
    }

    func begin() {
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let raw = UserDefaults.standard.object(forKey: Self.ratioKey) as? Double ?? 0.5
        let ratio = raw.isFinite ? min(0.8, max(0, raw)) : 0.5
        let device = enabled ? defaultDevice() : nil
        _ = policy.begin(device: device, enabled: enabled, ratio: ratio)
    }

    func release() { policy.release() }

    /// Synchronous: the caller may play the HUD sound only after this returns.
    func restoreForCue() { policy.restoreForCue() }

    func forceRestore() { policy.forceRestore() }

    /// Read-only support diagnostics. No device names or UIDs leave this method.
    func currentDefaultControl() -> OutputDuckingControl {
        defaultDevice()?.control ?? .none
    }

    private nonisolated static func isVolumeKey(_ event: NSEvent) -> Bool {
        guard event.type == .systemDefined, Int(event.subtype.rawValue) == 8 else { return false }
        let keyCode = (event.data1 >> 16) & 0xFFFF
        return keyCode == 0 || keyCode == 1 || keyCode == 7
    }

    private func saveRecovery(_ record: OutputDuckingRecoveryRecord?) {
        let defaults = UserDefaults.standard
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.recoveryKey)
        } else if record == nil {
            defaults.removeObject(forKey: Self.recoveryKey)
        }
    }

    private func tryRecovery() {
        guard let data = UserDefaults.standard.data(forKey: Self.recoveryKey) else { return }
        guard let record = try? JSONDecoder().decode(OutputDuckingRecoveryRecord.self, from: data) else {
            UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
            return
        }
        let elapsed = Date().timeIntervalSince1970 - record.recordedAt
        if !elapsed.isFinite || elapsed < 0 || elapsed > 600 {
            UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
            return
        }
        let oldDevice = findDevice(uid: record.uid)
        _ = policy.recover(record, on: oldDevice)
    }

    private func installHardwareListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if selector == kAudioHardwarePropertyDefaultOutputDevice {
                    self.policy.defaultOutputChanged()
                }
                self.tryRecovery()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                  &address, DispatchQueue.main, listener) == noErr else { return }
        hardwareListeners.append(listener) // Retain exactly the registered blocks for app lifetime.
    }

    private func defaultDevice() -> CoreAudioDuckingDevice? {
        guard let id = CoreAudioDuckingDevice.defaultOutputID() else { return nil }
        return resolve(id)
    }

    private func findDevice(uid: String) -> CoreAudioDuckingDevice? {
        for id in CoreAudioDuckingDevice.availableDeviceIDs() {
            guard CoreAudioDuckingDevice.uid(for: id) == uid else { continue }
            return resolve(id)
        }
        return nil
    }

    private func resolve(_ id: AudioDeviceID) -> CoreAudioDuckingDevice? {
        guard let uid = CoreAudioDuckingDevice.uid(for: id) else { return nil }
        if let known = devicesByUID[uid] {
            known.updateDeviceID(id)
            return known
        }
        guard let device = CoreAudioDuckingDevice(id: id, uid: uid) else { return nil }
        devicesByUID[uid] = device
        return device
    }
}

@MainActor
private final class MainDuckingClock: OutputDuckingScheduling {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var wallTime: TimeInterval { Date().timeIntervalSince1970 }
    func after(seconds: TimeInterval, perform: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(max(0, seconds) * 1000)))
            if !Task.isCancelled { perform() }
        }
    }
}

/// Per-UID capabilities are discovered once. Effective writes are still verified each time.
@MainActor
private final class CoreAudioDuckingDevice: OutputDuckingDevice {
    private(set) var uid: String
    let transport: OutputDuckingTransport
    private(set) var control: OutputDuckingControl
    let canMute: Bool
    private var id: AudioDeviceID
    private let volumeAddresses: [AudioObjectPropertyAddress]
    private let muteAddress: AudioObjectPropertyAddress?

    init?(id: AudioDeviceID, uid: String) {
        self.uid = uid
        self.id = id
        guard let transportCode = Self.readUInt(id, Self.address(
            selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal
        )) else { return nil }
        switch transportCode {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtin
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeUSB: transport = .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transport = .hdmi
        case kAudioDeviceTransportTypeVirtual: transport = .virtual
        case kAudioDeviceTransportTypeAggregate: transport = .aggregate
        default: transport = .other
        }

        let master = kAudioObjectPropertyElementMain
        let virtual = Self.address(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   scope: kAudioDevicePropertyScopeOutput, element: master)
        let scalar = Self.address(selector: kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioDevicePropertyScopeOutput, element: master)
        let channel1 = Self.address(selector: kAudioDevicePropertyVolumeScalar,
                                    scope: kAudioDevicePropertyScopeOutput, element: 1)
        let channel2 = Self.address(selector: kAudioDevicePropertyVolumeScalar,
                                    scope: kAudioDevicePropertyScopeOutput, element: 2)
        if Self.settable(id, virtual), Self.readFloat(id, virtual) != nil {
            control = .virtualMain; volumeAddresses = [virtual]
        } else if Self.settable(id, scalar), Self.readFloat(id, scalar) != nil {
            control = .scalar; volumeAddresses = [scalar]
        } else {
            let channels = [channel1, channel2].filter {
                Self.settable(id, $0) && Self.readFloat(id, $0) != nil
            }
            volumeAddresses = channels
            control = channels.isEmpty ? .none : .channels
        }
        let muteCandidates: [AudioObjectPropertyAddress] = [master, 1, 2].map {
            Self.address(selector: kAudioDevicePropertyMute,
                         scope: kAudioDevicePropertyScopeOutput, element: $0)
        }
        muteAddress = muteCandidates.first { Self.settable(id, $0) && Self.readUInt(id, $0) != nil }
        canMute = muteAddress != nil
        if volumeAddresses.isEmpty, canMute { control = .mute }
    }

    func updateDeviceID(_ newID: AudioDeviceID) { id = newID }

    var isConnected: Bool {
        // AudioDeviceID may be reused after unplug/replug. Never write to a new device via an old ID.
        Self.uid(for: id) == uid
    }

    func read() -> OutputDuckingReading? {
        guard isConnected else { return nil }
        let values = volumeAddresses.compactMap { Self.readFloat(id, $0).map(Double.init) }
        guard values.count == volumeAddresses.count else { return nil }
        let isMuted = muteAddress.flatMap { Self.readUInt(id, $0) }.map { $0 != 0 } ?? false
        return .init(levels: values, muted: isMuted)
    }

    func write(_ reading: OutputDuckingReading) -> Bool {
        guard isConnected, reading.levels.count == volumeAddresses.count else { return false }
        guard let before = read() else { return false }
        if reading.muted != before.muted {
            guard let muteAddress, Self.writeUInt(id, muteAddress, value: reading.muted ? 1 : 0) else {
                return false
            }
        }
        for (address, value) in zip(volumeAddresses, reading.levels) {
            guard Self.writeFloat(id, address, value: Float32(min(1, max(0, value)))) else { return false }
        }
        // CoreAudio/AirPods can apply property writes asynchronously. Read back inside 100 ms;
        // a mismatch remains visible to the policy, which restores and fuses that device.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.10
        repeat {
            if let actual = read(), Self.near(actual, reading) { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while true
        return true
    }

    private static func near(_ a: OutputDuckingReading, _ b: OutputDuckingReading) -> Bool {
        a.muted == b.muted && a.levels.count == b.levels.count &&
            zip(a.levels, b.levels).allSatisfy { abs($0.0 - $0.1) <= 0.02 }
    }

    private static func address(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func settable(_ id: AudioDeviceID, _ requested: AudioObjectPropertyAddress) -> Bool {
        var address = requested
        guard AudioObjectHasProperty(id, &address) else { return false }
        var mutable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &address, &mutable) == noErr && mutable.boolValue
    }

    private static func readFloat(_ id: AudioDeviceID, _ requested: AudioObjectPropertyAddress) -> Float32? {
        var address = requested
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    private static func readUInt(_ id: AudioDeviceID, _ requested: AudioObjectPropertyAddress) -> UInt32? {
        var address = requested
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeFloat(_ id: AudioDeviceID, _ requested: AudioObjectPropertyAddress,
                                   value input: Float32) -> Bool {
        var address = requested
        var value = input
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size),
                                          &value) == noErr
    }

    private static func writeUInt(_ id: AudioDeviceID, _ requested: AudioObjectPropertyAddress,
                                  value input: UInt32) -> Bool {
        var address = requested
        var value = input
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                          &value) == noErr
    }

    static func defaultOutputID() -> AudioDeviceID? {
        var address = self.address(selector: kAudioHardwarePropertyDefaultOutputDevice,
                                   scope: kAudioObjectPropertyScopeGlobal)
        var value: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &value) == noErr, value != kAudioObjectUnknown else { return nil }
        return value
    }

    static func availableDeviceIDs() -> [AudioDeviceID] {
        var address = self.address(selector: kAudioHardwarePropertyDevices,
                                   scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    static func uid(for id: AudioDeviceID) -> String? {
        var address = self.address(selector: kAudioDevicePropertyDeviceUID,
                                   scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        // CoreAudio documents this CFObject as caller-owned; balance its retained reference.
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
              let unmanaged else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
