import AppKit
import IMETrace
import Carbon

@MainActor
final class TestTextView: NSTextView {
    var trace: TraceWriter?
    var translated = false
    var allowCapture: Bool {
        NSApp.isActive && window?.firstResponder === self && !IsSecureEventInputEnabled()
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if allowCapture && hasMarkedText() { trace?.record(.marked) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if allowCapture {
            trace?.record(.inserted)
            let inserted = (string as? NSAttributedString)?.string ?? string as? String
            if trace?.run.scenario == "translation-undo", inserted == self.string, !hasMarkedText(),
               self.string.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
                translated = true
                trace?.record(.translatedDocument)
            }
        }
    }
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let documentUndoManager = UndoManager()
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { documentUndoManager }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let view = TestTextView()
    var timer: Timer?
    var hasFocused = false
    func applicationDidResignActive(_ notification: Notification) {
        if hasFocused { endObservation() }
    }
    func endObservation() {
        view.trace?.record(.lostFocus)
        view.trace = nil
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let run = try? TraceRun.current(), CommandLine.arguments.last == run.id.uuidString else {
            NSApp.terminate(nil)
            return
        }
        do {
            try JSONEncoder().encode(getpid()).write(to: run.directory.appendingPathComponent("host.pid"), options: .atomic)
        } catch { NSApp.terminate(nil); return }
        view.trace = TraceWriter(run: run, role: .host)
        view.trace?.record(.hostLaunched)
        view.allowsUndo = true
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu(title: "IMEHost")
        menu.addItem(appMenu)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let actions = NSMenu(title: "Edit")
        actions.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.submenu = actions
        menu.addItem(edit)
        NSApp.mainMenu = menu
        window.delegate = self
        window.contentView = view
        window.title = "随键译 · 合成输入验收"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        var checked = false
        var expectedEditedLetters: String?
        var editedInMiddle = false
        var restoredComposition = false
        var selectionRequested = false
        var sourceAcknowledged = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let view = self.view
                let window = self.window
                guard run.deadline > Date() else { NSApp.terminate(nil); return }
                if IsSecureEventInputEnabled() { self.endObservation(); return }
                guard NSApp.isActive, window.firstResponder === view else { return }
                if !self.hasFocused {
                    self.hasFocused = true
                    view.trace?.record(.focused)
                }
                if !sourceAcknowledged, let context = view.inputContext,
                   FileManager.default.fileExists(atPath: run.directory.appendingPathComponent("select").path) {
                    if !selectionRequested {
                        selectionRequested = true
                        context.selectedKeyboardInputSource = TraceRun.imeID
                    } else if context.selectedKeyboardInputSource == TraceRun.imeID {
                        sourceAcknowledged = true
                        view.trace?.record(.hostSelectedSource)
                    }
                }
                if ["panel-mark-ended", "panel-editor-cleared"].contains(run.scenario), view.hasMarkedText(),
                   FileManager.default.fileExists(atPath: run.directory.appendingPathComponent("end-mark").path) {
                    if run.scenario == "panel-mark-ended" { view.inputContext?.discardMarkedText() }
                    view.unmarkText()
                    if run.scenario == "panel-editor-cleared" { view.string = "" }
                    if !view.hasMarkedText() { view.trace?.record(.markEnded) }
                }
                if view.translated && view.string == "你好" && !view.hasMarkedText() {
                    view.translated = false
                    view.trace?.record(.undoRestored)
                }
                if checked, run.scenario == "composition-caret", view.hasMarkedText() {
                    let letters = view.string.filter { $0.isLetter }
                    if !editedInMiddle && letters == expectedEditedLetters {
                        editedInMiddle = true
                        view.trace?.record(.middleInsertion)
                    } else if editedInMiddle && !restoredComposition && letters == "nihaonihao" {
                        restoredComposition = true
                        view.trace?.record(.middleDeletion)
                    }
                }
                if !checked, FileManager.default.fileExists(atPath: run.directory.appendingPathComponent("check").path) {
                    checked = true
                    let ok: Bool
                    switch run.scenario {
                    case "composition-caret":
                        let marked = view.markedRange()
                        let caret = view.selectedRange()
                        ok = view.hasMarkedText() && caret.length == 0 && caret.location > marked.location
                            && caret.location < NSMaxRange(marked)
                            && view.string.filter { $0.isLetter } == "nihaonihao"
                        if ok {
                            let document = view.string as NSString
                            expectedEditedLetters = document.replacingCharacters(in: caret, with: "g").filter { $0.isLetter }
                        }
                    case "punctuation-preview":
                        ok = !view.hasMarkedText() && view.string == "。"
                    default:
                        ok = !view.hasMarkedText() && view.string == "你好"
                    }
                    view.trace?.record(ok ? .documentMatched : .documentMismatch)
                }
            }
        }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = HostDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
