import AppKit
import InputCore
import LocalTranslation
import SwiftUI
import Translation

@MainActor
private final class SetupAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TranslationSetupApp: App {
    @NSApplicationDelegateAdaptor(SetupAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("输入法设置", id: "setup") {
            TranslationSetupView()
                .frame(width: 520, height: 380)
        }
        .windowResizability(.contentSize)
    }
}

private struct TranslationSetupView: View {
    private enum Page: Hashable {
        case translation, appearance, about
    }

    @State private var page: Page = .translation
    @State private var settings = InputSettingsStore.shared.read()
    @State private var saveFailed = false

    var body: some View {
        TabView(selection: $page) {
            Form {
                Section("翻译预览") {
                    Toggle("启用翻译预览", isOn: setting(\.translationEnabled))
                    Picker("响应速度", selection: setting(\.speed)) {
                        ForEach(InputSettings.Speed.allCases, id: \.self) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                }
                TranslationModelSettings()
            }
            .formStyle(.grouped)
            .tabItem { Label("翻译", systemImage: "character.book.closed") }
            .tag(Page.translation)

            Form {
                Picker("预览布局", selection: setting(\.previewLayout)) {
                    ForEach(InputSettings.PreviewLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("浮层字号", selection: setting(\.previewSize)) {
                    ForEach(InputSettings.PreviewSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                ShortcutRecorder(keyCode: setting(\.replacementKeyCode))
            }
            .formStyle(.grouped)
            .tabItem { Label("外观与操作", systemImage: "textformat.size") }
            .tag(Page.appearance)

            Form {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("构建号", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                Button("查看开源许可", action: openLicense)
            }
            .formStyle(.grouped)
            .tabItem { Label("关于与诊断", systemImage: "info.circle") }
            .tag(Page.about)
        }
        .padding()
        .onOpenURL { url in
            if url.scheme == "sentencealong-settings", url.host == "translation" { page = .translation }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: InputSettingsStore.didChange)) { _ in
            settings = InputSettingsStore.shared.read()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings = InputSettingsStore.shared.read()
        }
        .alert("无法保存输入法设置", isPresented: $saveFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查随键译设置目录是否可以写入。")
        }
    }

    private func setting<Value>(_ key: WritableKeyPath<InputSettings, Value>) -> Binding<Value> {
        Binding {
            settings[keyPath: key]
        } set: { value in
            do {
                try InputSettingsStore.shared.update { $0[keyPath: key] = value }
            } catch {
                saveFailed = true
            }
            settings = InputSettingsStore.shared.read()
        }
    }

    private func openLicense() {
        let resources = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        NSWorkspace.shared.open(resources.appendingPathComponent("LICENSE.txt"))
        NSWorkspace.shared.open(resources.appendingPathComponent("THIRD_PARTY_NOTICES.md"))
    }
}

private struct TranslationModelSettings: View {
    private enum State: Equatable {
        case unchecked, checking, missing, preparing, ready, failed(String)

        var label: String {
            switch self {
            case .unchecked: "尚未检查"
            case .checking: "正在检查…"
            case .missing: "模型未就绪"
            case .preparing: "正在准备，等待系统完成…"
            case .ready: "已就绪"
            case .failed(let reason): reason
            }
        }
    }

    private let directions: [TranslationDirection] = [.chineseToEnglish, .englishToChinese]
    @State private var statuses: [TranslationDirection: State] = [:]
    @State private var preparation: TranslationDirection?
    @State private var configuration: TranslationSession.Configuration?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Section("本地模型") {
            ForEach(directions, id: \.self) { direction in
                let status = statuses[direction] ?? .unchecked
                LabeledContent("\(direction.sourceLabel) → \(direction.targetLabel)") {
                    HStack {
                        Text(status.label)
                            .foregroundStyle(.secondary)
                        if status == .unchecked || status == .missing {
                            Button("准备模型") { prepare(direction) }
                        }
                        if case .failed = status {
                            Button("重试准备") { prepare(direction) }
                        }
                    }
                }
            }
            Button(statuses.isEmpty ? "检查模型" : "重新检查", action: checkModels)
        }
        .disabled(checkTask != nil || preparation != nil)
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
            for direction in directions where statuses[direction] == .checking {
                statuses[direction] = .unchecked
            }
        }
        .translationTask(configuration) { session in
            guard let direction = preparation else { return }
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
                statuses[direction] = await verifiedState(direction)
                if statuses[direction] == .ready { notifyModelChange(direction) }
            } catch {
                let reason = LocalTranslationModels.classify(error)
                if reason is CancellationError {
                    statuses[direction] = .missing
                } else {
                    statuses[direction] = .failed((reason as? TranslationFailure)?.message ?? "准备失败，请重试")
                }
            }
            preparation = nil
        }
    }

    private func prepare(_ direction: TranslationDirection) {
        guard preparation == nil, checkTask == nil else { return }
        preparation = direction
        statuses[direction] = .preparing
        if configuration?.source == LocalTranslationModels.configuration(for: direction).source {
            configuration?.invalidate()
        } else {
            configuration = LocalTranslationModels.configuration(for: direction)
        }
    }

    private func checkModels() {
        guard checkTask == nil, preparation == nil else { return }
        for direction in directions { statuses[direction] = .checking }
        checkTask = Task { @MainActor in
            for direction in directions {
                let state = await verifiedState(direction)
                guard !Task.isCancelled else { return }
                statuses[direction] = state
            }
            for direction in directions where statuses[direction] == .ready {
                notifyModelChange(direction)
            }
            checkTask = nil
        }
    }

    private func verifiedState(_ direction: TranslationDirection) async -> State {
        do {
            try await LocalTranslationModels.verify(direction)
            return .ready
        } catch TranslationFailure.modelsNotInstalled {
            return .missing
        } catch {
            return .failed((error as? TranslationFailure)?.message ?? "模型检查失败")
        }
    }

    private func notifyModelChange(_ direction: TranslationDirection) {
        DistributedNotificationCenter.default().postNotificationName(
            LocalTranslationModels.statusDidChange, object: direction.rawValue, userInfo: nil, deliverImmediately: true
        )
    }
}
