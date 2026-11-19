import Foundation

// Which cloud switches may stay on for the selection the person has now, in one place. Every settings write
// point (unticking the enhancement, removing the key, changing the recognition method or its language, the menu
// bar's route switch, launch) calls it after it has saved, so a crash between two writes, or an older version,
// cannot leave a route switch next to a local route or an upload permission with both uses off.
// Enhancement is a remembered user preference; the frozen session decides whether it applies.
//
// It only ever closes. Nothing here turns a switch on, and the kill switch `visible` is never written, so
// calling it too often is harmless while missing one call leaves only what the admission gate refuses anyway.
// Pure Foundation, so the self-tests run every combination of it.

/// What the settings know when they reconcile the cloud switches: the saved selection, and whether the cloud
/// entry can be used at all.
///
/// When a fact is not known yet (the key state has not been read), pass `true` for it: reconciling only
/// closes, so `true` means "do not close on account of this", and the gate still refuses a dictation without
/// a key. Pass `false` only for what is known to be missing.
public struct CloudEntryReconcileContext: Sendable, Equatable {
    /// The selection is the Aliyun route itself (`voiceNative` with `CloudEntry.routeID`).
    public var selectionIsCloudRoute: Bool
    /// The selection is a local route the Aliyun recognizer can enhance (`CloudEntry.canEnhance`).
    public var selectionCanBeEnhanced: Bool
    /// A readable key is saved.
    public var credentialAvailable: Bool
    /// The cloud entry is offered (`cloud.entry.visible` is not switched off).
    public var entryVisible: Bool

    public init(
        selectionIsCloudRoute: Bool,
        selectionCanBeEnhanced: Bool,
        credentialAvailable: Bool,
        entryVisible: Bool
    ) {
        self.selectionIsCloudRoute = selectionIsCloudRoute
        self.selectionCanBeEnhanced = selectionCanBeEnhanced
        self.credentialAvailable = credentialAvailable
        self.entryVisible = entryVisible
    }

    /// The usual way in: the selection as saved, plus the two facts about the entry.
    public init(selection: VoiceInputSelection, credentialAvailable: Bool, entryVisible: Bool,
                provider: OnlineAPIProvider = .aliyunBailian) {
        self.init(
            selectionIsCloudRoute: selection.mode == .voiceNative && selection.routeID == CloudEntry.routeID,
            selectionCanBeEnhanced: CloudEntry.canEnhance(selection, provider: provider),
            credentialAvailable: credentialAvailable,
            entryVisible: entryVisible
        )
    }
}

extension CloudEntry {
    /// Whether "用于增强本地识别" can apply to this selection: a bundled Qwen route on this Mac, in a language the
    /// Aliyun recognizer takes. The settings offer the switch only then; the dictation path asks the same
    /// question (`HybridSpeechRoute.resolve`).
    public static func canEnhance(_ selection: VoiceInputSelection, provider: OnlineAPIProvider = .aliyunBailian) -> Bool {
        HybridSpeechRoute.resolve(
            isVoiceNative: selection.mode == .voiceNative,
            localRouteID: selection.routeID,
            language: selection.language,
            cloudProvider: provider
        ) != nil
    }
}

extension CloudEntryPreferences {
    /// Leaving the online route revokes that use first. The existing reconciliation owns upload consent:
    /// a separately enabled enhancement retains its permission; this method never grants permission.
    public static func leaveRoute(
        reconciling context: CloudEntryReconcileContext, in defaults: UserDefaults = .standard
    ) {
        setRouteEnabled(false, in: defaults)
        reconcile(context, in: defaults)
    }

    /// The switches that may stay on in `context`. Each rule only closes:
    /// - the route switch stays only while the Aliyun route is selected;
    /// - the enhancement preference stays while a key is saved and the entry is offered, across selections;
    /// - the upload permission stays only while one of the two still uses it.
    public func reconciled(_ context: CloudEntryReconcileContext) -> CloudEntryPreferences {
        var next = self
        next.routeEnabled = routeEnabled && context.selectionIsCloudRoute
        next.enhanceLocal = enhanceLocal
            && context.credentialAvailable
            && context.entryVisible
        next.uploadConsent = uploadConsent && (next.routeEnabled || next.enhanceLocal)
        return next
    }

    /// Loads the switches, reconciles them and writes back only those that close. Returns whether anything was
    /// written. The uses close before the upload permission, the order the settings follow by hand; either
    /// order is safe, since the gate needs a use and the permission together before any audio goes out.
    @discardableResult
    public static func reconcile(
        _ context: CloudEntryReconcileContext,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        let current = load(from: defaults)
        let next = current.reconciled(context)
        guard next != current else { return false }
        if current.enhanceLocal, !next.enhanceLocal { setEnhanceLocal(false, in: defaults) }
        if current.routeEnabled, !next.routeEnabled { setRouteEnabled(false, in: defaults) }
        if current.uploadConsent, !next.uploadConsent { setUploadConsent(false, in: defaults) }
        return true
    }
}
