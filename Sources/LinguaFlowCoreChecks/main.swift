import Carbon
import CoreGraphics
import Foundation
import LinguaFlowCore

private enum CheckFailure: Error, CustomStringConvertible {
    case mismatch(String)

    var description: String {
        switch self {
        case .mismatch(let message): message
        }
    }
}

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw CheckFailure.mismatch("\(label): expected \(expected), got \(actual)")
    }
}

private actor ImmediateProvider: TranslationProviding {
    func translate(_ request: TranslationRequest) async throws -> String {
        "English: \(request.sourceText)"
    }
}

@main
@MainActor
struct LinguaFlowCoreChecks {
    static func main() async throws {
        var buffer = CommittedSentenceBuffer(maxCharacters: 8)
        try expect(
            buffer.append("我今天"),
            SentenceSnapshot(text: "我今天", revision: 1, isFinal: false),
            "append first chunk"
        )
        try expect(
            buffer.append("去公园。"),
            SentenceSnapshot(text: "我今天去公园。", revision: 2, isFinal: true),
            "finalize sentence"
        )
        try expect(
            buffer.append("明天"),
            SentenceSnapshot(text: "明天", revision: 3, isFinal: false),
            "start a fresh sentence"
        )
        try expect(
            buffer.removeLastCharacter(),
            SentenceSnapshot(text: "明", revision: 4, isFinal: false),
            "mirror host backspace"
        )

        var chineseBuffer = CommittedSentenceBuffer(maxCharacters: 80)
        _ = chineseBuffer.append("价格3.")
        try expect(chineseBuffer.append("14元，继续。下一句")?.text, "下一句", "track the last sentence in a single commit")
        var decimalBuffer = CommittedSentenceBuffer(maxCharacters: 80)
        _ = decimalBuffer.append("价格3.")
        try expect(decimalBuffer.append("14元")?.text, "价格3.14元", "ASCII dot does not end a Chinese sentence")
        _ = decimalBuffer.append("\n")
        try expect(decimalBuffer.append("新行")?.text, "新行", "confirmed newline ends the sentence")
        var reopened = CommittedSentenceBuffer(maxCharacters: 80)
        _ = reopened.append("你好。！")
        try expect(reopened.removeLastCharacter()?.isFinal, true, "backspace leaves the preceding sentence ending")
        try expect(reopened.append("再见")?.text, "再见", "start a fresh sentence after backspacing a terminal mark")

        var deletionBuffer = CommittedSentenceBuffer(maxCharacters: 80)
        _ = deletionBuffer.append("我们需要")
        try expect(deletionBuffer.removeLastCharacter()?.text, "我们需", "delete one character")
        try expect(deletionBuffer.removeLastCharacter()?.text, "我们", "delete repeated character")
        try expect(deletionBuffer.removeLastCharacter()?.text, "我", "delete down to one character")
        try expect(deletionBuffer.removeLastCharacter(), nil, "delete final tracked character")
        try expect(deletionBuffer.isEmpty, true, "backspace empties tracked context")

        try expect(
            TrackedCaretReconciliation.action(
                expectedCaretLocation: 24,
                currentSelection: NSRange(location: 24, length: 0),
                hasActiveComposition: false,
                hasTrackedContext: true
            ),
            .keepContext,
            "keep an aligned collapsed caret"
        )
        try expect(
            TrackedCaretReconciliation.action(
                expectedCaretLocation: 24,
                currentSelection: NSRange(location: 3, length: 12),
                hasActiveComposition: false,
                hasTrackedContext: true
            ),
            .clearContext,
            "clear context before a selected host deletion"
        )
        try expect(
            TrackedCaretReconciliation.action(
                expectedCaretLocation: 24,
                currentSelection: NSRange(location: 17, length: 0),
                hasActiveComposition: false,
                hasTrackedContext: true
            ),
            .clearContext,
            "clear context after caret navigation"
        )
        try expect(
            TrackedCaretReconciliation.action(
                expectedCaretLocation: 24,
                currentSelection: NSRange(location: 3, length: 12),
                hasActiveComposition: true,
                hasTrackedContext: true
            ),
            .keepContext,
            "let Rime own deletion inside active composition"
        )
        try expect(
            TrackedCaretReconciliation.action(
                expectedCaretLocation: nil,
                currentSelection: NSRange(location: NSNotFound, length: 0),
                hasActiveComposition: false,
                hasTrackedContext: true
            ),
            .clearContext,
            "clear tracked context when the host caret is unavailable"
        )

        var englishBuffer = CommittedSentenceBuffer(maxCharacters: 80, periodEndsSentence: true)
        _ = englishBuffer.append("I")
        _ = englishBuffer.append(" ")
        _ = englishBuffer.append("recieved")
        try expect(
            englishBuffer.currentSnapshot?.text,
            "I recieved",
            "preserve spaces inside an English sentence"
        )
        try expect(
            englishBuffer.replaceCharacters(
                inUTF16Range: NSRange(location: 2, length: 8),
                with: "received"
            )?.text,
            "I received",
            "replace only the tracked misspelled word"
        )
        _ = englishBuffer.append(".")
        _ = englishBuffer.append(" ")
        try expect(
            englishBuffer.append("Thanks")?.text,
            "Thanks",
            "start a fresh English sentence after terminal punctuation"
        )

        try expect(
            TranslationDirection.englishToChinese.sourceLanguageIdentifier,
            "en",
            "English input translates from English"
        )
        try expect(
            TranslationDirection.englishToChinese.targetLanguageIdentifier,
            "zh-Hans",
            "English input translates into Simplified Chinese"
        )
        try expect(
            TrackedTextReplacement.hostRange(
                trackedText: "I recieved",
                trackedUTF16Range: NSRange(location: 2, length: 8),
                currentSelection: NSRange(location: 110, length: 0)
            ),
            NSRange(location: 102, length: 8),
            "map a tracked correction to the host document"
        )
        try expect(
            TrackedTextReplacement.hostRange(
                trackedText: "I recieved",
                trackedUTF16Range: NSRange(location: 2, length: 8),
                currentSelection: NSRange(location: 4, length: 0)
            ),
            nil,
            "refuse a correction when the host caret cannot contain the tracked text"
        )

        try expect(
            EnglishCandidateContext.trailingWord(in: "I want to lear"),
            EnglishCandidateContext(
                word: "lear",
                range: NSRange(location: 10, length: 4)
            ),
            "extract the unfinished English word at the caret"
        )
        try expect(
            EnglishCandidateContext.trailingWord(in: "I want to learn "),
            nil,
            "hide candidates after a word boundary"
        )
        try expect(
            EnglishCandidateInteraction.action(
                keyCode: 48,
                characters: "\t",
                candidateCount: 4,
                highlightedIndex: 2,
                hasShift: false,
                hasControl: false
            ),
            .select(index: 2),
            "Tab accepts the highlighted English candidate"
        )
        try expect(
            EnglishCandidateInteraction.action(
                keyCode: 124,
                characters: nil,
                candidateCount: 4,
                highlightedIndex: 3,
                hasShift: false,
                hasControl: false
            ),
            .highlight(index: 0),
            "right arrow wraps English candidate highlighting"
        )
        try expect(
            EnglishCandidateInteraction.action(
                keyCode: 19,
                characters: "2",
                candidateCount: 4,
                highlightedIndex: 0,
                hasShift: false,
                hasControl: false
            ),
            .select(index: 1),
            "number keys select English candidates directly"
        )
        try expect(
            EnglishCandidateInteraction.action(
                keyCode: 49,
                characters: " ",
                candidateCount: 4,
                highlightedIndex: 0,
                hasShift: false,
                hasControl: false
            ),
            .passThrough,
            "space preserves the exact English word instead of forcing completion"
        )

        let provider = ImmediateProvider()
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        var received: TranslationResult?
        coordinator.onResult = { received = $0 }
        coordinator.submit(.init(text: "你好", revision: 5, isFinal: false))

        for _ in 0..<100 where received == nil {
            await Task.yield()
        }

        try expect(
            received,
            TranslationResult(sourceText: "你好", translatedText: "English: 你好", revision: 5),
            "publish current translation"
        )

        try expect(
            LiveTranslationDraft.sourceText(
                committed: .init(text: "我今天", revision: 1, isFinal: false),
                provisionalCandidate: "想去公园"
            ),
            "我今天想去公园",
            "translate the highlighted candidate before commit"
        )
        try expect(
            LiveTranslationDraft.sourceText(
                committed: .init(text: "上一句。", revision: 2, isFinal: true),
                provisionalCandidate: "下一句"
            ),
            "下一句",
            "do not mix a finished sentence into the next live preview"
        )

        var committedCandidate = CommittedSentenceBuffer()
        _ = committedCandidate.append("我想")
        try expect(
            LiveTranslationDraft.sourceText(committed: committedCandidate.currentSnapshot, provisionalCandidate: "去公园"),
            "我想去公园",
            "preview the first candidate without committing it"
        )
        try expect(
            LiveTranslationDraft.sourceText(committed: committedCandidate.currentSnapshot, provisionalCandidate: "去图书馆"),
            "我想去图书馆",
            "switch the provisional candidate independently of the buffer"
        )
        _ = committedCandidate.append("去学校")
        try expect(
            LiveTranslationDraft.sourceText(committed: committedCandidate.currentSnapshot, provisionalCandidate: nil),
            "我想去学校",
            "use the actual Rime commit after composition"
        )

        var longSentence = CommittedSentenceBuffer(maxCharacters: 280)
        let limitText = String(repeating: "字", count: 280)
        _ = longSentence.append(limitText)
        try expect(LiveTranslationDraft.sourceText(committed: longSentence.currentSnapshot, provisionalCandidate: nil), limitText, "preview at the limit")
        try expect(LiveTranslationDraft.sourceText(committed: longSentence.currentSnapshot, provisionalCandidate: "词"), nil, "provisional candidate can exceed the limit")
        _ = longSentence.append("字")
        try expect(LiveTranslationDraft.sourceText(committed: longSentence.currentSnapshot, provisionalCandidate: nil), nil, "never translate an overlong sentence suffix")
        _ = longSentence.removeLastCharacter()
        try expect(LiveTranslationDraft.sourceText(committed: longSentence.currentSnapshot, provisionalCandidate: nil), nil, "a truncated sentence cannot recover through backspace")
        _ = longSentence.append("。")
        _ = longSentence.append("新句")
        try expect(LiveTranslationDraft.sourceText(committed: longSentence.currentSnapshot, provisionalCandidate: nil), "新句", "resume preview at the next sentence")

        let compactSize = UnifiedPanelLayout.size(
            contentWidths: [42, 156, 38],
            rowHeights: [20, 30, 20]
        )
        try expect(compactSize.width <= 260, true, "short content stays compact")
        try expect(compactSize.height, 102, "three rows use stable spacing")

        let below = UnifiedPanelLayout.origin(
            anchor: .init(x: 480, y: 420, width: 0, height: 22),
            panelSize: .init(width: 240, height: 102),
            visibleFrame: .init(x: 0, y: 0, width: 1440, height: 900)
        )
        try expect(below, .init(x: 480, y: 312), "place panel below the insertion point")

        let above = UnifiedPanelLayout.origin(
            anchor: .init(x: 480, y: 18, width: 0, height: 22),
            panelSize: .init(width: 240, height: 102),
            visibleFrame: .init(x: 0, y: 0, width: 1440, height: 900)
        )
        try expect(above, .init(x: 480, y: 46), "flip above near the screen bottom")

        let inlineCaret = CGRect(x: 906, y: 580, width: 1, height: 24)
        try expect(
            UnifiedPanelLayout.firstUsableAnchor(
                candidates: [inlineCaret],
                fallback: .init(x: 12, y: 800, width: 1, height: 24),
                visibleFrames: [.init(x: 0, y: 0, width: 1440, height: 900)]
            ),
            inlineCaret,
            "prefer the inline-session caret supplied for candidate placement"
        )
        try expect(
            UnifiedPanelLayout.firstUsableAnchor(
                candidates: [.zero],
                fallback: .zero,
                visibleFrames: [.init(x: 0, y: 0, width: 1440, height: 900)]
            ),
            nil,
            "reject a zero fallback instead of pinning the panel to a screen corner"
        )

        try expect(
            UnifiedPanelLayout.caretAnchor(
                candidates: [.zero, .zero],
                visibleFrames: [.init(x: 0, y: 0, width: 1440, height: 900)],
                currentLineRect: { inlineCaret }
            ),
            inlineCaret,
            "use the current inline line when document-relative rectangles fail after a line break"
        )

        try expect(
            TrackedCaretReconciliation.action(
                expectedCaretLocation: 24,
                currentSelection: NSRange(location: 20, length: 4),
                hasActiveComposition: false,
                hasTrackedContext: true,
                isAwaitingHostLineBreak: true
            ),
            .keepContext,
            "position refresh defers reconciliation until the pending host edit can be checked"
        )

        try expect(
            SentenceReplacementShortcut.matches(keyCode: UInt16(kVK_ANSI_T), control: true, shift: true),
            true,
            "Control + Shift + T triggers sentence replacement"
        )
        try expect(
            SentenceReplacementShortcut.matches(keyCode: UInt16(kVK_Return), control: true, shift: false),
            false,
            "Control + Return remains available to macOS"
        )
        try expect(
            SentenceReplacementShortcut.matches(keyCode: UInt16(kVK_ANSI_T), control: true, shift: false),
            false,
            "Control + T does not trigger replacement"
        )
        try expect(
            SentenceReplacementShortcut.matches(keyCode: UInt16(kVK_ANSI_T), control: false, shift: true),
            false,
            "Shift + T does not trigger replacement"
        )

        let original = "你好👋🏽。"
        let sentence = SentenceSnapshot(text: original, revision: 1, isFinal: true)
        let currentResult = TranslationResult(sourceText: original, translatedText: "Hello.", revision: 5)
        let caret = 12 + original.utf16.count
        let collapsed = NSRange(location: caret, length: 0)
        try expect(
            TrackedTextReplacement.sentenceRange(snapshot: sentence, translation: currentResult, currentRevision: 5, expectedCaret: caret, selection: collapsed, hasComposition: false),
            NSRange(location: 12, length: original.utf16.count),
            "map only the tracked sentence using UTF-16"
        )
        try expect(
            TrackedTextReplacement.sentenceRange(snapshot: sentence, translation: currentResult, currentRevision: 6, expectedCaret: caret, selection: collapsed, hasComposition: false),
            nil,
            "reject an older translation even when its source text matches"
        )
        try expect(
            TrackedTextReplacement.sentenceRange(snapshot: sentence, translation: currentResult, currentRevision: 5, expectedCaret: caret, selection: collapsed, hasComposition: true),
            nil,
            "refuse to replace while composing"
        )
        try expect(
            TrackedTextReplacement.sentenceRange(snapshot: sentence, translation: currentResult, currentRevision: 5, expectedCaret: caret, selection: NSRange(location: caret - 1, length: 0), hasComposition: false),
            nil,
            "refuse to replace after a caret move"
        )
        try expect(
            TrackedTextReplacement.sentenceRange(snapshot: sentence, translation: currentResult, currentRevision: 5, expectedCaret: caret, selection: NSRange(location: 12, length: 2), hasComposition: false),
            nil,
            "refuse to replace a selection"
        )
        try expect(
            TrackedTextReplacement.sentenceRange(snapshot: nil, translation: currentResult, currentRevision: 5, expectedCaret: nil, selection: collapsed, hasComposition: false),
            nil,
            "repeat after context reset does not replace again"
        )

        print("LinguaFlow core checks passed")
    }
}
