import AppKit
import InputCore
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var keyCode: UInt16
    @State private var monitor: Any?
    @State private var invalid = false

    var body: some View {
        Group {
            LabeledContent("替换快捷键") {
                Button(monitor != nil ? "按下 Control + Shift + 字母" : SentenceReplacementShortcut.label(for: keyCode)) {
                    if monitor == nil { start() } else { stop() }
                }
                Button("恢复默认") {
                    stop()
                    keyCode = SentenceReplacementShortcut.defaultKeyCode
                }
                .disabled(keyCode == SentenceReplacementShortcut.defaultKeyCode && monitor == nil)
            }
            if invalid { Text("请使用 Control + Shift 与一个字母。按 Esc 取消。").foregroundStyle(.secondary) }
        }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        invalid = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.control, .shift, .option, .command])
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if flags.contains(.command) { return event }
            guard flags == [.control, .shift],
                  SentenceReplacementShortcut.supports(keyCode: event.keyCode) else {
                invalid = true
                return nil
            }
            keyCode = event.keyCode
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        invalid = false
    }
}
