import Foundation
import InputCore
import XCTest

final class ReplacementTests: XCTestCase {
    func testHostEditAtSameCaretRejectsReplacement() {
        let snapshot = SentenceSnapshot(text: "你好", revision: 1, isFinal: false)
        let translation = TranslationResult(sourceText: snapshot.text, translatedText: "Hello", revision: 2)
        let decision = TrackedTextReplacement.decision(enabled: true, snapshot: snapshot, translation: translation,
                                                      currentRevision: 2, expectedCaret: 5,
                                                      selection: NSRange(location: 5, length: 0), hasComposition: false)
        guard case .success(let range) = decision else { return XCTFail("Expected valid caret range") }
        var host = MemoryTextClient(text: "前文：你们")
        let accepted = TrackedTextReplacement.applyIfVerified(range, expected: snapshot.text,
            read: { (host.text as NSString).substring(with: $0) },
            replace: { _ in host.commits += 1 })
        XCTAssertFalse(accepted)
        XCTAssertEqual(host.commits, 0)
    }
}
