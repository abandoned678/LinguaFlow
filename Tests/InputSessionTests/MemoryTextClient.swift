import Foundation
import InputSession

struct MemoryTextClient {
    var text: String
    var marked = ""
    var commits = 0
    mutating func apply(_ edits: [CompositionEdit]) {
        for edit in edits {
            switch edit {
            case .mark(let value): marked = value
            case .commit(let value):
                text += value
                marked = ""
                commits += 1
            }
        }
    }
}
