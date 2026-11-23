import XCTest
import InputCore

final class EnglishSentenceBoundaryTests: XCTestCase {
    func testBackspaceAfterEnglishSentenceMirrorsOnlyTheSeparator() {
        var buffer = CommittedSentenceBuffer(periodEndsSentence: true)
        buffer.append("I agree.")
        buffer.append("  ")
        XCTAssertEqual(buffer.removeLastCharacter()?.text, "I agree.")
        XCTAssertEqual(buffer.removeLastCharacter()?.text, "I agree.")
        XCTAssertEqual(buffer.removeLastCharacter()?.text, "I agree")
    }

    func testWordsNumbersDomainsAndAbbreviationsStayInCurrentSentence() {
        let text = "Review v3.14 at example.org, e.g. the API."
        var buffer = CommittedSentenceBuffer(periodEndsSentence: true)
        for character in text { buffer.append(String(character)) }
        XCTAssertEqual(buffer.currentSnapshot?.text, text)
        XCTAssertTrue(buffer.currentSnapshot?.isFinal == true)
        buffer.append(" Next")
        XCTAssertEqual(buffer.currentSnapshot?.text, "Next")
    }
}
