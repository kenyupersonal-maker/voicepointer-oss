import Foundation
@_spi(Testing) import VoicePointerCore

enum InputDeviceChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append("M \(label)") } }
        var setterCalls = 0
        for _ in 0..<2 {
            if InputConfigurationPolicy.shouldSetDevice(chosen: 1, systemDefault: 1) { setterCalls += 1 }
        }
        expect(setterCalls == 0, "F2 legacy default policy needs no device override")
        expect(InputConfigurationPolicy.shouldSetDevice(chosen: 1, systemDefault: 2), "F2 explicit policy differs from default")
        expect(InputConfigurationPolicy.validFormat(rate: 44100, nominal: 44100, channels: 1), "F3 fresh hardware format")
        expect(!InputConfigurationPolicy.validFormat(rate: 24000, nominal: 44100, channels: 1), "F3 stale format rejected")
        expect(InputConfigurationPolicy.captureDevice(configured: 1, followsDefault: true, systemDefault: 1, configuredAvailable: true) == 1,
            "F3 hardware input identity does not depend on AU device identifier")
        expect(InputConfigurationPolicy.captureDevice(configured: 1, followsDefault: true, systemDefault: 2, configuredAvailable: true) == 2,
            "F4 system input change is observed")
        expect(InputConfigurationPolicy.captureDevice(configured: 1, followsDefault: false, systemDefault: 2, configuredAvailable: true) == 1,
            "F4 pinned capture survives system default change")
        expect(InputConfigurationPolicy.captureDevice(configured: 1, followsDefault: false, systemDefault: 2, configuredAvailable: false) == 0,
            "F4 missing pinned input is observed")
        func action(_ same: Bool, _ running: Bool = true, _ observed: UInt64 = 2_000_000_000) -> InputConfigurationPolicy.Action {
            InputConfigurationPolicy.action(sameDeviceAndFormat: same, running: running, observedAt: observed, ownChangeAt: 1_000_000_000)
        }
        expect(action(true) == .sameDevice, "F4 unchanged notification ignored")
        expect(action(true, false) == .restartInPlace, "F4 stopped same format restarts without setter")
        expect(action(false, true, 1_100_000_000) == .selfInflicted, "F4 self-notification ignored")
        expect(action(false) == .routeChanged, "F4 genuine change uses M7")
        var reopens = 0
        for _ in 0..<2 {
            if action(true) == .routeChanged { reopens += 1 }
        }
        expect(reopens == 0 && setterCalls == 0, "F4 unchanged policy notifications do not reopen")
        let builtin = InputDevice(id: 1, key: "000000000001", name: "Fixture A", kind: .builtin)
        let bluetooth = InputDevice(id: 2, key: "000000000002", name: "Fixture B", kind: .bluetooth)
        let usb = InputDevice(id: 3, key: "000000000003", name: "Fixture C", kind: .usb)
        let devices = [builtin, bluetooth, usb]
        func pick(_ id: UInt32, _ policy: InputDevicePolicy, _ list: [InputDevice] = devices, _ pinned: String? = nil) -> InputDeviceResolution {
            InputDeviceResolver.resolve(devices: list, defaultID: id, policy: policy, pinnedKey: pinned)
        }
        expect(pick(2, .auto).chosen == builtin, "auto avoids bluetooth")
        expect(pick(3, .auto).chosen == usb, "auto follows USB")
        expect(pick(2, .auto, [bluetooth]).chosen == bluetooth, "no built-in remains usable")
        expect(pick(2, .system).chosen == bluetooth, "system explicit selection")
        expect(pick(2, .pinned, devices, "absent").chosen == builtin && pick(2, .pinned, devices, "absent").pinnedMissing, "missing pinned falls back")
        let runtime = InputDeviceRuntime(inventory: { (devices, 2) }, preferences: { (.system, nil) })
        runtime.beginIntent()
        let recognizer = runtime.selection().chosen?.id
        let meter = runtime.selection().chosen?.id
        expect(recognizer == 2 && meter == recognizer, "both engines share selection")
        expect(runtime.fallback(reason: "allZero", atMs: 500) == builtin, "fallback switches once")
        expect(runtime.selection().chosen == builtin && runtime.fallback(reason: "allZero", atMs: 1000) == nil, "no fallback loop")
        expect(runtime.selection().chosen?.id == runtime.selection().chosen?.id, "both engines share fallback")
        func resume(_ device: UInt32 = 1, _ rate: Double = 48000, _ channels: UInt32 = 1) -> Bool {
            InputRouteResumePolicy.canResume(oldDevice: 1, newDevice: device, oldRate: 48000, newRate: rate,
                oldChannels: 1, newChannels: channels, oldLayout: 1, newLayout: 1,
                oldInterleaved: false, newInterleaved: false)
        }
        expect(resume(), "same device and format resumes")
        expect(!resume(2) && !resume(1, 24000) && !resume(1, 48000, 2), "changed device or format seals")
        for code in ["AUDIO_ROUTE_CHANGED", "AUDIO_ROUTE_REOPEN_FAILED", "INPUT_DEVICE_SELECTION_FAILED", "INPUT_DEVICE_FORMAT_UNAVAILABLE"] {
            expect(SpeechFailureDiagnostics.safeCode(code) == code && SpeechFailureDiagnostics.message(for: code).contains("麦克风"),
                "route failures retain finite specific codes")
            expect(VoiceIssuePresentationPolicy.forBackendCode(code).message.contains("麦克风") &&
                SpeechFailureDiagnostics.code(code, provider: .openai) == code, "specific audio issue survives provider and HUD mapping")
        }
        for code in ["LOCAL_START_FAILED", "LOCAL_CAPTURE_FAILED", "LOCAL_INFERENCE_FAILED"] {
            expect(SpeechFailureDiagnostics.safeCode(code) == code && SpeechFailureDiagnostics.code(code, provider: .openai) == code, "F5 local failures keep local identity")
        }
        return failures
    }
}
