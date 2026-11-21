import AppKit
import IMETrace

extension RunDriver {
    func panelLifecycle() throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: TraceRun.imeID)
        guard apps.count == 1, let ime = apps.first else { throw RunFailure.blocked("Debug IME unavailable") }

        func windows() throws -> Set<Int> {
            guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw RunFailure.blocked("window list unavailable")
            }
            return Set(rows.compactMap { row in
                guard row[kCGWindowOwnerPID as String] as? pid_t == ime.processIdentifier else { return nil }
                return row[kCGWindowNumber as String] as? Int
            })
        }

        let baseline = try windows()
        try composeNihao()
        let appearDeadline = ContinuousClock.now + .seconds(3)
        var panelIDs = Set<Int>()
        while panelIDs.isEmpty && ContinuousClock.now < appearDeadline {
            try requireFocusedHost()
            panelIDs = try windows().subtracting(baseline)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        guard !panelIDs.isEmpty else { throw RunFailure.blocked("candidate panel never appeared") }
        try requireFocusedHost()
        if ["panel-mark-ended", "panel-editor-cleared"].contains(run.scenario) {
            try wait("translated candidate visible", timeout: 8, failure: .blocked("translation preview unavailable")) { $0.count(.translationReady, from: .ime) > 0 }
            try Data().write(to: run.directory.appendingPathComponent("end-mark"), options: .atomic)
            try wait("host ended marked text", failure: .blocked("host did not end marking")) {
                $0.count(.markEnded, from: .host) == 1
            }
        } else if run.scenario == "panel-app-switch" {
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  finder.activate(options: []) else { throw RunFailure.blocked("Finder did not activate") }
            let switchDeadline = ContinuousClock.now + .seconds(3)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != finder.processIdentifier,
                  ContinuousClock.now < switchDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier,
                  !host.isTerminated else { throw RunFailure.blocked("foreground app switch unavailable") }
        } else {
            guard host.bundleIdentifier == TraceRun.hostID, host.forceTerminate() else {
                throw RunFailure.blocked("test host could not be terminated")
            }
            let exitDeadline = ContinuousClock.now + .seconds(3)
            while !host.isTerminated && ContinuousClock.now < exitDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            guard host.isTerminated else { throw RunFailure.blocked("test host did not exit") }
        }
        let hideDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < hideDeadline {
            if try windows().isDisjoint(with: panelIDs) {
                let stableUntil = ContinuousClock.now + .milliseconds(750)
                while ContinuousClock.now < stableUntil {
                    guard try windows().isDisjoint(with: panelIDs) else {
                        throw RunFailure.failed("dismissed panel reappeared")
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw RunFailure.failed("candidate panel still visible after composition ended")
    }
}
