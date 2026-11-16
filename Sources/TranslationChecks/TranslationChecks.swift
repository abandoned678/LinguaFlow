import Darwin
import InputCore
import LocalTranslation

@main
struct TranslationChecks {
    static func main() async {
        if CommandLine.arguments.contains("--benchmark") {
            do {
                try await PreviewBenchmark.run()
                return
            } catch TranslationFailure.modelsNotInstalled {
                print("Benchmark needs the installed Chinese-to-English model")
                exit(2)
            } catch {
                let reason = (error as? TranslationFailure)?.message ?? "翻译测量已取消"
                print("Benchmark failed: \(reason)")
                exit(1)
            }
        }
        var status: Int32 = 0
        for direction in [TranslationDirection.chineseToEnglish, .englishToChinese] {
            do {
                try await LocalTranslationModels.verify(direction)
                print("\(direction.rawValue): ready")
            } catch TranslationFailure.modelsNotInstalled {
                print("\(direction.rawValue): modelsNotInstalled")
                if status == 0 { status = 2 }
            } catch {
                let reason = (error as? TranslationFailure)?.message ?? "翻译检查已取消"
                print("\(direction.rawValue): \(reason)")
                status = 1
            }
        }
        if status != 0 { exit(status) }
    }
}
