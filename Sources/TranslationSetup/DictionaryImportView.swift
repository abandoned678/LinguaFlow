import AppKit
import InputCore
import SwiftUI

private enum ImportSource: String, CaseIterable {
    case shortcuts = "个人短语（TSV）"
    case apple = "苹果文本替换（plist）"
    case sogou = "搜狗自定义短语（文本）"
    case weights = "带词频的词表（TSV）"

    var instruction: String {
        switch self {
        case .shortcuts: "UTF-8 文本，每行两列：输入码、短语，用 Tab 分隔。输入码使用小写英文字母。"
        case .apple: "到系统设置的「键盘 → 文本替换（自定义短语）」，选中条目并拖到桌面，再选择导出的 plist。仅导入随键译支持的输入码。"
        case .sogou: "在搜狗 Mac 的「自定义短语设置」选择「导出」，再选择可读的短语文本。支持每行“输入码,顺序=短语”；同一输入码仅保留第一条可用短语。"
        case .weights: "UTF-8 文本，每行三列：词条、输入码、正整数权重，用 Tab 分隔。同码词条按权重排序；全拼填连写拼音，双拼填实际按键。"
        }
    }

    var phraseFormat: PhraseImportFormat? {
        switch self {
        case .shortcuts: .tsv
        case .apple: .appleTextReplacements
        case .sogou: .sogouCustomPhrases
        case .weights: nil
        }
    }
}

private enum ImportContents: Sendable {
    case phrases(PhraseImportBatch)
    case weights([WeightedWord])

    var summary: String {
        switch self {
        case .phrases(let batch):
            "可处理 \(batch.validCount) 条，格式不符 \(batch.invalidCount) 条。将跳过重复输入码，保留已有短语。"
        case .weights(let words):
            "可处理 \(words.count) 条。文件中的权重会更新相同词条和输入码的导入记录，保留输入法自动学习的词频。"
        }
    }
    var canImport: Bool {
        switch self {
        case .phrases(let batch): batch.validCount > 0
        case .weights(let words): !words.isEmpty
        }
    }
}

private struct PendingImport: Identifiable {
    let id = UUID()
    let filename: String
    let contents: ImportContents
}

struct DictionaryImportView: View {
    let store: PersonalDictionary
    let reload: () -> Void
    @State private var source = ImportSource.shortcuts
    @State private var pending: PendingImport?
    @State private var status = ""
    @State private var busy = false
    @State private var confirmClear = false

    var body: some View {
        Section("从文件导入") {
            Picker("文件类型", selection: $source) {
                ForEach(ImportSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text(source.instruction).foregroundStyle(.secondary)
            if source == .apple, let url = URL(string: "https://support.apple.com/zh-cn/guide/mac-help/mchl2a7bd795/mac") {
                Link("苹果官方导出步骤", destination: url)
            } else if source == .sogou, let url = URL(string: "https://pinyin.sogou.com/help.php?list=1&q=9") {
                Link("搜狗短语格式说明", destination: url)
            }
            Button(busy ? "正在处理…" : "选择文件…", action: chooseFile)
            if source == .weights {
                Button("清除已导入的词频…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("清除所有导入的词频？", isPresented: $confirmClear) {
                        Button("清除导入词频", role: .destructive) { clearWeights() }
                        Button("取消", role: .cancel) {}
                    } message: { Text("个人短语和自动学习的词频会保留。") }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
        }
        .disabled(busy)
        .onChange(of: source) { _, _ in status = "" }
        .sheet(item: $pending) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text(item.filename).font(.headline)
                Text(item.contents.summary)
                HStack {
                    Spacer()
                    Button("取消") { pending = nil }.keyboardShortcut(.cancelAction)
                    Button("导入") { pending = nil; save(item.contents) }
                        .disabled(!item.contents.canImport).keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 390)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = source.phraseFormat
        busy = true
        status = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                let contents = try await Task.detached(priority: .userInitiated) {
                    let data = try DictionaryImportFile.read(url)
                    if let format { return ImportContents.phrases(try PhraseImportBatch(data: data, format: format)) }
                    return ImportContents.weights(try PersonalDictionary.weightedEntries(from: data))
                }.value
                pending = PendingImport(filename: url.lastPathComponent, contents: contents)
            } catch { status = error.localizedDescription }
        }
    }

    private func save(_ contents: ImportContents) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                status = try await Task.detached(priority: .userInitiated) { [store] in
                    switch contents {
                    case .phrases(let batch):
                        let result = try store.importPhrases(batch)
                        return "已添加 \(result.inserted) 条短语，跳过同码 \(result.skippedConflicts) 条、无效 \(result.invalidCount) 条。"
                    case .weights(let words):
                        let result = try store.importWeightedEntries(words)
                        return "已新增 \(result.added) 条词频，更新 \(result.updated) 条，未变更 \(result.unchanged) 条。"
                    }
                }.value
                reload()
            } catch { status = error.localizedDescription }
        }
    }

    private func clearWeights() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) { [store] in try store.clearImportedWeights() }.value
                status = "已清除导入的词频。"
            } catch { status = error.localizedDescription }
        }
    }

}
