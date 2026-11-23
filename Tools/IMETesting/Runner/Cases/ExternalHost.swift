import AppKit
import Carbon
import IMETrace
import InputCore

/// Only operates on a newly opened test document or an empty, unsent draft.
@MainActor
final class ExternalHost {
    static let cases = ["textedit-undo", "codex-draft", "codex-shift"]

    private let scenario: String
    private let app: NSRunningApplication
    private let document: URL?
    private let window: AXUIElement
    private let editor: AXUIElement
    private let settings = InputSettingsStore(directory: TraceRun.root.deletingLastPathComponent(),
                                              domain: TraceRun.imeID + ".preferences")
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

    /// Electron can reuse the same editor accessibility object for a new chat.
    /// Request a distinct window when the host exposes its File > New Window action.
    private static func openCodexWindow(_ app: AXUIElement) -> Bool {
        guard let bar = element(app, kAXMenuBarAttribute),
              let menus = attribute(bar, kAXChildrenAttribute) as? [AXUIElement] else { return false }
        for file in menus where ["File", "文件"].contains(attribute(file, kAXTitleAttribute) as? String ?? "") {
            for menu in attribute(file, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                for item in attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    if ["New Window", "新窗口"].contains(attribute(item, kAXTitleAttribute) as? String ?? "") {
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                }
            }
        }
        return false
    }

    init(run: TraceRun, installed: URL, manual: Bool) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw RunFailure.blocked("external checks require accessibility and event posting access")
        }
        scenario = run.scenario
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
        let ax = AXUIElementCreateApplication(pid)
        var originalWindows: [AXUIElement] = []
        let originalWindow = Self.element(ax, kAXFocusedWindowAttribute)
        let originalEditor = Self.element(ax, kAXFocusedUIElementAttribute)
        let hadTextArea = originalEditor.flatMap { Self.attribute($0, kAXRoleAttribute) as? String } == "AXTextArea"
        if document == nil {
            guard let windows = Self.attribute(ax, kAXWindowsAttribute) as? [AXUIElement] else {
                throw RunFailure.blocked("cannot identify existing Codex windows")
            }
            originalWindows = windows
            if !Self.openCodexWindow(ax) {
                try Self.post(UInt16(kVK_ANSI_N), flags: .maskCommand, to: pid)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
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
            if expectedFile == nil {
                guard let editorWindow = Self.element(edit, kAXWindowAttribute), CFEqual(editorWindow, win) else {
                    return false
                }
                let sameWindow = originalWindow.map { CFEqual($0, win) } == true
                let newWindow = !sameWindow && !originalWindows.contains { CFEqual($0, win) }
                var oldRole: CFTypeRef?
                let replaced = hadTextArea && originalEditor.map {
                    !CFEqual($0, edit) && AXUIElementCopyAttributeValue($0, kAXRoleAttribute as CFString, &oldRole) == .invalidUIElement
                } == true
                guard ExternalDraft.isNewTarget(newWindow: newWindow, sameWindow: sameWindow, replacedEditor: replaced)
                else { return false }
            }
            target = (win, edit)
            return true
        }), let target else { throw RunFailure.blocked("dedicated editor did not acquire focus") }
        (window, editor) = target
        try requireEditor(requireSource: false)
        // macOS may restore a different source as the new editor gains focus.
        if sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) != TraceRun.imeID {
            let filter = [kTISPropertyInputSourceID as String: TraceRun.imeID] as CFDictionary
            let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
            guard let source = sources.first, TISSelectInputSource(source) == noErr,
                  try Self.wait(2, for: {
                      try requireEditor(requireSource: false)
                      return sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == TraceRun.imeID
                  }) else { throw RunFailure.blocked("could not select Debug in dedicated editor") }
        }
        try requireEmptyEditor()
        editorVerified = true
    }

    private func requireEditor() throws { try requireEditor(requireSource: true) }

    private func requireEditor(requireSource: Bool) throws {
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        guard interrupted == 0, !IsSecureEventInputEnabled() else {
            throw RunFailure.blocked("interrupted or secure input")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw RunFailure.blocked("external host lost foreground")
        }
        guard !requireSource || sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == TraceRun.imeID else {
            throw RunFailure.blocked("Debug input source no longer selected in external host")
        }
        guard let win = Self.element(ax, kAXFocusedWindowAttribute), CFEqual(win, window) else {
            throw RunFailure.blocked("external host switched windows")
        }
        guard let edit = Self.element(ax, kAXFocusedUIElementAttribute), CFEqual(edit, editor) else {
            throw RunFailure.blocked("external host switched editors")
        }
    }

    private func requireEmptyEditor() throws {
        try requireEditor()
        // AXValue may be a placeholder. Read only the independent length and caret.
        let count = Self.attribute(editor, kAXNumberOfCharactersAttribute) as? Int
        guard let value = Self.attribute(editor, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { throw RunFailure.blocked("cannot verify empty draft") }
        var selection = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection),
              ExternalDraft.isEmpty(characterCount: count, selection: NSRange(location: selection.location, length: selection.length))
        else { throw RunFailure.blocked("draft is nonempty or editable character count unavailable") }
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

    static func panelValue(pid: pid_t) -> String? {
        let ime = AXUIElementCreateApplication(pid)
        guard var elements = Self.attribute(ime, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        while let element = elements.popLast() {
            if Self.attribute(element, kAXDescriptionAttribute) as? String == "随键译输入、纠错与翻译预览",
               let value = Self.attribute(element, kAXValueAttribute) as? String { return value }
            if let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                elements.append(contentsOf: children)
            }
        }
        return nil
    }

    func execute(manual: Bool) throws {
        var expectedCleanup: Set<String> = []
        defer {
            // A failed software route can leave the literal keystrokes in the draft.
            // Only remove our known sample, while the exact editor is still focused.
            if let sample = try? contents(), expectedCleanup.contains(sample) {
                try? key(UInt16(kVK_ANSI_A), .maskCommand)
                if (try? contents()) == sample { try? key(UInt16(kVK_Delete)) }
            }
            if let document {
                app.terminate()
                try? FileManager.default.removeItem(at: document)
            }
        }
        if scenario == "codex-shift" {
            try requireEmptyEditor()
            expectedCleanup = ["x", "xnihao", "xnihao ", "x你好"]
            let pid = app.processIdentifier
            try RunDriver.tapShift(to: pid, verifyTarget: requireEditor)
            guard try Self.wait(2, for: {
                try requireEditor()
                observedIMEPID = try debugWindows().values.first {
                    Self.panelValue(pid: $0)?.contains("临时英文") == true
                }
                return observedIMEPID != nil
            }) else { throw RunFailure.failed("Debug did not show English mode in dedicated draft") }
            lastStep = "installed Debug English mode indicator"
            try key(UInt16(kVK_ANSI_X))
            guard try Self.wait(2, for: { try contents() == "x" }) else {
                throw RunFailure.failed("direct English input mismatch")
            }
            lastStep = "first letter visible"
            try RunDriver.tapShift(to: pid, verifyTarget: requireEditor)
            for letter in PinyinCommit.letters { try key(letter) }
            guard try Self.wait(3, for: {
                try requireEditor()
                guard let observedIMEPID, try debugWindows().values.contains(observedIMEPID) else { return false }
                return Self.panelValue(pid: observedIMEPID)?.contains("候选") == true
            }) else { throw RunFailure.blocked("no candidate window from installed Debug after second Shift") }
            try key(PinyinCommit.confirm)
            guard try Self.wait(3, for: { try contents() == "x你好" }) else { throw RunFailure.failed("mixed English and Chinese commit mismatch") }
            lastStep = "direct letter and subsequent Chinese verified"
            return
        }
        guard settings.read().translationEnabled else { throw RunFailure.blocked("translation disabled in Debug settings") }
        try requireEmptyEditor()
        // Seed unrelated text through the host, so it is outside the IME sentence.
        guard AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString,
                                           ExternalDraft.prefix as CFString) == .success else {
            throw RunFailure.blocked("could not seed synthetic document prefix")
        }
        expectedCleanup.insert(ExternalDraft.prefix)
        guard try Self.wait(2, for: { try contents() == ExternalDraft.prefix }) else {
            throw RunFailure.blocked("synthetic document prefix not verified")
        }
        expectedCleanup.formUnion([ExternalDraft.chinese, ExternalDraft.prefix + "nihao", ExternalDraft.prefix + "nihao "])
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
        guard try Self.wait(manual ? 20 : 3, for: { try contents() == ExternalDraft.chinese }) else {
            throw RunFailure.failed("Chinese commit mismatch")
        }
        lastStep = "Chinese document verified"
        var preview: String?
        guard let pid = observedIMEPID, try Self.wait(20, for: {
            try requireEditor()
            guard try contents() == ExternalDraft.chinese else { throw RunFailure.blocked("sample changed before replacement") }
            guard try debugWindows().values.contains(pid) else { return false }
            preview = Self.panelValue(pid: pid).flatMap(ExternalDraft.previewTranslation)
            return preview != nil
        }), let preview else { throw RunFailure.blocked("expected English preview not observed before timeout") }
        lastStep = "English preview verified"
        let currentSettings = settings.read()
        guard currentSettings.translationEnabled else { throw RunFailure.blocked("translation disabled in Debug settings") }
        expectedCleanup.insert(ExternalDraft.prefix + preview)
        try key(currentSettings.replacementKeyCode, [.maskControl, .maskShift])
        guard try Self.wait(3, for: { ExternalDraft.matchesReplacement(try contents(), preview: preview) })
        else { throw RunFailure.failed("English range replacement mismatch") }
        lastStep = "English document verified"
        try key(UInt16(kVK_ANSI_Z), .maskCommand)
        guard try Self.wait(3, for: { try contents() == ExternalDraft.chinese }) else { throw RunFailure.failed("host undo mismatch") }
        lastStep = "native undo restored Chinese"
    }
}
