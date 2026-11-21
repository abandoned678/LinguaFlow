import Foundation
import IMETrace

enum PinyinCommit {
    static let name = "pinyin-commit"
    // ANSI N, I, H, A, O. Use physical key codes so macOS performs text input.
    static let letters: [UInt16] = [45, 34, 4, 0, 31]
    static let confirm: UInt16 = 49
}

extension RunDriver {
    func composeNihao() throws {
        if manual {
            print("请在测试窗口输入 nihao。"); fflush(stdout)
        } else {
            try typeLetters(PinyinCommit.letters)
        }
        try wait("highlighted 你好 and marked text", timeout: manual ? 35 : 5,
                 failure: .failed("candidate or marked text missing")) {
            $0.count(.candidateMatched, from: .ime) > 0 && $0.count(.marked, from: .host) > 0
        }
    }

    func commitNihao() throws {
        try composeNihao()
        if manual { print("按空格确认候选。"); fflush(stdout) }
        else { try send(PinyinCommit.confirm) }
        try wait("host inserted candidate", timeout: manual ? 20 : 5, failure: .failed("commit did not reach host")) {
            $0.count(.inserted, from: .host) > 0
        }
    }

    func pinyinCommit() throws {
        try commitNihao()
        try checkDocument()
        try wait("IME commit evidence", failure: .blocked("IME commit evidence unavailable")) {
            $0.count(.commitRequested, from: .ime) > 0
        }
        guard try evidence().pinyinCommitted else { throw RunFailure.failed("double-ended assertion failed") }
    }
}
