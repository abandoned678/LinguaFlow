import XCTest
@testable import TranslationSetup

final class UninstallServiceTests: XCTestCase {
    private static let baseID = "com.abandoned678.inputmethod.SentenceAlong"
    private let fm = FileManager.default

    @MainActor
    func testIdentityIsBoundToHelperLocationAndRejectsDuplicateAndSymlink() throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let user = root.appendingPathComponent("user")
        let system = root.appendingPathComponent("system")
        let debugID = Self.baseID + "Debug"
        func install(_ library: URL, id: String, name: String) throws -> URL {
            let app = library.appendingPathComponent("Input Methods/" + name)
            let helper = app.appendingPathComponent("Contents/Helpers/SentenceAlongSetup.app")
            try fm.createDirectory(at: helper, withIntermediateDirectories: true)
            let executable = app.appendingPathComponent("Contents/MacOS/SentenceAlongIME")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let info = ["CFBundleIdentifier": id, "TISInputSourceID": id, "CFBundleExecutable": "SentenceAlongIME"]
            try PropertyListEncoder().encode(info).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return helper
        }
        func validate(_ helper: URL, _ id: String) throws -> URL {
            try UninstallService.validateInstallation(helperID: id + ".Setup", helperURL: helper,
                                                      userLibrary: user, systemLibrary: system).url
        }

        let debug = try install(user, id: debugID, name: "SentenceAlongDebug.app")
        let release = try install(system, id: Self.baseID, name: "SentenceAlong.app")
        XCTAssertEqual(try validate(debug, debugID).lastPathComponent, "SentenceAlongDebug.app")
        XCTAssertEqual(try validate(release, Self.baseID).lastPathComponent, "SentenceAlong.app")
        XCTAssertThrowsError(try validate(debug, Self.baseID))
        XCTAssertThrowsError(try validate(release, debugID))
        XCTAssertThrowsError(try validate(root, Self.baseID))

        let userRelease = try install(user, id: Self.baseID, name: "SentenceAlong.app")
        XCTAssertThrowsError(try validate(release, Self.baseID))
        XCTAssertThrowsError(try validate(userRelease, Self.baseID))
        func debugSnapshot() throws -> UninstallService.Installation {
            try UninstallService.validateInstallation(helperID: debugID + ".Setup", helperURL: debug,
                                                      userLibrary: user, systemLibrary: system)
        }
        let confirmed = try debugSnapshot()
        XCTAssertThrowsError(try confirmed.ensureRemoved())
        let old = root.appendingPathComponent("recycled-debug")
        try fm.moveItem(at: confirmed.url, to: old)
        XCTAssertNoThrow(try confirmed.ensureRemoved())
        _ = try install(user, id: debugID, name: "SentenceAlongDebug.app")
        XCTAssertThrowsError(try confirmed.ensureRemoved())
        XCTAssertThrowsError(try debugSnapshot().ensureMatches(confirmed))
        let executable = (try validate(debug, debugID)).appendingPathComponent("Contents/MacOS/SentenceAlongIME")
        try fm.removeItem(at: executable)
        try fm.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        XCTAssertThrowsError(try validate(debug, debugID))
    }

    @MainActor
    func testFailureRollsBackOnlySuccessfulStepsForOriginalInstallation() async {
        enum Failure: Error { case disable, recycle }
        func events(enabled: Bool = true, selected: Bool = true, disableFails: Bool = false,
                    cancelled: Bool = true, sameCopy: Bool = true, enableOK: Bool = true,
                    selectOK: Bool = true) async -> ([String], String?) {
            var history: [String] = []
            do {
                try await UninstallService.withSourceRollback(switchAway: selected ? { history.append("switch") } : nil,
                    disable: enabled ? {
                        history.append("disable")
                        if disableFails { throw Failure.disable }
                    } : nil, originalStillInstalled: { sameCopy }, enable: {
                        history.append("enable")
                        return enableOK
                    }, selectOriginal: {
                        history.append("select")
                        return selectOK
                    }) {
                        history.append("remove")
                        if cancelled { throw Failure.recycle }
                    }
                return (history, nil)
            } catch { return (history, error.localizedDescription) }
        }
        let success = await events(cancelled: false)
        XCTAssertEqual(success.0, ["switch", "disable", "remove"])
        XCTAssertNil(success.1)
        let cancelled = await events()
        XCTAssertEqual(cancelled.0, ["switch", "disable", "remove", "enable", "select"])
        XCTAssertNotNil(cancelled.1)
        let partial = await events(disableFails: true)
        XCTAssertEqual(partial.0, ["switch", "disable", "select"])
        let replaced = await events(sameCopy: false)
        XCTAssertEqual(replaced.0, ["switch", "disable", "remove"])
        let enableFailed = await events(enableOK: false)
        XCTAssertEqual(enableFailed.0.last, "enable")
        XCTAssertTrue(enableFailed.1?.contains("重新添加") == true)
        let selectFailed = await events(selectOK: false)
        XCTAssertTrue(selectFailed.1?.contains("重新选择") == true)
        let inactive = await events(enabled: false, selected: false)
        XCTAssertEqual(inactive.0, ["remove"])
    }
}
