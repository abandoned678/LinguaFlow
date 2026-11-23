import Foundation
import RimeBridge

public enum RimeKey {
    public static let backspace: Int32 = 0xff08
    public static let `return`: Int32 = 0xff0d
    public static let escape: Int32 = 0xff1b
    public static let home: Int32 = 0xff50
    public static let left: Int32 = 0xff51
    public static let up: Int32 = 0xff52
    public static let right: Int32 = 0xff53
    public static let down: Int32 = 0xff54
    public static let pageUp: Int32 = 0xff55
    public static let pageDown: Int32 = 0xff56
    public static let end: Int32 = 0xff57
}

public struct RimeCandidate: Equatable, Sendable {
    public let text: String
    public let comment: String?

    public init(text: String, comment: String?) {
        self.text = text
        self.comment = comment
    }
}

public struct RimeSnapshot: Equatable, Sendable {
    public let consumed: Bool
    public let caretUTF16: Int
    public let preedit: String
    public let candidates: [RimeCandidate]
    public let highlightedIndex: Int
    public let commit: String?
    public let pageNumber: Int
    public let isLastPage: Bool

    public var canPageBackward: Bool { !candidates.isEmpty && pageNumber > 0 }
    public var canPageForward: Bool { !candidates.isEmpty && !isLastPage }

    public init(
        consumed: Bool,
        preedit: String,
        cursorByteOffset: Int? = nil,
        candidates: [RimeCandidate],
        highlightedIndex: Int,
        commit: String?,
        pageNumber: Int = 0,
        isLastPage: Bool = true
    ) {
        self.consumed = consumed
        self.preedit = preedit
        if let offset = cursorByteOffset, offset >= 0,
           let index = preedit.utf8.index(preedit.utf8.startIndex, offsetBy: offset, limitedBy: preedit.utf8.endIndex),
           let position = index.samePosition(in: preedit.utf16) {
            caretUTF16 = preedit.utf16.distance(from: preedit.utf16.startIndex, to: position)
        } else {
            caretUTF16 = preedit.utf16.count
        }
        self.candidates = candidates
        self.highlightedIndex = highlightedIndex
        self.commit = commit
        self.pageNumber = pageNumber
        self.isLastPage = isLastPage
    }
}

public enum RimeEngineError: Error, LocalizedError {
    case initializationFailed(String)
    case sessionCreationFailed(String)
    case schemaUnavailable

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let message), .sessionCreationFailed(let message): message
        case .schemaUnavailable: "随键译无法加载拼音输入方案。"
        }
    }
}

@MainActor
public final class RimeRuntime {
    public struct StartupTimings {
        public let initializationMS: Double
        public let maintenanceMS: Double
    }

    private static var initialized = false
    public private(set) var timings = StartupTimings(initializationMS: 0, maintenanceMS: 0)

    public init(sharedDataDirectory: URL, userDataDirectory: URL, logDirectory: URL? = nil) throws {
        guard !Self.initialized else { return }
        try FileManager.default.createDirectory(
            at: userDataDirectory,
            withIntermediateDirectories: true
        )

        var bridgeTimings = LFRimeStartup()
        let success = sharedDataDirectory.path.withCString { sharedPath in
            userDataDirectory.path.withCString { userPath in
                if let logDirectory {
                    return logDirectory.path.withCString { logPath in
                        lf_rime_initialize(sharedPath, userPath, logPath, &bridgeTimings)
                    }
                }
                return lf_rime_initialize(sharedPath, userPath, nil, &bridgeTimings)
            }
        }

        guard success != 0 else {
            throw RimeEngineError.initializationFailed(Self.lastError)
        }
        timings = StartupTimings(initializationMS: bridgeTimings.initialization_ms, maintenanceMS: bridgeTimings.maintenance_ms)
        Self.initialized = true
    }

    public static var lastError: String {
        guard let pointer = lf_rime_last_error() else { return "Unknown librime error" }
        return String(cString: pointer)
    }
}

/// A controller keeps the same session while composing. A failed creation can
/// be retried on reactivation or a new schema without retrying each key.
@MainActor
public struct RimeSessionSlot {
    public private(set) var engine: RimeEngine?
    private var attemptedSchema: String?

    public init() {}

    public mutating func load(schema: String, reactivated: Bool = false, create: (String) -> RimeEngine?) {
        guard engine == nil, reactivated || schema != attemptedSchema else { return }
        attemptedSchema = schema
        engine = create(schema)
    }
}

@MainActor
public final class RimeEngine {
    public var candidatePageSize = 5
    private var activePageSize = 5
    public private(set) var isComposing = false
    private var candidateCount = 0
    private var pageNumber = 0
    private var isLastPage = true
    public private(set) var schemaID: String
    public var usesASCIIPunctuation = false {
        didSet {
            if usesASCIIPunctuation != oldValue {
                lf_rime_session_set_ascii_punctuation(session, usesASCIIPunctuation ? 1 : 0)
            }
        }
    }
    nonisolated(unsafe) private var session: OpaquePointer?

    public init(runtime: RimeRuntime, schema: String = "luna_pinyin_simp") throws {
        guard let session = lf_rime_session_create() else {
            throw RimeEngineError.sessionCreationFailed(RimeRuntime.lastError)
        }
        guard schema.withCString({ lf_rime_session_select_schema(session, $0) }) != 0 else {
            lf_rime_session_destroy(session)
            throw RimeEngineError.schemaUnavailable
        }
        self.session = session
        self.schemaID = schema
        lf_rime_session_set_ascii_punctuation(session, 0)
    }

    @discardableResult
    public func selectSchema(_ schema: String) -> Bool {
        guard !isComposing, let session else { return false }
        if schema == schemaID { return true }
        guard schema.withCString({ lf_rime_session_select_schema(session, $0) }) != 0 else { return false }
        schemaID = schema
        lf_rime_session_set_ascii_punctuation(session, usesASCIIPunctuation ? 1 : 0)
        return true
    }

    deinit {
        if let session {
            lf_rime_session_destroy(session)
        }
    }

    public func process(keyCode: Int32, modifiers: Int32 = 0) -> RimeSnapshot {
        guard let session else {
            return .init(consumed: false, preedit: "", candidates: [], highlightedIndex: 0, commit: nil)
        }
        if !isComposing {
            activePageSize = min(10, max(5, candidatePageSize))
        } else if candidateCount > 0, modifiers == 4, keyCode == 118 || keyCode == 121 {
            // Luna's Control+V/Y bindings otherwise advance by its native five-item page.
            return changePage(backward: keyCode == 121)
        } else if modifiers == 0 {
            if keyCode == RimeKey.return, let raw = takeString(lf_rime_session_take_raw_input(session)) {
                return snapshot(consumed: true, rawCommit: raw)
            }
            if candidateCount > 0 {
                if (48...57).contains(keyCode) {
                    let index = Int((keyCode - 49 + 10) % 10)
                    if index < candidateCount { return selectCandidate(at: index) }
                    return snapshot(consumed: true)
                }
                switch keyCode {
                case RimeKey.pageDown, 61, 46: return changePage(backward: false)
                case RimeKey.pageUp, 45: return changePage(backward: true)
                case 44 where pageNumber > 0: return changePage(backward: true)
                default: break
                }
            }
        }
        let wasComposing = isComposing
        let consumed = lf_rime_session_process_key(session, keyCode, modifiers) != 0
        let result = snapshot(consumed: consumed)
        // In ascii_punct mode Rime passes printable punctuation to the host.
        // Commit it through the same IME path as a native result so caret and
        // translation tracking both include the character exactly once.
        if usesASCIIPunctuation, modifiers == 0, !wasComposing, !consumed,
           result.preedit.isEmpty, result.candidates.isEmpty, result.commit == nil,
           (33...126).contains(keyCode), let scalar = Unicode.Scalar(Int(keyCode)),
           !CharacterSet.alphanumerics.contains(scalar) {
            return RimeSnapshot(consumed: true, preedit: "", candidates: [], highlightedIndex: 0, commit: String(scalar))
        }
        return result
    }

    public func selectCandidate(at index: Int) -> RimeSnapshot {
        guard let session, (0..<candidateCount).contains(index),
              let absoluteIndex = Int32(exactly: pageNumber * activePageSize + index)
        else { return snapshot(consumed: false) }
        return snapshot(consumed: lf_rime_session_select_candidate(session, absoluteIndex) != 0)
    }

    public func changePage(backward: Bool) -> RimeSnapshot {
        guard let session, candidateCount > 0 else { return snapshot(consumed: false) }
        guard backward ? pageNumber > 0 : !isLastPage,
              let first = Int32(exactly: (pageNumber + (backward ? -1 : 1)) * activePageSize)
        else { return snapshot(consumed: true) }
        return snapshot(consumed: lf_rime_session_highlight_candidate(session, first) != 0)
    }

    public func clear() {
        isComposing = false
        candidateCount = 0
        pageNumber = 0
        isLastPage = true
        guard let session else { return }
        lf_rime_session_clear(session)
    }

    public func commitComposition() -> RimeSnapshot {
        guard let session else {
            return .init(consumed: false, preedit: "", candidates: [], highlightedIndex: 0, commit: nil)
        }
        let consumed = lf_rime_session_commit_composition(session) != 0
        return snapshot(consumed: consumed)
    }

    private func snapshot(consumed: Bool, rawCommit: String? = nil) -> RimeSnapshot {
        guard let session else {
            return .init(consumed: consumed, preedit: "", candidates: [], highlightedIndex: 0, commit: nil)
        }

        let commit = rawCommit ?? takeString(lf_rime_session_take_commit(session))
        var context = LFRimeSnapshot()
        guard lf_rime_session_copy_snapshot(session, Int32(activePageSize), &context) != 0 else {
            return .init(consumed: consumed, preedit: "", candidates: [], highlightedIndex: 0, commit: commit)
        }
        defer { lf_rime_snapshot_free(&context) }
        var candidates: [RimeCandidate] = []
        if let input = context.candidates {
            candidates.reserveCapacity(Int(context.count))
            for index in 0..<Int(context.count) {
                let candidate = input[index]
                guard let text = candidate.text else { continue }
                candidates.append(RimeCandidate(
                    text: String(cString: text),
                    comment: candidate.comment.map { String(cString: $0) }
                ))
            }
        }
        let result = RimeSnapshot(
            consumed: consumed,
            preedit: context.preedit.map { String(cString: $0) } ?? "",
            cursorByteOffset: Int(context.cursor_byte_offset),
            candidates: candidates,
            highlightedIndex: max(0, Int(context.highlighted_index)),
            commit: commit,
            pageNumber: max(0, Int(context.page_number)),
            isLastPage: context.is_last_page != 0
        )
        isComposing = !result.preedit.isEmpty
        candidateCount = result.candidates.count
        pageNumber = result.pageNumber
        isLastPage = result.isLastPage
        return result
    }

    private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { lf_rime_string_free(pointer) }
        return String(cString: pointer)
    }
}
