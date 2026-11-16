import Foundation
import InputCore
import LocalTranslation

enum PreviewBenchmark {
    private static let corpus = [
        "我今天打算骑车去公园。",
        "下午请把样品放在测试桌上。",
        "窗外有三只鸟飞过。",
        "他们明天早晨乘火车出发。",
        "这是一条用于测试的提醒。",
        "新书放在第二排最右边。",
        "我们已经更新了测试计时器。",
        "请在钟声响起之后休息。",
    ]

    @MainActor
    static func run() async throws {
        let provider = OnDeviceTranslationProvider(direction: .chineseToEnglish)
        _ = try await provider.translate(.init(sourceText: "合成预热。", revision: 0))
        let baseline = TranslationCoordinator(provider: provider, debounce: .milliseconds(400))
        let balanced = TranslationCoordinator(provider: provider)
        var baselineTimes: [Double] = []
        var balancedTimes: [Double] = []

        for (index, sentence) in (corpus + corpus).enumerated() {
            let snapshot = SentenceSnapshot(text: sentence, revision: UInt64(index), isFinal: false)
            if index.isMultiple(of: 2) {
                baselineTimes.append(try await measure(baseline, snapshot: snapshot))
                balancedTimes.append(try await measure(balanced, snapshot: snapshot))
            } else {
                balancedTimes.append(try await measure(balanced, snapshot: snapshot))
                baselineTimes.append(try await measure(baseline, snapshot: snapshot))
            }
        }

        print("Scope: dispatch to coordinator state, warm model, empty preview cache")
        printSummary("400ms", samples: baselineTimes)
        printSummary("balanced", samples: balancedTimes)
    }

    @MainActor
    private static func measure(_ coordinator: TranslationCoordinator, snapshot: SentenceSnapshot) async throws -> Double {
        coordinator.cancel()
        let start = ContinuousClock.now
        coordinator.submit(snapshot)
        let deadline = start + .seconds(5)
        while ContinuousClock.now < deadline {
            switch coordinator.state {
            case .ready:
                let parts = start.duration(to: .now).components
                return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
            case .failed(_, let failure):
                throw failure
            default:
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        throw TranslationFailure.timedOut
    }

    private static func printSummary(_ name: String, samples: [Double]) {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> String {
            let index = Int(ceil(Double(sorted.count) * fraction)) - 1
            return String(format: "%.1f ms", sorted[index])
        }
        print("\(name) samples=\(sorted.count) P50=\(percentile(0.50)) P95=\(percentile(0.95))")
    }
}
