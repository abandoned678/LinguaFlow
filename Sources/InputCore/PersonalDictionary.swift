import Darwin
import Foundation

public struct PersonalPhrase: Equatable, Identifiable, Sendable {
    public let code: String
    public let text: String
    public var id: String { code }

    public init(code: String, text: String) throws {
        guard (1...64).contains(code.utf8.count), code.utf8.allSatisfy({ (97...122).contains($0) }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 256,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              text.rangeOfCharacter(from: .newlines) == nil, !text.hasPrefix("#") else {
            throw PersonalDictionaryError.invalidPhrase
        }
        self.code = code
        self.text = text
    }
}

public enum PersonalDictionaryError: Error, LocalizedError {
    case invalidPhrase, duplicateCode, changed, unreadable

    public var errorDescription: String? {
        switch self {
        case .invalidPhrase: "输入码需为 1 至 64 个小写英文字母；短语最多 256 个字，不能以 # 开头或包含换行和控制字符。"
        case .duplicateCode: "这个输入码已被使用。"
        case .changed: "短语已在其他窗口变更，请刷新后重试。"
        case .unreadable: "无法读取个人词典，原文件已保留。"
        }
    }
}

/// The app-owned stabledb is separate from Rime's upstream custom_phrase file and learned LevelDB.
public struct PersonalDictionary: Sendable {
    public static let shared = PersonalDictionary(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/" + InputSettingsStore.productDirectory + "/Rime"))
    public static let didChange = Notification.Name(InputSettingsStore.domain + ".personalDictionaryChanged")
    public static let didClearLearning = Notification.Name(InputSettingsStore.domain + ".learningCleared")
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private var phraseFile: URL { directory.appendingPathComponent("sjy_personal.txt") }
    private var clearRequest: URL { directory.appendingPathComponent(".sjy-clear-learning") }
    private static let header = "# Rime table\n#@/db_name\tsjy_personal\n#@/db_type\ttabledb\n"

    /// The phrase file is atomically replaced on every edit. Activation can therefore
    /// detect a missed cross-process notification without reading any personal text.
    public struct Revision: Equatable {
        fileprivate let inode: UInt64
        fileprivate let modified: Date
    }

    public var revision: Revision? { revision(of: phraseFile) }

    func revision(of file: URL) -> Revision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Revision(inode: inode.uint64Value, modified: modified)
    }

    public func phrases() throws -> [PersonalPhrase] {
        guard FileManager.default.fileExists(atPath: phraseFile.path) else { return [] }
        let contents = try String(contentsOf: phraseFile, encoding: .utf8)
        var seen = Set<String>()
        return try contents.split(separator: "\n").compactMap { line in
            if line.first == "#" { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let phrase = try? PersonalPhrase(code: String(fields[1]), text: String(fields[0])),
                  seen.insert(phrase.code).inserted else { throw PersonalDictionaryError.unreadable }
            return phrase
        }
    }

    public func replace(_ previous: PersonalPhrase?, with next: PersonalPhrase?) throws {
        try locked {
            var entries = try phrases()
            if let previous {
                guard let index = entries.firstIndex(of: previous) else { throw PersonalDictionaryError.changed }
                entries.remove(at: index)
            }
            if let next {
                guard !entries.contains(where: { $0.code == next.code }) else { throw PersonalDictionaryError.duplicateCode }
                entries.append(next)
            }
            try write(entries)
        }
        notify()
    }

    /// Resolve conflicts against the dictionary as it exists at commit time.
    public func importPhrases(_ batch: PhraseImportBatch) throws -> PhraseImportResult {
        let result = try locked {
            var entries = try phrases()
            var used = Set(entries.map(\.code))
            let originalCount = entries.count
            for phrase in batch.phrases where used.insert(phrase.code).inserted {
                entries.append(phrase)
            }
            let inserted = entries.count - originalCount
            if inserted > 0 { try write(entries) }
            return PhraseImportResult(inserted: inserted, skippedConflicts: batch.validCount - inserted,
                                      invalidCount: batch.invalidCount)
        }
        if result.inserted > 0 { notify() }
        return result
    }

    private func write(_ entries: [PersonalPhrase]) throws {
        let lines = entries.sorted { $0.code < $1.code }.map { "\($0.text)\t\($0.code)\t100\n" }
        try (Self.header + lines.joined()).write(to: phraseFile, atomically: true, encoding: .utf8)
    }

    public func requestClearLearning() throws {
        try locked { try Data().write(to: clearRequest, options: .atomic) }
        notify()
    }

    public var clearPending: Bool { FileManager.default.fileExists(atPath: clearRequest.path) }

    /// Called only by the IME while no session has its learning database open.
    public func clearLearningIfRequested() throws {
        guard clearPending else { return }
        try locked {
            guard clearPending else { return }
            let database = directory.appendingPathComponent("luna_pinyin.userdb")
            if FileManager.default.fileExists(atPath: database.path) {
                try removeLearningDatabase(database)
            }
            try FileManager.default.removeItem(at: clearRequest)
        }
        DistributedNotificationCenter.default().postNotificationName(Self.didClearLearning, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    func removeLearningDatabase(_ database: URL) throws {
        // Another installation of the same identity could still own this LevelDB.
        // Honour the POSIX writer lock before removing any of its files.
        let lockFile = database.appendingPathComponent("LOCK").path
        let fd = open(lockFile, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 && lockf(fd, F_TLOCK, 0) != 0 { throw POSIXError(.EBUSY) }
        try FileManager.default.removeItem(at: database)
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".sjy-phrases.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    func notify() {
        DistributedNotificationCenter.default().postNotificationName(Self.didChange, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
