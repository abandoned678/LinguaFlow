@preconcurrency import AppKit
@preconcurrency import Carbon
@preconcurrency import InputMethodKit
import InputCore
import LocalTranslation
import OSLog
import RimeInput
import InputSession
#if DEBUG && IME_TEST_BUILD
import IMETrace
#endif

@objc(InputMethodController)
@MainActor
final class InputMethodController: IMKInputController {
    #if DEBUG && IME_TEST_BUILD
    private let probe = DebugIMEProbe()
    private let compositionLog = DebugCompositionLog()
    #endif
    private let product = InputProduct.current
    private var isActive = false
    private var activeClient: (any IMKTextInput)?
    private struct HostRanges {
        let client: ObjectIdentifier
        var selection: NSRange?
        var marked: NSRange?
    }
    private var eventRanges: HostRanges?
    private var engine: RimeEngine?
    private var observedHostMark = false
    private var palettesHidden = false
    private var currentPreedit = ""
    private var preeditCaret = 0
    private var currentCandidates: [RimeCandidate] = []
    private var currentHighlightedIndex = 0
    private var candidateRevision: UInt64 = 0
    private var canPageBackward = false
    private var canPageForward = false
    private var activeApplicationPID: pid_t?
    private lazy var sentenceBuffer = CommittedSentenceBuffer(maxCharacters: 280, periodEndsSentence: product == .english)
    private var settings = InputSettingsStore.shared.read()
    private var translationNotice: String?
    private var noticeTask: Task<Void, Never>?
    private var lastPresentedTranslation: UUID?
    private static let timing = OSSignposter(
        subsystem: "com.abandoned678.inputmethod.SentenceAlong", category: "InputTiming"
    )
    private static let logger = Logger(
        subsystem: "com.abandoned678.inputmethod.SentenceAlong", category: "InputTiming"
    )
    private var isUpdatingDraft = false
    private var spellingCorrection: EnglishSpellingCorrection?
    private var spellCheckRevision: UInt64 = 0
    private var spellCheckTask: Task<Void, Never>?
    private var expectedHostCaretLocation: Int?
    private var pendingHostLineBreak: Int?
    private let englishSpellChecker = EnglishSpellChecker()
    private var englishCandidateContext: EnglishCandidateContext?
    private var candidateMeaningRevision: UInt64 = 0
    private var candidateMeaningTask: Task<Void, Never>?
    private var candidateMeaningCache: [String: String] = [:]
    private var candidateTranslationProvider: OnDeviceTranslationProvider?
    private var lastValidAnchor: NSRect?
    private var positionRefreshTask: Task<Void, Never>?
    private let panelController = PreviewPanelController.shared
    private var coordinator: TranslationCoordinator!

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        activeClient = inputClient as? any IMKTextInput
        if product.usesRime {
            engine = AppEnvironment.shared.makeEngine(clientBundleID: activeClient?.bundleIdentifier())
        }

        let sentenceTranslationProvider = OnDeviceTranslationProvider(
            direction: product.translationDirection
        )
        coordinator = TranslationCoordinator(provider: sentenceTranslationProvider)
        coordinator.speed = settings.speed
        coordinator.setEnabled(settings.translationEnabled)
        if product == .english {
            candidateTranslationProvider = OnDeviceTranslationProvider(direction: .englishToChinese)
        }
        coordinator.onStateChange = { [weak self] state in
            guard let self, self.isActive, !self.isUpdatingDraft else { return }
            guard state != .hidden else { return }
            guard !IsSecureEventInputEnabled() else {
                self.clearDocumentContext(.secureInput)
                return
            }
            self.reconcileTrackedCaret(client: self.activeClient)
            guard self.coordinator.state == state else { return }
            self.renderPanel(client: self.activeClient)
        }
        let notifications = DistributedNotificationCenter.default()
        notifications.addObserver(self, selector: #selector(settingsDidChange(_:)), name: InputSettingsStore.didChange, object: nil)
        notifications.addObserver(self, selector: #selector(refreshModelStatus(_:)), name: LocalTranslationModels.statusDidChange, object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func activateServer(_ sender: Any!) {
        if isActive {
            clearDocumentContext(.reactivated)
        } else {
            #if DEBUG && IME_TEST_BUILD
            compositionLog.activated()
            #endif
        }
        activeClient = sender as? any IMKTextInput
        activeApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        #if DEBUG && IME_TEST_BUILD
        probe.activate(client: activeClient)
        #endif
        palettesHidden = false
        isActive = true
        reloadSettings()
    }

    override func deactivateServer(_ sender: Any!) {
        #if DEBUG && IME_TEST_BUILD
        probe.stop()
        #endif
        isActive = false
        clearDocumentContext(.deactivated)
        activeClient = nil
        activeApplicationPID = nil
    }

    override func inputControllerWillClose() {
        isActive = false
        #if DEBUG && IME_TEST_BUILD
        probe.stop()
        #endif
        clearDocumentContext(.controllerClosed, clearHostMark: false)
        activeClient = nil
        activeApplicationPID = nil
        super.inputControllerWillClose()
    }

    override func hidePalettes() {
        #if DEBUG && IME_TEST_BUILD
        if !palettesHidden {
            compositionLog.palettesHidden(composing: !currentPreedit.isEmpty,
                                          panelHasContent: panelController.ownsPanel(self) && panelController.hasContent)
        }
        #endif
        palettesHidden = true
        stopPositionRefresh()
        panelController.hide(owner: self)
        super.hidePalettes()
    }

    override func commitComposition(_ sender: Any!) {
        commitCurrentComposition(sender, source: .imkCallback)
    }

    private func commitCurrentComposition(_ sender: Any?, source: CompositionCommitSource) {
        guard isActive, !IsSecureEventInputEnabled(), !currentPreedit.isEmpty, let engine else { return }
        #if DEBUG && IME_TEST_BUILD
        compositionLog.commitRequested(source: source)
        #endif
        let snapshot = engine.commitComposition()
        apply(snapshot, client: client(from: sender))
    }

    override func composedString(_ sender: Any!) -> Any! {
        currentPreedit
    }

    override func selectionRange() -> NSRange {
        NSRange(location: preeditCaret, length: 0)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        []
    }

    override func menu() -> NSMenu! {
        reloadSettings()
        let menu = NSMenu(title: "随键译")
        let toggleItem = menu.addItem(withTitle: "启用翻译预览", action: #selector(toggleTranslation), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = settings.translationEnabled ? .on : .off
        menu.addItem(withTitle: "输入法设置…", action: #selector(openInputSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "准备本地翻译模型…", action: #selector(openTranslationSetup), keyEquivalent: "").target = self
        if product.usesRime, engine == nil, AppEnvironment.shared.health.state.isFailure {
            menu.addItem(.separator())
            let status = AppEnvironment.shared.health.state.label
            menu.addItem(withTitle: "\(status) · 查看诊断…", action: #selector(openDiagnostics), keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func toggleTranslation() {
        do {
            try InputSettingsStore.shared.update { $0.translationEnabled.toggle() }
            reloadSettings()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法保存翻译设置"
            alert.informativeText = "请检查随键译设置目录是否可以写入。"
            alert.runModal()
        }
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        reloadSettings()
    }

    private func reloadSettings() {
        let updated = InputSettingsStore.shared.read()
        let changed = updated.translationEnabled != settings.translationEnabled
        let appearanceChanged = updated.previewSize != settings.previewSize
            || updated.previewLayout != settings.previewLayout
            || updated.replacementKeyCode != settings.replacementKeyCode
        settings = updated
        coordinator.speed = updated.speed
        coordinator.setEnabled(updated.translationEnabled)
        guard isActive, changed || appearanceChanged else { return }
        guard !IsSecureEventInputEnabled() else {
            clearDocumentContext(.secureInput)
            return
        }
        guard changed else {
            renderPanel(client: activeClient)
            return
        }
        clearNotice()
        if !updated.translationEnabled {
            candidateMeaningRevision &+= 1
            candidateMeaningTask?.cancel()
            candidateMeaningTask = nil
            candidateMeaningCache.removeAll()
            if product == .english {
                currentCandidates = currentCandidates.map { RimeCandidate(text: $0.text, comment: nil) }
            }
            renderPanel(client: activeClient)
            return
        }
        guard let activeClient else {
            clearDocumentContext(.noActiveClient)
            return
        }
        reconcileTrackedCaret(client: activeClient)
        discardUnverifiedSentence(onResumeIn: activeClient)
        updateTranslationDraftAndPanel(client: activeClient)
        if product == .english, !currentCandidates.isEmpty {
            scheduleCandidateMeanings(for: currentCandidates.map(\.text))
        }
    }

    private func discardUnverifiedSentence(onResumeIn client: any IMKTextInput) {
        guard currentPreedit.isEmpty, let snapshot = sentenceBuffer.currentSnapshot, !snapshot.isOverlong else { return }
        let selection = readSelection(client)
        guard
            selection.location == expectedHostCaretLocation,
            let range = TrackedTextReplacement.hostRange(
                trackedText: snapshot.text,
                trackedUTF16Range: NSRange(location: 0, length: snapshot.text.utf16.count),
                currentSelection: selection
            ),
            client.attributedSubstring(from: range)?.string == snapshot.text
        else {
            clearTranslationContext()
            return
        }
    }

    @objc private func refreshModelStatus(_ notification: Notification) {
        guard notification.object as? String == product.translationDirection.rawValue else { return }
        if isActive {
            guard !IsSecureEventInputEnabled() else {
                clearDocumentContext(.secureInput)
                return
            }
            reconcileTrackedCaret(client: activeClient)
        }
        coordinator.modelStatusDidChange()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        guard isActive else {
            #if DEBUG && IME_TEST_BUILD
            if !IsSecureEventInputEnabled() { Self.timing.emitEvent("Inactive input controller") }
            #endif
            return false
        }
        palettesHidden = false
        let timing = Self.timing.beginInterval("Input event")
        defer { Self.timing.endInterval("Input event", timing) }
        let client = client(from: sender)
        eventRanges = client.map { HostRanges(client: ObjectIdentifier($0 as AnyObject)) }
        defer { eventRanges = nil }
        if let current = activeClient, let client,
           (current as AnyObject) !== (client as AnyObject) {
            clearDocumentContext(.clientChanged)
        }
        activeClient = client

        if IsSecureEventInputEnabled() {
            #if DEBUG && IME_TEST_BUILD
            probe.stop()
            #endif
            clearDocumentContext(.secureInput)
            return false
        }

        #if DEBUG && IME_TEST_BUILD
        probe.record(.key, client: client)
        #endif
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.option) {
            commitCurrentComposition(sender, source: .hostShortcut)
            clearDocumentContext(.hostShortcut)
            return false
        }

        if SentenceReplacementShortcut.matches(
            keyCode: event.keyCode,
            control: modifiers.contains(.control),
            shift: modifiers.contains(.shift),
            configuredKeyCode: settings.replacementKeyCode
        ) {
            if !event.isARepeat { replaceCurrentSentence(client: client) }
            return true
        }

        clearNotice()
        reconcileTrackedCaret(client: client)

        if isReturn(event), modifiers.contains(.control) {
            clearDocumentContext(.controlReturn)
            return false
        }

        if event.keyCode == 117 {
            commitCurrentComposition(sender, source: .forwardDelete)
            clearDocumentContext(.forwardDelete)
            return false
        }

        if product == .english {
            if modifiers.contains(.control) {
                clearDocumentContext(.englishControl)
                return false
            }
            return handleEnglish(event, client: client, modifiers: modifiers)
        }

        guard let engine else { return false }
        if activeApplicationPID == nil {
            activeApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        guard let key = rimeKeyMapping(for: event, modifiers: modifiers) else { return false }
        let snapshot = engine.process(keyCode: key.keyCode, modifiers: key.modifiers)
        apply(snapshot, client: client)

        if !snapshot.consumed {
            if isReturn(event), modifiers.isDisjoint(with: [.control, .command, .option]),
               currentPreedit.isEmpty {
                pendingHostLineBreak = expectedHostCaretLocation
            } else if event.keyCode == 51, !modifiers.contains(.control) {
                mirrorHostBackspace(client: client)
            } else if modifiers.contains(.control)
                || isNavigationKey(event.keyCode)
                || event.keyCode == 53 {
                clearDocumentContext(.navigationOrControl)
            }
        }

        return snapshot.consumed
    }

    private func replaceCurrentSentence(client: (any IMKTextInput)?) {
        guard let client else { return }
        let awaitedHostReturn = pendingHostLineBreak != nil
        if awaitedHostReturn { reconcileTrackedCaret(client: client) }

        let request: TranslationRequest?
        let translation: TranslationResult?
        if case .ready(let current, let result) = coordinator.state {
            request = current
            translation = result
        } else {
            request = nil
            translation = nil
        }
        let snapshot = sentenceBuffer.currentSnapshot
        let decision = TrackedTextReplacement.decision(
            enabled: settings.translationEnabled,
            snapshot: snapshot,
            translation: translation,
            currentRevision: request?.revision,
            expectedCaret: expectedHostCaretLocation,
            selection: readSelection(client),
            hasComposition: !currentPreedit.isEmpty || hasHostMarkedText(client)
        )
        switch decision {
        case .failure(let reason):
            if reason == .movedCaret || reason == .selection { clearDocumentContext(.replacementSelectionChanged) }
            showReplacementNotice(reason, client: client)
        case .success(let range):
            guard !awaitedHostReturn, let snapshot, let translation,
                  prepareReplacement(range, source: snapshot.text, translation: translation.translatedText, client: client),
                  TrackedTextReplacement.applyIfVerified(range, expected: snapshot.text,
                    read: { client.attributedSubstring(from: $0)?.string },
                    replace: { self.insert(translation.translatedText, in: $0, client: client) }) else {
                clearDocumentContext(.replacementRangeUnverified)
                showReplacementNotice(.unverifiedRange, client: client)
                return
            }
            clearDocumentContext(.translationReplaced)
        }
    }

    private func prepareReplacement(_ range: NSRange, source: String, translation: String,
                                    client: any IMKTextInput) -> Bool {
        var needsUndoBoundary = client.bundleIdentifier() == "com.apple.TextEdit"
        #if DEBUG && IME_TEST_BUILD
        needsUndoBoundary = needsUndoBoundary || client.bundleIdentifier() == TraceRun.hostID
        #endif
        guard needsUndoBoundary else { return true }
        guard let first = translation.first, client.attributedSubstring(from: range)?.string == source else { return false }
        // A cancelled inline composition at the sentence start moves NSTextView's
        // insertion point out of the preceding typing group without committing text.
        // IMK drops an empty mark unless an inline composition is already active.
        let start = NSRange(location: range.location, length: 0)
        let zero = NSRange(location: 0, length: 0)
        client.setMarkedText(NSAttributedString(string: String(first)), selectionRange: zero, replacementRange: start)
        client.setMarkedText("", selectionRange: zero, replacementRange: Self.notFoundRange)
        invalidateHostRanges()
        return !hasHostMarkedText(client) && readSelection(client) == start
    }

    private func showReplacementNotice(_ reason: TrackedTextReplacement.Rejection, client: any IMKTextInput) {
        clearNotice()
        translationNotice = reason.message
        renderPanel(client: client)
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.isActive, !IsSecureEventInputEnabled() else { return }
            self.clearNotice()
            self.renderPanel(client: self.activeClient)
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        translationNotice = nil
    }

    private func hasHostMarkedText(_ client: any IMKTextInput) -> Bool {
        let range = readMarkedRange(client)
        return range.location != NSNotFound && range.length > 0
    }

    private func apply(_ snapshot: RimeSnapshot, client: (any IMKTextInput)?) {
        let previousCandidate = Self.highlightedCandidate(currentCandidates, index: currentHighlightedIndex)
        let nextCandidate = Self.highlightedCandidate(snapshot.candidates, index: snapshot.highlightedIndex)
        let trigger = TranslationTrigger.compositionUpdate(
            commit: snapshot.commit,
            previousPreedit: currentPreedit,
            preedit: snapshot.preedit,
            highlightChanged: previousCandidate != nextCandidate || currentHighlightedIndex != snapshot.highlightedIndex
        )
        #if DEBUG && IME_TEST_BUILD
        if currentPreedit.isEmpty != snapshot.preedit.isEmpty {
            compositionLog.compositionEdge(began: currentPreedit.isEmpty, hasCommit: snapshot.commit?.isEmpty == false)
        }
        if nextCandidate == "你好" { probe.record(.candidateMatched, client: client) }
        #endif
        for edit in snapshot.hostEdits(previousPreedit: currentPreedit, previousCaret: preeditCaret) {
            switch edit {
            case .commit(let text):
                insert(text, in: Self.notFoundRange, client: client)
                if !IsSecureEventInputEnabled() {
                    sentenceBuffer.append(text)
                    recordCurrentCaret(client: client)
                }
            case .mark(let text):
                if currentPreedit.isEmpty || text.isEmpty { observedHostMark = false }
                currentPreedit = text
                preeditCaret = snapshot.caretUTF16
                setMarkedText(text, caret: preeditCaret, client: client)
            }
        }

        currentCandidates = snapshot.candidates
        currentHighlightedIndex = snapshot.highlightedIndex
        candidateRevision &+= 1
        canPageBackward = snapshot.canPageBackward
        canPageForward = snapshot.canPageForward
        updateTranslationDraftAndPanel(client: client, trigger: trigger)
    }

    private static func highlightedCandidate(_ candidates: [RimeCandidate], index: Int) -> String? {
        candidates.indices.contains(index) ? candidates[index].text : nil
    }

    private func updateTranslationDraftAndPanel(
        client: (any IMKTextInput)?,
        refreshEnglishCandidates: Bool = true,
        trigger: TranslationTrigger = .input
    ) {
        let candidate = currentPreedit.isEmpty || product != .chinese
            ? nil : Self.highlightedCandidate(currentCandidates, index: currentHighlightedIndex)
        let committed = sentenceBuffer.currentSnapshot
        let draft = LiveTranslationDraft.evaluate(committed: committed, provisionalCandidate: candidate)
        clearNotice()

        isUpdatingDraft = true
        switch draft {
        case .overlong:
            if settings.translationEnabled { translationNotice = "当前句超过 280 字" }
            coordinator.cancel()
        case .empty:
            if coordinator.state != .hidden { coordinator.cancel() }
        case .text(let text):
            let isFinal = committed?.isFinal == true && candidate == nil
            coordinator.submit(
                SentenceSnapshot(text: text, revision: sentenceBuffer.revision, isFinal: isFinal),
                trigger: trigger == .committedPunctuation && !isFinal ? .input : trigger
            )
        }
        isUpdatingDraft = false

        if product == .english {
            let text: String?
            if case .text(let value) = draft { text = value } else { text = nil }
            if refreshEnglishCandidates { updateEnglishCandidates(for: text) }
            scheduleSpellingCheck(for: text)
        }
        renderPanel(client: client)
    }

    private func renderPanel(client: (any IMKTextInput)?) {
        guard isActive, !palettesHidden else { return }
        guard activeApplicationPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            clearDocumentContext(.foregroundChangedOnRender, clearHostMark: false)
            return
        }
        let source: String?
        let translation: PreviewPanelController.TranslationState
        var action: (() -> Void)?
        switch coordinator.state {
        case .hidden:
            source = nil
            translation = translationNotice.map { .message($0) } ?? .hidden
        case .waiting(let request):
            source = request.sourceText
            translation = translationNotice.map { .message($0) } ?? .waiting
        case .translating(let request):
            source = request.sourceText
            translation = translationNotice.map { .message($0) } ?? .loading
        case .ready(let request, let result):
            source = request.sourceText
            translation = translationNotice.map { .message($0) } ?? .result(result.translatedText)
        case .failed(let request, let failure):
            source = request.sourceText
            #if DEBUG && IME_TEST_BUILD
            probe.record(failure == .modelsNotInstalled ? .translationUnavailable : .translationFailed, client: client)
            #endif
            if failure.canRetry {
                translation = .action(failure.message, button: "重试")
                action = { [weak self] in self?.retryTranslation(request) }
            } else if failure == .modelsNotInstalled {
                translation = .action(failure.message, button: "准备模型")
                action = { [weak self] in self?.openTranslationSetup() }
            } else {
                translation = .message(failure.message)
            }
        }

        panelController.update(
            owner: self,
            isComposing: !currentPreedit.isEmpty,
            sourceText: source,
            candidates: currentCandidates,
            highlightedIndex: currentHighlightedIndex,
            translation: translation,
            direction: product.translationDirection,
            spellingCorrection: spellingCorrection,
            settings: settings,
            candidateInteraction: mouseCandidateInteraction(),
            action: action
        )

        if panelController.hasContent {
            captureCaretAnchor(client: client)
            showPanel(client: client)
            if client != nil, lastValidAnchor != nil, case .result = translation,
               case .ready(let request, _) = coordinator.state, lastPresentedTranslation != request.id {
                #if DEBUG && IME_TEST_BUILD
                probe.record(.translationReady, client: client)
                #endif
                lastPresentedTranslation = request.id
                let duration = request.submittedAt.duration(to: .now).components
                let elapsedMS = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
                Self.logger.debug("stage=panelSubmitted elapsedMS=\(elapsedMS)")
            }
            startPositionRefresh()
        } else {
            stopPositionRefresh()
            panelController.hide(owner: self)
        }
    }

    private func mouseCandidateInteraction() -> PreviewPanelController.CandidateInteraction? {
        guard product.usesRime, !currentPreedit.isEmpty, !currentCandidates.isEmpty else { return nil }
        let revision = candidateRevision
        return .init(owner: ObjectIdentifier(self), revision: revision, canPageBackward: canPageBackward,
                     canPageForward: canPageForward) { [weak self] target in
            self?.handleMouseCandidate(target, revision: revision)
        }
    }

    private func handleMouseCandidate(_ target: PreviewPanelController.CandidateTarget, revision: UInt64) {
        guard isActive, panelController.ownsPanel(self), revision == candidateRevision,
              let activeApplicationPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == activeApplicationPID,
              !IsSecureEventInputEnabled(), let activeClient, let engine, !currentPreedit.isEmpty
        else { return }
        reconcileTrackedCaret(client: activeClient)
        guard revision == candidateRevision else { return }

        let snapshot: RimeSnapshot
        switch target {
        case .candidate(let index):
            guard currentCandidates.indices.contains(index) else { return }
            #if DEBUG && IME_TEST_BUILD
            if index == currentHighlightedIndex { probe.record(.mouseSelected, client: activeClient) }
            #endif
            snapshot = engine.selectCandidate(at: index)
        case .previousPage:
            guard canPageBackward else { return }
            snapshot = engine.changePage(backward: true)
        case .nextPage:
            guard canPageForward else { return }
            snapshot = engine.changePage(backward: false)
        }
        apply(snapshot, client: activeClient)
    }

    private func retryTranslation(_ request: TranslationRequest) {
        guard isActive, settings.translationEnabled, let activeClient, !IsSecureEventInputEnabled() else { return }
        reconcileTrackedCaret(client: activeClient)
        guard case .failed(let current, _) = coordinator.state, current.id == request.id else { return }
        translationNotice = nil
        coordinator.retry()
    }

    private func showPanel(client: (any IMKTextInput)?) {
        guard let client else { return }
        guard let lastValidAnchor else {
            panelController.hide(owner: self, relinquishOwnership: false)
            return
        }
        panelController.show(
            owner: self,
            near: lastValidAnchor,
            clientWindowLevel: client.windowLevel()
        )
        #if DEBUG && IME_TEST_BUILD
        if probe.needsClickPoint, currentCandidates.indices.contains(currentHighlightedIndex),
           currentCandidates[currentHighlightedIndex].text == "你好",
           let point = panelController.highlightedPoint() {
            probe.record(.candidateMatched, client: client, clickPoint: point)
        }
        #endif
    }

    private func startPositionRefresh() {
        guard positionRefreshTask == nil else { return }
        positionRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.refreshPanelPosition()
            }
        }
    }

    private func stopPositionRefresh() {
        positionRefreshTask?.cancel()
        positionRefreshTask = nil
    }

    private func refreshPanelPosition() {
        let interval = Self.timing.beginInterval("Check panel position")
        defer { Self.timing.endInterval("Check panel position", interval) }
        guard isActive, panelController.ownsPanel(self), let activeClient else {
            stopPositionRefresh()
            return
        }
        guard !IsSecureEventInputEnabled() else {
            clearDocumentContext(.secureInput)
            return
        }
        guard activeApplicationPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            clearDocumentContext(.foregroundChangedOnRefresh, clearHostMark: false)
            return
        }
        eventRanges = HostRanges(client: ObjectIdentifier(activeClient as AnyObject))
        defer { eventRanges = nil }
        if observedHostMark, let reason = hostCompositionResetReason(activeClient) {
            clearDocumentContext(reason, clearHostMark: false)
            return
        }
        reconcileTrackedCaret(client: activeClient)
        guard panelController.ownsPanel(self) else { return }
        captureCaretAnchor(client: activeClient)
        showPanel(client: activeClient)
    }

    private func hostCompositionResetReason(_ client: any IMKTextInput) -> ContextResetReason? {
        let mark = readMarkedRange(client)
        guard mark.location != NSNotFound else { return .markUnavailable }
        guard mark.length > 0 else { return .markEmpty }
        let caret = readSelection(client)
        guard caret.location != NSNotFound else { return .caretUnavailable }
        // Some clients retain the last IMK mark after clearing their editor. Only
        // verify our own composition, and only if the host caret has diverged.
        if caret == mark { return nil }
        if caret.length == 0, caret.location >= mark.location,
           caret.location - mark.location == preeditCaret { return nil }
        guard mark.length == currentPreedit.utf16.count else { return .markLengthMismatch }
        guard let markedText = client.attributedSubstring(from: mark)?.string else { return .markTextUnavailable }
        return markedText == currentPreedit ? nil : .markTextMismatch
    }

    private func readSelection(_ client: any IMKTextInput) -> NSRange {
        let matches = eventRanges?.client == ObjectIdentifier(client as AnyObject)
        if matches, let selection = eventRanges?.selection { return selection }
        let interval = Self.timing.beginInterval("Read selection")
        defer { Self.timing.endInterval("Read selection", interval) }
        let selection = client.selectedRange()
        if matches { eventRanges?.selection = selection }
        return selection
    }

    private func readMarkedRange(_ client: any IMKTextInput) -> NSRange {
        let matches = eventRanges?.client == ObjectIdentifier(client as AnyObject)
        if matches, let range = eventRanges?.marked { return range }
        let interval = Self.timing.beginInterval("Read marked range")
        defer { Self.timing.endInterval("Read marked range", interval) }
        let range = client.markedRange()
        if matches { eventRanges?.marked = range }
        return range
    }

    private func invalidateHostRanges() {
        eventRanges?.selection = nil
        eventRanges?.marked = nil
    }

    private func insert(_ text: String, in range: NSRange, client: (any IMKTextInput)?) {
        invalidateHostRanges()
        #if DEBUG && IME_TEST_BUILD
        probe.record(.commitRequested, client: client)
        #endif
        client?.insertText(text, replacementRange: range)
        invalidateHostRanges()
    }

    private func setMarkedText(_ text: String, caret: Int, client: (any IMKTextInput)?) {
        invalidateHostRanges()
        client?.setMarkedText(
            NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
            selectionRange: NSRange(location: caret, length: 0),
            replacementRange: Self.notFoundRange
        )
        invalidateHostRanges()
    }

    private func captureCaretAnchor(client: (any IMKTextInput)?) {
        lastValidAnchor = nil
        guard let client else { return }

        let markedRange = readMarkedRange(client)
        if !currentPreedit.isEmpty, markedRange.location != NSNotFound, markedRange.length > 0 {
            observedHostMark = true
        }
        let selectedRange = readSelection(client)
        let preferredRanges = currentPreedit.isEmpty
            ? [selectedRange, markedRange]
            : [markedRange, selectedRange]
        var candidates: [NSRect] = []
        for range in preferredRanges where range.location != NSNotFound {
            let endLocation = range.location.addingReportingOverflow(range.length)
            guard !endLocation.overflow else { continue }

            var actualRange = NSRange(location: NSNotFound, length: 0)
            let rect = client.firstRect(
                forCharacterRange: NSRange(location: endLocation.partialValue, length: 0),
                actualRange: &actualRange
            )
            candidates.append(rect)
        }

        let frames = NSScreen.screens.map(\.frame)
        lastValidAnchor = UnifiedPanelLayout.caretAnchor(candidates: candidates, visibleFrames: frames) {
            // Index zero is relative to the inline session, or the current selection without one.
            var lineHeightRect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
            return lineHeightRect
        }
    }

    private func clearDocumentContext(_ reason: ContextResetReason, clearHostMark: Bool = true) {
        #if DEBUG && IME_TEST_BUILD
        compositionLog.reset(reason, active: isActive, composing: !currentPreedit.isEmpty,
                             tracking: sentenceBuffer.currentSnapshot != nil, observedMark: observedHostMark,
                             hasExpectedCaret: expectedHostCaretLocation != nil, clearHostMark: clearHostMark)
        #endif
        stopPositionRefresh()
        observedHostMark = false
        if clearHostMark, !currentPreedit.isEmpty {
            setMarkedText("", caret: 0, client: activeClient)
        }
        engine?.clear()
        candidateRevision &+= 1
        canPageBackward = false
        canPageForward = false
        currentPreedit = ""
        preeditCaret = 0
        currentCandidates = []
        currentHighlightedIndex = 0
        clearEnglishCandidates()
        candidateMeaningCache.removeAll(keepingCapacity: true)
        clearTranslationContext()
        panelController.hide(owner: self)
        lastValidAnchor = nil
    }

    private func clearTranslationContext() {
        sentenceBuffer.reset()
        clearNotice()
        lastPresentedTranslation = nil
        spellingCorrection = nil
        expectedHostCaretLocation = nil
        pendingHostLineBreak = nil
        spellCheckRevision &+= 1
        spellCheckTask?.cancel()
        spellCheckTask = nil
        coordinator.cancel()
    }

    private func handleEnglish(
        _ event: NSEvent,
        client: (any IMKTextInput)?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        switch EnglishCandidateInteraction.action(
            keyCode: event.keyCode,
            characters: event.characters,
            candidateCount: currentCandidates.count,
            highlightedIndex: currentHighlightedIndex,
            hasShift: modifiers.contains(.shift),
            hasControl: modifiers.contains(.control)
        ) {
        case .passThrough:
            break
        case .dismiss:
            clearEnglishCandidates()
            renderPanel(client: client)
            return true
        case .select(let index):
            if applyEnglishCandidate(at: index, client: client) {
                return true
            }
            clearDocumentContext(.englishCandidateRejected)
            return false
        case .highlight(let index):
            currentHighlightedIndex = index
            renderPanel(client: client)
            return true
        }

        if event.keyCode == 48, applySpellingCorrection(client: client) {
            return true
        }
        if event.keyCode == 48 {
            clearDocumentContext(.unhandledTab)
            return false
        }

        if event.keyCode == 51 {
            mirrorHostBackspace(client: client)
            return false
        }

        if isNavigationKey(event.keyCode) || event.keyCode == 53 {
            clearDocumentContext(.englishNavigation)
            return false
        }

        if isReturn(event) {
            let selection = client.map { readSelection($0) }
            if sentenceBuffer.append("\n") != nil {
                updateTranslationDraftAndPanel(client: client)
            }
            if let selection, selection.location != NSNotFound {
                expectedHostCaretLocation = selection.location + 1
            }
            return false
        }

        guard !modifiers.contains(.control), let characters = event.characters else {
            return false
        }
        guard
            !characters.isEmpty,
            characters.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return false
        }

        let selection = client.map { readSelection($0) }
        if sentenceBuffer.append(characters) != nil {
            updateTranslationDraftAndPanel(client: client)
        }
        if let selection, selection.location != NSNotFound {
            expectedHostCaretLocation = selection.location + characters.utf16.count
        }
        return false
    }

    private func updateEnglishCandidates(for sourceText: String?) {
        guard
            let sourceText,
            let context = EnglishCandidateContext.trailingWord(in: sourceText)
        else {
            clearEnglishCandidates()
            return
        }

        let words = englishSpellChecker.candidates(for: context.word)
        guard !words.isEmpty else {
            clearEnglishCandidates()
            return
        }

        if englishCandidateContext == context, currentCandidates.map(\.text) == words {
            return
        }

        englishCandidateContext = context
        currentHighlightedIndex = 0
        currentCandidates = words.map { word in
            RimeCandidate(
                text: word,
                comment: candidateMeaningCache[word.lowercased()]
            )
        }
        scheduleCandidateMeanings(for: words)
    }

    private func scheduleCandidateMeanings(for words: [String]) {
        candidateMeaningRevision &+= 1
        let revision = candidateMeaningRevision
        candidateMeaningTask?.cancel()

        let missingWords = words.filter { candidateMeaningCache[$0.lowercased()] == nil }
        guard settings.translationEnabled, !missingWords.isEmpty, let provider = candidateTranslationProvider else {
            return
        }

        candidateMeaningTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let meanings = try await provider.translateCandidates(missingWords)
                try Task.checkCancellation()
                guard
                    let self, self.settings.translationEnabled, self.isActive,
                    !IsSecureEventInputEnabled(),
                    self.candidateMeaningRevision == revision,
                    self.currentCandidates.map(\.text) == words
                else {
                    return
                }

                for (word, meaning) in meanings {
                    self.candidateMeaningCache[word] = self.compactCandidateMeaning(meaning)
                }
                self.currentCandidates = words.map { word in
                    RimeCandidate(
                        text: word,
                        comment: self.candidateMeaningCache[word.lowercased()]
                    )
                }
                self.renderPanel(client: self.activeClient)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func applyEnglishCandidate(
        at index: Int,
        client: (any IMKTextInput)?
    ) -> Bool {
        guard
            let client,
            currentCandidates.indices.contains(index),
            let context = englishCandidateContext,
            let snapshot = sentenceBuffer.currentSnapshot,
            let hostRange = TrackedTextReplacement.hostRange(
                trackedText: snapshot.text,
                trackedUTF16Range: context.range,
                currentSelection: readSelection(client)
            ),
            client.attributedSubstring(from: hostRange)?.string == context.word
        else {
            return false
        }

        let replacement = currentCandidates[index].text
        insert(replacement, in: hostRange, client: client)
        expectedHostCaretLocation = hostRange.location + replacement.utf16.count
        _ = sentenceBuffer.replaceCharacters(inUTF16Range: context.range, with: replacement)
        spellingCorrection = nil
        clearEnglishCandidates()
        updateTranslationDraftAndPanel(
            client: client,
            refreshEnglishCandidates: false
        )
        return true
    }

    private func clearEnglishCandidates() {
        englishCandidateContext = nil
        if product == .english {
            currentCandidates = []
        }
        currentHighlightedIndex = 0
        candidateMeaningRevision &+= 1
        candidateMeaningTask?.cancel()
        candidateMeaningTask = nil
    }

    private func compactCandidateMeaning(_ meaning: String) -> String {
        let compact = meaning
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 16 else { return compact }
        return String(compact.prefix(16)) + "…"
    }

    private func reconcileHostLineBreak(client: (any IMKTextInput)?, selection: NSRange) {
        guard let location = pendingHostLineBreak else { return }
        pendingHostLineBreak = nil
        guard let client,
              selection == NSRange(location: location + 1, length: 0),
              client.attributedSubstring(from: NSRange(location: location, length: 1))?.string == "\n"
        else {
            clearDocumentContext(.lineBreakUnverified)
            return
        }
        sentenceBuffer.append("\n")
        expectedHostCaretLocation = location + 1
        updateTranslationDraftAndPanel(client: client)
    }

    private func reconcileTrackedCaret(client: (any IMKTextInput)?) {
        let selection = client.map { readSelection($0) } ?? Self.notFoundRange
        let action = TrackedCaretReconciliation.action(
            expectedCaretLocation: expectedHostCaretLocation,
            currentSelection: selection,
            hasActiveComposition: !currentPreedit.isEmpty,
            hasTrackedContext: sentenceBuffer.currentSnapshot != nil,
            isAwaitingHostLineBreak: pendingHostLineBreak != nil
        )
        switch action {
        case .keepContext:
            break
        case .clearContext:
            clearDocumentContext(.trackedCaretChanged)
        case .checkHostLineBreak:
            reconcileHostLineBreak(client: client, selection: selection)
        }
    }

    private func recordCurrentCaret(client: (any IMKTextInput)?) {
        let selection = client.map { readSelection($0) } ?? Self.notFoundRange
        guard selection.location != NSNotFound, selection.length == 0 else {
            expectedHostCaretLocation = nil
            return
        }
        expectedHostCaretLocation = selection.location
    }

    private func mirrorHostBackspace(client: (any IMKTextInput)?) {
        let selection = client.map { readSelection($0) } ?? Self.notFoundRange
        guard
            let lastCharacter = sentenceBuffer.currentSnapshot?.text.last,
            selection.location != NSNotFound,
            selection.length == 0,
            selection.location == expectedHostCaretLocation
        else {
            clearDocumentContext(.backspaceContextMismatch)
            return
        }

        let removedUTF16Count = String(lastCharacter).utf16.count
        guard selection.location >= removedUTF16Count else {
            clearDocumentContext(.backspaceRangeInvalid)
            return
        }

        if sentenceBuffer.removeLastCharacter() != nil {
            expectedHostCaretLocation = selection.location - removedUTF16Count
            updateTranslationDraftAndPanel(client: client)
        } else {
            clearDocumentContext(.lastCharacterRemoved)
        }
    }

    private func scheduleSpellingCheck(for sourceText: String?) {
        spellCheckRevision &+= 1
        let revision = spellCheckRevision
        spellCheckTask?.cancel()

        guard let sourceText, sourceText.rangeOfCharacter(from: .letters) != nil else {
            spellingCorrection = nil
            return
        }

        spellCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self, self.spellCheckRevision == revision else { return }
                self.spellingCorrection = self.englishSpellChecker.firstCorrection(in: sourceText)
                self.renderPanel(client: self.activeClient)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func applySpellingCorrection(client: (any IMKTextInput)?) -> Bool {
        guard
            let client,
            let correction = spellingCorrection,
            let snapshot = sentenceBuffer.currentSnapshot
        else {
            return false
        }

        let textLength = snapshot.text.utf16.count
        let correctionEnd = NSMaxRange(correction.range)
        guard correctionEnd <= textLength else { return false }

        let suffixRange = NSRange(
            location: correction.range.location,
            length: textLength - correction.range.location
        )
        guard
            let suffixStringRange = Range(suffixRange, in: snapshot.text),
            let correctionStringRange = Range(correction.range, in: snapshot.text),
            let hostRange = TrackedTextReplacement.hostRange(
                trackedText: snapshot.text,
                trackedUTF16Range: suffixRange,
                currentSelection: readSelection(client)
            )
        else {
            return false
        }

        let suffix = snapshot.text[suffixStringRange]
        let original = snapshot.text[correctionStringRange]
        guard suffix.hasPrefix(original) else { return false }
        guard client.attributedSubstring(from: hostRange)?.string == String(suffix) else {
            clearDocumentContext(.spellingRangeMismatch)
            return false
        }
        let trailingText = suffix.dropFirst(original.count)
        let replacement = correction.replacement + trailingText

        insert(replacement, in: hostRange, client: client)
        expectedHostCaretLocation = hostRange.location + replacement.utf16.count
        _ = sentenceBuffer.replaceCharacters(inUTF16Range: suffixRange, with: replacement)
        spellingCorrection = nil
        updateTranslationDraftAndPanel(client: client)
        return true
    }

    private func client(from sender: Any?) -> (any IMKTextInput)? {
        (sender as? any IMKTextInput) ?? activeClient
    }

    private func rimeKeyMapping(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> RimeKeyMapping? {
        let specialKey: Int32?
        switch event.keyCode {
        case 36, 76: specialKey = RimeKey.return
        case 51: specialKey = RimeKey.backspace
        case 53: specialKey = RimeKey.escape
        case 115: specialKey = RimeKey.home
        case 116: specialKey = RimeKey.pageUp
        case 119: specialKey = RimeKey.end
        case 121: specialKey = RimeKey.pageDown
        case 123: specialKey = RimeKey.left
        case 124: specialKey = RimeKey.right
        case 125: specialKey = RimeKey.down
        case 126: specialKey = RimeKey.up
        default:
            specialKey = nil
        }

        if let specialKey {
            return RimeKeyMapping(
                keyCode: specialKey,
                modifiers: rimeModifiers(from: modifiers)
            )
        }

        return RimeKeyboardMapper.printable(
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            shift: modifiers.contains(.shift),
            control: modifiers.contains(.control)
        )
    }

    private func rimeModifiers(from modifiers: NSEvent.ModifierFlags) -> Int32 {
        var result: Int32 = 0
        if modifiers.contains(.shift) { result |= 1 }
        if modifiers.contains(.control) { result |= 4 }
        return result
    }

    private func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private func isNavigationKey(_ keyCode: UInt16) -> Bool {
        [115, 116, 119, 121, 123, 124, 125, 126].contains(keyCode)
    }

    @objc private func openInputSettings() {
        openSetup(section: "general")
    }

    @objc private func openTranslationSetup() {
        openSetup(section: "translation")
    }

    @objc private func openDiagnostics() {
        openSetup(section: "about")
    }

    private func openSetup(section: String) {
        let setupURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("SentenceAlongSetup.app", isDirectory: true)
        guard let route = URL(string: "\(InputSettingsStore.settingsScheme)://\(section)") else { return }
        NSWorkspace.shared.open(
            [route], withApplicationAt: setupURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    private static let notFoundRange = NSRange(location: NSNotFound, length: NSNotFound)
}
