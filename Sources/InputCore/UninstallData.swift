import Darwin
import Foundation

/// Operates on a single product's Application Support directory after the IME has stopped.
public struct UninstallData: Sendable {
    public enum Category: CaseIterable, Sendable { case phrases, weights, learning, preferences }

    private let root: URL
    private var rime: URL { root.appendingPathComponent("Rime") }
    private var dictionary: PersonalDictionary { PersonalDictionary(directory: rime) }
    public init(directory: URL) { root = directory }

    private func exists(_ url: URL, directory: Bool = false) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return true
    }

    private var phrases: URL { rime.appendingPathComponent("sjy_personal.txt") }
    private var weights: URL { rime.appendingPathComponent("sjy_weighted.txt") }
    private var learning: URL { rime.appendingPathComponent("luna_pinyin.userdb") }
    private var pendingClear: URL { rime.appendingPathComponent(".sjy-clear-learning") }
    private var preferences: URL { InputSettingsStore(directory: root).preferencesURL }

    public func counts() throws -> (phrases: Int, weights: Int) {
        guard try exists(root, directory: true), try exists(rime, directory: true) else { return (0, 0) }
        let phraseCount = try exists(phrases) ? dictionary.phrases().count : 0
        let weightCount = try exists(weights) ? PersonalDictionary.parseWeightedEntries(Data(contentsOf: weights)).count : 0
        return (phraseCount, weightCount)
    }

    public func remove(_ selected: Set<Category>) throws {
        guard !selected.isEmpty, try exists(root, directory: true) else { return }
        let removePreferences = try selected.contains(.preferences) && exists(preferences)
        if !selected.subtracting([.preferences]).isEmpty, try exists(rime, directory: true) {
            try dictionary.locked {
                var files = [URL]()
                if selected.contains(.phrases), try exists(phrases) { files.append(phrases) }
                if selected.contains(.weights), try exists(weights) { files.append(weights) }
                if selected.contains(.learning) {
                    if try exists(pendingClear) { files.append(pendingClear) }
                    if try exists(learning, directory: true) { try dictionary.removeLearningDatabase(learning) }
                }
                for file in files { try FileManager.default.removeItem(at: file) }
            }
        }
        if removePreferences { try FileManager.default.removeItem(at: preferences) }
    }
}
