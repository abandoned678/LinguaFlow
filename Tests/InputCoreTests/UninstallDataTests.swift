import Foundation
import XCTest
@testable import InputCore

final class UninstallDataTests: XCTestCase {
    private let files = FileManager.default
    private let phrase = "Rime/sjy_personal.txt"
    private let weights = "Rime/sjy_weighted.txt"
    private let learned = "Rime/luna_pinyin.userdb/fixture.ldb"
    private let clearRequest = "Rime/.sjy-clear-learning"
    private let preferences = InputSettingsStore.domain + ".plist"
    private let unrelated = "Rime/unrelated.txt"

    private func fixture() throws -> URL {
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(InputSettingsStore.productDirectory)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for (path, contents) in [
            (phrase, "# test\n甲\tj\t100\n乙\ty\t100\n"),
            (weights, "# test\n乙\tyi\t42\n"),
            (learned, "synthetic"), (clearRequest, ""), (preferences, "settings"), (unrelated, "keep")
        ] {
            let url = directory.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return directory
    }

    func testPreviewAndDefaultKeepAllData() throws {
        let directory = try fixture()
        let paths = [phrase, weights, learned, clearRequest, preferences, unrelated]
        let urls = paths.map { directory.appendingPathComponent($0) }
        let before = try urls.map { try Data(contentsOf: $0) }
        let data = UninstallData(directory: directory)
        let counts = try data.counts()
        XCTAssertEqual(counts.phrases, 2)
        XCTAssertEqual(counts.weights, 1)
        try data.remove([])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    }

    func testEachSelectionAndCombinedSelectionAffectOnlyRequestedFiles() throws {
        let cases: [Set<UninstallData.Category>] = [
            [.phrases], [.weights], [.learning], [.preferences], [.weights, .learning],
            [.phrases, .weights, .learning, .preferences]
        ]
        for selected in cases {
            let directory = try fixture()
            let other = directory.deletingLastPathComponent().appendingPathComponent("OtherEdition")
            try files.copyItem(at: directory, to: other)
            let data = UninstallData(directory: directory)
            try data.remove(selected)
            try data.remove(selected)
            let owned: [(String, UninstallData.Category)] = [
                (phrase, .phrases), (weights, .weights), (learned, .learning),
                (clearRequest, .learning), (preferences, .preferences)
            ]
            for (path, category) in owned {
                XCTAssertEqual(files.fileExists(atPath: directory.appendingPathComponent(path).path),
                               !selected.contains(category))
                XCTAssertTrue(files.fileExists(atPath: other.appendingPathComponent(path).path))
            }
            XCTAssertTrue(files.fileExists(atPath: directory.appendingPathComponent(unrelated).path))
        }
    }

    func testSymlinkedRimeDirectoryCannotReadOrRemoveOtherEditionsData() throws {
        let directory = try fixture()
        let other = directory.deletingLastPathComponent().appendingPathComponent("OtherEdition")
        try files.moveItem(at: directory.appendingPathComponent("Rime"), to: other)
        try files.createSymbolicLink(at: directory.appendingPathComponent("Rime"), withDestinationURL: other)
        let data = UninstallData(directory: directory)
        XCTAssertThrowsError(try data.counts())
        XCTAssertThrowsError(try data.remove([.phrases, .weights, .learning]))
        XCTAssertTrue(files.fileExists(atPath: other.appendingPathComponent("sjy_personal.txt").path))
        XCTAssertTrue(files.fileExists(atPath: other.appendingPathComponent("sjy_weighted.txt").path))
        XCTAssertTrue(files.fileExists(atPath: other.appendingPathComponent("luna_pinyin.userdb/fixture.ldb").path))
    }

    func testLinkedPhraseFileIsRejectedWithoutChangingItsTarget() throws {
        let directory = try fixture()
        let url = directory.appendingPathComponent(phrase)
        let target = directory.deletingLastPathComponent().appendingPathComponent("external")
        try files.moveItem(at: url, to: target)
        let original = try Data(contentsOf: target)
        try files.createSymbolicLink(at: url, withDestinationURL: target)
        let data = UninstallData(directory: directory)
        XCTAssertThrowsError(try data.counts())
        XCTAssertThrowsError(try data.remove([.phrases]))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
