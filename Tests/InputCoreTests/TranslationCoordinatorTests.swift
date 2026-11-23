import XCTest
@testable import InputCore

private actor ControlledTranslationProvider: TranslationProviding {
    private var continuations: [UUID: CheckedContinuation<String, Error>] = [:]
    private var requested: [TranslationRequest] = []
    private var cancellations: [UUID] = []

    func translate(_ request: TranslationRequest) async throws -> String {
        requested.append(request)
        return try await withCheckedThrowingContinuation { continuations[request.id] = $0 }
    }

    func cancel(_ request: TranslationRequest) async {
        cancellations.append(request.id)
    }

    func request(at index: Int) async throws -> TranslationRequest {
        let deadline = ContinuousClock.now + .seconds(2)
        while !requested.indices.contains(index) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
        return requested[index]
    }

    func finish(_ request: TranslationRequest, with result: Result<String, Error>) {
        continuations.removeValue(forKey: request.id)?.resume(with: result)
    }

    func finishRemaining() {
        for continuation in continuations.values {
            continuation.resume(throwing: CancellationError())
        }
        continuations.removeAll()
    }

    func observedInputs() -> [String] { requested.map(\.sourceText) }
    func cancelledRequests() -> [UUID] { cancellations }
}

@MainActor
final class TranslationCoordinatorTests: XCTestCase {
    func testNewInputRetainsOnlyLatestWaitingRequest() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        let result = expectation(description: "latest translation")
        coordinator.onStateChange = { state in
            if case .ready(_, let response) = state {
                XCTAssertEqual(response.translatedText, "latest")
                result.fulfill()
            }
        }

        coordinator.submit(.init(text: "第一句", revision: 1, isFinal: false))
        let first = try await provider.request(at: 0)
        coordinator.submit(.init(text: "第二句", revision: 2, isFinal: false))
        coordinator.submit(.init(text: "第三句", revision: 3, isFinal: false))
        await provider.finish(first, with: .success("stale"))
        let last = try await provider.request(at: 1)
        XCTAssertEqual(last.sourceText, "第三句")
        await provider.finish(last, with: .success("latest"))
        await fulfillment(of: [result], timeout: 2)
        let inputs = await provider.observedInputs()
        XCTAssertEqual(inputs, ["第一句", "第三句"])
    }

    func testClosingAndReopeningRejectsLateErrorAndUsesNewRequestIdentity() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        let result = expectation(description: "translation after reopening")
        coordinator.onStateChange = { state in
            if case .failed = state { XCTFail("Cancelled error escaped") }
            if case .ready(_, let response) = state {
                XCTAssertEqual(response.translatedText, "new")
                result.fulfill()
            }
        }

        coordinator.submit(.init(text: "同一句", revision: 1, isFinal: false))
        let old = try await provider.request(at: 0)
        coordinator.setEnabled(false)
        XCTAssertEqual(coordinator.state, .hidden)
        coordinator.submit(.init(text: "关闭期间", revision: 2, isFinal: false))
        coordinator.setEnabled(true)
        coordinator.submit(.init(text: "同一句", revision: 1, isFinal: false))
        await provider.finish(old, with: .failure(CocoaError(.fileReadUnknown)))
        let new = try await provider.request(at: 1)
        XCTAssertNotEqual(old.id, new.id)
        await provider.finish(new, with: .success("new"))
        await fulfillment(of: [result], timeout: 2)
        let inputs = await provider.observedInputs()
        XCTAssertEqual(inputs, ["同一句", "同一句"])
    }
}

private actor ManualTranslationClock {
    private struct Wait {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiting: [UUID: Wait] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                waiting[id] = Wait(duration: duration, continuation: $0)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func awaitTimer(_ duration: Duration) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !waiting.values.contains(where: { $0.duration == duration }) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
    }

    func fire(_ duration: Duration) async throws {
        try await awaitTimer(duration)
        let timer = try XCTUnwrap(waiting.first { $0.value.duration == duration }?.key)
        waiting.removeValue(forKey: timer)?.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
extension TranslationCoordinatorTests {
    func testTriggerDelaysAndOnlyCommittedPunctuationFinalizesImmediately() {
        for (speed, ordinary, candidate) in [
            (InputSettings.Speed.fast, 120, 80), (.balanced, 200, 120), (.efficient, 400, 250),
        ] {
            XCTAssertEqual(TranslationTrigger.input.delay(speed: speed), .milliseconds(ordinary))
            XCTAssertEqual(TranslationTrigger.candidate.delay(speed: speed), .milliseconds(candidate))
            XCTAssertEqual(TranslationTrigger.committedPunctuation.delay(speed: speed), .zero)
        }
        XCTAssertEqual(
            TranslationTrigger.compositionUpdate(commit: "。", previousPreedit: "", preedit: "", highlightChanged: false),
            .committedPunctuation
        )
        XCTAssertEqual(
            TranslationTrigger.compositionUpdate(commit: ".", previousPreedit: "", preedit: "", highlightChanged: false),
            .committedPunctuation
        )
        XCTAssertEqual(
            TranslationTrigger.compositionUpdate(commit: nil, previousPreedit: "ni", preedit: "ni", highlightChanged: true),
            .candidate
        )
        XCTAssertEqual(
            TranslationTrigger.compositionUpdate(commit: "\n", previousPreedit: "", preedit: "", highlightChanged: false),
            .input
        )
    }

    func testFinalizationPromotesExistingDebounceAndSameTextIsNotRequestedTwice() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let clock = ManualTranslationClock()
        let coordinator = TranslationCoordinator(provider: provider, sleep: { try await clock.sleep($0) })
        coordinator.submit(.init(text: "你好！", revision: 1, isFinal: false))
        try await clock.awaitTimer(.milliseconds(200))
        let before = await provider.observedInputs()
        XCTAssertTrue(before.isEmpty)
        coordinator.submit(.init(text: "你好！", revision: 2, isFinal: true), trigger: .committedPunctuation)
        let request = try await provider.request(at: 0)
        coordinator.submit(.init(text: "你好！", revision: 2, isFinal: true))
        await provider.finish(request, with: .success("Hello!"))
        try await waitForState(coordinator) { if case .ready = $0 { true } else { false } }
        let after = await provider.observedInputs()
        XCTAssertEqual(after, ["你好！"])
    }

    func testClosingWhileDebouncingNeverCallsProvider() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let clock = ManualTranslationClock()
        let coordinator = TranslationCoordinator(provider: provider, sleep: { try await clock.sleep($0) })
        coordinator.submit(.init(text: "你好", revision: 1, isFinal: false))
        try await clock.awaitTimer(.milliseconds(200))
        coordinator.setEnabled(false)
        coordinator.submit(.init(text: "已关闭", revision: 2, isFinal: false))
        let inputs = await provider.observedInputs()
        XCTAssertEqual(inputs, [])
        XCTAssertEqual(coordinator.state, .hidden)
    }

    func testTimeoutRetryAndOldSuccessCannotOverwriteNewResult() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let clock = ManualTranslationClock()
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero, sleep: { try await clock.sleep($0) })
        coordinator.submit(.init(text: "你好", revision: 1, isFinal: false))
        let first = try await provider.request(at: 0)
        try await clock.fire(.seconds(3))
        try await waitForState(coordinator) { $0 == .failed(first, .timedOut) }

        coordinator.retry()
        let second = try await provider.request(at: 1)
        XCTAssertNotEqual(first.id, second.id)
        await provider.finish(second, with: .success("Hello"))
        let expected = TranslationCoordinator.State.ready(second, .init(sourceText: "你好", translatedText: "Hello", revision: 1))
        try await waitForState(coordinator) { $0 == expected }
        await provider.finish(first, with: .success("stale"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(coordinator.state, expected)
        let cancelled = await provider.cancelledRequests()
        XCTAssertEqual(cancelled, [first.id])
    }

    func testCacheUsesCurrentRevisionAndIsPurgedOnContextClear() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        for (index, text) in ["你好", "再见"].enumerated() {
            coordinator.submit(.init(text: text, revision: UInt64(index), isFinal: false))
            let request = try await provider.request(at: index)
            await provider.finish(request, with: .success("translated"))
            try await waitForState(coordinator) { if case .ready = $0 { true } else { false } }
        }
        coordinator.submit(.init(text: "你好", revision: 10, isFinal: false))
        guard case .ready(let request, let result) = coordinator.state else { return XCTFail("Expected immediate cache hit") }
        XCTAssertEqual(request.revision, 10)
        XCTAssertEqual(result.revision, 10)
        coordinator.cancel()
        coordinator.submit(.init(text: "你好", revision: 11, isFinal: false))
        let uncached = try await provider.request(at: 2)
        XCTAssertEqual(uncached.revision, 11)
    }

    func testRetriesOnlyWhenMissingModelStatusChanges() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        coordinator.submit(.init(text: "你好", revision: 1, isFinal: false))
        let first = try await provider.request(at: 0)
        await provider.finish(first, with: .failure(TranslationFailure.modelsNotInstalled))
        try await waitForState(coordinator) { $0 == .failed(first, .modelsNotInstalled) }
        coordinator.submit(.init(text: "今天", revision: 2, isFinal: false))
        guard case .failed(_, .modelsNotInstalled) = coordinator.state else {
            return XCTFail("Expected the model failure without rescheduling")
        }
        coordinator.modelStatusDidChange()
        let second = try await provider.request(at: 1)
        XCTAssertEqual(second.sourceText, "今天")
    }

    func testCacheEvictsLeastRecentlyUsedEntry() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        for index in 0...32 {
            if index == 32 {
                coordinator.submit(.init(text: "句子 0", revision: 40, isFinal: false))
                guard case .ready(let request, _) = coordinator.state, request.revision == 40 else {
                    return XCTFail("Expected recently used item")
                }
            }
            coordinator.submit(.init(text: "句子 \(index)", revision: UInt64(index), isFinal: false))
            let request = try await provider.request(at: index)
            await provider.finish(request, with: .success("synthetic"))
            try await waitForState(coordinator) {
                if case .ready(let current, _) = $0 { return current.id == request.id }
                return false
            }
        }
        coordinator.submit(.init(text: "句子 0", revision: 41, isFinal: false))
        guard case .ready(let cached, _) = coordinator.state, cached.revision == 41 else {
            return XCTFail("Expected item retained by the recent cache hit")
        }
        coordinator.submit(.init(text: "句子 1", revision: 42, isFinal: false))
        let evicted = try await provider.request(at: 33)
        XCTAssertEqual(evicted.sourceText, "句子 1")
    }

    func testEmptyTranslationIsNotCached() async throws {
        let provider = ControlledTranslationProvider()
        addTeardownBlock { await provider.finishRemaining() }
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        coordinator.submit(.init(text: "你好", revision: 1, isFinal: false))
        let first = try await provider.request(at: 0)
        await provider.finish(first, with: .success(" "))
        try await waitForState(coordinator) { $0 == .failed(first, .failed) }
        coordinator.submit(.init(text: "再见", revision: 2, isFinal: false))
        let second = try await provider.request(at: 1)
        await provider.finish(second, with: .success("Goodbye"))
        try await waitForState(coordinator) { if case .ready = $0 { true } else { false } }
        coordinator.submit(.init(text: "你好", revision: 3, isFinal: false))
        let uncached = try await provider.request(at: 2)
        XCTAssertEqual(uncached.revision, 3)
    }

    private func waitForState(
        _ coordinator: TranslationCoordinator,
        matching predicate: (TranslationCoordinator.State) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(coordinator.state) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Expected translation state transition")
                throw CocoaError(.fileReadUnknown)
            }
            await Task.yield()
        }
    }
}
