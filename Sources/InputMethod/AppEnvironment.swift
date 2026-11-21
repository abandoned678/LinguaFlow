import Foundation
import InputCore
import OSLog
import RimeInput

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    private let logger = Logger(subsystem: "com.abandoned678.inputmethod.SentenceAlong", category: "Rime")
    private var runtime: RimeRuntime?
    private var didStart = false
    private(set) var health = EngineHealth(state: .preparing)

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        publish(.preparing)

        guard let sharedData = Bundle.main.resourceURL?.appendingPathComponent("Rime", isDirectory: true),
              FileManager.default.isReadableFile(atPath: sharedData.appendingPathComponent("luna_pinyin_simp.schema.yaml").path) else {
            publish(.missingResources)
            return
        }

        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let userData = appSupport
                .appendingPathComponent(InputSettingsStore.productDirectory, isDirectory: true)
                .appendingPathComponent("Rime", isDirectory: true)
            runtime = try RimeRuntime(sharedDataDirectory: sharedData, userDataDirectory: userData)
            publish(.available)
        } catch {
            publish(.startupFailed)
        }
    }

    func makeEngine() -> RimeEngine? {
        guard let runtime else { return nil }
        let start = ContinuousClock.now
        do {
            let engine = try RimeEngine(runtime: runtime)
            let duration = start.duration(to: .now).components
            let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            logger.debug("stage=sessionCreation elapsedMS=\(elapsed)")
            if health.state != .available || health.sessionMS == nil { publish(.available, sessionMS: elapsed) }
            return engine
        } catch RimeEngineError.schemaUnavailable {
            if health.state != .schemaUnavailable { publish(.schemaUnavailable) }
            return nil
        } catch {
            if health.state != .sessionFailed { publish(.sessionFailed) }
            return nil
        }
    }

    private func publish(_ state: EngineHealth.State, sessionMS: Double? = nil) {
        health = EngineHealth(
            state: state, initializationMS: runtime?.timings.initializationMS,
            maintenanceMS: runtime?.timings.maintenanceMS, sessionMS: sessionMS
        )
        logger.info("state=\(state.rawValue, privacy: .public)")
        if let runtime {
            logger.debug("stage=initialization elapsedMS=\(runtime.timings.initializationMS) maintenanceMS=\(runtime.timings.maintenanceMS)")
        }
        do {
            try health.write()
        } catch {
            logger.error("Unable to save engine diagnostics")
        }
    }
}
