import Foundation

public enum HostCompositionEnd: Equatable {
    case markEnded, documentCleared
}

public struct HostCompositionObservation {
    public private(set) var verifiedMark: NSRange?
    private var pendingEnd: HostCompositionEnd?
    private var confirmedNonemptyDocument: Bool?
    private var retryDocumentLengthAfter: ContinuousClock.Instant?

    public init() {}

    /// Host readbacks may lag behind a new setMarkedText call.
    public mutating func wroteMark() {
        verifiedMark = nil
        pendingEnd = nil
        retryDocumentLengthAfter = nil
    }

    /// Calibrate document length once per context, only after the client has acknowledged our mark.
    @discardableResult
    public mutating func observed(mark: NSRange, selection: NSRange, preeditLength: Int, caret: Int,
                                  documentLength: () -> Int) -> Bool {
        guard preeditLength > 0, mark.location != NSNotFound, mark.length == preeditLength,
              selection.location != NSNotFound,
              selection == mark || (selection.length == 0 && selection.location >= mark.location &&
                                    selection.location - mark.location == caret) else { return false }
        verifiedMark = mark
        pendingEnd = nil
        retryDocumentLengthAfter = nil
        if confirmedNonemptyDocument == nil {
            let length = documentLength()
            confirmedNonemptyDocument = length > 0 && length != NSNotFound
        }
        return true
    }

    public mutating func refresh(mark: NSRange, selection: NSRange, preeditLength: Int, caret: Int,
                                 now: ContinuousClock.Instant = .now, documentLength: () -> Int) -> HostCompositionEnd? {
        if observed(mark: mark, selection: selection, preeditLength: preeditLength, caret: caret,
                    documentLength: documentLength) { return nil }
        guard let verifiedMark, selection.location != NSNotFound else { pendingEnd = nil; return nil }

        let reason: HostCompositionEnd
        if mark.location == NSNotFound || mark.length == 0 {
            reason = .markEnded
        } else if mark == verifiedMark, selection == NSRange(location: 0, length: 0),
                  confirmedNonemptyDocument == true {
            // Some editors retain an obsolete marked range after deleting their document.
            // IMK's length can be expensive or unsupported; query only for this transition.
            if let retryDocumentLengthAfter, now < retryDocumentLengthAfter { return nil }
            guard documentLength() == 0 else {
                retryDocumentLengthAfter = now.advanced(by: .seconds(1))
                pendingEnd = nil
                return nil
            }
            reason = .documentCleared
        } else {
            pendingEnd = nil
            return nil
        }
        defer { pendingEnd = reason }
        return pendingEnd == reason ? reason : nil
    }
}

extension HostCompositionObservation {
    public func ownedMarkToDiscard(preedit: String, mark: NSRange, selection: NSRange,
                                   read: (NSRange) -> String?) -> NSRange? {
        guard !preedit.isEmpty, mark.location != NSNotFound, mark.location >= 0,
              mark.length == preedit.utf16.count, verifiedMark.map({ $0 == mark }) ?? true else { return nil }
        let caretInside = selection.length == 0 && selection.location != NSNotFound &&
            selection.location >= mark.location && selection.location - mark.location <= mark.length
        guard selection == mark || caretInside, read(mark) == preedit else { return nil }
        return mark
    }
}
