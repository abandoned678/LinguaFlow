import Foundation
import InputCore
import OSLog
import RimeInput
#if DEBUG && IME_TEST_BUILD
import IMETrace
#endif

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    private let logger = Logger(subsystem: "com.abandoned678.inputmethod.SentenceAlong", category: "Rime")
    private var runtime: RimeRuntime?
    private var didStart = false
    private let dailyEngines = NSHashTable<RimeEngine>.weakObjects()
    private var needsDictionaryReload = false
    private var phraseRevision: PersonalDictionary.Revision?
    private var unavailableSchemas = Set<String>()
    private var dictionaryObserver: NSObjectProtocol?
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
            do { try PersonalDictionary.shared.clearLearningIfRequested() }
            catch { needsDictionaryReload = true; logger.error("Learning reset deferred") }
            runtime = try RimeRuntime(sharedDataDirectory: sharedData, userDataDirectory: userData)
            phraseRevision = PersonalDictionary.shared.revision
            dictionaryObserver = DistributedNotificationCenter.default().addObserver(
                forName: PersonalDictionary.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.checkDictionaryChanges()
                }
            }
            publish(.available)
        } catch {
            publish(.startupFailed)
        }
    }

    func makeEngine(schema: String, clientBundleID: String?) -> RimeEngine? {
        guard let runtime else { return nil }
        let start = ContinuousClock.now
        do {
            #if DEBUG && IME_TEST_BUILD
            if isTestHost(clientBundleID) { return try RimeEngine(runtime: runtime, schema: "sentencealong_fixture") }
            #endif
            let engine = try RimeEngine(runtime: runtime, schema: schema)
            dailyEngines.add(engine)
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

    private func isTestHost(_ bundleID: String?) -> Bool {
        #if DEBUG && IME_TEST_BUILD
        return bundleID == TraceRun.hostID
        #else
        return false
        #endif
    }

    func prepare(engine: RimeEngine, settings: InputSettings, clientBundleID: String?) -> Bool {
        guard !engine.isComposing else { return false }
        #if DEBUG && IME_TEST_BUILD
        if isTestHost(clientBundleID) {
            guard select("sentencealong_fixture", for: engine) else { return false }
            dailyEngines.remove(engine)
            return true
        }
        #endif
        dailyEngines.add(engine)
        reloadDictionaryIfIdle()
        return select(settings.pinyinSchema, for: engine)
    }

    private func select(_ schema: String, for engine: RimeEngine) -> Bool {
        guard !unavailableSchemas.contains(schema) else { return false }
        if engine.selectSchema(schema) {
            if health.state == .schemaUnavailable, schema != "sjy_idle" { publish(.available, sessionMS: health.sessionMS) }
            return true
        }
        unavailableSchemas.insert(schema)
        if health.state != .schemaUnavailable { publish(.schemaUnavailable) }
        return false
    }

    func checkDictionaryChanges() {
        let store = PersonalDictionary.shared
        let revision = store.revision
        if revision != phraseRevision || store.clearPending {
            needsDictionaryReload = true
            phraseRevision = revision
        }
        unavailableSchemas.removeAll()
        reloadDictionaryIfIdle()
    }

    func reloadDictionaryIfIdle() {
        guard needsDictionaryReload else { return }
        let engines = dailyEngines.allObjects
        guard !engines.contains(where: { $0.isComposing }) else { return }
        // Rime shares its stabledb and LevelDB handles across sessions. Release every
        // reader before opening the updated phrase table or removing the learned DB.
        for engine in engines {
            guard select("sjy_idle", for: engine) else { return }
        }
        do {
            try PersonalDictionary.shared.clearLearningIfRequested()
            needsDictionaryReload = false
        } catch {
            // Retry at the next activation or explicit request instead of on each key.
            needsDictionaryReload = false
            logger.error("Unable to clear the learned dictionary")
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
