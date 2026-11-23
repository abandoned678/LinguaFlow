import AppKit
import Carbon
import IMETrace

extension RunDriver {
    func candidateSelection() throws {
        if run.scenario == "candidate-tenth-click" {
            try typeLetters([UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_I)])
        } else {
            try composeNihao()
        }
        if manual {
            print("请点击高亮的「你好」。"); fflush(stdout)
        } else {
            try wait("visible candidate coordinates", failure: .blocked("no visible candidate target")) {
                $0.events.contains { $0.role == .ime && $0.clickPoint != nil }
            }
            try requireFocusedHost()
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: TraceRun.imeID)
            guard apps.count == 1, let point = try evidence().events.compactMap(\.clickPoint).last else {
                throw RunFailure.blocked("ambiguous IME target")
            }
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let window = windows.first(where: {
                      guard let bounds = $0[kCGWindowBounds as String] as? [String: CGFloat],
                            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                      return rect.contains(point)
                  }), window[kCGWindowOwnerPID as String] as? Int32 == apps[0].processIdentifier,
                  let number = window[kCGWindowNumber as String] as? Int else {
                throw RunFailure.blocked("candidate window is obscured")
            }
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                          mouseCursorPosition: point, mouseButton: .left) else {
                    throw RunFailure.blocked("mouse event unavailable")
                }
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(number))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(number))
                event.post(tap: .cghidEventTap)
            }
        }
        try wait("candidate click and host commit", timeout: manual ? 25 : 5, failure: .failed("click or commit missing")) {
            $0.count(.mouseSelected, from: .ime) == 1 && $0.count(.inserted, from: .host) == 1
        }
        try checkDocument()
    }
}
