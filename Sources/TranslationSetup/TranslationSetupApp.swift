import AppKit
import InputCore
import LocalTranslation
import SwiftUI
import Translation

@MainActor
private final class SetupAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UninstallView.operationInProgress ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TranslationSetupApp: App {
    @NSApplicationDelegateAdaptor(SetupAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("输入法设置", id: "setup") {
            TranslationSetupView()
                .frame(width: 660, height: 510)
        }
        .windowResizability(.contentSize)
    }
}

private struct TranslationSetupView: View {
    private enum Page: Hashable {
        case input, translation, appearance, dictionary, guide, about
    }

    @State private var page: Page = .translation
    @State private var settings = InputSettingsStore.shared.read()
    @State private var saveFailed = false
    @State private var showingUninstall = false
    @State private var applicationRemoved = false
    @State private var engineHealth = EngineHealth.read()

    var body: some View {
        TabView(selection: $page) {
            Form {
                Section("拼音输入") {
                    Picker("每页候选数", selection: setting(\.candidatePageSize)) {
                        ForEach(5...10, id: \.self) { Text("\($0) 项").tag($0) }
                    }
                    Toggle("使用英文标点", isOn: setting(\.usesASCIIPunctuation))
                    Toggle("单按 Shift 切换临时英文", isOn: setting(\.shiftTogglesEnglish))
                }
                PinyinSettingsControls(layout: setting(\.pinyinLayout), fuzzy: setting(\.fuzzyInitials),
                                          learnsWords: setting(\.learnsWords))
            }
            .formStyle(.grouped)
            .tabItem { Label("输入与候选", systemImage: "keyboard") }
            .tag(Page.input)

            Form {
                Section("翻译预览") {
                    Toggle("启用翻译预览", isOn: setting(\.translationEnabled))
                    Picker("翻译方向", selection: setting(\.translationDirection)) {
                        Text("中文 → 英文").tag(TranslationDirection.chineseToEnglish)
                        Text("英文 → 简体中文").tag(TranslationDirection.englishToChinese)
                    }
                    Picker("响应速度", selection: setting(\.speed)) {
                        ForEach(InputSettings.Speed.allCases, id: \.self) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                }
                AppPreviewSettings(overrides: settings.appPreviewOverrides) { id, choice in
                    update { $0.appPreviewOverrides[id] = choice == .followGlobal ? nil : choice }
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
                Picker("候选翻页键", selection: setting(\.pagingKeys)) {
                    ForEach(InputSettings.PagingKeys.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("恢复默认翻页键") { update { $0.pagingKeys = .standard } }
                    .disabled(settings.pagingKeys == .standard)
                ShortcutRecorder(keyCode: setting(\.replacementKeyCode))
            }
            .formStyle(.grouped)
            .tabItem { Label("外观与操作", systemImage: "textformat.size") }
            .tag(Page.appearance)

            DictionarySettingsView()
                .tabItem { Label("词典与短语", systemImage: "book") }
                .tag(Page.dictionary)

            UsageGuide(settings: settings)
                .tabItem { Label("使用说明", systemImage: "questionmark.circle") }
                .tag(Page.guide)

            Form {
                DiagnosticsSettings(resources: appResources, engineHealth: engineHealth)
                Section("卸载") {
                    Button("卸载" + UninstallView.productName + "…", role: .destructive) {
                        showingUninstall = true
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("关于与诊断", systemImage: "info.circle") }
            .tag(Page.about)
        }
        .padding()
        .disabled(applicationRemoved)
        .sheet(isPresented: $showingUninstall) {
            UninstallView { applicationRemoved = true }
        }
        .onOpenURL { url in
            guard url.scheme == InputSettingsStore.settingsScheme else { return }
            if url.host == "translation" { page = .translation }
            if url.host == "guide" { page = .guide }
            if url.host == "about" { page = .about }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: InputSettingsStore.didChange)) { _ in
            settings = InputSettingsStore.shared.read()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: EngineHealth.didChange)) { _ in
            engineHealth = EngineHealth.read()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings = InputSettingsStore.shared.read()
            engineHealth = EngineHealth.read()
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
            update { $0[keyPath: key] = value }
        }
    }

    private func update(_ edit: (inout InputSettings) -> Void) {
        do { try InputSettingsStore.shared.update(edit) }
        catch { saveFailed = true }
        settings = InputSettingsStore.shared.read()
    }

    private var appResources: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
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
