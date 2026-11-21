import XCTest
import RimeInput
import InputSession

final class CompositionTests: XCTestCase {
    func testCommitAndNextCompositionAreDeliveredInOrder() {
        let snapshot = RimeSnapshot(consumed: true, preedit: "hao", candidates: [], highlightedIndex: 0, commit: "你")
        XCTAssertEqual(snapshot.hostEdits(previousPreedit: "ni"), [.commit("你"), .mark("hao")])
    }

    func testCaretOnlyChangeUsesUTF16Selection() {
        let snapshot = RimeSnapshot(consumed: true, preedit: "lü 好", cursorByteOffset: 3,
                                    candidates: [], highlightedIndex: 0, commit: nil)
        XCTAssertEqual(snapshot.caretUTF16, 2)
        XCTAssertEqual(snapshot.hostEdits(previousPreedit: snapshot.preedit, previousCaret: 4), [.mark(snapshot.preedit)])
    }

    func testCandidateOnlyRefreshDoesNotRewriteMarkedText() {
        let snapshot = RimeSnapshot(consumed: true, preedit: "ni", candidates: [], highlightedIndex: 1, commit: nil)
        XCTAssertTrue(snapshot.hostEdits(previousPreedit: "ni").isEmpty)
    }

    @MainActor
    func testRealEngineReplayCommitsOnceAndKeepsPrefix() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shared = root.appendingPathComponent(".build/rime-shared")
        guard FileManager.default.fileExists(atPath: shared.appendingPathComponent("essay.txt").path) else {
            throw XCTSkip("Prepare fixtures with scripts/prepare-rime-data.sh")
        }
        let user = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: user) }
        let runtime = try RimeRuntime(sharedDataDirectory: shared, userDataDirectory: user)
        let engine = try RimeEngine(runtime: runtime)
        var host = MemoryTextClient(text: "前文：")
        for key in "nihao ".utf8 {
            let snapshot = engine.process(keyCode: Int32(key))
            host.apply(snapshot.hostEdits(previousPreedit: host.marked))
        }
        XCTAssertEqual(host.text, "前文：你好")
        XCTAssertEqual(host.commits, 1)
        XCTAssertTrue(host.marked.isEmpty)
    }
}
