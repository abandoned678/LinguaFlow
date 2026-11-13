import Foundation
import Translation

@main
struct TranslationChecks {
    static func main() async throws {
        let source = Locale.Language(identifier: "zh-Hans")
        let target = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: source, to: target)

        switch status {
        case .installed:
            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate("你好，很高兴认识你。")
            let reverseSession = TranslationSession(installedSource: target, target: source)
            let reverseResponse = try await reverseSession.translate("Hello, nice to meet you.")
            print("Apple Translation checks passed: \(response.targetText) / \(reverseResponse.targetText)")
        case .supported:
            print("Apple Translation models are supported but not installed")
            exit(2)
        case .unsupported:
            print("Apple Translation language pair is unsupported")
            exit(1)
        @unknown default:
            print("Apple Translation status is unknown")
            exit(1)
        }
    }
}
