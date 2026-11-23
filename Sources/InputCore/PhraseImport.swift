import Foundation

public enum PhraseImportFormat: Sendable {
    case tsv, appleTextReplacements, sogouCustomPhrases
}

public struct PhraseImportResult: Sendable {
    public let inserted: Int
    public let skippedConflicts: Int
    public let invalidCount: Int
}

public enum PhraseImportError: LocalizedError {
    case invalidEncoding, invalidPropertyList, noPhrases, tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: "无法解码文件，请使用 UTF-8 或带字节顺序标记的 UTF-16 文本。"
        case .invalidPropertyList: "请选择从 Mac「替换文本」导出的 plist 文件。"
        case .noPhrases: "未找到可导入的短语，请检查所选格式与输入码。"
        case .tooLarge: "短语文件超过 16 MiB，请拆分后导入。"
        }
    }
}

public struct PhraseImportBatch: Sendable {
    let phrases: [PersonalPhrase]
    public var validCount: Int { phrases.count }
    public let invalidCount: Int

    public init(data: Data, format: PhraseImportFormat) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw PhraseImportError.tooLarge }
        var valid: [PersonalPhrase] = []
        var invalid = 0
        func collect(_ code: String?, _ text: String?) {
            if let code, let text, let phrase = try? PersonalPhrase(code: code, text: text) {
                valid.append(phrase)
            } else {
                invalid += 1
            }
        }

        switch format {
        case .appleTextReplacements:
            guard let records = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any] else {
                throw PhraseImportError.invalidPropertyList
            }
            for record in records {
                let fields = record as? [String: Any]
                collect(fields?["shortcut"] as? String, fields?["phrase"] as? String)
            }
        case .tsv:
            try Self.decodeText(data).enumerateLines { line, _ in
                if line.allSatisfy(\.isWhitespace) { return }
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { invalid += 1; return }
                collect(String(fields[0]), String(fields[1]))
            }
        case .sogouCustomPhrases:
            // A following continuation makes the entire entry multiline and
            // incompatible with PersonalPhrase. Never import its first line alone.
            var pending: (code: String, text: String?)?
            func finishPending() {
                if let pending { collect(pending.code, pending.text) }
                pending = nil
            }
            try Self.decodeText(data).enumerateLines { line, _ in
                if line.isEmpty || line.hasPrefix(";") { return }
                guard let comma = line.firstIndex(of: ","), let equals = line.firstIndex(of: "="), comma < equals else {
                    if pending != nil { pending?.text = nil }
                    else { invalid += 1 }
                    return
                }
                finishPending()
                let rank = line[line.index(after: comma)..<equals]
                let hasRank = rank.utf8.allSatisfy { (48...57).contains($0) } && (Int(rank) ?? 0) > 0
                pending = (String(line[..<comma]), hasRank ? String(line[line.index(after: equals)...]) : nil)
            }
            finishPending()
        }
        guard !valid.isEmpty else { throw PhraseImportError.noPhrases }
        self.phrases = valid
        self.invalidCount = invalid
    }

    private static func decodeText(_ data: Data) throws -> String {
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            text = String(data: data, encoding: .utf16)
        } else {
            let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
            text = String(data: bytes, encoding: .utf8)
        }
        guard let text else { throw PhraseImportError.invalidEncoding }
        return text
    }
}
