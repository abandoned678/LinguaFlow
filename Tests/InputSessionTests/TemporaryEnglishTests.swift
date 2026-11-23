import XCTest
import InputSession

final class TemporaryEnglishTests: XCTestCase {
    func testReactivateSameFocusedEditorKeepsDirectEnglish() {
        var mode = TemporaryEnglishMode()
        mode.shiftDown(56)
        XCTAssertTrue(mode.acceptsRelease(56))
        mode.toggle()
        mode.activate(continuingSameClient: true)
        XCTAssertTrue(mode.isEnglish, "same editor reactivation lost temporary English")
        mode.activate(continuingSameClient: false)
        XCTAssertFalse(mode.isEnglish)
    }

    func testReactivationBetweenShiftEdgesKeepsOnlySameClientGesture() {
        var mode = TemporaryEnglishMode()
        mode.shiftDown(56)
        mode.activate(continuingSameClient: true)
        XCTAssertTrue(mode.acceptsRelease(56))
        mode.shiftDown(60)
        mode.activate(continuingSameClient: false)
        XCTAssertFalse(mode.acceptsRelease(60))
    }

    func testDuplicateModifierEventsToggleExactlyOncePerPhysicalTap() {
        for key: UInt16 in [56, 60] {
            var mode = TemporaryEnglishMode()
            for expected in [true, false] {
                mode.shiftDown(key)
                mode.shiftDown(key)
                if mode.acceptsRelease(key) { mode.toggle() }
                if mode.acceptsRelease(key) { mode.toggle() }
                XCTAssertEqual(mode.isEnglish, expected)
            }
        }
    }

    func testChordAndDifferentShiftCannotToggle() {
        var mode = TemporaryEnglishMode()
        mode.shiftDown(56)
        mode.cancelGesture()
        XCTAssertFalse(mode.acceptsRelease(56))
        mode.shiftDown(60)
        XCTAssertFalse(mode.acceptsRelease(56))
        // Left down, right down, left up (Shift flag still set), right up.
        mode.shiftDown(56)
        mode.shiftDown(60)
        mode.shiftDown(56)
        XCTAssertFalse(mode.acceptsRelease(60))
    }
}
