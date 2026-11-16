import Foundation
import XCTest
@testable import InputCore

final class InputSettingsTests: XCTestCase {
    func testMissingAndInvalidFieldsUseDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InputSettingsStore(directory: directory)
        XCTAssertEqual(store.read(), InputSettings())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["version": 0, "translationEnabled": false, "speed": "unknown"],
            format: .binary, options: 0
        )
        try data.write(to: store.preferencesURL)
        XCTAssertFalse(store.read().translationEnabled)
        XCTAssertEqual(store.read().speed, .balanced)
        try Data("malformed".utf8).write(to: store.preferencesURL)
        XCTAssertEqual(store.read(), InputSettings())
    }

    func testIndependentWritersPreserveEachOthersFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ime = InputSettingsStore(directory: directory)
        let setup = InputSettingsStore(directory: directory)

        try ime.update { $0.translationEnabled = false }
        try setup.update { $0.speed = .fast }
        XCTAssertEqual(ime.read(), setup.read())
        XCTAssertFalse(ime.read().translationEnabled)
        XCTAssertEqual(ime.read().speed, .fast)
    }
}
