import AppKit
import InputCore
import SwiftUI

@MainActor
struct UninstallView: View {
    static var productName: String {
        InputSettingsStore.productDirectory == "SentenceAlongDebug" ? "随键译 Debug" : "随键译正式版"
    }
    static private(set) var operationInProgress = false

    let onApplicationRemoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var application: UninstallService.Installation?
    @State private var selected = Set<UninstallData.Category>()
    @State private var counts: (phrases: Int, weights: Int)?
    @State private var loading = true
    @State private var confirming = false
    @State private var working = false
    @State private var removed = false
    @State private var cleanupFailed = false
    @State private var message = ""

    private let directory = InputSettingsStore.shared.preferencesURL.deletingLastPathComponent()
    private let categories: [UninstallData.Category] = [.phrases, .weights, .learning, .preferences]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(removed ? "已卸载" + Self.productName : "卸载" + Self.productName)
                .font(.title2.bold())
            if !removed {
                if let application {
                    Text(application.url.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if application.url.path.hasPrefix("/Library/") {
                        Text("此应用安装在系统目录，卸载会影响这台 Mac 的所有用户。下列数据选项仅适用于当前用户。")
                    }
                    Text("默认保留全部数据。勾选要随应用一起删除的项目。")
                    ForEach(categories, id: \.self) { category in
                        Toggle(label(category), isOn: Binding {
                            selected.contains(category)
                        } set: { enabled in
                            if enabled { selected.insert(category) } else { selected.remove(category) }
                        })
                        .toggleStyle(.checkbox)
                        .disabled(loading || working)
                    }
                }
            }
            if loading || working {
                ProgressView(working ? (removed ? "正在清理数据…" : "正在卸载…") : "正在检查安装和数据…").controlSize(.small)
            }
            if !message.isEmpty {
                Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if removed {
                    if cleanupFailed {
                        Button("重试清理") { Task { await retryCleanup() } }.disabled(working)
                        Button("打开数据目录") { NSWorkspace.shared.open(directory) }
                    }
                    Button("退出设置") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction).disabled(working)
                } else {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                    Button("继续卸载…", role: .destructive) { confirming = true }
                        .disabled(application == nil || loading || working)
                }
            }
        }
        .padding(24).frame(width: 500)
        .task { await load() }
        .interactiveDismissDisabled(working || removed)
        .alert("确认卸载" + Self.productName + "？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("卸载", role: .destructive) { Task { await uninstall() } }
        } message: {
            Text(selected.isEmpty ? "将保留词典和设置。" :
                    "将删除" + categories.filter { selected.contains($0) }.map(label).joined(separator: "、") + "。删除的数据无法恢复。")
        }
    }

    private func label(_ category: UninstallData.Category) -> String {
        switch category {
        case .phrases: counts.map { "个人短语（\($0.phrases) 条）" } ?? "个人短语"
        case .weights: counts.map { "导入的词频（\($0.weights) 条）" } ?? "导入的词频"
        case .learning: "本机学习的词频（整个学习词库）"
        case .preferences: "设置与快捷键"
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            application = try UninstallService.installedApplication()
            counts = try await Task.detached(priority: .userInitiated) { [directory] in
                try UninstallData(directory: directory).counts()
            }.value
        } catch {
            message = application == nil ? error.localizedDescription : "无法统计词典条数。你仍可保留全部数据或选择清理对应类别。"
        }
    }

    private func uninstall() async {
        guard !working, !removed, let application else { return }
        working = true
        Self.operationInProgress = true
        defer { working = false; Self.operationInProgress = false }
        do {
            try await UninstallService.removeApplication(expected: application)
        } catch {
            message = "卸载未完成。" + error.localizedDescription
            return
        }

        onApplicationRemoved()
        removed = true
        await cleanSelectedData()
    }

    private func retryCleanup() async {
        guard removed, cleanupFailed, !working else { return }
        working = true
        Self.operationInProgress = true
        defer { working = false; Self.operationInProgress = false }
        await cleanSelectedData()
    }

    private func cleanSelectedData() async {
        if selected.isEmpty {
            message = "已保留词典、设置与快捷键。"
            return
        }
        do {
            guard let application else { throw CocoaError(.fileNoSuchFile) }
            try application.ensureRemoved()
            try await Task.detached(priority: .userInitiated) { [directory, selected] in
                try UninstallData(directory: directory).remove(selected)
            }.value
            cleanupFailed = false
            message = "已清除所选数据。"
        } catch {
            cleanupFailed = true
            message = "所选数据未全部清除。" + error.localizedDescription
        }
    }
}
