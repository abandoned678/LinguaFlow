import Foundation
import OSLog

public struct TranslationRequest: Equatable, Sendable {
    public let id: UUID
    public let sourceText: String
    public let revision: UInt64
    public let lifecycle: UInt64
    public let submittedAt: ContinuousClock.Instant

    public init(sourceText: String, revision: UInt64, lifecycle: UInt64 = 0) {
        self.id = UUID()
        self.sourceText = sourceText
        self.revision = revision
        self.lifecycle = lifecycle
        self.submittedAt = .now
    }
}

public struct TranslationResult: Equatable, Sendable {
    public let sourceText: String
    public let translatedText: String
    public let revision: UInt64

    public init(sourceText: String, translatedText: String, revision: UInt64) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.revision = revision
    }
}

public enum TranslationFailure: Error, Equatable, Sendable {
    case modelsNotInstalled, unavailable, failed, timedOut

    public var message: String {
        switch self {
        case .modelsNotInstalled: "本地翻译模型未准备，请在输入法设置中准备"
        case .unavailable: "当前系统无法使用本地翻译"
        case .failed: "翻译失败，可重试"
        case .timedOut: "翻译超时，可重试"
        }
    }

    public var canRetry: Bool { self == .failed || self == .timedOut }
}

public protocol TranslationProviding: Sendable {
    func translate(_ request: TranslationRequest) async throws -> String
    func cancel(_ request: TranslationRequest) async
}

public extension TranslationProviding {
    func cancel(_ request: TranslationRequest) async {}
}

public enum TranslationTrigger: String, Sendable {
    case input, candidate, committedPunctuation, retry

    public static func compositionUpdate(
        commit: String?,
        previousPreedit: String,
        preedit: String,
        highlightChanged: Bool
    ) -> Self {
        if let last = commit?.last, "。！？!?".contains(last) {
            return .committedPunctuation
        }
        if commit == nil, preedit == previousPreedit, highlightChanged {
            return .candidate
        }
        return .input
    }

    public func delay(speed: InputSettings.Speed) -> Duration {
        switch (self, speed) {
        case (.input, .fast), (.candidate, .balanced): .milliseconds(120)
        case (.input, .balanced): .milliseconds(200)
        case (.input, .efficient): .milliseconds(400)
        case (.candidate, .fast): .milliseconds(80)
        case (.candidate, .efficient): .milliseconds(250)
        case (.committedPunctuation, _), (.retry, _): .zero
        }
    }
}

@MainActor
public final class TranslationCoordinator {
    public enum State: Equatable {
        case hidden
        case waiting(TranslationRequest)
        case translating(TranslationRequest)
        case ready(TranslationRequest, TranslationResult)
        case failed(TranslationRequest, TranslationFailure)

        var request: TranslationRequest? {
            switch self {
            case .hidden: nil
            case .waiting(let request), .translating(let request),
                 .ready(let request, _), .failed(let request, _): request
            }
        }
    }

    private struct Pending {
        let request: TranslationRequest
        var trigger: TranslationTrigger
        var eligible = false
    }

    private struct Active {
        let request: TranslationRequest
        let task: Task<Void, Never>
        let timeout: Task<Void, Never>
    }

    // A coordinator is scoped to one language direction and one provider policy.
    // The cache cannot cross either boundary, even when source text is identical.
    private struct CacheEntry {
        let text: String
        let translation: String
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public var onStateChange: ((State) -> Void)?
    public private(set) var state: State = .hidden
    public private(set) var isEnabled = true
    public var speed: InputSettings.Speed = .balanced

    private let provider: any TranslationProviding
    private let fixedDebounce: Duration?
    private let timeout: Duration
    private let sleep: Sleep
    private let logger = Logger(subsystem: "com.abandoned678.inputmethod.SentenceAlong", category: "Translation")
    private var lifecycle: UInt64 = 0
    private var pending: Pending?
    private var debounceTask: Task<Void, Never>?
    private var active: Active?
    private var retiring = Set<UUID>()
    private var modelFailure: TranslationFailure?
    private var cache: [CacheEntry] = []

    public init(
        provider: any TranslationProviding,
        debounce: Duration? = nil,
        timeout: Duration = .seconds(3),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.provider = provider
        self.fixedDebounce = debounce
        self.timeout = timeout
        self.sleep = sleep
    }

    deinit {
        debounceTask?.cancel()
        active?.timeout.cancel()
        active?.task.cancel()
        if let request = active?.request {
            let provider = self.provider
            Task { await provider.cancel(request) }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled { cancel() }
    }

    public func submit(_ snapshot: SentenceSnapshot, trigger: TranslationTrigger = .input) {
        guard isEnabled else { return }
        if trigger != .retry, let current = state.request, current.sourceText == snapshot.text {
            if trigger == .committedPunctuation, let queued = pending, queued.request.id == current.id {
                pending?.trigger = .committedPunctuation
                debounceElapsed(for: current.id)
            }
            return
        }

        debounceTask?.cancel()
        pending = nil
        let request = TranslationRequest(sourceText: snapshot.text, revision: snapshot.revision, lifecycle: lifecycle)
        if let index = cache.firstIndex(where: { $0.text == snapshot.text }) {
            let cached = cache.remove(at: index)
            cache.append(cached)
            logger.debug("outcome=cacheHit trigger=\(trigger.rawValue, privacy: .public)")
            publish(.ready(request, result(for: request, text: cached.translation)))
            return
        }
        if let modelFailure {
            publish(.failed(request, modelFailure))
            return
        }

        pending = Pending(request: request, trigger: trigger)
        publish(.waiting(request))
        guard pending?.request.id == request.id else { return }
        let delay = trigger == .committedPunctuation || trigger == .retry
            ? .zero : fixedDebounce ?? trigger.delay(speed: speed)
        guard delay > .zero else {
            debounceElapsed(for: request.id)
            return
        }
        debounceTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.debounceElapsed(for: request.id)
        }
    }

    public func retry() {
        guard case .failed(let request, let reason) = state, reason.canRetry else { return }
        submit(.init(text: request.sourceText, revision: request.revision, isFinal: false), trigger: .retry)
    }

    public func modelStatusDidChange() {
        guard modelFailure != nil else { return }
        modelFailure = nil
        guard let request = state.request else { return }
        submit(.init(text: request.sourceText, revision: request.revision, isFinal: false), trigger: .retry)
    }

    public func cancel() {
        lifecycle &+= 1
        pending = nil
        debounceTask?.cancel()
        debounceTask = nil
        cache.removeAll()
        retireActive()
        publish(.hidden)
    }

    private func debounceElapsed(for id: UUID) {
        guard pending?.request.id == id else { return }
        debounceTask?.cancel()
        debounceTask = nil
        pending?.eligible = true
        startIfPossible()
    }

    private func startIfPossible() {
        guard isEnabled, active == nil, retiring.count < 2, let pending, pending.eligible else { return }
        self.pending = nil
        let request = pending.request
        let startedAt = ContinuousClock.now
        let queueDelay = request.submittedAt.duration(to: startedAt).components
        let queueMilliseconds = queueDelay.seconds * 1_000 + queueDelay.attoseconds / 1_000_000_000_000_000
        let length = request.sourceText.count
        let lengthBucket = length <= 20 ? "1–20" : length <= 80 ? "21–80" : "81–280"
        let trigger = pending.trigger.rawValue
        let work = Task { [weak self, provider, logger] in
            let outcome: Result<String, Error>
            do {
                try Task.checkCancellation()
                logger.debug("stage=request trigger=\(trigger, privacy: .public) length=\(lengthBucket, privacy: .public) queueMS=\(queueMilliseconds)")
                outcome = .success(try await provider.translate(request))
            } catch {
                outcome = .failure(error)
            }
            self?.finish(request, outcome: outcome, startedAt: startedAt)
        }
        let timeout = Task { [weak self, sleep, timeout] in
            do { try await sleep(timeout) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expire(request)
        }
        active = Active(request: request, task: work, timeout: timeout)
        publish(.translating(request))
    }

    private func finish(_ request: TranslationRequest, outcome: Result<String, Error>, startedAt: ContinuousClock.Instant) {
        if retiring.remove(request.id) != nil {
            startIfPossible()
            return
        }
        guard active?.request.id == request.id else { return }
        active?.timeout.cancel()
        active = nil
        let duration = startedAt.duration(to: .now).components
        let elapsed = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
        guard isCurrent(request) else {
            startIfPossible()
            return
        }

        if case .failure(let error) = outcome, let reason = error as? TranslationFailure,
           reason == .modelsNotInstalled || reason == .unavailable {
            modelFailure = reason
            publish(.failed(request, reason))
        } else {
            if case .success(let text) = outcome, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if cache.count == 32 { cache.removeFirst() }
                cache.append(CacheEntry(text: request.sourceText, translation: text))
                logger.debug("outcome=ready modelMS=\(elapsed)")
                publish(.ready(request, result(for: request, text: text)))
            } else {
                logger.debug("outcome=failed modelMS=\(elapsed)")
                publish(.failed(request, .failed))
            }
        }
        startIfPossible()
    }

    private func expire(_ request: TranslationRequest) {
        guard active?.request.id == request.id else { return }
        retireActive()
        logger.debug("outcome=timeout")
        if isCurrent(request) { publish(.failed(request, .timedOut)) }
        startIfPossible()
    }

    private func retireActive() {
        guard let active else { return }
        self.active = nil
        retiring.insert(active.request.id)
        active.timeout.cancel()
        active.task.cancel()
        logger.debug("outcome=cancelled")
        let provider = self.provider
        Task { await provider.cancel(active.request) }
    }

    private func isCurrent(_ request: TranslationRequest) -> Bool {
        isEnabled && request.lifecycle == lifecycle && state.request == request
    }

    private func result(for request: TranslationRequest, text: String) -> TranslationResult {
        .init(sourceText: request.sourceText, translatedText: text, revision: request.revision)
    }

    private func publish(_ value: State) {
        guard state != value else { return }
        state = value
        onStateChange?(value)
    }
}
