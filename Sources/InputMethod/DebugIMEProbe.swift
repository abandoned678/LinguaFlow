#if DEBUG && IME_TEST_BUILD
import AppKit
import Carbon
import IMETrace
import RimeInput
import InputMethodKit

@MainActor
final class DebugIMEProbe {
    private var writer: TraceWriter?
    private var hostPID: pid_t?
    private var checkedFirstKey = false
    func clickTarget(in candidates: [RimeCandidate], highlighted: Int) -> Int? {
        switch writer?.run.scenario {
        case "candidate-click" where candidates.indices.contains(highlighted) && candidates[highlighted].text == "你好":
            return highlighted
        case "candidate-tenth-click" where candidates.indices.contains(9) && candidates[9].text == "室":
            return 9
        default: return nil
        }
    }

    private func matches(_ client: (any IMKTextInput)?) -> Bool {
        !IsSecureEventInputEnabled() && client?.bundleIdentifier() == TraceRun.hostID
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TraceRun.hostID
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID
    }

    func activate(client: (any IMKTextInput)?) {
        writer = nil
        checkedFirstKey = false
        guard client?.bundleIdentifier() == TraceRun.hostID, !IsSecureEventInputEnabled(),
              Bundle.main.bundleIdentifier == TraceRun.imeID, let run = try? TraceRun.current(),
              let pidData = try? Data(contentsOf: run.directory.appendingPathComponent("host.pid")),
              let pid = try? JSONDecoder().decode(pid_t.self, from: pidData),
              Bundle.main.object(forInfoDictionaryKey: "IMETestBuild") as? String == run.build else { return }
        hostPID = pid
        guard matches(client) else { return }
        writer = TraceWriter(run: run, role: .ime)
        writer?.record(.activated)
    }

    func record(_ stage: TraceStage, client: (any IMKTextInput)?, clickPoint: CGPoint? = nil) {
        // Some hosts acquire their active IMK session only with the first key.
        if stage == .key, writer == nil, !checkedFirstKey {
            activate(client: client)
            checkedFirstKey = true
        }
        guard let writer else { return }
        guard matches(client) else { stop(); return }
        writer.record(stage, clickPoint: clickPoint)
    }

    func recordPreview(for source: String, client: (any IMKTextInput)?) {
        switch writer?.run.scenario {
        case "english-undo" where source != "hello",
             "ascii-comma-context" where source != "你好,你好",
             "mixed-period-replace" where source != "你好":
            return
        default: break
        }
        record(.translationReady, client: client)
    }

    func stop() {
        checkedFirstKey = true
        writer?.record(.stopped)
        writer = nil
    }
}
#endif
