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

    func translationReplacement() throws {
        try commitNihao()
        try waitForPreview()
        try send(UInt16(kVK_ANSI_T), flags: [.maskControl, .maskShift])
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
