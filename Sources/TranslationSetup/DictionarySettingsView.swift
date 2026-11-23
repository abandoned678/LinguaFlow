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
    @State private var editing: PersonalPhrase?
    @State private var code = ""
    @State private var phrase = ""
    @State private var status = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("个人短语") {
                TextField("输入码（如 sjy）", text: $code)
                TextField("短语（如 随键译）", text: $phrase)
                HStack {
                    Button(editing == nil ? "添加短语" : "保存修改") {
                        perform {
                            try store.replace(editing, with: PersonalPhrase(code: code, text: phrase))
                            resetEditor()
                        }
                    }.disabled(code.isEmpty || phrase.isEmpty)
                    if editing != nil { Button("取消编辑", action: resetEditor) }
                }
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.code).monospaced()
                        Text(entry.text)
                        Spacer()
                        Button("编辑") { editing = entry; code = entry.code; phrase = entry.text }
                        Button("删除", role: .destructive) {
                            perform {
                                try store.replace(entry, with: nil)
                                if editing == entry { resetEditor() }
                            }
                        }
                    }
                }
            }
            Section("学习数据") {
                Button("清除个人词频…", role: .destructive) { confirmClear = true }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .onAppear {
            perform {}
            if store.clearPending { status = "等待输入法清除个人词频。" }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: PersonalDictionary.didClearLearning)) { _ in
            status = "已清除个人词频，个人短语已保留。"
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: PersonalDictionary.didChange)) { _ in
            do { entries = try store.phrases() } catch { status = error.localizedDescription }
        }
        .confirmationDialog("清除本输入源学到的词频？", isPresented: $confirmClear) {
            Button("清除词频", role: .destructive) {
                perform { try store.requestClearLearning() }
                if status.isEmpty { status = "已请求清除。输入法会在当前组词结束后处理，个人短语及偏好保留。" }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除后无法撤销。个人短语和输入偏好会保留。")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); entries = try store.phrases(); status = "" }
        catch { status = error.localizedDescription }
    }

    private func resetEditor() { editing = nil; code = ""; phrase = "" }
}
