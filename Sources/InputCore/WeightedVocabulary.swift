import Foundation

public struct WeightedWord: Equatable, Sendable {
    public let text: String
    public let code: String
    public let weight: Int

    fileprivate var key: String { code + "\t" + text }
}

public struct WeightedImportResult: Sendable {
    public fileprivate(set) var added = 0
    public fileprivate(set) var updated = 0
    public fileprivate(set) var unchanged = 0
}

private enum WeightedVocabularyError: Error, LocalizedError {
    case encoding, invalid(Int), conflict(Int), empty

    var errorDescription: String? {
        switch self {
        case .encoding: "词频表需使用 UTF-8 文本。"
        case .invalid(let line): "第 \(line) 行格式无效。请用制表符分隔词条、小写输入码和正整数词频。"
        case .conflict(let line): "第 \(line) 行与文件中已有的相同词条和输入码使用了不同词频。"
        case .empty: "文件中没有可导入的词频条目。"
        }
    }
}

extension PersonalDictionary {
    private var weightedFile: URL { directory.appendingPathComponent("sjy_weighted.txt") }
    public var weightedRevision: Revision? { revision(of: weightedFile) }

    public static func weightedEntries(from data: Data) throws -> [WeightedWord] {
        let entries = try parseWeightedEntries(data)
        guard !entries.isEmpty else { throw WeightedVocabularyError.empty }
        return entries
    }

    static func parseWeightedEntries(_ data: Data) throws -> [WeightedWord] {
        guard let source = String(data: data, encoding: .utf8) else { throw WeightedVocabularyError.encoding }
        let text = source.first == "\u{FEFF}" ? source.dropFirst() : source[...]
        var entries: [WeightedWord] = []
        var seen: [String: Int] = [:]
        for (index, row) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if row.isEmpty || row.hasPrefix("#") { continue }
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let phrase = try? PersonalPhrase(code: String(fields[1]), text: String(fields[0])),
                  fields[2].utf8.allSatisfy({ (48...57).contains($0) }),
                  let weight = Int32(fields[2]), weight > 0 else { throw WeightedVocabularyError.invalid(index + 1) }
            let item = WeightedWord(text: phrase.text, code: phrase.code, weight: Int(weight))
            if let previous = seen[item.key] {
                guard previous == item.weight else { throw WeightedVocabularyError.conflict(index + 1) }
            } else {
                seen[item.key] = item.weight
                entries.append(item)
            }
        }
        return entries
    }

    public func importWeightedEntries(_ entries: [WeightedWord]) throws -> WeightedImportResult {
        let result: WeightedImportResult = try locked {
            let existing: [WeightedWord]
            do {
                existing = try Self.parseWeightedEntries(Data(contentsOf: weightedFile))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                existing = []
            }
            var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
            var result = WeightedImportResult()
            for item in entries {
                if let previous = merged.updateValue(item, forKey: item.key) {
                    if previous.weight == item.weight { result.unchanged += 1 }
                    else { result.updated += 1 }
                } else {
                    result.added += 1
                }
            }
            if result.added + result.updated > 0 {
                let ordered = merged.values.sorted { lhs, rhs in
                    if lhs.code != rhs.code { return lhs.code < rhs.code }
                    if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                    return lhs.text < rhs.text
                }
                var output = "# Rime table\n#@/db_name\tsjy_weighted\n#@/db_type\ttabledb\n"
                for item in ordered { output += "\(item.text)\t\(item.code)\t\(item.weight)\n" }
                try output.write(to: weightedFile, atomically: true, encoding: .utf8)
            }
            return result
        }
        if result.added + result.updated > 0 { notify() }
        return result
    }

    public func clearImportedWeights() throws {
        let removed: Bool = try locked {
            do { try FileManager.default.removeItem(at: weightedFile); return true }
            catch let error as CocoaError where error.code == .fileNoSuchFile { return false }
        }
        if removed { notify() }
    }
}
