import AppKit
import Carbon
import IMETrace

/// Only operates on a newly opened test document or an empty, unsent draft.
@MainActor
final class ExternalHost {
    static let cases = ["textedit-undo", "codex-draft"]

    private let app: NSRunningApplication
    private let document: URL?
    private let window: AXUIElement
    private let editor: AXUIElement
    private let installed: URL
    private(set) var observedIMEPID: pid_t?
    private(set) var lastStep = "empty editor verified"

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ app: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func wait(_ seconds: TimeInterval, for condition: () throws -> Bool) throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        repeat {
            guard interrupted == 0, !IsSecureEventInputEnabled() else { throw RunFailure.blocked("interrupted or secure input") }
            if try condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        } while ContinuousClock.now < deadline
        return false
    }

    init(run: TraceRun, installed: URL, manual: Bool) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw RunFailure.blocked("external checks require accessibility and event posting access")
        }
        self.installed = installed
        var launchedInstance: NSRunningApplication?
        var temporaryFile: URL?
        var editorVerified = false
        defer {
            if !editorVerified {
                launchedInstance?.terminate()
                if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            }
        }
        if run.scenario == "textedit-undo" {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("SentenceAlong-\(run.id).txt")
            try Data().write(to: file)
            temporaryFile = file
            document = file
            let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
                .map(\.processIdentifier))
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["-ApplePersistenceIgnoreState", "YES"]
            var instance: NSRunningApplication?
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: config) { opened, _ in
                DispatchQueue.main.async { instance = opened }
            }
            guard try Self.wait(8, for: { instance != nil }), let instance else { throw RunFailure.blocked("TextEdit launch") }
            guard instance.bundleIdentifier == "com.apple.TextEdit", !existingPIDs.contains(instance.processIdentifier) else {
                throw RunFailure.blocked("TextEdit reused an existing process")
            }
            launchedInstance = instance
            app = instance
        } else {
            guard let codex = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else {
                throw RunFailure.blocked("Codex is not running")
            }
            document = nil
            app = codex
        }
        app.activate(options: [.activateAllWindows])
        let pid = app.processIdentifier
        guard try Self.wait(4, for: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else {
            throw RunFailure.blocked("external host did not activate")
        }
        if document == nil {
            try Self.post(UInt16(kVK_ANSI_N), flags: .maskCommand, to: pid)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let ax = AXUIElementCreateApplication(pid)
        let expectedFile = document
        let waitingForClick = manual && expectedFile == nil
        if waitingForClick {
            print("请点击刚打开的新草稿输入框，等待输入提示。")
            fflush(stdout)
        }
        var target: (AXUIElement, AXUIElement)?
        guard try Self.wait(waitingForClick ? 40 : 5, for: {
            guard let win = Self.element(ax, kAXFocusedWindowAttribute),
                  let edit = Self.element(ax, kAXFocusedUIElementAttribute),
                  Self.attribute(edit, kAXRoleAttribute) as? String == "AXTextArea" else { return false }
            if let expectedFile {
                guard let path = Self.attribute(win, kAXDocumentAttribute) as? String,
                      URL(string: path)?.standardizedFileURL.resolvingSymlinksInPath()
                        == expectedFile.standardizedFileURL.resolvingSymlinksInPath() else { return false }
            }
            target = (win, edit)
            return true
        }), let target else { throw RunFailure.blocked("dedicated editor did not acquire focus") }
        (window, editor) = target
        // Placeholder text can be exposed as AXValue. Verify the end of the
        // editable document before reading any text or sending sample input.
        try key(UInt16(kVK_DownArrow), .maskCommand)
        guard let rangeValue = Self.attribute(editor, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { throw RunFailure.blocked("cannot verify empty draft") }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location == 0,
              selection.length == 0 else { throw RunFailure.blocked("draft is not empty") }
        editorVerified = true
    }

    private func requireEditor() throws {
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        guard interrupted == 0, !IsSecureEventInputEnabled() else {
            throw RunFailure.blocked("interrupted or secure input")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw RunFailure.blocked("external host lost foreground")
        }
        guard sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == TraceRun.imeID else {
            throw RunFailure.blocked("Debug input source no longer selected in external host")
        }
        guard let win = Self.element(ax, kAXFocusedWindowAttribute), CFEqual(win, window) else {
            throw RunFailure.blocked("external host switched windows")
        }
        guard let edit = Self.element(ax, kAXFocusedUIElementAttribute), CFEqual(edit, editor) else {
            throw RunFailure.blocked("external host switched editors")
        }
    }

    private func contents() throws -> String {
        try requireEditor()
        guard let value = Self.attribute(editor, kAXValueAttribute) as? String else { throw RunFailure.blocked("editor value unavailable") }
        return value
    }

    private static func post(_ code: UInt16, flags: CGEventFlags, to pid: pid_t) throws {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw RunFailure.blocked("event target lost focus")
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw RunFailure.blocked("key event unavailable")
            }
            event.flags = flags
            event.postToPid(pid)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.10))
    }

    private func key(_ code: UInt16, _ flags: CGEventFlags = []) throws {
        try requireEditor()
        try Self.post(code, flags: flags, to: app.processIdentifier)
    }

    private func debugWindows() throws -> [Int: pid_t] {
        let executable = installed.appendingPathComponent("Contents/MacOS/SentenceAlongIME").standardizedFileURL
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: TraceRun.imeID)
            .filter { $0.executableURL?.standardizedFileURL == executable }.map(\.processIdentifier))
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw RunFailure.blocked("window evidence unavailable")
        }
        var windows: [Int: pid_t] = [:]
        for row in rows {
            if let pid = row[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
               let id = row[kCGWindowNumber as String] as? Int {
                windows[id] = pid
            }
        }
        return windows
    }

    func execute(manual: Bool) throws {
        defer {
            // A failed software route can leave the literal keystrokes in the draft.
            // Only remove our known sample, while the exact editor is still focused.
            if let sample = try? contents(), ["nihao", "nihao ", "你好", "hello", "hi"].contains(sample.lowercased()) {
                try? key(UInt16(kVK_ANSI_A), .maskCommand)
                if (try? contents()) == sample { try? key(UInt16(kVK_Delete)) }
            }
            if let document {
                app.terminate()
                try? FileManager.default.removeItem(at: document)
            }
        }
        let baseline = try debugWindows()
        if manual {
            print("输入 nihao，等候选窗出现后按空格。"); fflush(stdout)
        } else {
            for letter in PinyinCommit.letters { try key(letter) }
        }
        guard try Self.wait(manual ? 40 : 3, for: {
            try requireEditor()
            let windows = try debugWindows()
            observedIMEPID = windows.first(where: { baseline[$0.key] != $0.value })?.value
            return observedIMEPID != nil
        }) else { throw RunFailure.blocked("no candidate window from the installed Debug IME") }
        lastStep = "installed Debug candidate window"
        if !manual { try key(PinyinCommit.confirm) }
        guard try Self.wait(manual ? 20 : 3, for: { try contents() == "你好" }) else {
            throw RunFailure.failed("Chinese commit mismatch")
        }
        lastStep = "Chinese document verified"
        // External apps do not export the synthetic host's translation-ready probe.
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        try key(UInt16(kVK_ANSI_T), [.maskControl, .maskShift])
        guard try Self.wait(3, for: {
            let translation = try contents().lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            return ["hello", "hi"].contains(translation)
        }) else { throw RunFailure.failed("English range replacement mismatch") }
        lastStep = "English document verified"
        try key(UInt16(kVK_ANSI_Z), .maskCommand)
        guard try Self.wait(3, for: { try contents() == "你好" }) else { throw RunFailure.failed("host undo mismatch") }
        lastStep = "native undo restored Chinese"
    }
}
