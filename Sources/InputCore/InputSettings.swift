import CoreFoundation
import Darwin
import Foundation

public struct InputSettings: Equatable, Sendable {
    public enum Speed: String, CaseIterable, Sendable {
        case fast, balanced, efficient

        public var label: String {
            switch self {
            case .fast: "快速"
            case .balanced: "均衡"
            case .efficient: "节能"
            }
        }
    }

    public enum PreviewLayout: String, CaseIterable, Sendable {
        case compact, standard

        public var label: String { self == .compact ? "精简" : "完整" }
    }

    public enum PreviewSize: String, CaseIterable, Sendable {
        case small, standard, large

        public var label: String {
            switch self {
            case .small: "小"
            case .standard: "标准"
            case .large: "大"
            }
        }

        public var fontScale: CGFloat {
            switch self {
            case .small: 0.86
            case .standard: 1
            case .large: 1.22
            }
        }
    }

    public var translationEnabled = true
    public var speed = Speed.balanced
    public var previewLayout = PreviewLayout.standard
    public var previewSize = PreviewSize.standard
    public var replacementKeyCode = SentenceReplacementShortcut.defaultKeyCode

    public init() {}
}

public struct InputSettingsStore: Sendable {
    public static let productDirectory = productDirectory(for: Bundle.main.bundleIdentifier)
    static func productDirectory(for bundleID: String?) -> String {
        let debugID = "com.abandoned678.inputmethod.SentenceAlongDebug"
        return [debugID, debugID + ".Setup"].contains(bundleID ?? "")
            ? "SentenceAlongDebug" : "SentenceAlong"
    }
    public static let domain = "com.abandoned678.inputmethod." + productDirectory + ".preferences"
    public static var settingsScheme: String { productDirectory == "SentenceAlongDebug" ? "sentencealong-debug-settings" : "sentencealong-settings" }
    public static let didChange = Notification.Name(domain + ".didChange")
    public static let shared = InputSettingsStore(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/" + productDirectory, isDirectory: true)
    )

    private static let version = 1
    private let directory: URL
    private let preferencesDomain: String

    public init(directory: URL, domain: String = Self.domain) {
        self.directory = directory
        self.preferencesDomain = domain
    }

    public var preferencesURL: URL {
        directory.appendingPathComponent(preferencesDomain + ".plist")
    }

    public func read() -> InputSettings {
        decode(readFields())
    }

    public func update(_ edit: (inout InputSettings) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(preferencesDomain + ".lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // Writes are serialized across the helper and IME. Readers see either complete file.
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var fields = readFields()
        let previous = decode(fields)
        var settings = previous
        edit(&settings)
        if !SentenceReplacementShortcut.supports(keyCode: settings.replacementKeyCode) {
            settings.replacementKeyCode = previous.replacementKeyCode
        }
        guard settings != previous else { return }
        fields["version"] = max(fields["version"] as? Int ?? 0, Self.version)
        if settings.translationEnabled != previous.translationEnabled {
            fields["translationEnabled"] = settings.translationEnabled
        }
        if settings.speed != previous.speed { fields["speed"] = settings.speed.rawValue }
        if settings.previewLayout != previous.previewLayout { fields["previewLayout"] = settings.previewLayout.rawValue }
        if settings.previewSize != previous.previewSize { fields["previewSize"] = settings.previewSize.rawValue }
        if settings.replacementKeyCode != previous.replacementKeyCode {
            fields["replacementKeyCode"] = Int(settings.replacementKeyCode)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        try data.write(to: preferencesURL, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(preferencesDomain + ".didChange"), object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    private func readFields() -> [String: Any] {
        guard let data = try? Data(contentsOf: preferencesURL),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return [:] }
        return values
    }

    private func decode(_ fields: [String: Any]) -> InputSettings {
        // Unversioned and v0 use the same field names. Read known fields from newer files and preserve extras.
        var settings = InputSettings()
        if let value = fields["translationEnabled"] as? NSNumber,
           CFGetTypeID(value) == CFBooleanGetTypeID() {
            settings.translationEnabled = value.boolValue
        }
        if let value = fields["speed"] as? String, let speed = InputSettings.Speed(rawValue: value) {
            settings.speed = speed
        }
        if let value = fields["previewLayout"] as? String, let layout = InputSettings.PreviewLayout(rawValue: value) {
            settings.previewLayout = layout
        }
        if let value = fields["previewSize"] as? String, let size = InputSettings.PreviewSize(rawValue: value) {
            settings.previewSize = size
        }
        if let value = fields["replacementKeyCode"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(),
           let key = UInt16(exactly: value.intValue), value.doubleValue == Double(key),
           SentenceReplacementShortcut.supports(keyCode: key) {
            settings.replacementKeyCode = key
        }
        return settings
    }
}
