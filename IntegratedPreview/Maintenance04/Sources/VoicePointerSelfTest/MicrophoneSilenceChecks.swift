@preconcurrency import AVFoundation
import Foundation
import CAudioMeterSupport
@_spi(Testing) import VoicePointerCore

@MainActor
enum MicrophoneSilenceChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append("T1 \(name)") } }
        let start: UInt64 = 1_000_000_000
        var gate = MicrophoneSilenceGate(now: start)
        expect(gate.observe(peak: 0, now: start) == .waiting, "first zero must be held without early failure")
        expect(gate.observe(peak: 0, now: start + 1_200_000_000) == .waiting, "duration without minimum callbacks must not trip")
        expect(gate.observe(peak: 0, now: start + 1_200_000_000) == .allZero, "peak, duration and callbacks jointly trip")
        let noCallbacks = MicrophoneSilenceGate(now: start)
        expect(noCallbacks.decision(now: start + 799_000_000) == .waiting, "no callback timeout lower boundary")
        expect(noCallbacks.decision(now: start + 800_000_000) == .noCallbacks, "zero callbacks deadline")
        var stalled = MicrophoneSilenceGate(now: start)
        _ = stalled.observe(peak: 0, now: start + 100_000_000)
        _ = stalled.observe(peak: 0, now: start + 200_000_000)
        expect(stalled.decision(now: start + 699_000_000) == .waiting, "stall lower boundary")
        expect(stalled.decision(now: start + 700_000_000) == .stalled, "two callbacks then 500ms interruption")
        var zeros = MicrophoneSilenceGate(now: start)
        _ = zeros.observe(peak: 0, now: start + 100_000_000)
        _ = zeros.observe(peak: 0, now: start + 200_000_000)
        expect(zeros.observe(peak: 0, now: start + 500_000_000) == .allZero, "500ms three-zero-callback deadline")
        var threshold = MicrophoneSilenceGate(now: start)
        expect(threshold.observe(peak: 0.00001, now: start) == .waiting, "peak threshold is inclusive silence")
        expect(threshold.observe(peak: 0.000011, now: start) == .audible, "peak above threshold opens real PCM")
        expect(threshold.observe(peak: 0, now: start + 10_000_000_000) == .audible, "pauses after speech stay available")
        var tuned = MicrophoneSilenceGate(now: start, configuration: .init(minimumCallbacks: 1, silenceMilliseconds: 20))
        expect(tuned.observe(peak: 0, now: start + 20_000_000) == .allZero, "configured thresholds change decision")

        func pcm(format: AVAudioCommonFormat = .pcmFormatFloat32, amplitude: Double,
                 interleaved: Bool = false, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer? {
            guard let format = AVAudioFormat(commonFormat: format, sampleRate: 48_000, channels: channels, interleaved: interleaved),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else { return nil }
            buffer.frameLength = 4800
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for channel in 0..<Int(channels) {
                guard let pointer = list[interleaved ? 0 : channel].mData else { return nil }
                for frame in 0..<4800 {
                    let value = sin(Double(frame) * 2 * .pi * 440 / 48_000) * amplitude
                    let index = interleaved ? frame * Int(channels) + channel : frame
                    switch format.commonFormat {
                    case .pcmFormatFloat32: pointer.assumingMemoryBound(to: Float.self)[index] = Float(value)
                    case .pcmFormatFloat64: pointer.assumingMemoryBound(to: Double.self)[index] = value
                    case .pcmFormatInt16: pointer.assumingMemoryBound(to: Int16.self)[index] = Int16(value * 32767)
                    case .pcmFormatInt32: pointer.assumingMemoryBound(to: Int32.self)[index] = Int32(value * 2147483647)
                    default: return nil
                    }
                }
            }
            return buffer
        }
        guard let zero = pcm(amplitude: 0), let quiet = pcm(amplitude: 0.1), let loud = pcm(amplitude: 0.4) else {
            return failures + ["T1 synthetic PCM allocation"]
        }
        let formats: [AVAudioCommonFormat] = [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32]
        for format in formats {
            for interleaved in [false, true] {
                guard let buffer = pcm(format: format, amplitude: 0.25, interleaved: interleaved, channels: 2) else {
                    failures.append("T1 format fixture allocation"); continue
                }
                let measurement = PCMBufferLevel.measure(buffer)
                expect(measurement.supported && measurement.peak > 0.24 && measurement.level > 0.45,
                       "float/integer planar/interleaved levels must follow real sine PCM")
            }
        }
        expect(PCMBufferLevel.level(of: loud) > PCMBufferLevel.level(of: quiet), "blue bar level responds to amplitude")
        expect(PCMBufferLevel.level(of: zero) == 0, "zero must not synthesize a blue bar")
        do {
            let resumed = try MicrophoneCaptureTesting.routeResume(first: quiet, second: loud, sameRoute: true)
            expect(resumed.buffers == 2 && resumed.frames == 9600 && !resumed.failure, "route resume retains both segments and rejects detached callbacks")
            let sealed = try MicrophoneCaptureTesting.routeResume(first: quiet, second: loud, sameRoute: false)
            expect(sealed.buffers == 1 && sealed.frames == 4800 && !sealed.failure, "changed route retains captured segment without failure")
        } catch { failures.append("M7 route synthetic PCM") }
        for code in [MicrophoneSilenceGate.noSoundCode, MicrophoneSilenceGate.noCallbacksCode] {
            let presentation = VoiceIssuePresentationPolicy.forBackendCode(code)
            expect(presentation.message == MicrophoneSilenceGate.message, "fixed HUD silence copy")
            expect(presentation.shouldPresent && presentation.stage == .audio, "silence error must reach HUD")
        }
        do {
            for shared in [false, true] {
                let silent = try await MicrophoneCaptureTesting.run(buffers: [zero, zero, zero], shared: shared)
                expect(silent.acceptedBuffers == 0 && silent.inferenceCalls == 0 && silent.finals == 0,
                       "48k zeros must not reach actual local inference through physical/shared capture")
                expect(silent.failureCode == MicrophoneSilenceGate.noSoundCode, "all-zero capture has finite silence code")
                expect(logFieldsValid(silent.diagnostics), "capture diagnostic numeric field whitelist")
            }
            let missing = try await MicrophoneCaptureTesting.run(buffers: [], noCallbacks: true)
            expect(missing.inferenceCalls == 0 && missing.acceptedBuffers == 0 && missing.finals == 0,
                   "no callbacks must not infer")
            expect(missing.failureCode == MicrophoneSilenceGate.noCallbacksCode, "missing callbacks have a distinct code")
            expect(missing.diagnostics.contains("state=no_callbacks"), "missing callbacks diagnosed separately")
            let audible = try await MicrophoneCaptureTesting.run(buffers: [quiet, loud])
            expect(audible.inferenceCalls > 0 && audible.inferredNonzeroBytes > 0 && audible.finals == 1,
                   "48k sine must reach actual converter and inference")
            expect(audible.failureCode == nil && audible.acceptedBuffers == 2 && audible.level > 0,
                   "audible capture keeps PCM and publishes blue bar")
            expect(logFieldsValid(audible.diagnostics), "nonzero diagnostics whitelist")
            for shared in [false, true] {
                for noCallbacks in [false, true] {
                    let cloud = try await MicrophoneCaptureTesting.runCloud(buffers: noCallbacks ? [] : [zero, zero, zero],
                                                                           noCallbacks: noCallbacks, shared: shared)
                    expect(cloud.preparesBeforeAudio == 0 && cloud.credentialReads == 0 && cloud.prepares == 0,
                           "silent cloud capture must not read credentials or prepare an ASR request")
                    expect(cloud.pcmSends == 0 && cloud.finishCommands == 0 && cloud.finals == 0,
                           "silent cloud capture must not send PCM/finish or return a final")
                    expect(cloud.failureCode == (noCallbacks ? MicrophoneSilenceGate.noCallbacksCode : MicrophoneSilenceGate.noSoundCode),
                           "cloud silence keeps the specific HUD code")
                }
            }
            for immediate in [false, true] {
                let cloud = try await MicrophoneCaptureTesting.runCloud(buffers: [quiet, loud], finishImmediately: immediate)
                expect(cloud.preparesBeforeAudio == 0 && cloud.credentialReads == 1 && cloud.prepares == 1 && cloud.pcmSends > 0,
                       "audible cloud PCM opens exactly one request, including an immediate finish")
                expect(cloud.finishCommands == 1 && cloud.finals == 1 && cloud.failureCode == nil,
                       "audible cloud finish still reaches its final")
            }
            for noCallbacks in [false, true] {
                let cloud = try await MicrophoneCaptureTesting.runCloud(buffers: noCallbacks ? [] : [zero, zero, zero],
                                                                       noCallbacks: noCallbacks, groq: true)
                expect(cloud.transcriptionCalls == 0 && cloud.finals == 0,
                       "Groq silence must not transcribe")
                expect(cloud.failureCode == (noCallbacks ? MicrophoneSilenceGate.noCallbacksCode : MicrophoneSilenceGate.noSoundCode),
                       "Groq silence keeps the specific HUD code")
            }
        } catch { failures.append("T1 synthetic pipeline failed") }
        await InputDeviceInventory.waitUntilReady()
        let deviceFields = InputDeviceInventory.diagnosticFields(for: 0)
        expect(logFieldsValid(deviceFields), "device metadata must be enum/digest/numbers only")
        for line in MicrophoneCaptureTesting.diagnosticLogLines(format: zero.format) {
            let fields = line.split(separator: " ").dropFirst().joined(separator: " ")
            expect(logFieldsValid(fields), "actual recognition/meter/route log formatter whitelist")
        }
        for invalid in ["rawPeak=secret text=PRIVATE", "deviceClass=Ken-device", "sampleRate=NaN"] {
            expect(!logFieldsValid(invalid), "whitelist rejects arbitrary payload")
        }
        return failures
    }

    private static func logFieldsValid(_ fields: String) -> Bool {
        let numeric: Set<String> = ["sampleRate", "channels", "commonFormat", "callbacks", "nonzero", "unsupported",
                                    "framesMin", "framesMax", "rawPeak", "firstNonzeroMs", "hardwareRate", "tapRate", "attempt"]
        let enums: [String: Set<String>] = ["state": ["no_callbacks", "all_zero", "nonzero"],
                                          "deviceClass": ["builtin", "bluetooth", "continuity", "usb", "aggregate", "other", "unknown"],
                                          "muted": ["true", "false", "unknown"],
                                          "path": ["recognition", "meter"], "phase": ["start", "end", "reopen"]]
        for token in fields.split(separator: " ") {
            let parts = token.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let key = String(parts[0]), value = String(parts[1])
            if numeric.contains(key) {
                guard value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return false }
            } else if let allowed = enums[key] {
                guard allowed.contains(value) else { return false }
            } else if key == "deviceID" {
                guard value.range(of: #"^(?:0|[a-f0-9]{12})$"#, options: .regularExpression) != nil else { return false }
            } else { return false }
        }
        return !fields.isEmpty
    }
}
