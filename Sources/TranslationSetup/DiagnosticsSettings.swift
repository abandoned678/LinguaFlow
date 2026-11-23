import AppKit
import InputCore
import LocalTranslation
import SwiftUI

struct DiagnosticsSettings: View {
    private struct BuildInfo: Decodable {
        let Version: String
        let Build: String
        let MinimumSystem: String
        let Commit: String
        let WorkingTreeChanges: Bool
        let Configuration: String
        let BundledLibraries: String
        let BuildFormulas: String
        let DictionaryRevisions: String

        static func load(from directory: URL) -> Self? {
            let url = directory.appendingPathComponent("BuildInfo.plist")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListDecoder().decode(Self.self, from: data)
        }
    }

    let resources: URL
    let engineHealth: EngineHealth?
    @State private var checkTask: Task<Void, Never>?
    @State private var selfCheck: [String] = []
    @State private var copied = false

    var body: some View {
        let info = BuildInfo.load(from: resources)
        Section("构建") {
            LabeledContent("版本", value: info?.Version ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            LabeledContent("构建号", value: info?.Build ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            if let info {
                LabeledContent("源码提交", value: String(info.Commit.prefix(12)))
                LabeledContent("最低系统", value: "macOS " + info.MinimumSystem)
            }
        }

        Section("本地数据") {
            let directory = InputSettingsStore.shared.preferencesURL.deletingLastPathComponent()
            LabeledContent("输入法数据目录") {
                Text(directory.path(percentEncoded: false))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }

        Section("诊断") {
            LabeledContent("拼音引擎（最近报告）", value: engineHealth?.state.label ?? "尚无状态")
            if engineHealth?.state.isFailure == true {
                Text("切换至其他输入法后重新选择随键译。若问题持续，请重新安装并查看构建版本。")
                    .foregroundStyle(.secondary)
            }
            Button(checkTask == nil ? "检查本地翻译" : "正在检查…", action: startCheck)
                .disabled(checkTask != nil)
            ForEach(selfCheck, id: \.self) { Text($0).foregroundStyle(.secondary) }
            Button(copied ? "已复制诊断信息" : "复制诊断信息") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                copied = pasteboard.setString(report(info), forType: .string)
            }
        }
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
        }

        Section("开源许可") {
            Button("查看随键译许可") { NSWorkspace.shared.open(resources.appendingPathComponent("LICENSE.txt")) }
            Button("查看第三方组件声明") { NSWorkspace.shared.open(resources.appendingPathComponent("THIRD_PARTY_NOTICES.md")) }
        }
    }

    private func startCheck() {
        guard checkTask == nil else { return }
        selfCheck = []
        copied = false
        checkTask = Task { @MainActor in
            var statuses: [String] = []
            for direction in [TranslationDirection.chineseToEnglish, .englishToChinese] {
                let status: String
                do {
                    try await LocalTranslationModels.verify(direction)
                    status = "已就绪"
                } catch {
                    status = (error as? TranslationFailure)?.message ?? "检查失败"
                }
                guard !Task.isCancelled else { return }
                statuses.append("\(direction.sourceLabel) → \(direction.targetLabel)  \(status)")
            }
            selfCheck = statuses
            checkTask = nil
        }
    }

    private func report(_ info: BuildInfo?) -> String {
        var lines = [
            "SentenceAlong",
            "系统 \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "拼音引擎 \(engineHealth?.state.rawValue ?? "unknown")",
        ]
        if let info {
            lines += [
                "版本 \(info.Version) (\(info.Build))",
                "最低系统 \(info.MinimumSystem)",
                "源码提交 \(info.Commit)",
                "工作区有改动 \(info.WorkingTreeChanges)",
                "构建配置 \(info.Configuration)",
                "内嵌动态库\n\(info.BundledLibraries)",
                "构建依赖\n\(info.BuildFormulas)",
                "词库提交\n\(info.DictionaryRevisions)",
            ]
        }
        if let engineHealth {
            for (label, timing) in [
                ("引擎初始化", engineHealth.initializationMS),
                ("词库维护", engineHealth.maintenanceMS),
                ("会话创建", engineHealth.sessionMS),
            ] {
                if let timing, timing.isFinite { lines.append("\(label) \(String(format: "%.1f ms", timing))") }
            }
        }
        return (lines + selfCheck).joined(separator: "\n")
    }
}
