import Foundation
import InputCore
import XCTest

final class PhraseImportTests: XCTestCase {
    private func withStore(_ test: (PersonalDictionary) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(PersonalDictionary(directory: directory))
    }

    func testTSVMergesAtCommitTimeAndRetryDoesNotRewrite() throws {
        let input = Data("\u{feff}abc\t先來\r\ndef\t保留 空格 \r\nabc\t另外\r\nghi\t一\nghi\t二\nBAD\t拒绝\ntoo\tmany\tcolumns".utf8)
        let batch = try PhraseImportBatch(data: input, format: .tsv)
        XCTAssertEqual(batch.validCount, 5)
        XCTAssertEqual(batch.invalidCount, 2)
        try withStore { store in
            // Simulate a manual edit in another window after parsing this file.
            let existing = try PersonalPhrase(code: "abc", text: "已存在")
            try PersonalDictionary(directory: store.directory).replace(nil, with: existing)
            let result = try store.importPhrases(batch)
            XCTAssertEqual(result.inserted, 2)
            XCTAssertEqual(result.skippedConflicts, 3)
            XCTAssertEqual(result.invalidCount, 2)
            let rows = try store.phrases()
            XCTAssertTrue(rows.contains(existing))
            XCTAssertTrue(rows.contains(try PersonalPhrase(code: "def", text: "保留 空格 ")))
            XCTAssertTrue(rows.contains(try PersonalPhrase(code: "ghi", text: "一")))
            let revision = store.revision
            XCTAssertEqual(try store.importPhrases(batch).inserted, 0)
            XCTAssertEqual(store.revision, revision)
        }
    }

    func testAppleXMLAndBinaryAndUnsupportedShortcuts() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let records: [[String: String]] = [["shortcut": "key", "phrase": "繁體"], ["shortcut": "foo1", "phrase": "無效"],
                                                ["phrase": "缺码"]]
            let data = try PropertyListSerialization.data(fromPropertyList: records, format: format, options: 0)
            let batch = try PhraseImportBatch(data: data, format: .appleTextReplacements)
            try withStore { store in
                let report = try store.importPhrases(batch)
                XCTAssertEqual(report.inserted, 1)
                XCTAssertEqual(report.invalidCount, 2)
                XCTAssertTrue(try store.phrases().first == PersonalPhrase(code: "key", text: "繁體"))
            }
        }
    }

    func testSogouKeepsEqualsHandlesBOMAndSkipsWholeMultilineOrDynamicRecord() throws {
        let input = ";注释\r\nab,1= first=2 \r\nbc,2=第一行\r\n第二行\r\ncd,3=#动态\r\nde,0=无效位置\r\nef,4=末项"
        for (encoding, bom): (String.Encoding, [UInt8]) in [(.utf16LittleEndian, [0xff, 0xfe]), (.utf16BigEndian, [0xfe, 0xff]), (.utf8, [])] {
            let batch = try PhraseImportBatch(data: Data(bom) + XCTUnwrap(input.data(using: encoding)), format: .sogouCustomPhrases)
            XCTAssertEqual(batch.validCount, 2)
            XCTAssertEqual(batch.invalidCount, 3)
            try withStore { store in
                _ = try store.importPhrases(batch)
                XCTAssertTrue(try store.phrases().first == PersonalPhrase(code: "ab", text: " first=2 "))
            }
        }
    }

    func testRejectsUnknownFilesAndPreservesUnreadableDictionary() throws {
        XCTAssertThrowsError(try PhraseImportBatch(data: Data([0xf0, 0xff, 0x09]), format: .tsv))
        XCTAssertThrowsError(try PhraseImportBatch(data: Data("unrelated".utf8), format: .sogouCustomPhrases))
        XCTAssertThrowsError(try PhraseImportBatch(data: Data("not a plist".utf8), format: .appleTextReplacements))
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let file = store.directory.appendingPathComponent("sjy_personal.txt")
            let contents = Data("broken row".utf8)
            try contents.write(to: file)
            let batch = try PhraseImportBatch(data: Data("abc\t短语".utf8), format: .tsv)
            XCTAssertThrowsError(try store.importPhrases(batch))
            XCTAssertTrue(try Data(contentsOf: file) == contents)
        }
    }
}
