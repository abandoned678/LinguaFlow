import SwiftUI
import InputCore

struct PinyinSettingsControls: View {
    @Binding var layout: PinyinLayout
    @Binding var fuzzy: Set<FuzzyInitial>
    @Binding var learnsWords: Bool

    var body: some View {
        Section("拼音") {
            Picker("输入方案", selection: $layout) {
                ForEach(PinyinLayout.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            ForEach(FuzzyInitial.allCases, id: \.self) { group in
                Toggle("模糊音 " + group.label, isOn: Binding(
                    get: { fuzzy.contains(group) },
                    set: { enabled in
                        if enabled { fuzzy.insert(group) } else { fuzzy.remove(group) }
                    }))
            }
            Toggle("使用并学习个人词频", isOn: $learnsWords)
        }
    }
}

struct DictionarySettingsView: View {
    private let store = PersonalDictionary.shared
    @State private var entries: [PersonalPhrase] = []
    @State private var phraseRevision = PersonalDictionary.shared.revision
    @State private var writing = false
    @State private var editing: PersonalPhrase?
    @State private var code = ""
    @State private var phrase = ""
    @State private var status = ""
    @State private var confirmClear = false
    @State private var visibleCount = 50
    @State private var filter = ""

    var body: some View {
        Form {
            DictionaryImportView(store: store) { phraseRevision = store.revision }
            Section("个人短语") {
                TextField("输入码（如 sjy）", text: $code)
                TextField("短语（如 随键译）", text: $phrase)
                HStack {
                    Button(editing == nil ? "添加短语" : "保存修改") {
                        let previous = editing
                        let inputCode = code
                        let inputText = phrase
                        perform { [store] in
                            try store.replace(previous, with: PersonalPhrase(code: inputCode, text: inputText))
                        } onSuccess: { resetEditor() }
                    }.disabled(code.isEmpty || phrase.isEmpty)
                    if editing != nil { Button("取消编辑", action: resetEditor) }
                }
                if entries.count > 50 || !filter.isEmpty {
                    TextField("搜索输入码或短语", text: $filter)
                        .onChange(of: filter) { _, _ in visibleCount = 50 }
                }
                let matches = filter.isEmpty ? entries : entries.filter { $0.code.contains(filter) || $0.text.contains(filter) }
                ForEach(matches.prefix(visibleCount)) { entry in
                    HStack {
                        Text(entry.code).monospaced()
                        Text(entry.text)
                        Spacer()
                        Button("编辑") { editing = entry; code = entry.code; phrase = entry.text }
                        Button("删除", role: .destructive) {
                            perform { [store] in try store.replace(entry, with: nil) } onSuccess: {
                                if editing == entry { resetEditor() }
                            }
                        }
                    }
                }
                if matches.count > visibleCount {
                    Button("显示更多短语") { visibleCount += 50 }
                }
            }
            Section("学习数据") {
                Button("清除个人词频…", role: .destructive) { confirmClear = true }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .disabled(writing)
        .task(id: phraseRevision) {
            do {
                let values = try await Task.detached(priority: .userInitiated) { [store] in try store.phrases() }.value
                if !Task.isCancelled { entries = values }
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
        .onAppear {
            phraseRevision = store.revision
            if store.clearPending { status = "等待输入法清除个人词频。" }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: PersonalDictionary.didClearLearning)) { _ in
            status = "已清除个人词频，个人短语已保留。"
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: PersonalDictionary.didChange)) { _ in
            phraseRevision = store.revision
        }
        .confirmationDialog("清除本输入源学到的词频？", isPresented: $confirmClear) {
            Button("清除词频", role: .destructive) {
                perform { [store] in try store.requestClearLearning() } onSuccess: {
                    status = store.clearPending ? "已请求清除。输入法会在当前组词结束后处理。" : "已清除个人词频。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后无法撤销。个人短语和输入偏好会保留。")
        }
    }

    private func perform(_ action: @escaping @Sendable () throws -> Void,
                         onSuccess: @escaping @MainActor () -> Void) {
        writing = true
        Task { @MainActor in
            defer { writing = false }
            do {
                try await Task.detached(priority: .userInitiated, operation: action).value
                status = ""
                phraseRevision = store.revision
                onSuccess()
            } catch { status = error.localizedDescription }
        }
    }

    private func resetEditor() { editing = nil; code = ""; phrase = "" }
}
