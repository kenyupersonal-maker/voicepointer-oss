import Foundation

/// Storage/admission dependencies stay outside the credential-free configuration value.
extension OnlineAPIConfiguration {
    public var credentialSlot: CloudCredentialProvider {
        switch provider { case .aliyunBailian, .aliyunIntl: .aliyunBeijing; case .groq: .groq; case .openai: .openai; case .siliconflow: .siliconflow }
    }
    /// CN retains the legacy 3.0 identity; station and model changes require separate confirmation.
    public func admissionIdentity() throws -> CloudAdmissionIdentity {
        _ = try validatedEndpoint()
        guard provider.isAliyun else { throw CloudAdmissionIdentityError.invalidComponent }
        return try CloudAdmissionIdentity(provider: provider == .aliyunBailian ? CloudEntry.provider : "aliyun-intl",
            accountReference: CloudEntry.accountReference, credentialRevision: credentialRevision,
            region: provider == .aliyunBailian ? CloudEntry.region : "intl", workspace: CloudEntry.workspace, modelID: modelID)
    }
    /// Pure metadata migration. No key access, persistence, consent or route changes.
    public static func migrateLegacy(selection: VoiceInputSelection, aliyunEndpoint: String,
                                     aliyunRevision: String?, groqRevision: String?) -> Self? {
        if selection.routeID == "groq-v3" || selection.routeID == "groq-turbo", let revision = groqRevision {
            return .init(provider: .groq, modelID: selection.routeID == "groq-v3" ? "whisper-large-v3" : "whisper-large-v3-turbo", credentialRevision: revision)
        }
        if let revision = aliyunRevision {
            return .init(provider: .aliyunBailian, modelID: AliWireCodec.legacyModelID,
                endpointOverride: aliyunEndpoint == AliEndpoint.defaultURLString ? nil : aliyunEndpoint, credentialRevision: revision)
        }
        return nil
    }
}
