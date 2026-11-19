import Foundation

// How the coordinator wires "用于增强本地识别" into one dictation. Every decision it takes about the enhancement
// is a plain function here, so the self-tests (and a Linux build) can run them: the coordinator, which needs
// AppKit, only reads its own state, calls these, and records the lines they return.
//
// Trace lines carry counts, epochs and finite labels only: never text, never a key. None of them contains
// `route=aliyun` or `cloud admission admitted`, which the coordinator checks read as "a cloud route started
// without a permit". With the enhancement off nothing here returns a line, so such a dictation's trace is the
// same as before this mode existed.

@_spi(Testing) public enum HybridSessionPolicy {
    // MARK: Frozen when the gesture begins

    /// Whether this dictation runs with the enhancement: the settings granted it (the consent set the app
    /// passes to `gestureBegan` carries `CloudEntry.enhanceConsentID`) and the recognizer hands the app its
    /// text. The Aliyun route itself is never enhanced. A later change in the settings reaches the dictation
    /// only as a withdrawal, never as a late opt-in.
    public static func freezesEnhancement(consent: Set<String>, selection: VoiceInputSelection,
                                         cloudProvider: OnlineAPIProvider = .aliyunBailian) -> Bool {
        CloudEntry.canEnhance(selection, provider: cloudProvider)
            && consent.contains(CloudEntry.enhanceConsentID)
    }

    /// Whether `allowed` (the consent set after a settings change) withdraws the enhancement this dictation was
    /// begun with. True once per dictation: the withdrawal sticks, and ticking the box again does not bring the
    /// cloud branch back until the next dictation.
    public static func withdrawsEnhancement(frozen: Bool, alreadyWithdrawn: Bool, allowed: Set<String>) -> Bool {
        frozen && !alreadyWithdrawn && !allowed.contains(CloudEntry.enhanceConsentID)
    }

    // MARK: Asking the gate

    public enum SkipReason: String, Sendable, Equatable, CaseIterable {
        /// Not a bundled Qwen route (Apple speech, another local model), so nothing to enhance.
        case routeIneligible
        /// A Qwen route, in a language the Aliyun recognizer does not take.
        case languageUnsupported
        /// The last dictation's cloud branch is still shutting down in the background.
        case previousCloudDraining
        /// The gate admitted it, but the local+cloud backend could not be built (an invalid endpoint).
        case constructFailed
        /// The gate admitted it, but the person withdrew the enhancement before the backend was built.
        case consentWithdrawn
    }

    public enum AdmissionPlan: Sendable, Equatable {
        /// Ask the gate for this dictation, with the local route the cloud would enhance.
        case ask(HybridSpeechRoute)
        /// Run the plain local backend without asking.
        case skip(SkipReason)
    }

    /// Whether a dictation begun with the enhancement asks the gate at all. The gate is not asked for a route
    /// or language the hybrid backend cannot run, and not while an earlier cloud branch is still draining:
    /// that would make two concurrent streams, which the service throttles (`Throttling.Concurrency`).
    public static func admissionPlan(for selection: VoiceInputSelection, cloudDrainOutstanding: Int,
                                     cloudProvider: OnlineAPIProvider = .aliyunBailian) -> AdmissionPlan {
        let isVoiceNative = selection.mode == .voiceNative
        guard let route = HybridSpeechRoute.resolve(
            isVoiceNative: isVoiceNative, localRouteID: selection.routeID, language: selection.language,
            cloudProvider: cloudProvider
        ) else {
            let knownRoute = isVoiceNative && HybridSpeechRoute.localRouteIDs.contains(selection.routeID)
            return .skip(knownRoute ? .languageUnsupported : .routeIneligible)
        }
        guard cloudDrainOutstanding <= 0 else { return .skip(.previousCloudDraining) }
        return .ask(route)
    }

    public static func admittedTrace(epoch: UInt64) -> String {
        "hybrid admission admitted epoch=\(epoch)"
    }

    /// `reason` is the gate's finite label (`CloudDictationStart.denied`); anything that is not a plain label
    /// is written as `unknown`, so this line can never carry text.
    public static func deniedTrace(reason: String) -> String {
        "hybrid admission denied reason=\(isTraceLabel(reason) ? reason : "unknown") fallback=localOnly"
    }

    public static func skippedTrace(_ reason: SkipReason) -> String {
        "hybrid skipped reason=\(reason.rawValue)"
    }

    // MARK: Starting the backend

    /// What the `speech backend start …` line gets appended: nothing unless this dictation was begun with the
    /// enhancement, so a dictation without it writes that line exactly as before.
    public static func backendStartSuffix(enhancementFrozen: Bool, hybridBackend: Bool,
                                         cloudProvider: OnlineAPIProvider = .aliyunBailian) -> String {
        guard enhancementFrozen else { return "" }
        return hybridBackend ? " hybrid=\(cloudProvider.isAliyun ? "aliyun" : cloudProvider.rawValue)" : " hybrid=off"
    }

    // MARK: The final text

    /// A final text and the lexicon hits the dictation keeps, plus the line to record (nil: none).
    public struct GuardedFinal: Sendable, Equatable {
        public let event: SpeechInputEvent
        public let hits: [LexiconSnapshot.Hit]
        public let trace: String?
    }

    /// The final text after the personal lexicon (`corrected` is `DictationCorrector.correct(event, mode:)`).
    ///
    /// Only a cloud-enhancement final whose text the lexicon changed goes through `HybridProjectionGuard`: a
    /// local final keeps exactly the path it had before this mode. When the guard refuses, the dictation keeps
    /// the cloud's own raw text with no hits (K05 rule 4: back to that candidate's raw, never the local draft).
    public static func guardedFinal(
        _ event: SpeechInputEvent,
        corrected: (event: SpeechInputEvent, hits: [LexiconSnapshot.Hit])
    ) -> GuardedFinal {
        guard event.transcriptSource == .cloudEnhancement,
              let raw = event.text, let projected = corrected.event.text,
              !raw.unicodeScalars.elementsEqual(projected.unicodeScalars) else {
            return GuardedFinal(event: corrected.event, hits: corrected.hits, trace: nil)
        }
        switch HybridProjectionGuard.check(raw: raw, projected: projected) {
        case .accepted:
            return GuardedFinal(
                event: corrected.event, hits: corrected.hits,
                trace: "hybrid projection guard result=accepted hits=\(corrected.hits.count)"
            )
        case .rejected(let reason):
            return GuardedFinal(
                event: event, hits: [],
                trace: "hybrid projection guard result=rawFallback reason=\(reason.rawValue) hits=0"
            )
        }
    }

    private static func isTraceLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E: return true
            default: return false
            }
        }
    }
}
