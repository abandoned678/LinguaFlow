import Foundation

/// Expected contents of the dedicated external-host sample. Never persist editor text.
public enum ExternalDraft {
    public static let prefix = "前文："
    public static let chinese = prefix + "你好"

    public static func isNewTarget(newWindow: Bool, sameWindow: Bool, replacedEditor: Bool) -> Bool {
        newWindow || (sameWindow && replacedEditor)
    }

    public static func isEmpty(characterCount: Int?, selection: NSRange?) -> Bool {
        characterCount == 0 && selection == NSRange(location: 0, length: 0)
    }

    public static func previewTranslation(_ value: String) -> String? {
        // PreviewView's AX value in standard and compact layout respectively.
        for label in ["中文 你好。EN ", "EN "] where value.hasPrefix(label) {
            let translation = String(value.dropFirst(label.count))
            let accepted = ["hello", "hi"].flatMap { word in ["", ".", "!", "。", "！"].map { word + $0 } }
            if accepted.contains(translation.lowercased()) { return translation }
        }
        return nil
    }

    public static func matchesReplacement(_ document: String, preview: String) -> Bool {
        document == prefix + preview
    }
}
