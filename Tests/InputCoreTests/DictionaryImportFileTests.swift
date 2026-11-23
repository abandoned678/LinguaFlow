import Foundation
import XCTest
@testable import InputCore

final class DictionaryImportFileTests: XCTestCase {
    func testShortReadEndingAtNewlineContinuesUntilEOF() throws {
        var chunks = [Data("a\tb\n".utf8), Data("c\td".utf8), Data()]
        let data = try DictionaryImportFile.readChunks(limit: 7) { _ in chunks.removeFirst() }
        XCTAssertEqual(data, Data("a\tb\nc\td".utf8))
    }

    func testLimitAppliesAcrossShortReads() {
        var chunks = [Data([1, 2]), Data([3])]
        XCTAssertThrowsError(try DictionaryImportFile.readChunks(limit: 2) { _ in chunks.removeFirst() })
    }
}
