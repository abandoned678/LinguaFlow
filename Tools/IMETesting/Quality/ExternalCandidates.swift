import AppKit
import Carbon

// Samples the system and Sogou Pinyin in a dedicated NSTextView. All candidate
// comparisons happen in memory. Escape cancels every sample without selection.
private enum MeasurementError: String, Error {
    case corpus, hostFocus, sourceChanged, sourceUnavailable, eventPermission, missingCandidates
    case incompleteComposition, unexpectedCommit, restoreSource, interrupted
}

private var interrupted: sig_atomic_t = 0

private func sourceID(_ source: TISInputSource) -> String? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

private func currentSourceID() -> String? {
    sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
}

private func attribute(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, key as CFString, &result) == .success else { return nil }
    return result
}

private func pumpEvents(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005),
                                       inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
}

private struct Source {
    let id: String
    let ownerID: String?
    let role: String
    let value: String

    static let all = [
        Source(id: "com.apple.inputmethod.SCIM.ITABC", ownerID: nil, role: kAXButtonRole, value: kAXTitleAttribute),
        Source(id: "com.sogou.inputmethod.sogou.pinyin", ownerID: "com.sogou.inputmethod.sogou",
               role: kAXStaticTextRole, value: kAXValueAttribute)
    ]
}

private final class Observer: NSObject, NSApplicationDelegate {
    private let view = NSTextView()
    private let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 650, height: 140),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let initialSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    private let initialApp = NSWorkspace.shared.frontmostApplication
    private let keys = Dictionary(uniqueKeysWithValues: zip("abcdefghijklmnopqrstuvwxyz",
        [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6].map(UInt16.init)))
    private(set) var exitCode: Int32 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "随键译 · 合成拼音候选对照"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.run() }
    }

    private func checkFocus() throws {
        guard interrupted == 0 else { throw MeasurementError.interrupted }
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              window.firstResponder === view else { throw MeasurementError.hostFocus }
    }

    private func send(_ key: UInt16, source: Source) throws {
        try checkFocus()
        guard currentSourceID() == source.id, view.inputContext?.selectedKeyboardInputSource == source.id
        else { throw MeasurementError.sourceChanged }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            else { throw MeasurementError.eventPermission }
            event.flags = []
            event.postToPid(getpid())
        }
        pumpEvents(for: 0.025)
    }

    // Apple's candidate list belongs to the host. Sogou presents its own AX window.
    private func candidates(_ source: Source) -> [String]? {
        let pid: pid_t
        if let owner = source.ownerID {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first else { return nil }
            pid = app.processIdentifier
        } else { pid = getpid() }
        let app = AXUIElementCreateApplication(pid)
        for panel in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if pid == getpid(), attribute(panel, kAXTitleAttribute) as? String == window.title { continue }
            for list in attribute(panel, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard attribute(list, kAXRoleAttribute) as? String == kAXListRole,
                      let children = attribute(list, kAXChildrenAttribute) as? [AXUIElement],
                      !children.isEmpty else { continue }
                var result = [String]()
                for row in children.prefix(5) {
                    guard attribute(row, kAXRoleAttribute) as? String == source.role,
                          let candidate = attribute(row, source.value) as? String, !candidate.isEmpty else { return nil }
                    result.append(candidate)
                }
                return result
            }
        }
        return nil
    }

    private func sample(_ input: String, target: String, source: Source) throws -> Int {
        guard view.string.isEmpty, !view.hasMarkedText() else { throw MeasurementError.unexpectedCommit }
        for letter in input {
            guard let key = keys[letter] else { throw MeasurementError.corpus }
            try send(key, source: source)
        }
        pumpEvents(for: 0.12)
        try checkFocus()
        guard view.hasMarkedText() else { throw MeasurementError.incompleteComposition }
        let deadline = Date().addingTimeInterval(1.5)
        var ranked = candidates(source)
        while ranked == nil, Date() < deadline {
            pumpEvents(for: 0.05)
            try checkFocus()
            ranked = candidates(source)
        }
        guard let ranked else { throw MeasurementError.missingCandidates }
        let rank = ranked.firstIndex(of: target).map { $0 + 1 } ?? 0
        try send(UInt16(kVK_Escape), source: source)
        pumpEvents(for: 0.09)
        guard !view.hasMarkedText(), view.string.isEmpty else { throw MeasurementError.unexpectedCommit }
        return rank
    }

    private func run() {
        defer {
            if TISSelectInputSource(initialSource) != noErr || currentSourceID() != sourceID(initialSource) {
                print("BLOCKED: restoreSource")
                exitCode = 2
            }
            if let initialApp, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                initialApp.activate(options: [])
            }
            NSApp.stop(nil)
        }
        do {
            guard CommandLine.arguments.count == 2 else { throw MeasurementError.corpus }
            let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let corpus = text.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            guard !corpus.isEmpty, corpus.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty })
            else { throw MeasurementError.corpus }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw MeasurementError.eventPermission }
            let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
            for profile in Source.all {
                try checkFocus()
                guard let source = sources.compactMap({ $0 as! TISInputSource? }).first(where: { sourceID($0) == profile.id }),
                      TISSelectInputSource(source) == noErr else {
                    print("source=\(profile.id) BLOCKED: sourceUnavailable")
                    exitCode = 2
                    continue
                }
                view.inputContext?.selectedKeyboardInputSource = profile.id
                pumpEvents(for: 0.45)
                var first = 0
                var topFive = 0
                var complete = 0
                for (index, row) in corpus.enumerated() {
                    do {
                        let rank = try sample(row[0], target: row[1], source: profile)
                        print("source=\(profile.id) sample=\(index + 1) rankInTopFive=\(rank)")
                        complete += 1
                        if rank == 1 { first += 1 }
                        if rank > 0 { topFive += 1 }
                    } catch let issue as MeasurementError
                        where issue == .missingCandidates || issue == .incompleteComposition || issue == .unexpectedCommit {
                        print("source=\(profile.id) sample=\(index + 1) BLOCKED: \(issue.rawValue)")
                        exitCode = 2
                        try send(UInt16(kVK_Escape), source: profile)
                        view.inputContext?.discardMarkedText()
                        view.string = ""
                        pumpEvents(for: 0.1)
                    }
                }
                print("source=\(profile.id) complete=\(complete) total=\(corpus.count) first=\(first) topFive=\(topFive)")
            }
        } catch {
            exitCode = 2
            print("BLOCKED:", (error as? MeasurementError)?.rawValue ?? "unavailable")
        }
    }
}

signal(SIGINT) { _ in interrupted = 1 }
signal(SIGTERM) { _ in interrupted = 1 }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
private let observer = Observer()
app.delegate = observer
app.run()
exit(observer.exitCode)
