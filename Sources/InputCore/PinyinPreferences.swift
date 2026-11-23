import Foundation

public enum PinyinLayout: String, CaseIterable, Sendable {
    case full, flypy
    public var label: String { self == .full ? "简体全拼" : "小鹤双拼" }
}

public enum FuzzyInitial: String, CaseIterable, Sendable {
    case z, c, s
    public var label: String { "\(rawValue) / \(rawValue)h" }
}

extension InputSettings {
    public var pinyinSchema: String {
        let initials = FuzzyInitial.allCases.filter { fuzzyInitials.contains($0) }.map(\.rawValue).joined()
        if pinyinLayout == .full && initials.isEmpty && learnsWords { return "luna_pinyin_simp" }
        return "sjy_\(pinyinLayout.rawValue)\(initials)\(learnsWords ? "" : "_private")"
    }
}
