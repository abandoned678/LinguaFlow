import Foundation
import InputCore
@preconcurrency import Translation

public enum LocalTranslationModels {
    public static let statusDidChange = Notification.Name(InputSettingsStore.domain + ".modelsDidChange")

    public static func configuration(for direction: TranslationDirection) -> TranslationSession.Configuration {
        let (source, target) = languages(for: direction)
        if #available(macOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return .init(source: source, target: target)
    }

    static func installedSession(for direction: TranslationDirection) -> TranslationSession {
        let (source, target) = languages(for: direction)
        if #available(macOS 26.4, *) {
            return .init(installedSource: source, target: target, preferredStrategy: .lowLatency)
        }
        return .init(installedSource: source, target: target)
    }

    public static func verify(_ direction: TranslationDirection) async throws {
        let sample = direction == .chineseToEnglish ? "你好，很高兴认识你。" : "Hello, nice to meet you."
        let provider = OnDeviceTranslationProvider(direction: direction)
        let request = TranslationRequest(sourceText: sample, revision: 0)
        try await withTaskCancellationHandler {
            _ = try await provider.translate(request)
        } onCancel: {
            Task { await provider.cancel(request) }
        }
    }

    public static func classify(_ error: Error) -> Error {
        switch error {
        case is CancellationError, TranslationError.alreadyCancelled: CancellationError()
        case TranslationError.notInstalled: TranslationFailure.modelsNotInstalled
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing: TranslationFailure.unavailable
        case let failure as TranslationFailure: failure
        default: TranslationFailure.failed
        }
    }

    private static func languages(for direction: TranslationDirection) -> (Locale.Language, Locale.Language) {
        (.init(identifier: direction.sourceLanguageIdentifier), .init(identifier: direction.targetLanguageIdentifier))
    }
}

public actor OnDeviceTranslationProvider: TranslationProviding {
    private let direction: TranslationDirection
    private var idle: TranslationSession?
    private var sessions: [UUID: TranslationSession] = [:]

    public init(direction: TranslationDirection) {
        self.direction = direction
    }

    public func translate(_ request: TranslationRequest) async throws -> String {
        try await withSession(id: request.id) { session in
            let text = try await session.translate(request.sourceText).targetText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationFailure.failed
            }
            return text
        }
    }

    public func translateCandidates(_ words: [String]) async throws -> [String: String] {
        guard !words.isEmpty else { return [:] }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withSession(id: id) { session in
                let requests = words.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let responses = try await session.translations(from: requests)
                var translations: [String: String] = [:]
                for response in responses {
                    guard let identifier = response.clientIdentifier, let index = Int(identifier),
                          words.indices.contains(index) else { continue }
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { translations[words[index].lowercased()] = text }
                }
                return translations
            }
        } onCancel: {
            Task { await self.cancelSession(id: id) }
        }
    }

    public func cancel(_ request: TranslationRequest) {
        cancelSession(id: request.id)
    }

    private func cancelSession(id: UUID) {
        sessions.removeValue(forKey: id)?.cancel()
    }

    private func withSession<Value>(
        id: UUID,
        _ operation: (TranslationSession) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let session = idle ?? LocalTranslationModels.installedSession(for: direction)
        idle = nil
        sessions[id] = session
        do {
            let ready = await session.isReady
            try Task.checkCancellation()
            guard sessions[id] != nil else { throw CancellationError() }
            guard ready else {
                let configuration = LocalTranslationModels.configuration(for: direction)
                if let source = configuration.source {
                    let availability: LanguageAvailability
                    if #available(macOS 26.4, *) {
                        availability = LanguageAvailability(preferredStrategy: configuration.preferredStrategy)
                    } else {
                        availability = LanguageAvailability()
                    }
                    if await availability.status(from: source, to: configuration.target) == .unsupported {
                        throw TranslationFailure.unavailable
                    }
                }
                throw TranslationFailure.modelsNotInstalled
            }
            let result = try await operation(session)
            try Task.checkCancellation()
            guard sessions.removeValue(forKey: id) != nil else { throw CancellationError() }
            idle = session
            return result
        } catch {
            cancelSession(id: id)
            throw LocalTranslationModels.classify(error)
        }
    }
}
