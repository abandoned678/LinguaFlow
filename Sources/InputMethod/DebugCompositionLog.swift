#if DEBUG && IME_TEST_BUILD
import Carbon
import Foundation
import OSLog
#endif

enum CompositionCommitSource {
    case imkCallback, hostShortcut, forwardDelete
}

enum ContextResetReason {
    case secureInput, reactivated, deactivated, controllerClosed, noActiveClient, clientChanged
    case hostShortcut, controlReturn, forwardDelete, englishControl, navigationOrControl
    case replacementSelectionChanged, replacementRangeUnverified, translationReplaced
    case foregroundChangedOnRender, foregroundChangedOnRefresh
    case markUnavailable, markEmpty, caretUnavailable, markLengthMismatch, markTextUnavailable, markTextMismatch
    case englishCandidateRejected, unhandledTab, englishNavigation
    case lineBreakUnverified, trackedCaretChanged, backspaceContextMismatch, backspaceRangeInvalid
    case lastCharacterRemoved, spellingRangeMismatch
}

#if DEBUG && IME_TEST_BUILD
struct DebugCompositionLog {
    private let controllerID = UUID()
    private static let log = Logger(
        subsystem: "com.abandoned678.inputmethod.SentenceAlongDebug", category: "CompositionReset"
    )

    func activated() {
        guard !IsSecureEventInputEnabled() else { return }
        Self.log.notice("activate controller=\(controllerID.uuidString, privacy: .public)")
    }

    func compositionEdge(began: Bool, hasCommit: Bool) {
        guard !IsSecureEventInputEnabled() else { return }
        let edge = began ? "began" : "ended"
        Self.log.notice("composition edge=\(edge, privacy: .public) controller=\(controllerID.uuidString, privacy: .public) hasCommit=\(hasCommit)")
    }

    func commitRequested(source: CompositionCommitSource) {
        guard !IsSecureEventInputEnabled() else { return }
        Self.log.notice("commitComposition source=\(String(describing: source), privacy: .public) controller=\(controllerID.uuidString, privacy: .public)")
    }

    func palettesHidden(composing: Bool, panelHasContent: Bool) {
        guard composing || panelHasContent, !IsSecureEventInputEnabled() else { return }
        Self.log.notice("hidePalettes controller=\(controllerID.uuidString, privacy: .public) composing=\(composing) panelHasContent=\(panelHasContent)")
    }

    func reset(_ reason: ContextResetReason, active: Bool, composing: Bool, tracking: Bool,
               observedMark: Bool, hasExpectedCaret: Bool, clearHostMark: Bool) {
        let lifecycleEvent = reason == .reactivated || reason == .deactivated || reason == .controllerClosed
        guard lifecycleEvent || composing || tracking || observedMark || hasExpectedCaret,
              reason != .secureInput, !IsSecureEventInputEnabled() else { return }
        Self.log.notice("""
            reset reason=\(String(describing: reason), privacy: .public) controller=\(controllerID.uuidString, privacy: .public) \
            active=\(active) composing=\(composing) tracking=\(tracking) observedMark=\(observedMark) \
            clearHostMark=\(clearHostMark && composing)
            """)
    }
}
#endif
