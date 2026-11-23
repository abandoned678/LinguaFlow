import Foundation
import RimeInput

/// Compares synthetic text in memory and reports row numbers and metrics only.
@MainActor
enum PinyinQuality {
    private struct Sample {
        let code: Substring
        let expected: String
    }

    static func run(shared: URL, user: URL, corpus: URL) throws {
        let runtime = try RimeRuntime(sharedDataDirectory: shared, userDataDirectory: user)
        let engine = try RimeEngine(runtime: runtime)
        let rows = try String(contentsOf: corpus, encoding: .utf8).split(separator: "\n")
        let samples = try rows.enumerated().map { index, row in
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[1].isEmpty, !fields[0].isEmpty,
                  fields[0].utf8.allSatisfy({ (97...122).contains($0) }) else {
                throw NSError(domain: "InvalidSyntheticCorpus", code: index + 1)
            }
            return Sample(code: fields[0], expected: String(fields[1]))
        }

        func locate(_ sample: Sample) -> (slot: Int, rank: Int)? {
            engine.clear()
            var snapshot: RimeSnapshot?
            for key in sample.code.utf8 { snapshot = engine.process(keyCode: Int32(key)) }
            for page in 0..<10 {
                guard let current = snapshot else { break }
                if let slot = current.candidates.firstIndex(where: { $0.text == sample.expected }) {
                    return (slot, page * 5 + slot + 1)
                }
                guard current.canPageForward else { break }
                snapshot = engine.changePage(backward: false)
            }
            return nil
        }

        // Finish the entire cold ranking pass before allowing any training commits.
        let ranks = samples.map { locate($0)?.rank }
        print("sample,rank,extra_page_keys,selections_until_first")
        for (index, sample) in samples.enumerated() {
            guard let rank = ranks[index] else { print("\(index + 1),>50,NA,NA"); continue }
            var hit = locate(sample)
            var trained = 0
            while let current = hit, current.rank > 1, trained < 5 {
                guard engine.selectCandidate(at: current.slot).commit == sample.expected else { break }
                trained += 1
                hit = locate(sample)
            }
            let learned = hit?.rank == 1 ? String(trained) : "NA"
            print("\(index + 1),\(rank),\((rank - 1) / 5),\(learned)")
        }
        let located = ranks.compactMap { $0 }
        let first = located.filter { $0 == 1 }.count
        let topFive = located.filter { $0 <= 5 }.count
        let extra = located.reduce(0) { $0 + ($1 - 1) / 5 }
        print("samples=\(rows.count) first=\(first) firstFive=\(topFive) within50=\(located.count) extraPageKeysForLocated=\(extra)")
    }
}
