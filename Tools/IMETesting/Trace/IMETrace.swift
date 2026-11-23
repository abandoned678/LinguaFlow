import Foundation
import CoreGraphics

public enum TraceRole: String, Codable, Sendable { case ime, host }
public enum TraceStage: String, Codable, Sendable {
    case hostLaunched, hostSelectedSource, focused, lostFocus, activated, key, candidateMatched, commitRequested, marked, inserted
    case middleInsertion, middleDeletion, markEnded, switchPending, directionApplied
    case documentMatched, documentMismatch, stopped, overflow, translationReady, translationUnavailable, translationFailed, translatedDocument, undoRestored, mouseSelected
}

public struct TraceRun: Codable, Sendable {
    public static let imeID = "com.abandoned678.inputmethod.SentenceAlongDebug"
    public static let hostID = imeID + ".Host"
    public static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SentenceAlongDebug/Tests", isDirectory: true)
    public static let active = root.appendingPathComponent("active.json")
    public let id: UUID
    public let build: String
    public let scenario: String
    public let deadline: Date
    public init(build: String, scenario: String, lifetime: TimeInterval = 90) {
        id = UUID()
        self.build = build
        self.scenario = scenario
        deadline = Date().addingTimeInterval(lifetime)
    }
    public var directory: URL { Self.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func validate(at now: Date) throws {
        guard deadline > now else { throw CocoaError(.userCancelled) }
    }
    public static func current() throws -> Self {
        let run = try JSONDecoder().decode(Self.self, from: Data(contentsOf: active))
        try run.validate(at: Date())
        return run
    }
}

public struct TraceEvent: Codable, Sendable {
    public let run: UUID
    public let session: UUID
    public let role: TraceRole
    public let index: Int
    public let stage: TraceStage
    public var clickPoint: CGPoint? = nil
}

// Each process owns its stream. Event files become visible only after an atomic write.
@MainActor
public final class TraceWriter {
    public let run: TraceRun
    private let role: TraceRole
    private let session = UUID()
    private let queue = DispatchQueue(label: "SentenceAlong.trace-writer")
    private var index = 0
    public init(run: TraceRun, role: TraceRole) {
        self.run = run
        self.role = role
    }

    public func record(_ stage: TraceStage, clickPoint: CGPoint? = nil) {
        guard run.deadline > Date(), index <= 256 else { return }
        let event = TraceEvent(run: run.id, session: session, role: role, index: index,
                               stage: index == 256 ? .overflow : stage, clickPoint: clickPoint)
        index += 1
        let directory = run.directory
        queue.async {
            let url = directory.appendingPathComponent("\(event.session)-\(event.index).json")
            do { try JSONEncoder().encode(event).write(to: url, options: .atomic) }
            catch { fputs("IMETrace: event write failed\n", stderr) }
        }
    }
}

public struct TraceEvidence {
    public let events: [TraceEvent]
    public init(directory: URL, run: UUID) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try self.init(events: files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(TraceEvent.self, from: Data(contentsOf: $0))
        }, run: run)
    }

    public init(events: [TraceEvent], run: UUID) throws {
        guard events.allSatisfy({ $0.run == run && $0.stage != .overflow }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for stream in Dictionary(grouping: events, by: \.session).values {
            let indices = stream.map(\.index).sorted()
            guard indices == Array(0..<stream.count), Set(stream.map(\.role)).count == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        self.events = events.sorted { $0.index < $1.index }
    }

    public func count(_ stage: TraceStage, from role: TraceRole) -> Int {
        events.filter { $0.role == role && $0.stage == stage }.count
    }

    public var pinyinCommitted: Bool {
        for stream in Dictionary(grouping: events.filter { $0.role == .ime }, by: \.session).values {
            let stages = stream.map(\.stage)
            guard stages.first == .activated, let commit = stages.firstIndex(of: .commitRequested),
                  let space = stages[..<commit].lastIndex(of: .key),
                  let candidate = stages[..<space].lastIndex(of: .candidateMatched),
                  stages[..<candidate].filter({ $0 == .key }).count == 5,
                  stages[..<commit].filter({ $0 == .key }).count == 6 else { continue }
            let host = events.filter { $0.role == .host }
            guard Set(host.map(\.session)).count == 1 else { return false }
            let edits = host.map(\.stage)
            return count(.commitRequested, from: .ime) == 1 && count(.inserted, from: .host) == 1
                && edits.contains(.focused) && edits.last == .documentMatched
                && edits.firstIndex(of: .marked).map { $0 < (edits.firstIndex(of: .inserted) ?? 0) } == true
        }
        return false
    }
}
