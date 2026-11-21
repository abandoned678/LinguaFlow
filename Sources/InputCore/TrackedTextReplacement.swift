import Foundation

public enum TrackedTextReplacement {
    public enum Rejection: Equatable, Error {
        case disabled, composition, selection, movedCaret, overlong, waiting, unverifiedRange

        public var message: String {
            switch self {
            case .disabled: "翻译预览已关闭"
            case .composition: "请先确认当前组词"
            case .selection: "当前存在选区"
            case .movedCaret: "光标已离开当前句"
            case .overlong: "当前句超过长度限制"
            case .waiting: "正在等待译文"
            case .unverifiedRange: "无法确认宿主文本范围"
            }
        }
    }

    public static func decision(
        enabled: Bool,
        snapshot: SentenceSnapshot?,
        translation: TranslationResult?,
        currentRevision: UInt64?,
        expectedCaret: Int?,
        selection: NSRange,
        hasComposition: Bool
    ) -> Result<NSRange, Rejection> {
        if !enabled { return .failure(.disabled) }
        if selection.location != NSNotFound, selection.length > 0 { return .failure(.selection) }
        if hasComposition { return .failure(.composition) }
        if selection.location == NSNotFound { return .failure(.unverifiedRange) }
        if let expectedCaret, expectedCaret != selection.location { return .failure(.movedCaret) }
        if snapshot?.isOverlong == true { return .failure(.overlong) }
        guard let snapshot, let expectedCaret else { return .failure(.unverifiedRange) }
        guard let translation, let currentRevision else { return .failure(.waiting) }
        guard let range = sentenceRange(
            snapshot: snapshot, translation: translation, currentRevision: currentRevision,
            expectedCaret: expectedCaret, selection: selection, hasComposition: false
        ) else { return .failure(.unverifiedRange) }
        return .success(range)
    }

    public static func sentenceRange(
        snapshot: SentenceSnapshot?,
        translation: TranslationResult?,
        currentRevision: UInt64,
        expectedCaret: Int?,
        selection: NSRange,
        hasComposition: Bool
    ) -> NSRange? {
        guard !hasComposition,
              let snapshot, !snapshot.text.isEmpty, !snapshot.isOverlong,
              let translation, translation.revision == currentRevision,
              translation.sourceText == snapshot.text,
              !translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expectedCaret, selection.location == expectedCaret
        else { return nil }
        return hostRange(
            trackedText: snapshot.text,
            trackedUTF16Range: NSRange(location: 0, length: snapshot.text.utf16.count),
            currentSelection: selection
        )
    }

    public static func applyIfVerified(_ range: NSRange, expected: String,
                                       read: (NSRange) -> String?, replace: (NSRange) -> Void) -> Bool {
        guard read(range) == expected else { return false }
        replace(range)
        return true
    }

    public static func hostRange(
        trackedText: String,
        trackedUTF16Range: NSRange,
        currentSelection: NSRange
    ) -> NSRange? {
        guard
            currentSelection.location != NSNotFound,
            currentSelection.length == 0,
            trackedUTF16Range.location != NSNotFound,
            NSMaxRange(trackedUTF16Range) <= trackedText.utf16.count,
            currentSelection.location >= trackedText.utf16.count
        else {
            return nil
        }

        let trackedStart = currentSelection.location - trackedText.utf16.count
        let hostLocation = trackedStart.addingReportingOverflow(trackedUTF16Range.location)
        guard !hostLocation.overflow else { return nil }

        return NSRange(
            location: hostLocation.partialValue,
            length: trackedUTF16Range.length
        )
    }
}
