import AppKit
import Carbon
import IMETrace
import InputCore

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
    static let debugSettings = InputSettingsStore(directory: TraceRun.root.deletingLastPathComponent(),
                                                 domain: TraceRun.imeID + ".preferences")

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

    static func tapShift(to pid: pid_t, key: UInt16 = UInt16(kVK_Shift), verifyTarget: () throws -> Void) throws {
        for down in [true, false] {
            try verifyTarget()
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else {
                throw RunFailure.blocked("modifier event unavailable")
            }
            event.type = .flagsChanged
            event.flags = down ? .maskShift : []
            event.postToPid(pid)
        }
    }

    func typeLetters(_ keys: [UInt16]) throws {
        let initialCount = try evidence().count(.key, from: .ime)
        for (index, key) in keys.enumerated() {
            try send(key)
            try wait("key \(index + 1) reached IMK", failure: .blocked("key delivery stopped at \(index)")) {
                $0.count(.key, from: .ime) >= initialCount + index + 1
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
        case "direction-switch", "direction-selection":
            try commitNihao()
            try typeLetters(PinyinCommit.letters)
            try wait("second composition present", failure: .failed("pre-switch mark missing")) {
                $0.count(.switchPending, from: .host) == 1
            }
            try Self.debugSettings.update { $0.translationDirection = .englishToChinese }
            try wait("active Debug session applied direction", failure: .blocked("direction change not observed")) {
                $0.count(.directionApplied, from: .ime) == 1
            }
            if run.scenario == "direction-selection" {
                try checkDocument()
                return
            }
            try wait("direction switch cancelled only the mark", failure: .failed("mark or committed prefix changed")) {
                $0.count(.markEnded, from: .host) == 1
            }
            let keysBeforeEnglish = try evidence().count(.key, from: .ime)
            try send(UInt16(kVK_ANSI_A), flags: .maskShift)
            try wait("capital letter reached IMK", failure: .blocked("English key delivery stopped")) {
                $0.count(.key, from: .ime) == keysBeforeEnglish + 1
            }
            try typeLetters([UInt16(kVK_Space), UInt16(kVK_ANSI_2)])
            try wait("English characters inserted", failure: .failed("English input was not committed")) {
                $0.count(.inserted, from: .host) == 4
            }
            try checkDocument()
        case "candidate-tenth":
            try typeLetters([UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_I)])
            try send(UInt16(kVK_ANSI_0))
            try wait("tenth candidate committed", failure: .failed("tenth selection missing")) {
                $0.count(.inserted, from: .host) == 1
            }
            try checkDocument()
        case "shift-toggle", "shift-toggle-live", "shift-toggle-idle":
            if run.scenario != "shift-toggle-idle" {
                try typeLetters([UInt16(kVK_ANSI_N)])
                try wait("initial pinyin mark", failure: .failed("missing initial composition")) { $0.count(.marked, from: .host) > 0 }
            }
            if run.scenario == "shift-toggle-live" {
                try Self.debugSettings.update { $0.shiftTogglesEnglish = true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            guard AXIsProcessTrusted() else { throw RunFailure.blocked("mode feedback requires accessibility permission") }
            let ime = NSRunningApplication.runningApplications(withBundleIdentifier: TraceRun.imeID)
            guard ime.count == 1, let pid = ime.first?.processIdentifier else { throw RunFailure.blocked("installed Debug unavailable") }
            try Self.tapShift(to: host.processIdentifier, verifyTarget: requireFocusedHost)
            try wait("English mode indicator", timeout: 2, failure: .failed("English mode feedback missing")) { _ in
                ExternalHost.panelValue(pid: pid)?.contains("临时英文") == true
            }
            try typeLetters([UInt16(kVK_ANSI_X)])
            try wait("temporary English committed", failure: .failed("Shift did not enable direct input")) {
                $0.count(.inserted, from: .host) > 0
            }
            try Self.tapShift(to: host.processIdentifier, key: UInt16(kVK_RightShift), verifyTarget: requireFocusedHost)
            try wait("Chinese mode indicator", timeout: 2, failure: .failed("Chinese mode feedback missing")) { _ in
                ExternalHost.panelValue(pid: pid)?.contains("中文拼音") == true
            }
            try typeLetters(PinyinCommit.letters)
            try send(PinyinCommit.confirm)
            try checkDocument()
        case "raw-return":
            try composeNihao()
            try send(UInt16(kVK_Return))
            try wait("Return committed once", failure: .failed("raw commit missing")) {
                $0.count(.inserted, from: .host) == 1
            }
            try checkDocument()
        case "composition-caret": try compositionEditing()
        case "punctuation-preview": try punctuationPreview()
        case "ascii-comma-context", "mixed-period-replace": try mixedPunctuation()
        case "panel-host-exit", "panel-mark-ended", "panel-editor-cleared", "panel-app-switch": try panelLifecycle()
        case "candidate-click", "candidate-tenth-click": try candidateSelection()
        case "translation-undo", "english-undo": try translationReplacement()
        default: try pinyinCommit()
        }
    }
}


@MainActor
private func launchHost(tools: URL, run: TraceRun) throws -> NSRunningApplication {
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
    return host
}

@MainActor
func execute() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2 || args.count == 3, args[0] == "--case", ["pinyin-commit", "candidate-tenth", "candidate-tenth-click", "direction-switch", "direction-selection", "english-undo", "shift-toggle", "shift-toggle-live", "shift-toggle-idle", "raw-return", "composition-caret", "punctuation-preview", "ascii-comma-context", "mixed-period-replace", "translation-undo", "candidate-click", "panel-host-exit", "panel-mark-ended", "panel-editor-cleared", "panel-app-switch"].contains(args[1]) || ExternalHost.cases.contains(args[1]),
          args.count == 2 || args[2] == "--manual" else {
        throw RunFailure.blocked("usage: IMERunner --case pinyin-commit [--manual]")
    }
    let manual = args.contains("--manual")
    let external = ExternalHost.cases.contains(args[1])
    guard !manual || (external && args[1] != "codex-shift") || args[1] == "pinyin-commit" || args[1] == "candidate-click" else {
        throw RunFailure.blocked("manual input is supported for pinyin-commit, candidate-click and external hosts")
    }
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          session["CGSSessionScreenIsLocked"] as? Bool != true else {
        throw RunFailure.blocked("unlock the macOS desktop before running host tests")
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
    let started = DispatchTime.now().uptimeNanoseconds
    let run = TraceRun(build: build, scenario: args[1])
    let fm = FileManager.default
    try fm.createDirectory(at: run.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lock = open(TraceRun.root.appendingPathComponent("runner.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw RunFailure.blocked("cannot open run lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RunFailure.blocked("another run is active") }
    // Only these explicit scenarios modify a Debug preference; preserve unrelated user settings.
    let store = RunDriver.debugSettings
    let previous = store.read()
    if ["direction-switch", "direction-selection"].contains(run.scenario), previous.translationDirection != .chineseToEnglish {
        throw RunFailure.blocked("start the direction-switch test in Chinese to English mode")
    }
    if ["shift-toggle", "shift-toggle-live", "shift-toggle-idle", "codex-shift"].contains(run.scenario) {
        try store.update {
            $0.shiftTogglesEnglish = run.scenario != "shift-toggle-live"
            $0.translationDirection = .chineseToEnglish
        }
    }
    let punctuationCase = ["ascii-comma-context", "mixed-period-replace"].contains(run.scenario)
    if punctuationCase {
        try store.update {
            $0.translationDirection = .chineseToEnglish
            $0.usesASCIIPunctuation = true
            $0.shiftTogglesEnglish = true
        }
    }
    if run.scenario == "english-undo" {
        try store.update { $0.translationDirection = .englishToChinese }
    }
    if ["candidate-tenth", "candidate-tenth-click"].contains(run.scenario) {
        try store.update { $0.candidatePageSize = 10 }
    }
    defer {
        do {
            if punctuationCase {
                try store.update {
                    if $0.translationDirection == .chineseToEnglish { $0.translationDirection = previous.translationDirection }
                    if $0.usesASCIIPunctuation { $0.usesASCIIPunctuation = previous.usesASCIIPunctuation }
                    if $0.shiftTogglesEnglish { $0.shiftTogglesEnglish = previous.shiftTogglesEnglish }
                }
            } else if ["candidate-tenth", "candidate-tenth-click"].contains(run.scenario) {
                try store.update { if $0.candidatePageSize == 10 { $0.candidatePageSize = previous.candidatePageSize } }
            } else if ["shift-toggle", "shift-toggle-live", "shift-toggle-idle", "codex-shift"].contains(run.scenario) {
                try store.update {
                    $0.shiftTogglesEnglish = previous.shiftTogglesEnglish
                    $0.translationDirection = previous.translationDirection
                }
            } else if ["direction-switch", "direction-selection", "english-undo"].contains(run.scenario) {
                try store.update { $0.translationDirection = previous.translationDirection }
            }
        } catch { fputs("Unable to restore the Debug input preference.\n", stderr) }
    }
    if !external { try JSONEncoder().encode(run).write(to: TraceRun.active, options: .atomic) }
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
    print("run=\(run.id) build=\(build) driver=\(manual ? "manual" : "CGEvent") evidence=\(run.directory.path)")
    var driver: RunDriver?
    var externalHost: ExternalHost?
    var host: NSRunningApplication?
    defer { host?.terminate() }
    func report(_ status: String, reason: String = "") throws {
        var summary = ["status": status, "reason": reason, "lastStep": driver?.lastStep ?? externalHost?.lastStep ?? "host launch requested",
                       "inputSourceID": TraceRun.imeID, "installedBundle": installed.path,
                       "case": run.scenario, "build": run.build, "run": run.id.uuidString,
                       "driver": manual ? "manual" : "CGEvent"]
        summary["elapsedMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        if let pid = externalHost?.observedIMEPID {
            summary["observedIMEPID"] = String(pid)
        }
        try JSONEncoder().encode(summary).write(to: run.directory.appendingPathComponent("summary.report"), options: .atomic)
    }
    do {
        if external {
            let test = try ExternalHost(run: run, installed: installed, manual: manual)
            externalHost = test
            try test.execute(manual: manual)
        } else {
            let app = try launchHost(tools: tools, run: run)
            host = app
            let test = RunDriver(run: run, host: app, manual: manual)
            driver = test
            try test.execute()
        }
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
