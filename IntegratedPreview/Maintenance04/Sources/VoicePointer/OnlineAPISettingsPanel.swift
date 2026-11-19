import AppKit
import Combine
import Foundation
import SwiftUI
import VoicePointerCore

/// A projection only. The caller supplies masked metadata, never a key or credential store.
struct OnlineAPIPanelSnapshot: Equatable {
    enum Attention: Equatable { case keyRejected, freeQuotaExhausted, confirmationExpired }
    var configuration: OnlineAPIConfiguration?
    var availableModelIDs: [String]
    var maskedKey: String
    var confirmedModelIDs: Set<String>
    var quotaValidUntil: Date?
    var attention: Attention?
    static let empty = Self(configuration: nil, availableModelIDs: [], maskedKey: "", confirmedModelIDs: [], quotaValidUntil: nil, attention: nil)
    var models: [String] { configuration?.provider.modelIDs.filter(Set(availableModelIDs).contains) ?? [] }
}

@MainActor final class OnlineAPIPanelModel: ObservableObject {
    enum CheckResult: Sendable { case available, failed(OnlineAPIProblem) }
    typealias ValidateModel = @MainActor (OnlineAPIConfiguration) async -> CheckResult
    typealias CommitModel = @MainActor (OnlineAPIConfiguration, Bool) async throws -> OnlineAPIConfiguration
    @Published private(set) var snapshot: OnlineAPIPanelSnapshot
    @Published private(set) var pendingModelID: String?
    @Published private(set) var checking = false
    @Published private(set) var saving = false
    @Published private(set) var message = ""
    @Published private(set) var validatedPending: OnlineAPIConfiguration?
    private let validate: ValidateModel?
    private let commit: CommitModel?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    init(snapshot: OnlineAPIPanelSnapshot, validate: ValidateModel? = nil, commit: CommitModel? = nil) {
        self.snapshot = snapshot; self.validate = validate; self.commit = commit
    }
    var selectedModelID: String { pendingModelID ?? snapshot.configuration?.modelID ?? "" }
    var needsQuotaConfirmation: Bool {
        validatedPending.map { $0.provider.isAliyun && !snapshot.confirmedModelIDs.contains($0.modelID) } ?? false
    }
    func update(_ value: OnlineAPIPanelSnapshot) {
        let old = snapshot.configuration, new = value.configuration
        let sameIdentity = old?.provider == new?.provider && old?.credentialRevision == new?.credentialRevision
            && old?.endpointOverride == new?.endpointOverride
        let ownCommit = saving && new?.modelID == pendingModelID
        if !sameIdentity || (old?.modelID != new?.modelID && !ownCommit) || pendingModelID.map({ !value.models.contains($0) }) == true {
            cancelPending(reason: "configurationChanged")
        }
        snapshot = value
    }
    func close() { cancelPending(reason: "windowClosed") }
    private func cancelPending(reason: String) {
        if pendingModelID != nil || checking || saving {
            RuntimeTrace.record("online model select result=cancelled reason=\(reason)")
            message = OnlineAPIStrings.modelSelectionCancelled
        }
        generation &+= 1; task?.cancel(); task = nil; pendingModelID = nil; validatedPending = nil; checking = false; saving = false
    }
    func selectModel(_ id: String) {
        guard !saving, snapshot.models.contains(id),
              var config = snapshot.configuration else { return }
        if id == config.modelID { cancelPending(reason: "selectionChanged"); return }
        cancelPending(reason: "selectionChanged"); message = ""
        guard let validate else { message = OnlineAPIStrings.modelCheckUnavailable; return }
        config.modelID = id; pendingModelID = id; checking = true
        let expected = generation
        task = Task { [weak self] in
            let result = await validate(config)
            guard let self, !Task.isCancelled, expected == self.generation else { return }
            self.checking = false
            switch result {
            case .available:
                self.validatedPending = config
                if !self.needsQuotaConfirmation { self.apply(config, confirmed: false) }
            case .failed(let problem):
                if problem.cause == .cancelled { self.cancelPending(reason: "validationCancelled") }
                else {
                    self.pendingModelID = nil; self.message = OnlineAPIStrings.panelModelProblem(problem)
                    RuntimeTrace.record("online model select result=failed reason=validationFailed")
                }
            }
        }
    }
    func confirmPendingQuota(_ confirmed: Bool) {
        guard confirmed, needsQuotaConfirmation, let config = validatedPending,
              config.provider == snapshot.configuration?.provider,
              config.credentialRevision == snapshot.configuration?.credentialRevision,
              config.endpointOverride == snapshot.configuration?.endpointOverride else { return }
        apply(config, confirmed: true)
    }
    private func apply(_ config: OnlineAPIConfiguration, confirmed: Bool) {
        guard let commit else { message = OnlineAPIStrings.modelCheckUnavailable; return }
        saving = true
        let expected = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await commit(config, confirmed)
                guard !Task.isCancelled, expected == self.generation else { return }
                self.snapshot.configuration = saved
                if confirmed { self.snapshot.confirmedModelIDs.insert(saved.modelID) }
                self.pendingModelID = nil; self.validatedPending = nil; self.saving = false; self.message = ""
                RuntimeTrace.record("online model select result=passed reason=none")
            } catch {
                guard !Task.isCancelled, expected == self.generation else { return }
                self.saving = false; self.pendingModelID = nil; self.validatedPending = nil; self.message = OnlineAPIStrings.modelSaveFailed
                RuntimeTrace.record("online model select result=failed reason=storageFailed")
            }
        }
    }
}

struct OnlineAPISettingsPanel: View {
    let snapshot: OnlineAPIPanelSnapshot
    let configure: (OnlineAPISetupPage) -> Void
    let replace: () -> Void
    let remove: () -> Void
    let confirmQuota: () async throws -> Void
    let disableOnline: () async throws -> Void
    let healthState: EngineHealthState?
    @StateObject private var model: OnlineAPIPanelModel
    @State private var showingReconfirmation = false
    @State private var quotaTip = false
    @State private var modelHovered = false
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OnlineAPIPalette { .init(dark: colorScheme == .dark) }
    init(snapshot: OnlineAPIPanelSnapshot, configure: @escaping (OnlineAPISetupPage) -> Void,
         replace: @escaping () -> Void, remove: @escaping () -> Void,
         confirmQuota: @escaping () async throws -> Void, disableOnline: @escaping () async throws -> Void,
         validateModel: OnlineAPIPanelModel.ValidateModel? = nil, commitModel: OnlineAPIPanelModel.CommitModel? = nil,
         healthState: EngineHealthState? = nil) {
        self.snapshot = snapshot; self.configure = configure; self.replace = replace; self.remove = remove
        self.confirmQuota = confirmQuota; self.disableOnline = disableOnline
        self.healthState = healthState
        _model = StateObject(wrappedValue: OnlineAPIPanelModel(snapshot: snapshot, validate: validateModel, commit: commitModel))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OnlineAPIStrings.panelTitle).font(.system(size: 13, weight: .semibold)).fontWeight(.semibold)
                .foregroundStyle(palette.secondary).frame(height: 20, alignment: .leading)
            if let config = model.snapshot.configuration {
                if let attention = model.snapshot.attention { banner(attention, provider: config.provider).padding(.bottom, 2) }
                VStack(spacing: 0) {
                    row(OnlineAPIStrings.provider) {
                        Text(OnlineAPIStrings.providerName(config.provider)).fontWeight(.semibold)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(healthState.map { SettingsTone($0).color } ?? (model.snapshot.attention == nil ? palette.accent : .orange)).frame(width: 7, height: 7)
                            Text(healthState?.statusTitle ?? (model.snapshot.attention == nil ? OnlineAPIStrings.panelAvailable : OnlineAPIStrings.panelAttention))
                        }.font(.system(size: 12.5, weight: .semibold)).foregroundStyle(healthState.map { SettingsTone($0).color } ?? (model.snapshot.attention == nil ? palette.accent : .orange))
                    }
                    Divider().overlay(palette.softLine)
                    row(OnlineAPIStrings.model) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Menu {
                                    ForEach(model.snapshot.models, id: \.self) { id in
                                        Button { model.selectModel(id) } label: {
                                            if id == config.modelID { Label(OnlineAPIStrings.modelChoice(id, recommended: id == model.snapshot.models.first), systemImage: "checkmark") }
                                            else { Text(OnlineAPIStrings.modelChoice(id, recommended: id == model.snapshot.models.first)) }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(OnlineAPIStrings.modelName(model.selectedModelID)).foregroundStyle(.primary)
                                        if model.selectedModelID == model.snapshot.models.first { apiTag(OnlineAPIStrings.recommended, palette: palette) }
                                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(palette.tertiary)
                                    }.padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                                        .background(modelHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize().disabled(model.saving)
                                    .onHover { modelHovered = $0 }
                                if model.checking || model.saving { Text(OnlineAPIStrings.modelChecking).font(.caption).foregroundStyle(.secondary) }
                            }
                            if model.needsQuotaConfirmation {
                                Text(OnlineAPIStrings.modelQuotaConfirmation(model.selectedModelID)).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Toggle(OnlineAPIStrings.quotaLabel(config.provider), isOn: .init(get: { model.saving }, set: { model.confirmPendingQuota($0) }))
                                        .toggleStyle(.checkbox).disabled(model.saving)
                                    Button(OnlineAPIStrings.how) { openQuota(config.provider) }
                                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
                                }.popover(isPresented: $quotaTip) { Text(OnlineAPIStrings.quotaTip).font(.system(size: 12)).padding(12).frame(width: 270) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().overlay(palette.softLine)
                    row(OnlineAPIStrings.keyLabel) {
                        Text(model.snapshot.maskedKey).font(.system(size: 12.5, design: .monospaced))
                        Spacer()
                        Button(OnlineAPIStrings.replace, action: replace).buttonStyle(OnlineAPIButtonStyle(palette: palette, height: 26, horizontalPadding: 10))
                        Button(OnlineAPIStrings.delete, action: remove).buttonStyle(.plain).foregroundStyle(palette.red).padding(.horizontal, 10)
                    }
                    if config.provider.isAliyun, let until = model.snapshot.quotaValidUntil, model.snapshot.attention == nil {
                        Divider().overlay(palette.softLine)
                        row(OnlineAPIStrings.quota) {
                            Text(OnlineAPIStrings.confirmedQuota(config.provider, until: until)).fontWeight(.regular).foregroundStyle(palette.secondary)
                        }
                    }
                }.apiCard(palette)
                if !model.message.isEmpty { Text(model.message).font(.system(size: 12)).foregroundStyle(palette.red) }
            } else { emptyCard }
        }.font(.system(size: 13)).tint(palette.accent)
            .onChange(of: snapshot) { _, value in model.update(value) }
            .onDisappear { model.close() }
            .background(OnlineAPIWindowCloseGuard(closed: { model.close() }))
            .sheet(isPresented: $showingReconfirmation) {
                OnlineAPIReconfirmationView(provider: model.snapshot.configuration?.provider ?? .aliyunBailian,
                    look: { openQuota(model.snapshot.configuration?.provider ?? .aliyunBailian) },
                    confirm: { try await confirmQuota(); try Task.checkCancellation(); showingReconfirmation = false },
                    disable: { try await disableOnline(); try Task.checkCancellation(); showingReconfirmation = false })
            }
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).fontWeight(.regular).foregroundStyle(palette.secondary).frame(width: 70, alignment: .leading)
            content().frame(minHeight: 20)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 11)
    }
    private var emptyCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "key").font(.system(size: 18)).foregroundStyle(palette.secondary)
                .frame(width: 34, height: 34).background(palette.softLine, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(OnlineAPIStrings.panelEmptyTitle).font(.system(size: 13.5, weight: .semibold))
                Text(OnlineAPIStrings.panelEmptyDetail).font(.system(size: 12, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(OnlineAPIStrings.freeCreate) { configure(.guide) }.buttonStyle(OnlineAPIButtonStyle(palette: palette, height: 26, horizontalPadding: 10))
            Button(OnlineAPIStrings.configure) { configure(.form) }.buttonStyle(OnlineAPIButtonStyle(palette: palette, primary: true, height: 26, horizontalPadding: 10))
        }.padding(.vertical, 18).padding(.horizontal, 16).apiCard(palette)
    }
    private func banner(_ attention: OnlineAPIPanelSnapshot.Attention, provider: OnlineAPIProvider) -> some View {
        let title: String
        let detail: String
        let button: String
        switch attention {
        case .keyRejected:
            title = OnlineAPIStrings.keyRejectedTitle; detail = OnlineAPIStrings.keyRejectedDetail(provider); button = OnlineAPIStrings.replaceKey
        case .freeQuotaExhausted:
            title = OnlineAPIStrings.quotaExhaustedTitle; detail = OnlineAPIStrings.quotaExhaustedDetail; button = OnlineAPIStrings.changeModel
        case .confirmationExpired:
            title = OnlineAPIStrings.quotaExpiredTitle; detail = OnlineAPIStrings.quotaExpiredDetail(provider); button = OnlineAPIStrings.confirm
        }
        return HStack(spacing: 10) {
            Text(title).fontWeight(.semibold).foregroundStyle(.orange)
            Text(detail).fontWeight(.regular).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button) {
                switch attention {
                case .keyRejected: replace()
                case .freeQuotaExhausted:
                    if let id = model.snapshot.models.first(where: { $0 != model.snapshot.configuration?.modelID }) { model.selectModel(id) }
                case .confirmationExpired: showingReconfirmation = true
                }
            }.buttonStyle(OnlineAPIButtonStyle(palette: palette, primary: true, height: 26, horizontalPadding: 10))
        }.font(.system(size: 12.5)).padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.orange.opacity(palette.dark ? 0.18 : 0.14), in: RoundedRectangle(cornerRadius: 10))
    }
    private func openQuota(_ provider: OnlineAPIProvider) {
        if let url = URL(string: OnlineAPIPublicLinks.quota(provider)) { NSWorkspace.shared.open(url) }
        quotaTip = provider == .aliyunBailian
    }
}

struct OnlineAPIReconfirmationView: View {
    let provider: OnlineAPIProvider
    let look: () -> Void
    let confirm: () async throws -> Void
    let disable: () async throws -> Void
    @State private var message = ""
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @Environment(\.colorScheme) private var colorScheme
    private var palette: OnlineAPIPalette { .init(dark: colorScheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OnlineAPIStrings.reconfirmTitle).font(.system(size: 16, weight: .semibold))
            Text(OnlineAPIStrings.reconfirmText(provider)).font(.system(size: 13, weight: .regular)).fontWeight(.regular).foregroundStyle(palette.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            HStack(spacing: 8) {
                Button(OnlineAPIStrings.reconfirmOff) { perform(disable) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Button(OnlineAPIStrings.reconfirmLook, action: look).buttonStyle(OnlineAPIButtonStyle(palette: palette))
                Button(OnlineAPIStrings.reconfirmYes) { perform(confirm) }.buttonStyle(OnlineAPIButtonStyle(palette: palette, primary: true))
            }.padding(.top, 18)
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(palette.red).padding(.top, 8) }
        }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 16).frame(width: 420)
            .disabled(busy)
            .onDisappear { task?.cancel(); task = nil }
            .background(OnlineAPIWindowCloseGuard(closed: { task?.cancel(); task = nil }))
            .background(palette.window, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 12)
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        task = Task { @MainActor in
            defer { busy = false }
            do { try await action(); try Task.checkCancellation(); message = "" }
            catch { if !Task.isCancelled { message = OnlineAPIStrings.reconfirmFailed } }
        }
    }
}
