import Foundation
import InputCore
import XCTest

final class PersonalDictionaryTests: XCTestCase {
    func testEditsSurviveReopenAndCannotOverwriteConcurrentChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PersonalDictionary(directory: url), second = PersonalDictionary(directory: url)
        let a = try PersonalPhrase(code: "sjy", text: "测试短语")
        let b = try PersonalPhrase(code: "sjyy", text: "新短语")
        try first.replace(nil, with: a)
        XCTAssertEqual(try second.phrases(), [a])
        XCTAssertThrowsError(try second.replace(nil, with: a))
        try second.replace(a, with: b)
        XCTAssertThrowsError(try first.replace(a, with: nil))
        XCTAssertEqual(try first.phrases(), [b])
        try first.replace(b, with: nil)
        XCTAssertEqual(try second.phrases(), [])
        XCTAssertThrowsError(try PersonalPhrase(code: "invalid/file", text: "x"))
        XCTAssertThrowsError(try PersonalPhrase(code: "sjy", text: "x\ny"))
    }

    func testClearingLearnedWordsPreservesPersonalPhrasesAndOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersonalDictionary(directory: url)
        let phrase = try PersonalPhrase(code: "abc", text: "固定短语")
        try store.replace(nil, with: phrase)
        let db = url.appendingPathComponent("luna_pinyin.userdb")
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        try Data().write(to: url.appendingPathComponent("user.yaml"))
        try store.clearLearningIfRequested()
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        try store.requestClearLearning()
        XCTAssertTrue(store.clearPending)
        try store.clearLearningIfRequested()
        XCTAssertFalse(store.clearPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("user.yaml").path))
        XCTAssertEqual(try store.phrases(), [phrase])
    }
}
