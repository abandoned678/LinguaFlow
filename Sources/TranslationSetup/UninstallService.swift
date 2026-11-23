import AppKit
import Carbon

/// Only the installed setup helper may remove its enclosing input method.
@MainActor
enum UninstallService {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    private static var removing = false

    struct Installation: Equatable {
        let url: URL
        fileprivate let id: String
        fileprivate let device: UInt64
        fileprivate let inode: UInt64
        fileprivate let executableInode: UInt64
        fileprivate let locations: [URL]

        func ensureMatches(_ confirmed: Installation) throws {
            guard self == confirmed else { throw Failure("安装副本已更换，请重新打开卸载确认页。") }
        }

        func ensureRemoved() throws {
            for location in locations {
                var statInfo = stat()
                guard lstat(location.path, &statInfo) != 0, errno == ENOENT else {
                    throw Failure("安装目录中仍有同名副本或目录无法核对，已停止清理数据。")
                }
            }
        }
    }

    static func installedApplication() throws -> Installation {
        try validateInstallation(helperID: Bundle.main.bundleIdentifier, helperURL: Bundle.main.bundleURL,
                                 userLibrary: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
                                 systemLibrary: URL(fileURLWithPath: "/Library"))
    }

    static func validateInstallation(helperID: String?, helperURL: URL, userLibrary: URL, systemLibrary: URL)
        throws -> Installation {
        let id: String
        let name: String
        switch helperID {
        case "com.abandoned678.inputmethod.SentenceAlong.Setup":
            id = "com.abandoned678.inputmethod.SentenceAlong"
            name = "SentenceAlong.app"
        case "com.abandoned678.inputmethod.SentenceAlongDebug.Setup":
            id = "com.abandoned678.inputmethod.SentenceAlongDebug"
            name = "SentenceAlongDebug.app"
        default:
            throw Failure("请从已安装的随键译输入法菜单打开设置，再执行卸载。")
        }

        let fm = FileManager.default
        let locations = [userLibrary, systemLibrary].map { $0.appendingPathComponent("Input Methods/" + name) }
        let userApp = locations[0]
        var allowed = [userApp]
        if name == "SentenceAlong.app" {
            allowed.append(locations[1])
        }
        guard let url = allowed.first(where: {
            $0.appendingPathComponent("Contents/Helpers/SentenceAlongSetup.app").path == helperURL.path
        }) else { throw Failure("当前设置助手不在已安装的输入法目录中。请从输入法菜单打开设置。") }

        let executable = url.appendingPathComponent("Contents/MacOS/SentenceAlongIME")
        let plist = url.appendingPathComponent("Contents/Info.plist")
        var bundleStat = stat()
        var executableStat = stat()
        guard [url, executable, plist, helperURL].allSatisfy({
            $0.path == $0.resolvingSymlinksInPath().path
        }), let info = NSDictionary(contentsOf: plist),
           info["CFBundleIdentifier"] as? String == id, info["TISInputSourceID"] as? String == id,
           info["CFBundleExecutable"] as? String == "SentenceAlongIME",
           fm.isExecutableFile(atPath: executable.path),
           lstat(url.path, &bundleStat) == 0, lstat(executable.path, &executableStat) == 0 else {
            throw Failure("无法核对已安装输入法的身份或路径。请检查安装位置。")
        }
        if locations.contains(where: { $0.path != url.path && fm.fileExists(atPath: $0.path) }) {
            throw Failure("用户和系统输入法目录中有同名副本。请先在访达中移走多余副本，再从要卸载的版本打开设置。")
        }
        return Installation(url: url, id: id, device: UInt64(bundleStat.st_dev), inode: UInt64(bundleStat.st_ino),
                            executableInode: UInt64(executableStat.st_ino), locations: locations)
    }

    static func removeApplication(expected: Installation) async throws {
        guard !removing else { throw Failure("卸载正在进行中。") }
        removing = true
        defer { removing = false }

        let target = try installedApplication()
        try target.ensureMatches(expected)
        let sourceFilter = [kTISPropertyBundleID as String: target.id,
                            kTISPropertyInputSourceID as String: target.id] as CFDictionary
        guard let sources = TISCreateInputSourceList(sourceFilter, false)?.takeRetainedValue(),
              let enabled = sources as? [TISInputSource],
              let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            throw Failure("无法读取当前键盘输入源，请在已解锁的桌面中重试。")
        }
        guard enabled.count <= 1 else { throw Failure("系统中有多个同名输入源，无法确认卸载目标。") }
        let selected = sourceID(original) == target.id
        try await withSourceRollback(switchAway: selected ? {
            guard let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  sourceID(layout) != target.id, TISSelectInputSource(layout) == noErr else {
                throw Failure("无法切换输入源。请先切换到另一种键盘布局，再重试卸载。")
            }
        } : nil, disable: enabled.first.map { source in
            {
                guard TISDisableInputSource(source) == noErr else {
                    throw Failure("macOS 未能停用此输入源。请在「系统设置 → 键盘」中移除该输入源后重试。")
                }
            }
        }, originalStillInstalled: { (try? installedApplication()) == target },
        enable: { enabled.first.map { TISEnableInputSource($0) == noErr } ?? true },
        selectOriginal: { TISSelectInputSource(original) == noErr }) {
            try await stopInputMethod(at: target.url, identifier: target.id)
            try installedApplication().ensureMatches(expected)
            let recycled = try await NSWorkspace.shared.recycle([target.url])
            guard recycled.keys.contains(where: { $0.path == target.url.path }),
                  !FileManager.default.fileExists(atPath: target.url.path) else {
                throw Failure("未能确认输入法已移入废纸篓。请检查安装目录。")
            }
        }
    }

    static func withSourceRollback(switchAway: (() throws -> Void)?, disable: (() throws -> Void)?,
                                   originalStillInstalled: () -> Bool, enable: () -> Bool,
                                   selectOriginal: () -> Bool, removal: () async throws -> Void) async throws {
        var switched = false
        var disabled = false
        do {
            if let switchAway {
                try switchAway()
                switched = true
            }
            if let disable {
                try disable()
                disabled = true
            }
            try await removal()
        } catch {
            if originalStillInstalled() {
                if disabled && !enable() {
                    throw Failure("\(error.localizedDescription) 请到「系统设置 → 键盘」重新添加此输入源。")
                }
                if switched && !selectOriginal() {
                    throw Failure("\(error.localizedDescription) 请从输入菜单重新选择原输入源。")
                }
            }
            throw error
        }
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func stopInputMethod(at url: URL, identifier: String) async throws {
        let expected = url.appendingPathComponent("Contents/MacOS/SentenceAlongIME").path
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard applications.allSatisfy({ $0.executableURL?.path == expected }) else {
            throw Failure("另一份相同标识的输入法正在运行。请退出该副本后重试。")
        }
        for app in applications where !app.isTerminated {
            _ = app.terminate()
        }
        for _ in 0..<30 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("输入法进程仍在运行。请结束当前组词并切换到其他输入源后重试。")
    }
}
