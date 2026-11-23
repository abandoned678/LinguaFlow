import XCTest
import IMETrace

final class ExternalDraftTests: XCTestCase {
    func testIgnoredNewDraftWithCaretAtStartIsRejected() {
        XCTAssertFalse(ExternalDraft.isNewTarget(newWindow: false, sameWindow: true, replacedEditor: false))
        XCTAssertFalse(ExternalDraft.isEmpty(characterCount: 12, selection: NSRange(location: 0, length: 0)))
        XCTAssertFalse(ExternalDraft.isEmpty(characterCount: nil, selection: NSRange(location: 0, length: 0)))
        XCTAssertTrue(ExternalDraft.isEmpty(characterCount: 0, selection: NSRange(location: 0, length: 0)))
    }

    func testReadyPreviewInBothLayouts() {
        XCTAssertEqual(ExternalDraft.previewTranslation("EN Hello!"), "Hello!")
        XCTAssertEqual(ExternalDraft.previewTranslation("中文 你好。EN Hi."), "Hi.")
        for value in ["EN 等待翻译", "EN Hello!\n", "EN !Hello", "候选 1 你好。EN Hello", "中文 其他。EN Hello"] {
            XCTAssertNil(ExternalDraft.previewTranslation(value))
        }
    }

    func testStrictDocumentPreservesPrefixAndLineEndings() {
        let prefix = ExternalDraft.prefix
        XCTAssertTrue(ExternalDraft.matchesReplacement(prefix + "Hello!", preview: "Hello!"))
        for document in ["Hello!", prefix + "Hello!\n", prefix + " Hello!", prefix + "Hello"] {
            XCTAssertFalse(ExternalDraft.matchesReplacement(document, preview: "Hello!"))
        }
    }
}
