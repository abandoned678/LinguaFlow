import AppKit
import InputCore
import SwiftUI
import UniformTypeIdentifiers

struct AppPreviewSettings: View {
    let overrides: [String: InputSettings.PreviewOverride]
    let setOverride: (String, InputSettings.PreviewOverride) -> Void
    @State private var selectedID: String?
    @State private var invalidApp = false

    var body: some View {
        Section("按应用设置预览") {
            ForEach(Set(overrides.keys).union(selectedID.map { [$0] } ?? []).sorted(), id: \.self) { id in
                Picker(selection: Binding(get: { overrides[id] ?? .followGlobal }, set: { choice in
                    setOverride(id, choice)
                    if choice == .followGlobal { selectedID = nil }
                })) {
                    ForEach(InputSettings.PreviewOverride.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Text(displayName(for: id)).help(id)
                }
            }
            Button("选择应用…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.applicationBundle]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else { invalidApp = true; return }
                selectedID = id
            }
        }
        .alert("无法识别应用", isPresented: $invalidApp) { Button("好") {} }
    }

    private func displayName(for id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return url.deletingPathExtension().lastPathComponent
    }
}
