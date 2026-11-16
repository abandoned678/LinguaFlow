import Foundation

public struct EngineHealth: Codable, Equatable {
    public enum State: String, Codable {
        case preparing, available, missingResources, startupFailed, sessionFailed, schemaUnavailable

        public var label: String {
            switch self {
            case .preparing: "准备中"
            case .available: "可用"
            case .missingResources: "找不到拼音资源"
            case .startupFailed: "拼音引擎启动失败"
            case .sessionFailed: "无法创建拼音输入会话"
            case .schemaUnavailable: "拼音输入方案不可用"
            }
        }

        public var isFailure: Bool { self != .preparing && self != .available }
    }

    public let state: State
    public let initializationMS: Double?
    public let maintenanceMS: Double?
    public let sessionMS: Double?

    public init(state: State, initializationMS: Double? = nil, maintenanceMS: Double? = nil, sessionMS: Double? = nil) {
        self.state = state
        self.initializationMS = initializationMS
        self.maintenanceMS = maintenanceMS
        self.sessionMS = sessionMS
    }

    public static let didChange = Notification.Name(InputSettingsStore.domain + ".engineHealthDidChange")

    public static let location = InputSettingsStore.shared.preferencesURL.deletingLastPathComponent()
        .appendingPathComponent("EngineHealth.plist")

    public static func read(from url: URL = location) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Self.self, from: data)
    }

    public func write(to url: URL = location) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        if url == Self.location {
            DistributedNotificationCenter.default().postNotificationName(
                Self.didChange, object: nil, userInfo: nil, deliverImmediately: true
            )
        }
    }
}
