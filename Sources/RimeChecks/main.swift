import Foundation
import RimeInput

@main
@MainActor
struct RimeChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--profiles" {
            try PinyinProfiles.run(shared: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--quality" {
            let paths = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
            try PinyinQuality.run(shared: paths[0], user: paths[1], corpus: paths[2])
            return
        }
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: rime-checks <shared-data-dir> <user-data-dir>\n", stderr)
            exit(2)
        }

        let sharedDataDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let requiredOpenCCResources = [
            "t2s.json",
            "t2hk.json",
            "t2tw.json",
            "CJK_Compatibility_Ideographs.ocd2",
            "TSPhrases.ocd2",
            "TSCharactersExt.ocd2",
            "TSCharacters.ocd2",
            "HKVariantsPhrases.ocd2",
            "HKVariants.ocd2",
            "TWVariantsPhrases.ocd2",
            "TWVariants.ocd2",
        ]
        for resource in requiredOpenCCResources {
            let resourceURL = sharedDataDirectory
                .appendingPathComponent("opencc", isDirectory: true)
                .appendingPathComponent(resource)
            guard FileManager.default.isReadableFile(atPath: resourceURL.path) else {
                fputs("Bundled OpenCC resource is missing: \(resourceURL.path)\n", stderr)
                exit(1)
            }
        }

        let runtime = try RimeRuntime(
            sharedDataDirectory: sharedDataDirectory,
            userDataDirectory: URL(fileURLWithPath: CommandLine.arguments[2])
        )
        do {
            _ = try RimeEngine(runtime: runtime, schema: "sentencealong-missing-test-schema")
            fputs("Rime accepted a nonexistent schema\n", stderr)
            exit(1)
        } catch RimeEngineError.schemaUnavailable {
            // A bad schema is an explicit error and must leave the runtime reusable.
        }
        let engine = try RimeEngine(runtime: runtime)
        print("Rime startup: initialization \(runtime.timings.initializationMS) ms, maintenance \(runtime.timings.maintenanceMS) ms")
        let shiftedPunctuation: [(actual: String, unmodified: String, expected: Int32)] = [
            ("?", "/", 0x3f),
            ("~", "`", 0x7e),
            ("|", "\\", 0x7c),
        ]
        for sample in shiftedPunctuation {
            let mapped = RimeKeyboardMapper.printable(
                characters: sample.actual,
                charactersIgnoringModifiers: sample.unmodified,
                shift: true,
                control: false
            )
            guard mapped == .init(keyCode: sample.expected, modifiers: 0) else {
                fputs("Shift punctuation mapped incorrectly: \(sample), got \(String(describing: mapped))\n", stderr)
                exit(1)
            }
        }

        let question = engine.process(keyCode: 0x3f)
        guard question.commit == "？" else {
            fputs("Rime did not commit a Chinese question mark: \(question)\n", stderr)
            exit(1)
        }

        var latest = RimeSnapshot(
            consumed: false,
            preedit: "",
            candidates: [],
            highlightedIndex: 0,
            commit: nil
        )
        for scalar in "nihao".unicodeScalars {
            latest = engine.process(keyCode: Int32(scalar.value))
        }

        guard latest.consumed, !latest.preedit.isEmpty, !latest.candidates.isEmpty else {
            fputs("Rime did not produce candidates for nihao: \(latest)\n", stderr)
            exit(1)
        }

        let committed = engine.process(keyCode: 0x20)
        guard let text = committed.commit, !text.isEmpty else {
            fputs("Rime did not commit the first candidate\n", stderr)
            exit(1)
        }

        for scalar in "ceshi".unicodeScalars {
            latest = engine.process(keyCode: Int32(scalar.value))
        }

        guard latest.consumed, latest.candidates.contains(where: { $0.text == "测试" }) else {
            fputs("Rime did not produce the simplified candidate 测试 for ceshi: \(latest)\n", stderr)
            exit(1)
        }

        engine.clear()
        for scalar in "ni".unicodeScalars {
            latest = engine.process(keyCode: Int32(scalar.value))
        }
        let pageOne = latest
        let pageTwo = engine.process(keyCode: RimeKey.pageDown)
        guard pageOne.pageNumber == 0, !pageOne.canPageBackward, pageOne.canPageForward,
              pageTwo.pageNumber == 1, pageTwo.canPageBackward, pageTwo.consumed, pageTwo.preedit == pageOne.preedit,
              pageTwo.commit == nil, pageTwo.candidates != pageOne.candidates,
              pageTwo.candidates.indices.contains(pageTwo.highlightedIndex) else {
            fputs("Rime failed to advance a page without committing\n", stderr)
            exit(1)
        }
        let previous = engine.process(keyCode: RimeKey.pageUp)
        guard previous.candidates == pageOne.candidates, previous.highlightedIndex == pageOne.highlightedIndex,
              previous.commit == nil, previous.candidates.count >= 2 else {
            fputs("Rime failed to restore candidate order and highlighting\n", stderr)
            exit(1)
        }
        let advanced = engine.changePage(backward: false)
        let returned = engine.changePage(backward: true)
        guard advanced.candidates == pageTwo.candidates, advanced.commit == nil,
              returned.candidates == pageOne.candidates, returned.commit == nil else {
            fputs("Rime's direct page API changed the candidate selection or committed text\n", stderr)
            exit(1)
        }
        let picked = engine.selectCandidate(at: 1)
        guard picked.consumed, picked.commit == previous.candidates[1].text,
              engine.process(keyCode: RimeKey.escape).commit == nil else {
            fputs("Rime failed to commit exactly one selected candidate\n", stderr)
            exit(1)
        }

        func type(_ letters: String) -> RimeSnapshot {
            var snapshot = RimeSnapshot(consumed: false, preedit: "", candidates: [], highlightedIndex: 0, commit: nil)
            for byte in letters.utf8 { snapshot = engine.process(keyCode: Int32(byte)) }
            return snapshot
        }

        _ = type("nihaonihao")
        let raw = engine.process(keyCode: RimeKey.return)
        guard raw.consumed, raw.commit == "nihaonihao", raw.preedit.isEmpty,
              !engine.process(keyCode: RimeKey.return).consumed else {
            fputs("Return must commit raw composition exactly once and pass through when idle\n", stderr)
            exit(1)
        }
        engine.usesASCIIPunctuation = true
        for character in ",.!?".unicodeScalars {
            let punctuation = engine.process(keyCode: Int32(character.value))
            guard punctuation.consumed, punctuation.commit == String(character), punctuation.preedit.isEmpty else {
                fputs("ASCII punctuation must be explicitly committed once for sentence tracking\n", stderr)
                exit(1)
            }
        }
        engine.usesASCIIPunctuation = false
        guard engine.process(keyCode: 63).commit == "？" else {
            fputs("Disabling ASCII punctuation did not restore Chinese punctuation\n", stderr)
            exit(1)
        }

        // Project the native ordering into larger pages without skipping the
        // first candidate or repeating the previous page's final candidate.
        var reference = type("shi").candidates
        for _ in 0..<3 { reference += engine.changePage(backward: false).candidates }
        engine.clear()
        engine.candidatePageSize = 10
        let longFirstPage = type("shi")
        let longSecondPage = engine.changePage(backward: false)
        guard longFirstPage.candidates + longSecondPage.candidates == reference else {
            fputs("Resizing candidate pages changed the native ordering\n", stderr)
            exit(1)
        }
        engine.clear()

        for count in 5...10 {
            engine.candidatePageSize = count
            let first = type("shi")
            guard first.candidates.count == count else {
                fputs("Rime candidate page did not match configured size\n", stderr)
                exit(1)
            }
            engine.candidatePageSize = count == 10 ? 5 : count + 1
            let modifiedNext = engine.process(keyCode: 118, modifiers: 4)
            let modifiedPrevious = engine.process(keyCode: 121, modifiers: 4)
            guard modifiedNext.pageNumber == 1, modifiedNext.highlightedIndex == 0,
                  modifiedPrevious.pageNumber == 0, modifiedPrevious.candidates == first.candidates else {
                fputs("Control+V/Y must move one displayed page in both directions\n", stderr)
                exit(1)
            }
            let next = engine.changePage(backward: false)
            guard next.pageNumber == 1, next.candidates.count == count, next.commit == nil,
                  engine.changePage(backward: true).candidates == first.candidates else {
                fputs("Changing the requested page size disturbed an active composition\n", stderr)
                exit(1)
            }
            let keyCode = Int32(48 + count % 10)
            let selected = engine.process(keyCode: keyCode)
            guard selected.commit == first.candidates[count - 1].text, selected.preedit.isEmpty else {
                fputs("Final numbered candidate did not match the committed text\n", stderr)
                exit(1)
            }
            engine.candidatePageSize = count
            _ = type("shi")
            let later = engine.process(keyCode: RimeKey.pageDown)
            guard later.candidates.count == count, engine.selectCandidate(at: count - 1).commit == later.candidates.last?.text else {
                fputs("Clicking the final candidate on a later page failed\n", stderr)
                exit(1)
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["SENTENCEALONG_RIME_BENCHMARK"] == "1" {
            var samples = [Double]()
            for _ in 0..<300 {
                engine.clear()
                for scalar in "nihao".unicodeScalars {
                    let start = ContinuousClock.now
                    _ = engine.process(keyCode: Int32(scalar.value))
                    let elapsed = start.duration(to: .now).components
                    samples.append(Double(elapsed.seconds) * 1e6 + Double(elapsed.attoseconds) / 1e12)
                }
            }
            let ordered = samples.sorted()
            print("Rime key snapshots: \(samples.count) samples, P50 \(ordered[749]) µs, P95 \(ordered[1424]) µs")
        }
        #endif

        print("Rime checks passed: nihao -> \(text), ceshi -> 测试")
    }
}
