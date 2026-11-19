import Foundation
import CoreAudio

/// Explicit installed-process acceptance only. The private aggregate is never
/// made a system default or persisted in application preferences.
@_spi(Testing) @MainActor public final class PrivateAggregateCaptureProbe {
    private let deviceID: AudioDeviceID
    public let pinnedKey: String
    private init(deviceID: AudioDeviceID, pinnedKey: String) {
        self.deviceID = deviceID; self.pinnedKey = pinnedKey
    }
    public static func create() async throws -> PrivateAggregateCaptureProbe {
        await InputDeviceInventory.waitUntilReady()
        guard let builtin = InputDeviceInventory.read().devices.first(where: { $0.kind == .builtin }) else {
            throw TrialCoreError.invalid("PROBE_BUILTIN_MISSING")
        }
        let result: (OSStatus, AudioDeviceID) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var uid: CFString = "" as CFString
                var size = UInt32(MemoryLayout<CFString>.size)
                let read = withUnsafeMutablePointer(to: &uid) {
                    AudioObjectGetPropertyData(builtin.id, &property, 0, nil, &size, $0)
                }
                guard read == noErr else { continuation.resume(returning: (read, 0)); return }
                let description: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "VoicePointer private capture acceptance",
                    kAudioAggregateDeviceUIDKey: "com.kenyu.voicepointer.capture-probe." + UUID().uuidString,
                    kAudioAggregateDeviceIsPrivateKey: 1,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                    kAudioAggregateDeviceMainSubDeviceKey: uid
                ]
                var id: AudioDeviceID = 0
                let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
                continuation.resume(returning: (status, id))
            }
        }
        guard result.0 == noErr, result.1 != 0 else {
            throw TrialCoreError.invalid("PROBE_AGGREGATE_CREATE_FAILED")
        }
        for _ in 0..<100 {
            await InputDeviceInventory.waitUntilReady()
            if let device = InputDeviceInventory.read().devices.first(where: { $0.id == result.1 }) {
                return .init(deviceID: result.1, pinnedKey: device.key)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = await destroy(result.1)
        throw TrialCoreError.invalid("PROBE_AGGREGATE_INVENTORY_UNAVAILABLE")
    }
    public func close() async -> Bool {
        guard await Self.destroy(deviceID) == noErr else { return false }
        for _ in 0..<100 {
            await InputDeviceInventory.waitUntilReady()
            if !InputDeviceInventory.read().devices.contains(where: { $0.id == deviceID }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    private nonisolated static func destroy(_ id: AudioDeviceID) async -> OSStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: AudioHardwareDestroyAggregateDevice(id))
            }
        }
    }
}
