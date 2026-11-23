import Carbon

public enum SentenceReplacementShortcut {
    public static let defaultKeyCode = UInt16(kVK_ANSI_T)
    public static var label: String { label(for: defaultKeyCode) }

    private static let letters = Dictionary(uniqueKeysWithValues: [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
    ].map { (UInt16($0.key), $0.value) })

    public static func supports(keyCode: UInt16) -> Bool { letters[keyCode] != nil }

    public static func keyEquivalent(for keyCode: UInt16) -> String {
        (letters[keyCode] ?? "T").lowercased()
    }

    public static func label(for keyCode: UInt16) -> String {
        "⌃⇧" + (letters[keyCode] ?? "T")
    }

    public static func matches(
        keyCode: UInt16, control: Bool, shift: Bool, configuredKeyCode: UInt16 = defaultKeyCode
    ) -> Bool {
        control && shift && keyCode == configuredKeyCode && supports(keyCode: configuredKeyCode)
    }
}
