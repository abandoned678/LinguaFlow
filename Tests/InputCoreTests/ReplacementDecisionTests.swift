import Carbon
import Foundation
import XCTest
@testable import InputCore

final class ReplacementDecisionTests: XCTestCase {
    private let snapshot = SentenceSnapshot(text: "你🙂", revision: 1, isFinal: false)
    private let translation = TranslationResult(sourceText: "你🙂", translatedText: "Hello 🙂", revision: 7)
    private let caret = NSRange(location: 15, length: 0)

    func testReplacementDistinguishesRejectionsAndProducesUTF16Range() {
        XCTAssertEqual(decide(enabled: false, composing: true), .failure(.disabled))
        XCTAssertEqual(decide(composing: true), .failure(.composition))
        XCTAssertEqual(decide(selection: NSRange(location: 11, length: 1)), .failure(.selection))
        XCTAssertEqual(decide(selection: NSRange(location: 11, length: 0)), .failure(.movedCaret))
        XCTAssertEqual(decide(selection: NSRange(location: NSNotFound, length: 0)), .failure(.unverifiedRange))
        XCTAssertEqual(decide(ready: false), .failure(.waiting))
        XCTAssertEqual(decide(revision: 6), .failure(.unverifiedRange))
        XCTAssertEqual(decide(overlong: true), .failure(.overlong))
        XCTAssertEqual(decide(), .success(NSRange(location: 12, length: 3)))
    }

    func testShortcutRejectsNonLettersAndMatchesCurrentSetting() {
        let key = UInt16(kVK_ANSI_Y)
        XCTAssertEqual(SentenceReplacementShortcut.label(for: key), "⌃⇧Y")
        XCTAssertTrue(SentenceReplacementShortcut.matches(keyCode: key, control: true, shift: true, configuredKeyCode: key))
        XCTAssertFalse(SentenceReplacementShortcut.matches(keyCode: key, control: false, shift: true, configuredKeyCode: key))
        XCTAssertFalse(SentenceReplacementShortcut.matches(keyCode: SentenceReplacementShortcut.defaultKeyCode, control: true, shift: true, configuredKeyCode: key))
        XCTAssertFalse(SentenceReplacementShortcut.supports(keyCode: UInt16(kVK_Return)))
    }

    private func decide(
        enabled: Bool = true, composing: Bool = false, selection: NSRange? = nil,
        ready: Bool = true, revision: UInt64 = 7, overlong: Bool = false
    ) -> Result<NSRange, TrackedTextReplacement.Rejection> {
        TrackedTextReplacement.decision(
            enabled: enabled,
            snapshot: overlong ? .init(text: snapshot.text, revision: 1, isFinal: false, isOverlong: true) : snapshot,
            translation: ready ? translation : nil, currentRevision: revision, expectedCaret: caret.location,
            selection: selection ?? caret, hasComposition: composing
        )
    }
}
