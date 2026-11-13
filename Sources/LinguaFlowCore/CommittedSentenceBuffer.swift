import Foundation

public struct SentenceSnapshot: Equatable, Sendable {
    public let text: String
    public let revision: UInt64
    public let isFinal: Bool

    public init(text: String, revision: UInt64, isFinal: Bool) {
        self.text = text
        self.revision = revision
        self.isFinal = isFinal
    }
}

public struct CommittedSentenceBuffer: Sendable {
    public private(set) var revision: UInt64 = 0

    private let maxCharacters: Int
    private let periodEndsSentence: Bool
    private var text = ""
    private var startsNewSentenceOnNextAppend = false
    private var lastSnapshot: SentenceSnapshot?

    public init(maxCharacters: Int = 280, periodEndsSentence: Bool = false) {
        precondition(maxCharacters > 0, "maxCharacters must be greater than zero")
        self.maxCharacters = maxCharacters
        self.periodEndsSentence = periodEndsSentence
    }

    public var isEmpty: Bool {
        text.isEmpty
    }

    public var currentSnapshot: SentenceSnapshot? {
        lastSnapshot
    }

    @discardableResult
    public mutating func append(_ committedText: String) -> SentenceSnapshot? {
        guard !committedText.isEmpty else { return nil }
        var changed = false
        for character in committedText {
            if character.isNewline {
                if !text.isEmpty, !startsNewSentenceOnNextAppend {
                    startsNewSentenceOnNextAppend = true
                    changed = true
                }
                continue
            }
            if character.isWhitespace, text.isEmpty || startsNewSentenceOnNextAppend {
                continue
            }
            let terminal = isTerminal(character)
            if startsNewSentenceOnNextAppend, !terminal {
                text.removeAll(keepingCapacity: true)
            }
            text.append(character)
            changed = true
            startsNewSentenceOnNextAppend = terminal
        }
        guard changed else { return nil }

        if text.count > maxCharacters {
            text = String(text.suffix(maxCharacters))
        }

        revision &+= 1
        let isFinal = startsNewSentenceOnNextAppend
        let snapshot = SentenceSnapshot(text: text, revision: revision, isFinal: isFinal)
        lastSnapshot = snapshot
        startsNewSentenceOnNextAppend = isFinal
        return snapshot
    }

    @discardableResult
    public mutating func replaceCharacters(
        inUTF16Range range: NSRange,
        with replacement: String
    ) -> SentenceSnapshot? {
        guard
            range.location != NSNotFound,
            let stringRange = Range(range, in: text)
        else {
            return nil
        }

        text.replaceSubrange(stringRange, with: replacement)
        if text.count > maxCharacters {
            text = String(text.suffix(maxCharacters))
        }

        revision &+= 1
        guard !text.isEmpty else {
            startsNewSentenceOnNextAppend = false
            lastSnapshot = nil
            return nil
        }

        let isFinal = text.last.map(isTerminal) ?? false
        let snapshot = SentenceSnapshot(text: text, revision: revision, isFinal: isFinal)
        lastSnapshot = snapshot
        startsNewSentenceOnNextAppend = isFinal
        return snapshot
    }

    @discardableResult
    public mutating func removeLastCharacter() -> SentenceSnapshot? {
        guard !text.isEmpty else { return nil }

        text.removeLast()
        startsNewSentenceOnNextAppend = text.last.map(isTerminal) ?? false
        revision &+= 1

        guard !text.isEmpty else {
            lastSnapshot = nil
            return nil
        }

        let snapshot = SentenceSnapshot(
            text: text,
            revision: revision,
            isFinal: text.last.map(isTerminal) ?? false
        )
        lastSnapshot = snapshot
        return snapshot
    }

    public mutating func reset() {
        text.removeAll(keepingCapacity: false)
        startsNewSentenceOnNextAppend = false
        lastSnapshot = nil
        revision &+= 1
    }

    private func isTerminal(_ character: Character) -> Bool {
        "。！？!?".contains(character) || (periodEndsSentence && character == ".")
    }
}
