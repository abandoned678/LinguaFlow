import Carbon

public enum SentenceReplacementShortcut {
    public static let label = "⌃⇧T"

    public static func matches(keyCode: UInt16, control: Bool, shift: Bool) -> Bool {
        control && shift && keyCode == kVK_ANSI_T
    }
}
