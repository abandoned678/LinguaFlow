import XCTest
@testable import LinguaFlowCore

private actor ControlledTranslationProvider: TranslationProviding {
    private var continuations: [UInt64: CheckedContinuation<String, Error>] = [:]

    func translate(_ request: TranslationRequest) async throws -> String {
        let key = request.sourceText == "新请求" ? 2 : request.revision
        return try await withCheckedThrowingContinuation { continuation in
            continuations[key] = continuation
        }
    }

    func complete(revision: UInt64, with text: String) {
        continuations.removeValue(forKey: revision)?.resume(returning: text)
    }

    func fail(revision: UInt64) {
        continuations.removeValue(forKey: revision)?.resume(throwing: CocoaError(.fileReadUnknown))
    }

    func waitUntilRequested(revision: UInt64) async {
        while continuations[revision] == nil {
            await Task.yield()
        }
    }
}

@MainActor
final class TranslationCoordinatorTests: XCTestCase {
    func testOnlyPublishesTheNewestRevision() async {
        let provider = ControlledTranslationProvider()
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        var results: [TranslationResult] = []
        coordinator.onResult = { results.append($0) }

        coordinator.submit(.init(text: "第一句", revision: 1, isFinal: false))
        await provider.waitUntilRequested(revision: 1)
        coordinator.submit(.init(text: "第二句", revision: 2, isFinal: false))
        await provider.waitUntilRequested(revision: 2)

        await provider.complete(revision: 1, with: "stale")
        await provider.complete(revision: 2, with: "the second sentence")

        for _ in 0..<20 where results.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(results, [
            .init(sourceText: "第二句", translatedText: "the second sentence", revision: 2),
        ])
    }

    func testCancelledRequestCannotPublishErrorAfterRevisionIsReused() async {
        let old = ControlledTranslationProvider()
        let coordinator = TranslationCoordinator(provider: old, debounce: .zero)
        var errors = 0
        coordinator.onError = { _ in errors += 1 }
        coordinator.submit(.init(text: "旧请求", revision: 1, isFinal: false))
        await old.waitUntilRequested(revision: 1)
        coordinator.cancel()
        coordinator.submit(.init(text: "新请求", revision: 1, isFinal: false))
        await old.fail(revision: 1)
        await old.waitUntilRequested(revision: 2)
        await old.complete(revision: 2, with: "new")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(errors, 0)
    }

    func testCancelPreventsALateResultFromPublishing() async {
        let provider = ControlledTranslationProvider()
        let coordinator = TranslationCoordinator(provider: provider, debounce: .zero)
        var results: [TranslationResult] = []
        coordinator.onResult = { results.append($0) }

        coordinator.submit(.init(text: "私密内容", revision: 9, isFinal: false))
        await provider.waitUntilRequested(revision: 9)
        coordinator.cancel()
        await provider.complete(revision: 9, with: "private content")

        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertTrue(results.isEmpty)
    }
}
