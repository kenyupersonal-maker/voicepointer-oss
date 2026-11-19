// T12 2026-10-02: Production grouped Form; all operations flow through the shared, injectable data VM.
import SwiftUI
import VoicePointerCore

@MainActor struct DataSettingsPage: View {
    @ObservedObject var runtime: SettingsLogicRuntime
    let review: Bool
    @State private var showRemoval = false
    @State private var showLexiconRemoval = false
    @State private var confirmedIntent = false
    private var data: DataManagementViewModel { runtime.data }

    private static func icon(for id: ManagedDataID) -> String {
        switch id {
        case .model17, .model06, .punctuation, .modelDownloads: "shippingbox"
        case .diagnosticLogs: "doc.text"
        case .touchSamples: "magicmouse"
        case .personalLexicon: "character.book.closed"
        }
    }

    var body: some View {
        SettingsPageBody(SettingsPage.data.title) {
            SettingsGroup {
                if data.phase == .loading || data.phase == .idle {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(SettingsStrings.dataLoading) }
                        .accessibilityLabel(SettingsStrings.dataLoading)
                } else {
                    if data.phase == .error {
                        Label(SettingsStrings.dataFailure(data.failure), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        Button(SettingsStrings.dataReload) { Task { await data.refresh() } }
                            .accessibilityLabel(SettingsStrings.dataReload)
                    }
                    if data.items.isEmpty && data.phase != .error {
                        Text(SettingsStrings.dataEmpty).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(data.items, id: \.id) { item in
                        HStack(spacing: 12) {
                            SettingsRowLabel(SettingsStrings.dataName(item.id), icon: Self.icon(for: item.id))
                            Spacer(minLength: 8)
                            Text(SettingsStrings.dataSize(item.sizeBytes)).font(.system(size: 12.5))
                                .foregroundStyle(.secondary).monospacedDigit()
                            Button(SettingsStrings.delete, role: .destructive) { Task { await data.delete(item.id) } }
                                .accessibilityLabel(SettingsStrings.deleteDataName(item.id))
                        }
                    }
                }
            } header: {
                Text(SettingsStrings.dataDownloaded)
            }
            if data.phase != .loading && data.phase != .idle && data.confirmation != .confirmed {
                SettingsGroup(SettingsStrings.dataLexiconSection) {
                    HStack(spacing: 12) {
                        SettingsRowLabel(SettingsStrings.dataClearLexicon, icon: "character.book.closed")
                        Spacer(minLength: 8)
                        Button(SettingsStrings.delete, role: .destructive) { showLexiconRemoval = true }
                            .accessibilityLabel(SettingsStrings.dataClearLexicon)
                    }
                }
                SettingsGroup {
                    HStack(spacing: 12) {
                        SettingsRowLabel(SettingsStrings.dataPrepareUninstall, icon: "trash")
                        Spacer(minLength: 8)
                        Button(SettingsStrings.delete, role: .destructive) {
                            data.requestUninstall(); showRemoval = data.confirmation == .requested
                        }
                        .accessibilityLabel(SettingsStrings.dataPrepareUninstall)
                    }
                }
            }
        }
        .accessibilityValue(data.phase.rawValue)
        .task { if !review { await data.refresh() } }
        .confirmationDialog(SettingsStrings.dataRemovalTitle, isPresented: $showRemoval, titleVisibility: .visible) {
            Button(SettingsStrings.delete, role: .destructive) {
                confirmedIntent = true
                Task { await data.confirmUninstall(); confirmedIntent = false }
            }
            Button(SettingsStrings.cancel, role: .cancel) { data.cancelUninstall() }
        } message: { Text(SettingsStrings.dataRemovalDetail(data.items, total: data.totalBytes)) }
        .onChange(of: showRemoval) { _, shown in if !shown && !confirmedIntent { data.cancelUninstall() } }
        .confirmationDialog(SettingsStrings.dataClearLexiconTitle, isPresented: $showLexiconRemoval, titleVisibility: .visible) {
            Button(SettingsStrings.delete, role: .destructive) { Task { await data.clearLexicon() } }
            Button(SettingsStrings.cancel, role: .cancel) {}
        } message: { Text(SettingsStrings.dataClearLexiconDetail) }
    }
}
