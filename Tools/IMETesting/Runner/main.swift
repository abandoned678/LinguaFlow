import AppKit
import Carbon
import IMETrace

enum RunFailure: Error {
    case blocked(String), failed(String)
}

func sourceID(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

var interrupted: sig_atomic_t = 0

@MainActor
final class RunDriver {
    let run: TraceRun
    let host: NSRunningApplication
    let manual: Bool
    private(set) var lastStep = "host launch requested"
    init(run: TraceRun, host: NSRunningApplication, manual: Bool) {
        self.run = run
        self.host = host
        self.manual = manual
    }

    func evidence() throws -> TraceEvidence {
        try TraceEvidence(directory: run.directory, run: run.id)
    }

    func wait(_ label: String, timeout: TimeInterval = 5, failure: RunFailure,
              until condition: (TraceEvidence) -> Bool) throws {
        let end = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < end {
            guard interrupted == 0, !host.isTerminated else { throw RunFailure.blocked("interrupted or host closed") }
            let observed = try evidence()
            guard observed.count(.lostFocus, from: .host) == 0 else {
                throw RunFailure.blocked("test host lost focus or entered secure input")
            }
            if condition(observed) {
                lastStep = label
                print("ok: " + label)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw failure
    }

    func requireFocusedHost() throws {
        guard interrupted == 0, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == host.processIdentifier,
              sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == TraceRun.imeID else {
            throw RunFailure.blocked("focus, input source or secure input changed")
        }
    }

    func send(_ code: UInt16, flags: CGEventFlags = []) throws {
        try requireFocusedHost()
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw RunFailure.blocked("keyboard event unavailable")
            }
            event.flags = flags
            event.postToPid(host.processIdentifier)
        }
    }

    func typeLetters(_ keys: [UInt16]) throws {
        for (index, key) in keys.enumerated() {
            try send(key)
            try wait("key \(index + 1) reached IMK", failure: .blocked("key delivery stopped at \(index)")) {
                $0.count(.key, from: .ime) >= index + 1
            }
        }
    }

    func checkDocument() throws {
        try Data().write(to: run.directory.appendingPathComponent("check"), options: .atomic)
        try wait("host document checkpoint", failure: .blocked("host checkpoint unavailable")) {
            $0.count(.documentMatched, from: .host) + $0.count(.documentMismatch, from: .host) > 0
        }
        guard try evidence().count(.documentMatched, from: .host) == 1 else {
            throw RunFailure.failed("host document or selection did not match")
        }
    }

    func execute() throws {
        try wait("host launched", failure: .blocked("no host launch evidence")) { $0.count(.hostLaunched, from: .host) == 1 }
        host.activate(options: [.activateAllWindows])
        try wait("host focused", failure: .blocked("test text view did not acquire focus")) {
            $0.count(.focused, from: .host) > 0
        }
        try wait("Debug input source selected", failure: .blocked("Debug source selection did not persist")) { _ in
            sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == TraceRun.imeID
        }
        try Data().write(to: run.directory.appendingPathComponent("select"), options: .atomic)
        try wait("text view selected Debug source", failure: .blocked("host input context did not select Debug source")) {
            $0.count(.hostSelectedSource, from: .host) == 1
        }
        if !manual && !CGPreflightPostEventAccess() {
            throw RunFailure.blocked("missing permission to post keyboard events")
        }
        switch run.scenario {
        case "composition-caret": try compositionEditing()
        case "punctuation-preview": try punctuationPreview()
        case "panel-host-exit", "panel-mark-ended", "panel-editor-cleared", "panel-app-switch": try panelLifecycle()
        case "candidate-click": try candidateSelection()
        case "translation-undo": try translationReplacement()
        default: try pinyinCommit()
        }
    }
}


@MainActor
func execute() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2 || args.count == 3, args[0] == "--case", ["pinyin-commit", "composition-caret", "punctuation-preview", "translation-undo", "candidate-click", "panel-host-exit", "panel-mark-ended", "panel-editor-cleared", "panel-app-switch"].contains(args[1]),
          args.count == 2 || args[2] == "--manual" else {
        throw RunFailure.blocked("usage: IMERunner --case pinyin-commit [--manual]")
    }
    let manual = args.contains("--manual")
    guard !manual || args[1] == "pinyin-commit" || args[1] == "candidate-click" else {
        throw RunFailure.blocked("manual input is supported for pinyin-commit and candidate-click")
    }
    let tools = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    let ime = Bundle(url: tools.appendingPathComponent("SentenceAlongDebug.app"))
    guard let build = ime?.object(forInfoDictionaryKey: "IMETestBuild") as? String else {
        throw RunFailure.blocked("missing Debug build metadata")
    }
    let installed = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods/SentenceAlongDebug.app")
    guard let installedBundle = Bundle(url: installed), installedBundle.bundleIdentifier == TraceRun.imeID,
          installedBundle.object(forInfoDictionaryKey: "IMETestBuild") as? String == build else {
        throw RunFailure.blocked("installed Debug IME missing or stale; install matching build")
    }
    let run = TraceRun(build: build, scenario: args[1])
    let fm = FileManager.default
    try fm.createDirectory(at: run.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lock = open(TraceRun.root.appendingPathComponent("runner.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw RunFailure.blocked("cannot open run lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RunFailure.blocked("another run is active") }
    try JSONEncoder().encode(run).write(to: TraceRun.active, options: .atomic)
    defer { try? fm.removeItem(at: TraceRun.active) }
    let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    func restoreOriginalSource() throws {
        guard TISSelectInputSource(original) == noErr,
              sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == sourceID(original) else {
            throw RunFailure.blocked("could not restore original input source")
        }
    }
    // Covers early exits before the host is ready for a report.
    var restored = false
    defer { if !restored { TISSelectInputSource(original) } }
    // Establish the source before AppKit creates the test view's first text input session.
    let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
    var selected = false
    for case let source as TISInputSource in sources where sourceID(source) == TraceRun.imeID {
        selected = TISSelectInputSource(source) == noErr
        break
    }
    guard selected else { throw RunFailure.blocked("Debug input source unavailable") }
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = [run.id.uuidString]
    config.createsNewApplicationInstance = true
    config.activates = true
    var result: Result<NSRunningApplication, Error>?
    NSWorkspace.shared.openApplication(at: tools.appendingPathComponent("IMEHost.app"), configuration: config) { app, error in
        DispatchQueue.main.async {
            if let app { result = .success(app) }
            else { result = .failure(error ?? RunFailure.blocked("host launch failed")) }
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while result == nil, Date() < deadline, interrupted == 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    }
    guard let result else { throw RunFailure.blocked("host launch timed out") }
    let host = try result.get()
    defer { host.terminate() }
    print("run=\(run.id) build=\(build) driver=\(manual ? "manual" : "CGEvent") evidence=\(run.directory.path)")
    let driver = RunDriver(run: run, host: host, manual: manual)
    func report(_ status: String, reason: String = "") throws {
        let summary = ["status": status, "reason": reason, "lastStep": driver.lastStep,
                       "case": run.scenario, "build": run.build, "run": run.id.uuidString,
                       "driver": manual ? "manual" : "CGEvent"]
        try JSONEncoder().encode(summary).write(to: run.directory.appendingPathComponent("summary.report"), options: .atomic)
    }
    do {
        try driver.execute()
        try restoreOriginalSource()
        restored = true
        try report("passed")
    } catch {
        do {
            try restoreOriginalSource()
            restored = true
        } catch let cleanup {
            try report("blocked", reason: String(describing: cleanup))
            throw cleanup
        }
        if case RunFailure.failed(let reason) = error {
            try report("failed", reason: reason)
        } else {
            try report("blocked", reason: String(describing: error))
        }
        throw error
    }
}

signal(SIGINT) { _ in interrupted = 1 }
signal(SIGTERM) { _ in interrupted = 1 }
MainActor.assumeIsolated {
    do { try execute(); print("PASS"); exit(0) }
    catch RunFailure.failed(let why) { print("FAIL: " + why); exit(1) }
    catch { print("BLOCKED: \(error)"); exit(2) }
}
