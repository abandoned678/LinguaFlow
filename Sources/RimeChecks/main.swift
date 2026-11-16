import Foundation
import RimeInput

@main
@MainActor
struct RimeChecks {
    static func main() throws {
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
        let engine = try RimeEngine(runtime: runtime)
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
        guard pageTwo.consumed, pageTwo.preedit == pageOne.preedit,
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
        let picked = engine.selectCandidate(at: 1)
        guard picked.consumed, picked.commit == previous.candidates[1].text,
              engine.process(keyCode: RimeKey.escape).commit == nil else {
            fputs("Rime failed to commit exactly one selected candidate\n", stderr)
            exit(1)
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
