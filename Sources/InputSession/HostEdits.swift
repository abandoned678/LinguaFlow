import RimeInput

public enum CompositionEdit: Equatable {
    case commit(String)
    case mark(String)
}

extension RimeSnapshot {
    public func hostEdits(previousPreedit: String, previousCaret: Int? = nil) -> [CompositionEdit] {
        var edits: [CompositionEdit] = []
        if let commit, !commit.isEmpty { edits.append(.commit(commit)) }
        let oldCaret = previousCaret ?? previousPreedit.utf16.count
        if preedit != previousPreedit || caretUTF16 != oldCaret {
            edits.append(.mark(preedit))
        }
        return edits
    }
}
