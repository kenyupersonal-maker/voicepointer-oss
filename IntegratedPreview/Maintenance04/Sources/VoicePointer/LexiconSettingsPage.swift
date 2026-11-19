// T6 2026-10-02: Separate total lexicon size from per-dictation hints and keep edit groups collapsed.
import SwiftUI
import VoicePointerCore

/// 「个人词库」页：管理词条、开关，以及从最近听写一键纠错。
///
/// 一个词条 = 一个正确写法 + 若干识别错的写法。听写出来的文字在写进输入框之前，按字面把错的写法换成正确的写法
/// （英文不分大小写，中文至少两个字）。词库只作用在应用自己识别出来的文字上（本地识别、阿里云）；豆包输入法的文字由输入法直接写入，
/// 应用拿不到，所以词库管不到它。
@MainActor
struct LexiconSettingsPage: View {
    @ObservedObject var lexicon: LexiconRuntime
    @ObservedObject private var learning = CorrectionLearningRuntime.shared
    @ObservedObject private var memory = RecognitionMemoryRuntime.shared
    let providerStore: ProviderSettingsStore
    let usesDoubao: Bool
    let reviewFixture: SettingsReviewLexiconFixture?

    @State private var applyEnabled: Bool
    @State private var hotwordsEnabled: Bool
    @State private var recentContextEnabled: Bool
    @State private var learnEnabled: Bool
    @State private var newCanonical = ""
    @State private var newVariants = ""
    @State private var addNote: PageNote?
    @State private var deletedNoticeToken: UUID?
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var termsSearchCache = LexiconTermSearchCache()
    @State private var searchCacheInitialized = false
    @State private var editing: LexiconTerm?
    @State private var fixing: DictationRecord?
    @State private var confirmClearAll = false
    @State private var confirmRecover = false
    @State private var recoverNote = ""
    @State private var busy = false

    private var presentation: LexiconSettingsPresentation {
        LexiconSettingsPresentation(termCount: lexicon.terms.count, pendingCount: learning.pending.count)
    }

    struct PageNote: Equatable {
        let text: String
        let isError: Bool
    }

    init(
        lexicon: LexiconRuntime,
        providerStore: ProviderSettingsStore,
        usesDoubao: Bool,
        reviewFixture: SettingsReviewLexiconFixture? = nil
    ) {
        self.lexicon = lexicon
        self.providerStore = providerStore
        self.usesDoubao = usesDoubao
        self.reviewFixture = reviewFixture
        _applyEnabled = State(initialValue: providerStore.value.applyPersonalLexicon)
        _hotwordsEnabled = State(initialValue: providerStore.value.useHotwordsLocally)
        _recentContextEnabled = State(initialValue: providerStore.value.useRecentContextLocally)
        _learnEnabled = State(initialValue: providerStore.value.learnCorrections)
    }

    var body: some View {
        // 2026-11-07: same page body as the other pages; the term list inside is a LazyVStack, so only the rows
        // on screen are built (the old List did the same; a Form built the whole lexicon at once).
        SettingsPageBody(SettingsPage.lexicon.title) {
            switch lexicon.availability {
            case .ready:
                summarySection
                switchSection
                termsSection
                addSection
                learningSection
                if !learning.justLearned.isEmpty { justLearnedSection }
                recentSection
            case .loading:
                SettingsGroup {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(SettingsStrings.lexiconSettingsPageCopy001).foregroundStyle(.secondary)
                    }
                }
            case .malformed:
                problemSection(
                    SettingsStrings.lexiconSettingsPageCopy002,
                    action: (SettingsStrings.lexiconSettingsPageCopy003, { confirmRecover = true })
                )
            case .unsupportedVersion:
                problemSection(SettingsStrings.lexiconSettingsPageCopy004, action: nil)
            case .unavailable:
                problemSection(
                    SettingsStrings.lexiconSettingsPageCopy005,
                    action: (SettingsStrings.lexiconSettingsPageCopy006, { Task { await lexicon.reload() } })
                )
            }
        }
        .onAppear {
            if !searchCacheInitialized {
                searchCacheInitialized = true
                rebuildVisibleTerms()
            }
        }
        .onChange(of: lexicon.terms) { _, _ in rebuildVisibleTerms() }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard !Task.isCancelled else { return }
            if debouncedQuery != query {
                debouncedQuery = query
                rebuildVisibleTerms()
            }
        }
        .task {
            #if SETTINGS_REVIEW_HOST
            if let reviewFixture {
                lexicon.installSettingsReviewFixture(termCount: reviewFixture.termCount)
                learning.installSettingsReviewFixture(pendingCount: reviewFixture.pendingCount)
            } else {
                lexicon.pruneRecent()
                learning.refresh()
            }
            #else
            lexicon.pruneRecent()
            learning.refresh()
            #endif
        }
        .sheet(item: $editing) { term in
            LexiconTermEditor(term: term, save: { canonical, variants, enabled in
                await lexicon.update(id: term.id, canonical: canonical, variants: variants, isEnabled: enabled)
            })
        }
        .sheet(item: $fixing) { record in
            LexiconFixSheet(record: record, save: { suggestion in
                let result = await lexicon.add(
                    canonical: suggestion.canonical, variants: [suggestion.variant], source: .recentFix
                )
                if case .success(let added) = result { addNote = Self.note(forAdded: added) }
                return result
            })
        }
        .confirmationDialog(SettingsStrings.lexiconSettingsPageCopy007, isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button(SettingsStrings.lexiconSettingsPageCopy008, role: .destructive) {
                Task {
                    let result = await lexicon.removeAll()
                    if case .failure(let error) = result { addNote = PageNote(text: Self.message(for: error), isError: true) }
                }
            }
            Button(SettingsStrings.cancel, role: .cancel) {}
        } message: {
            Text(SettingsStrings.lexiconSettingsPageCopy010)
        }
        .confirmationDialog(SettingsStrings.lexiconSettingsPageCopy011, isPresented: $confirmRecover, titleVisibility: .visible) {
            Button(SettingsStrings.lexiconSettingsPageCopy012, role: .destructive) {
                Task {
                    let ok = await lexicon.recoverMalformed()
                    recoverNote = ok ? "" : SettingsStrings.lexiconSettingsPageCopy013
                }
            }
            Button(SettingsStrings.cancel, role: .cancel) {}
        } message: {
            Text(SettingsStrings.lexiconSettingsPageCopy015)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(SettingsStrings.lexiconTermCountSummary(presentation.termCount))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    Spacer(minLength: 8)
                    InfoPopoverButton(text: SettingsStrings.lexiconHotwordHelp)
                }
                Text(SettingsStrings.lexiconSettingsPageCopy018)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if deletedNoticeToken != nil {
                    Text(SettingsStrings.lexiconDeletedNotice)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var switchSection: some View {
        SettingsGroup {
            Toggle(isOn: Binding(get: { applyEnabled }, set: { setApply($0) })) {
                SettingsRowLabel(SettingsStrings.lexiconSettingsPageCopy016, icon: "character.book.closed")
            }
            Toggle(isOn: Binding(get: { hotwordsEnabled }, set: { setHotwords($0) })) {
                SettingsRowLabel(SettingsStrings.lexiconSettingsPageCopy017, icon: "star")
            }
                .disabled(!applyEnabled)
            Text(hotwordsStatusLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { recentContextEnabled }, set: { setRecentContext($0) })) {
                SettingsRowLabel(SettingsStrings.recentContextToggle, icon: "clock.arrow.circlepath")
            }
            Text(SettingsStrings.recentContextHelp)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(SettingsStrings.recentContextCount(memory.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(SettingsStrings.recentContextClear) { memory.clear(reason: "button") }
            }
            .task {
                while !Task.isCancelled {
                    memory.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            if usesDoubao {
                Label(
                    SettingsStrings.lexiconSettingsPageCopy021,
                    systemImage: "info.circle"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !recoverNote.isEmpty {
                Text(recoverNote).font(.system(size: 12)).foregroundStyle(.orange)
            }
        } footer: {
            Text(SettingsStrings.lexiconSettingsPageCopy023)
        }
    }

    // T7: Independent controls at the bottom; no migration or status check can switch these on.
    private var learningSection: some View {
        SettingsGroup(SettingsStrings.learningSection) {
            Toggle(isOn: Binding(get: { learnEnabled }, set: { setLearn($0) })) {
                SettingsRowLabel(SettingsStrings.lexiconSettingsPageCopy019, icon: "graduationcap")
            }
            Text(SettingsStrings.lexiconSettingsPageCopy020)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the next dictation would hand to the recognizer, so the person can see the switch doing something.
    private var hotwordsStatusLine: String {
        guard applyEnabled, hotwordsEnabled else { return SettingsStrings.lexiconSettingsPageCopy024 }
        let selection = providerStore.value.selection
        guard selection.mode == .voiceNative, RecognitionHotwords.localRouteAccepts(selection.routeID) else {
            return SettingsStrings.lexiconSettingsPageCopy025
        }
        let count = lexicon.hotwords(applying: true).count
        return count == 0 ? SettingsStrings.lexiconSettingsPageCopy026 : SettingsStrings.lexiconSettingsPageCopy027(count)
    }

    private var addSection: some View {
        SettingsGroup {
        SettingsDisclosure(
            title: SettingsStrings.lexiconSettingsPageCopy033,
            initiallyExpanded: LexiconSettingsPresentation.manualAddDisclosureExpandedByDefault
        ) {
            TextField(SettingsStrings.lexiconSettingsPageCopy028, text: $newCanonical, prompt: Text(SettingsStrings.lexiconSettingsPageCopy029))
            TextField(SettingsStrings.lexiconSettingsPageCopy030, text: $newVariants, prompt: Text(SettingsStrings.lexiconSettingsPageCopy031))
            HStack(spacing: 10) {
                Button(SettingsStrings.lexiconSettingsPageCopy032) { addTerm() }
                    .disabled(busy || newCanonical.trimmingCharacters(in: .whitespaces).isEmpty)
                if let addNote {
                    Text(addNote.text)
                        .font(.system(size: 12))
                        .foregroundStyle(addNote.isError ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(SettingsStrings.lexiconSettingsPageCopy034)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    private func pendingSection(count: Int) -> some View {
        SettingsGroup {
        SettingsDisclosure(
            title: SettingsStrings.lexiconSettingsPageCopy036,
            count: count,
            initiallyExpanded: LexiconSettingsPresentation.pendingDisclosureExpandedByDefault
        ) {
            ForEach(learning.pending) { entry in
                pendingRow(entry)
            }
            Text(SettingsStrings.lexiconSettingsPageCopy037)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    private var justLearnedSection: some View {
        SettingsGroup {
        SettingsDisclosure(title: SettingsStrings.justLearnedTitle, count: learning.justLearned.count,
                           initiallyExpanded: true) {
            ForEach(learning.justLearned.prefix(5)) { entry in
                HStack {
                    Text(entry.hotwordOnly ? entry.canonical + SettingsStrings.learnedHotwordSuffix
                        : entry.variant + " → " + entry.canonical)
                    Spacer()
                    Button(SettingsStrings.justLearnedUndo) { Task { await learning.undo(entry) } }
                }
            }
        }
        }
    }

    private var termsSection: some View {
        SettingsGroup {
            if lexicon.terms.count > 8 {
                TextField(SettingsStrings.lexiconSettingsPageCopy038, text: $query, prompt: Text(SettingsStrings.lexiconSettingsPageCopy039))
            }
            if lexicon.terms.isEmpty {
                Text(SettingsStrings.lexiconSettingsPageCopy040)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                LazyVStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                    ForEach(termsSearchCache.visibleTerms) { term in
                        termRow(term)
                    }
                }
            }
            if !lexicon.terms.isEmpty {
                Button(SettingsStrings.lexiconSettingsPageCopy041, role: .destructive) { confirmClearAll = true }
            }
        } header: {
            Text(SettingsStrings.lexiconSettingsPageCopy042)
        }
    }

    private var recentSection: some View {
        SettingsGroup {
            let recent = lexicon.freshRecent
            if recent.isEmpty {
                Text(SettingsStrings.lexiconSettingsPageCopy043)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            } else {
                ForEach(recent) { record in
                    recentRow(record)
                }
                Button(SettingsStrings.lexiconSettingsPageCopy044) { lexicon.clearRecent() }
            }
        } header: {
            Text(SettingsStrings.lexiconSettingsPageCopy045)
        } footer: {
            Text(SettingsStrings.lexiconSettingsPageCopy046)
        }
    }

    private func problemSection(_ text: String, action: (String, () -> Void)?) -> some View {
        SettingsGroup {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
            }
        }
    }

    // MARK: - Rows

    private func deleteTerm(_ term: LexiconTerm) {
        if term.source == .automaticallyLearned {
            Task {
                // Every user deletion of an automatic pair must persist its permanent ban first.
                if !(await learning.undoAutomaticallyLearned(term)) {
                    addNote = PageNote(text: SettingsStrings.lexiconSettingsPageCopy055, isError: true)
                }
            }
            return
        }
        Task {
            let result = await lexicon.remove(id: term.id)
            switch result {
            case .success:
                // No existing ordinary-term undo contract: show a truthful five-second notice.
                let token = UUID()
                deletedNoticeToken = token
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if deletedNoticeToken == token { deletedNoticeToken = nil }
            case .failure:
                report(result)
            }
        }
    }

    private func termRow(_ term: LexiconTerm) -> some View {
        LexiconTermRowView(
            term: term,
            onEdit: { editing = term },
            onDelete: { deleteTerm(term) },
            onSetEnabled: { enabled in
                Task { report(await lexicon.setEnabled(id: term.id, enabled)) }
            }
        )
    }

    private func pendingRow(_ entry: CorrectionLedger.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SettingsStrings.correction(entry.variant, entry.canonical))
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                Text(Self.pendingLine(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(SettingsStrings.lexiconSettingsPageCopy051) { acceptPending(entry) }
                .controlSize(.small)
                .disabled(busy)
            Button(SettingsStrings.lexiconSettingsPageCopy052) { learning.dismiss(entry) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func recentRow(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.text)
                .font(.system(size: 13))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(record.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !record.hits.isEmpty {
                    Text(SettingsStrings.lexiconSettingsPageCopy053(record.hits.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(SettingsStrings.lexiconSettingsPageCopy054) { fixing = record }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    // Reuse the tested calculation path; rendering never filters the full list.
    private func rebuildVisibleTerms() {
        _ = termsSearchCache.update(terms: lexicon.terms, query: debouncedQuery)
    }

    /// A failed switch or delete says so at the top of the page instead of silently snapping back.
    private func report(_ result: Result<Void, LexiconStore.StoreError>) {
        if case .failure(let error) = result { addNote = PageNote(text: Self.message(for: error), isError: true) }
    }

    private func setApply(_ enabled: Bool) {
        var preferences = providerStore.value
        preferences.applyPersonalLexicon = enabled
        do {
            try providerStore.update(preferences)
            applyEnabled = enabled
            RuntimeTrace.record("lexicon apply enabled=\(enabled)")
        } catch {
            applyEnabled = providerStore.value.applyPersonalLexicon
            addNote = PageNote(text: SettingsStrings.lexiconSettingsPageCopy055, isError: true)
        }
    }

    private func setHotwords(_ enabled: Bool) {
        var preferences = providerStore.value
        preferences.useHotwordsLocally = enabled
        do {
            try providerStore.update(preferences)
            hotwordsEnabled = enabled
            RuntimeTrace.record("lexicon hotwords enabled=\(enabled)")
        } catch {
            hotwordsEnabled = providerStore.value.useHotwordsLocally
            addNote = PageNote(text: SettingsStrings.lexiconSettingsPageCopy055, isError: true)
        }
    }

    private func setRecentContext(_ enabled: Bool) {
        var preferences = providerStore.value
        preferences.useRecentContextLocally = enabled
        do {
            try providerStore.update(preferences)
            recentContextEnabled = enabled
            if !enabled { memory.clear(reason: "toggleOff") }
        } catch {
            recentContextEnabled = providerStore.value.useRecentContextLocally
            addNote = PageNote(text: SettingsStrings.lexiconSettingsPageCopy055, isError: true)
        }
    }

    private func setLearn(_ enabled: Bool) {
        var preferences = providerStore.value
        preferences.learnCorrections = enabled
        do {
            try providerStore.update(preferences)
            learnEnabled = enabled
            if !enabled { learning.stopLearning() }
            RuntimeTrace.record("learn enabled=\(enabled)")
        } catch {
            learnEnabled = providerStore.value.learnCorrections
            addNote = PageNote(text: SettingsStrings.lexiconSettingsPageCopy055, isError: true)
        }
    }

    private func acceptPending(_ entry: CorrectionLedger.Entry) {
        busy = true
        Task {
            let result = await learning.accept(entry)
            busy = false
            switch result {
            case .added(let added): addNote = Self.note(forAdded: added)
            case .refused(let reason): addNote = PageNote(text: Self.message(forRefused: reason), isError: true)
            case .failed(let error): addNote = PageNote(text: Self.message(for: error), isError: true)
            }
        }
    }

    private func addTerm() {
        let variants = Self.splitVariants(newVariants)
        // A plain word this short would neither replace anything nor be handed to the recognizer.
        if variants.isEmpty,
           newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).count < RecognitionHotwords.minimumCharacters {
            addNote = PageNote(text: SettingsStrings.lexiconSettingsPageCopy058, isError: true)
            return
        }
        busy = true
        Task {
            let result = await lexicon.add(canonical: newCanonical, variants: variants, source: .manual)
            busy = false
            switch result {
            case .success(let added):
                // Nothing typed as a wrong spelling and the word was already there: nothing was merged.
                addNote = variants.isEmpty && added.kind != .created
                    ? PageNote(text: SettingsStrings.lexiconSettingsPageCopy059(added.term.canonical), isError: false)
                    : Self.note(forAdded: added)
                newCanonical = ""
                newVariants = ""
            case .failure(let error):
                addNote = PageNote(text: Self.message(for: error), isError: true)
            }
        }
    }

    // MARK: - Text

    /// Splits what the person typed into wrong spellings: commas (either width), 顿号, semicolons, new lines.
    static func splitVariants(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The editor lists one wrong spelling per line, so a spelling that contains a comma survives editing.
    static func splitLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func pendingLine(_ entry: CorrectionLedger.Entry) -> String {
        var text = SettingsStrings.lexiconSettingsPageCopy060(entry.sightings)
        if entry.confidence == .strong {
            let sameLetters = entry.variant.filter { !$0.isWhitespace }.lowercased()
                == entry.canonical.filter { !$0.isWhitespace }.lowercased()
            text += sameLetters ? SettingsStrings.lexiconSettingsPageCopy061 : SettingsStrings.lexiconSettingsPageCopy062
        }
        return text
    }

    /// Why a suggestion was not added after all: the lexicon changed since it was made.
    static func message(forRefused reason: String) -> String {
        switch reason {
        case "variantOwned": return SettingsStrings.lexiconSettingsPageCopy063
        case "variantIsCanonical": return SettingsStrings.lexiconSettingsPageCopy064
        case "canonicalIsVariant": return SettingsStrings.lexiconSettingsPageCopy065
        case "canonicalSwitchedOff": return SettingsStrings.lexiconSettingsPageCopy066
        default: return SettingsStrings.lexiconSettingsPageCopy067
        }
    }

    static func variantsLine(_ term: LexiconTerm) -> String {
        term.variants.isEmpty ? SettingsStrings.lexiconSettingsPageCopy068 : SettingsStrings.lexiconSettingsPageCopy069 + term.variants.joined(separator: "、")
    }

    static func note(forAdded added: LexiconStore.AddResult) -> PageNote {
        var text = added.kind == .created
            ? SettingsStrings.lexiconSettingsPageCopy070(added.term.canonical)
            : SettingsStrings.lexiconSettingsPageCopy071(added.term.canonical)
        if !added.takenFrom.isEmpty {
            text += SettingsStrings.lexiconSettingsPageCopy072(added.takenFrom.joined(separator: "」「"))
        }
        return PageNote(text: text, isError: false)
    }

    static func message(for error: LexiconStore.StoreError) -> String {
        switch error {
        case .validation(let problem): return problem.message
        case .notLoaded: return SettingsStrings.lexiconSettingsPageCopy073
        case .unavailable: return SettingsStrings.lexiconSettingsPageCopy074
        case .malformed, .unsupportedVersion: return SettingsStrings.lexiconSettingsPageCopy075
        case .changedOnDisk: return SettingsStrings.lexiconSettingsPageCopy076
        }
    }
}

/// Only a visible row observes hover, so moving the pointer does not rebuild
/// the whole 2,000-item settings list or invalidate the search cache.
@MainActor
private struct LexiconTermRowView: View {
    let term: LexiconTerm
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetEnabled: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(term.canonical)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(term.isEnabled ? Color.primary : Color.secondary)
                Text(LexiconSettingsPage.variantsLine(term))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if term.hitCount > 0 {
                    Text(SettingsStrings.lexiconSettingsPageCopy047(term.hitCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)

            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(SettingsStrings.lexiconSettingsPageCopy049)
                .opacity(isHovered ? 1 : 0)
                .disabled(!isHovered)
                .accessibilityHidden(!isHovered)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(SettingsStrings.lexiconSettingsPageCopy050)
                .opacity(isHovered ? 1 : 0)
                .disabled(!isHovered)
                .accessibilityHidden(!isHovered)

            Toggle(SettingsStrings.lexiconSettingsPageCopy048, isOn: Binding(
                get: { term.isEnabled },
                set: { enabled in onSetEnabled(enabled) }
            ))
            .toggleStyle(SettingsBareSwitchStyle())
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(SettingsStrings.lexiconSettingsPageCopy049, action: onEdit)
            Button(SettingsStrings.lexiconSettingsPageCopy050, role: .destructive, action: onDelete)
        }
    }
}

/// 编辑一个词条：正确写法、错写、开关。
private struct LexiconTermEditor: View {
    let term: LexiconTerm
    let save: (String, [String], Bool) async -> Result<LexiconStore.AddResult, LexiconStore.StoreError>

    @Environment(\.dismiss) private var dismiss
    @State private var canonical: String
    @State private var variants: String
    @State private var isEnabled: Bool
    @State private var busy = false
    @State private var errorText = ""

    init(
        term: LexiconTerm,
        save: @escaping (String, [String], Bool) async -> Result<LexiconStore.AddResult, LexiconStore.StoreError>
    ) {
        self.term = term
        self.save = save
        _canonical = State(initialValue: term.canonical)
        _variants = State(initialValue: term.variants.joined(separator: "\n"))
        _isEnabled = State(initialValue: term.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SettingsStrings.lexiconSettingsPageCopy077).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsStrings.lexiconSettingsPageCopy028).font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("", text: $canonical).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsStrings.lexiconSettingsPageCopy079).font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $variants)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            Toggle(SettingsStrings.lexiconSettingsPageCopy080, isOn: $isEnabled)
            if !errorText.isEmpty {
                Text(errorText).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(SettingsStrings.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(SettingsStrings.save) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || canonical.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        busy = true
        Task {
            let result = await save(canonical, LexiconSettingsPage.splitLines(variants), isEnabled)
            busy = false
            switch result {
            case .success: dismiss()
            case .failure(let error): errorText = LexiconSettingsPage.message(for: error)
            }
        }
    }
}

/// 纠正一句最近的听写：把句子改成想要的样子，自动算出「错写 → 正确写法」，确认后加入词库。
private struct LexiconFixSheet: View {
    let record: DictationRecord
    let save: (CorrectionDiff.Suggestion) async -> Result<LexiconStore.AddResult, LexiconStore.StoreError>

    @Environment(\.dismiss) private var dismiss
    @State private var edited: String
    @State private var busy = false
    @State private var errorText = ""

    init(
        record: DictationRecord,
        save: @escaping (CorrectionDiff.Suggestion) async -> Result<LexiconStore.AddResult, LexiconStore.StoreError>
    ) {
        self.record = record
        self.save = save
        _edited = State(initialValue: record.text)
    }

    private var outcome: Result<CorrectionDiff.Suggestion, CorrectionDiff.Rejection>? {
        edited == record.text ? nil : record.suggestion(afterEditingTo: edited)
    }

    private var suggestion: CorrectionDiff.Suggestion? {
        if case .success(let value)? = outcome { return value }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SettingsStrings.lexiconSettingsPageCopy083).font(.headline)
            Text(SettingsStrings.lexiconSettingsPageCopy084)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("", text: $edited, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
            previewLine
            if !errorText.isEmpty {
                Text(errorText).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(SettingsStrings.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(SettingsStrings.lexiconSettingsPageCopy051) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || suggestion == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var previewLine: some View {
        switch outcome {
        case .none:
            EmptyView()
        case .success(let value)?:
            Label(SettingsStrings.lexiconSettingsPageCopy087(value.variant, value.canonical), systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let rejection)?:
            Label(rejection.message, systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        guard let suggestion else { return }
        busy = true
        Task {
            let result = await save(suggestion)
            busy = false
            switch result {
            case .success: dismiss()
            case .failure(let error): errorText = LexiconSettingsPage.message(for: error)
            }
        }
    }
}
