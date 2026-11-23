import XCTest
@testable import InputCore

final class WeightedVocabularyTests: XCTestCase {
    private func words(_ tsv: String) throws -> [WeightedWord] {
        try PersonalDictionary.weightedEntries(from: Data(tsv.utf8))
    }

    func testWeightedImportValidatesTheWholeFile() throws {
        let rows = try words("\u{FEFF}# test\r\n甲\tjia\t0001\r\n甲\tjia\t1\r\n乙\tyi\t2\r\n")
        XCTAssertEqual(rows.map(\.weight), [1, 2])
        for invalid in ["# only", "甲\tjia\t0", "甲\tJIA\t20", "甲\tjia\t2147483648",
                        "甲\tjia\t1\n乙\tyi\tab", "甲\tjia\t1\n甲\tjia\t2"] {
            XCTAssertThrowsError(try words(invalid))
        }
        XCTAssertThrowsError(try PersonalDictionary.weightedEntries(from: Data([0xff, 0xfe])))
    }

    func testMergeIsIdempotentAndBothClearOperationsAreIndependent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PersonalDictionary(directory: dir)
        let phrase = try PersonalPhrase(code: "sj", text: "手动")
        try store.replace(nil, with: phrase)
        let initial = try words("甲\ttest\t1\n乙\ttest\t2")
        XCTAssertEqual(try store.importWeightedEntries(initial).added, 2)
        let revision = try XCTUnwrap(store.weightedRevision)
        XCTAssertEqual(try store.importWeightedEntries(initial).unchanged, 2)
        XCTAssertEqual(store.weightedRevision, revision)
        let result = try store.importWeightedEntries(words("甲\ttest\t9\n丙\tfinish\t3"))
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 1)
        let table = dir.appendingPathComponent("sjy_weighted.txt")
        XCTAssertEqual(try PersonalDictionary.weightedEntries(from: Data(contentsOf: table)).map(\.weight), [3, 9, 2])
        try store.requestClearLearning()
        try store.clearLearningIfRequested()
        XCTAssertTrue(FileManager.default.fileExists(atPath: table.path))
        let db = dir.appendingPathComponent("luna_pinyin.userdb")
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        try store.clearImportedWeights()
        try store.clearImportedWeights()
        XCTAssertNil(store.weightedRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        XCTAssertEqual(try store.phrases(), [phrase])
    }

    func testCorruptExistingTableIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sjy_weighted.txt")
        let contents = Data("invalid row".utf8)
        try contents.write(to: file)
        XCTAssertThrowsError(try PersonalDictionary(directory: dir).importWeightedEntries(words("词条\tct\t5")))
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }
}
