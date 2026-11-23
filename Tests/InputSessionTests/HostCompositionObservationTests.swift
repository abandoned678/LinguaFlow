import Foundation
import InputSession
import XCTest

final class HostCompositionObservationTests: XCTestCase {
    private let zero = NSRange(location: 0, length: 0)
    private let mark = NSRange(location: 0, length: 2)
    private let end = NSRange(location: 2, length: 0)
    private let missing = NSRange(location: NSNotFound, length: 0)

    func testUnreadableAndStaleHostReadbacksKeepCompositionAcrossRefreshes() {
        var subject = HostCompositionObservation()
        for stale in [mark, NSRange(location: 0, length: 1)] {
            subject.wroteMark()
            subject.observed(mark: stale, selection: zero, preeditLength: 2, caret: 2, documentLength: { 2 })
            for _ in 0..<5 {
                XCTAssertNil(subject.refresh(mark: stale, selection: zero, preeditLength: 2, caret: 2,
                                              documentLength: { 0 }))
            }
        }
    }

    func testVerifiedMarkSurvivesUnreliableReadsAndEndsOnConfirmedClear() {
        var subject = HostCompositionObservation()
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 2 })
        XCTAssertNil(subject.refresh(mark: mark, selection: end, preeditLength: 2, caret: 2,
                                      documentLength: { 2 }))
        for _ in 0..<3 {
            XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                          documentLength: { NSNotFound }))
        }
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 2 })
        XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                      documentLength: { 0 }))
        XCTAssertEqual(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                        documentLength: { 0 }), .documentCleared)
    }

    func testHostClearsBeforeFirstTimerRefresh() {
        var subject = HostCompositionObservation()
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 2 })
        XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2, documentLength: { 0 }))
        XCTAssertEqual(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                       documentLength: { 0 }), .documentCleared)
    }

    func testHostLengthCanCatchUpAfterCaretReachesZero() {
        var subject = HostCompositionObservation()
        let start = ContinuousClock.now
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 2 })
        XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                     now: start, documentLength: { 2 }))
        XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                     now: start + .milliseconds(250), documentLength: { XCTFail("unthrottled probe"); return 0 }))
        XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                     now: start + .seconds(1), documentLength: { 0 }))
        XCTAssertEqual(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                       now: start + .milliseconds(1250), documentLength: { 0 }), .documentCleared)
    }

    func testClientThatAlwaysReportsZeroLengthKeepsItsMark() {
        var subject = HostCompositionObservation()
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 0 })
        for _ in 0..<4 {
            XCTAssertNil(subject.refresh(mark: mark, selection: zero, preeditLength: 2, caret: 2,
                                         documentLength: { XCTFail("untrusted length lookup"); return 0 }))
        }
    }

    func testNewMarkInvalidatesPendingHostEnd() {
        var subject = HostCompositionObservation()
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 2 })
        XCTAssertNil(subject.refresh(mark: missing, selection: end, preeditLength: 2, caret: 2,
                                      documentLength: { 2 }))
        subject.wroteMark()
        XCTAssertNil(subject.refresh(mark: missing, selection: end, preeditLength: 3, caret: 3,
                                      documentLength: { 2 }))
        subject.observed(mark: mark, selection: end, preeditLength: 2, caret: 2, documentLength: { 2 })
        XCTAssertNil(subject.refresh(mark: missing, selection: end, preeditLength: 2, caret: 2,
                                      documentLength: { 2 }))
        XCTAssertEqual(subject.refresh(mark: missing, selection: end, preeditLength: 2, caret: 2,
                                        documentLength: { 2 }), .markEnded)
    }
}

extension HostCompositionObservationTests {
    func testReactivationDiscardsOnlyVerifiedMarkedRange() {
        let observed = HostCompositionObservation()
        let mark = NSRange(location: 4, length: 2)
        let caret = NSRange(location: 6, length: 0)
        XCTAssertNil(observed.ownedMarkToDiscard(preedit: "ni", mark: mark, selection: NSRange(location: 0, length: 3)) { _ in "ni" })
        XCTAssertNil(observed.ownedMarkToDiscard(preedit: "ni", mark: NSRange(location: NSNotFound, length: 0), selection: caret) { _ in "ni" })
        XCTAssertNil(observed.ownedMarkToDiscard(preedit: "ni", mark: mark, selection: caret) { _ in "新文" })
        XCTAssertEqual(observed.ownedMarkToDiscard(preedit: "ni", mark: mark, selection: caret) { _ in "ni" }, mark)
    }
}
