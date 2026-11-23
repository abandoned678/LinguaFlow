import Carbon
import IMETrace

extension RunDriver {
    private func waitForPreview() throws {
        try wait("translation result", timeout: 10, failure: .failed("preview did not arrive")) {
            $0.count(.translationReady, from: .ime) > 0 || $0.count(.translationUnavailable, from: .ime) > 0
                || $0.count(.translationFailed, from: .ime) > 0
        }
        if try evidence().count(.translationFailed, from: .ime) > 0 { throw RunFailure.failed("translation failed") }
        guard try evidence().count(.translationReady, from: .ime) > 0 else {
            throw RunFailure.blocked("translation provider unavailable")
        }
    }

    func punctuationPreview() throws {
        try typeLetters([UInt16(kVK_ANSI_Period)])
        try waitForPreview()
        try checkDocument()
    }

    func mixedPunctuation() throws {
        if run.scenario == "ascii-comma-context" {
            try commitNihao()
            try typeLetters([UInt16(kVK_ANSI_Comma)])
        } else {
            try Self.tapShift(to: host.processIdentifier, verifyTarget: requireFocusedHost)
            try typeLetters([UInt16(kVK_ANSI_X), UInt16(kVK_ANSI_Period), UInt16(kVK_Space)])
            try Self.tapShift(to: host.processIdentifier, verifyTarget: requireFocusedHost)
        }
        let commits = try evidence().count(.inserted, from: .host)
        try typeLetters(PinyinCommit.letters)
        try send(PinyinCommit.confirm)
        try wait("last word committed", failure: .failed("final Chinese word missing")) {
            $0.count(.inserted, from: .host) > commits
        }
        // The IME probe acknowledges only this scenario's expected source sentence.
        try waitForPreview()
        if run.scenario == "mixed-period-replace" {
            try send(Self.debugSettings.read().replacementKeyCode, flags: [.maskControl, .maskShift])
            try wait("replacement preserved the previous sentence", failure: .failed("replacement boundary mismatch")) {
                $0.count(.translatedDocument, from: .host) == 1
            }
            try send(UInt16(kVK_ANSI_Z), flags: .maskCommand)
            try wait("undo restored only the final sentence", failure: .failed("undo boundary mismatch")) {
                $0.count(.undoRestored, from: .host) == 1
            }
        }
        try checkDocument()
    }

    func translationReplacement() throws {
        if run.scenario == "english-undo" {
            try typeLetters([UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_E), UInt16(kVK_ANSI_L),
                             UInt16(kVK_ANSI_L), UInt16(kVK_ANSI_O)])
        } else {
            try commitNihao()
        }
        try waitForPreview()
        try send(Self.debugSettings.read().replacementKeyCode, flags: [.maskControl, .maskShift])
        try wait("translated host document", failure: .failed("range replacement failed")) {
            $0.count(.translatedDocument, from: .host) == 1
        }
        try send(UInt16(kVK_ANSI_Z), flags: [.maskCommand])
        try wait("undo restored original sentence", failure: .failed("undo did not restore original text")) {
            $0.count(.undoRestored, from: .host) == 1
        }
        try checkDocument()
    }
}
