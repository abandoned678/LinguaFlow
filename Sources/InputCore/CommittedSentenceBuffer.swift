import Foundation

public struct SentenceSnapshot: Equatable, Sendable {
    public let text: String
    public let revision: UInt64
    public let isFinal: Bool
    public let isOverlong: Bool

    public init(text: String, revision: UInt64, isFinal: Bool, isOverlong: Bool = false) {
        self.text = text
        self.revision = revision
        self.isFinal = isFinal
        self.isOverlong = isOverlong
    }
}

public struct CommittedSentenceBuffer: Sendable {
    public private(set) var revision: UInt64 = 0

    private let maxCharacters: Int
    private let periodEndsSentence: Bool
    private var text = ""
    private var isOverlong = false
    private var startsNewSentenceOnNextAppend = false
    private var adjacentToEnglishPeriod = false
    // Sentence-separating spaces are in the document but outside the preview's text.
    private var trailingSeparators = ""
    public var lastTrackedCharacter: Character? { trailingSeparators.last ?? text.last }
    private var lastSnapshot: SentenceSnapshot?

    public init(maxCharacters: Int = 280, periodEndsSentence: Bool = true) {
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
                trailingSeparators.removeAll(keepingCapacity: true)
                adjacentToEnglishPeriod = false
                if !text.isEmpty, !startsNewSentenceOnNextAppend {
                    startsNewSentenceOnNextAppend = true
                    changed = true
                }
                continue
            }
            if character.isWhitespace, text.isEmpty || startsNewSentenceOnNextAppend {
                adjacentToEnglishPeriod = false
                if periodEndsSentence && !text.isEmpty {
                    trailingSeparators.append(character)
                    if trailingSeparators.count > maxCharacters { reset(); changed = false }
                }
                continue
            }
            let wasSeparated = !trailingSeparators.isEmpty
            trailingSeparators.removeAll(keepingCapacity: true)
            let continuesToken = adjacentToEnglishPeriod && Self.isASCIITokenCharacter(character)
            if startsNewSentenceOnNextAppend, !continuesToken, wasSeparated || !isTerminalPunctuation(character) {
                text.removeAll(keepingCapacity: true)
                isOverlong = false
            }
            text.append(character)
            if text.count > maxCharacters {
                isOverlong = true
                text.removeFirst()
            }
            changed = true
            updateBoundary()
        }
        guard changed else { return nil }

        revision &+= 1
        let isFinal = startsNewSentenceOnNextAppend
        let snapshot = SentenceSnapshot(text: text, revision: revision, isFinal: isFinal, isOverlong: isOverlong)
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
            !isOverlong,
            range.location != NSNotFound,
            let stringRange = Range(range, in: text)
        else {
            return nil
        }

        text.replaceSubrange(stringRange, with: replacement)
        if text.count > maxCharacters {
            isOverlong = true
            text = String(text.suffix(maxCharacters))
        }

        revision &+= 1
        guard !text.isEmpty else {
            startsNewSentenceOnNextAppend = false
            lastSnapshot = nil
            return nil
        }

        updateBoundary()
        let isFinal = startsNewSentenceOnNextAppend
        let snapshot = SentenceSnapshot(text: text, revision: revision, isFinal: isFinal, isOverlong: isOverlong)
        lastSnapshot = snapshot
        startsNewSentenceOnNextAppend = isFinal
        return snapshot
    }

    @discardableResult
    public mutating func removeLastCharacter() -> SentenceSnapshot? {
        guard !text.isEmpty else { return nil }

        if !trailingSeparators.isEmpty {
            trailingSeparators.removeLast()
            if trailingSeparators.isEmpty { updateBoundary() }
            return lastSnapshot
        }
        text.removeLast()
        updateBoundary()
        revision &+= 1

        guard !text.isEmpty else {
            lastSnapshot = nil
            return nil
        }

        let snapshot = SentenceSnapshot(
            text: text,
            revision: revision,
            isFinal: startsNewSentenceOnNextAppend,
            isOverlong: isOverlong
        )
        lastSnapshot = snapshot
        return snapshot
    }

    public mutating func reset() {
        text.removeAll(keepingCapacity: false)
        trailingSeparators.removeAll(keepingCapacity: false)
        isOverlong = false
        startsNewSentenceOnNextAppend = false
        lastSnapshot = nil
        adjacentToEnglishPeriod = false
        revision &+= 1
    }

    private mutating func updateBoundary() {
        startsNewSentenceOnNextAppend = text.last.map(isTerminalPunctuation) ?? false
        adjacentToEnglishPeriod = false
        guard periodEndsSentence, text.last == "." else { return }
        // Rejoin a dot inside an ASCII token (e.g. a version or domain), but
        // start fresh when the user resumes Chinese after an English sentence.
        adjacentToEnglishPeriod = text.dropLast().last.map(Self.isASCIITokenCharacter) ?? false
        let word = String(text.reversed().prefix { ($0.isASCII && $0.isLetter) || $0 == "." }.reversed()).lowercased()
        let parts = word.dropLast().split(separator: ".")
        let initials = parts.count >= 2 && parts.allSatisfy { $0.count == 1 }
        if initials || ["mr.", "mrs.", "ms.", "dr.", "prof.", "vs.", "etc."].contains(word) {
            startsNewSentenceOnNextAppend = false
        }
    }

    private static func isASCIITokenCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private func isTerminalPunctuation(_ character: Character) -> Bool {
        "。！？!?".contains(character) || (periodEndsSentence && character == ".")
    }
}
