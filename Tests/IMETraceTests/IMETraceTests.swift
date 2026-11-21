import XCTest
@testable import IMETrace

final class IMETraceTests: XCTestCase {
    private let id = UUID()
    private func stream(_ role: TraceRole, _ stages: [TraceStage]) -> [TraceEvent] {
        let session = UUID()
        return stages.enumerated().map {
            TraceEvent(run: id, session: session, role: role, index: $0.offset, stage: $0.element)
        }
    }

    func testRequiresBothProcessesAndExactlyOneCommit() throws {
        let ime = stream(.ime, [.activated] + Array(repeating: .key, count: 5) + [.candidateMatched, .key, .commitRequested])
        let host = stream(.host, [.focused, .marked, .inserted, .documentMatched])
        XCTAssertTrue(try TraceEvidence(events: ime + host, run: id).pinyinCommitted)
        XCTAssertFalse(try TraceEvidence(events: host, run: id).pinyinCommitted)
        XCTAssertFalse(try TraceEvidence(events: ime, run: id).pinyinCommitted)
        XCTAssertFalse(try TraceEvidence(events: ime + stream(.host, [.focused, .marked, .inserted, .inserted, .documentMatched]), run: id).pinyinCommitted)
        XCTAssertThrowsError(try TraceEvidence(events: ime + host, run: UUID()))
    }

    func testExpiredRunCannotStartAnotherSession() throws {
        let run = TraceRun(build: "fixture", scenario: "pinyin-commit")
        XCTAssertNoThrow(try run.validate(at: run.deadline.addingTimeInterval(-1)))
        XCTAssertThrowsError(try run.validate(at: run.deadline))
    }

    func testMissingDuplicateAndOverflowAreIncompleteEvidence() {
        let events = stream(.host, [.focused, .marked])
        XCTAssertThrowsError(try TraceEvidence(events: [events[1]], run: id))
        XCTAssertThrowsError(try TraceEvidence(events: events + events, run: id))
        XCTAssertThrowsError(try TraceEvidence(events: stream(.ime, [.overflow]), run: id))
        XCTAssertThrowsError(try TraceEvidence(directory: URL(fileURLWithPath: "/nonexistent-ime-fixture"), run: id))
    }
}
