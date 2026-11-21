import Carbon
import IMETrace

extension RunDriver {
    func compositionEditing() throws {
        try typeLetters(PinyinCommit.letters + PinyinCommit.letters)
        try wait("active marked text", failure: .failed("marked text missing")) { $0.count(.marked, from: .host) > 0 }
        for step in 1...3 {
            try send(UInt16(kVK_LeftArrow))
            try wait("left arrow \(step) reached IMK", failure: .blocked("navigation delivery stopped")) {
                $0.count(.key, from: .ime) == 10 + step
            }
        }
        try checkDocument()
        try send(UInt16(kVK_ANSI_G))
        try wait("inserted letter at composition caret", failure: .failed("in-place edit mismatch")) {
            $0.count(.middleInsertion, from: .host) == 1
        }
        try send(UInt16(kVK_Delete))
        try wait("backspace restored composition", failure: .failed("backspace mismatch")) {
            $0.count(.middleDeletion, from: .host) == 1
        }
    }
}
