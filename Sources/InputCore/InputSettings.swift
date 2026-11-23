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

    public enum PreviewOverride: String, CaseIterable, Sendable {
        case followGlobal, enabled, disabled

        public var label: String {
            switch self {
            case .followGlobal: "跟随全局"
            case .enabled: "开启预览"
            case .disabled: "关闭预览"
            }
        }
    }

    public enum PagingKeys: String, CaseIterable, Sendable {
        case standard, brackets

        public var label: String {
            switch self {
            case .standard: "Page Up / Down、- / ="
            case .brackets: "标准键及 [ / ]"
            }
        }
    }

    public var pinyinLayout = PinyinLayout.full
    public var fuzzyInitials: Set<FuzzyInitial> = []
    public var learnsWords = true
    public var candidatePageSize = 5
    public var translationDirection = TranslationDirection.chineseToEnglish
    public var appPreviewOverrides: [String: PreviewOverride] = [:]
    public var shiftTogglesEnglish = false
    public var usesASCIIPunctuation = false
    public var pagingKeys = PagingKeys.standard

    public func previewEnabled(for bundleID: String?) -> Bool {
        switch bundleID.flatMap({ appPreviewOverrides[$0] }) ?? .followGlobal {
        case .followGlobal: translationEnabled
        case .enabled: true
        case .disabled: false
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
        if !(5...10).contains(settings.candidatePageSize) { settings.candidatePageSize = previous.candidatePageSize }
        settings.appPreviewOverrides = settings.appPreviewOverrides.filter { !$0.key.isEmpty && $0.value != .followGlobal }
        guard settings != previous else { return }
        fields["version"] = max(fields["version"] as? Int ?? 0, Self.version)
        if settings.pinyinLayout != previous.pinyinLayout { fields["pinyinLayout"] = settings.pinyinLayout.rawValue }
        if settings.fuzzyInitials != previous.fuzzyInitials { fields["fuzzyInitials"] = settings.fuzzyInitials.map(\.rawValue).sorted() }
        if settings.learnsWords != previous.learnsWords { fields["learnsWords"] = settings.learnsWords }
        if settings.candidatePageSize != previous.candidatePageSize { fields["candidatePageSize"] = settings.candidatePageSize }
        if settings.translationDirection != previous.translationDirection { fields["translationDirection"] = settings.translationDirection.rawValue }
        if settings.pagingKeys != previous.pagingKeys { fields["pagingKeys"] = settings.pagingKeys.rawValue }
        if settings.shiftTogglesEnglish != previous.shiftTogglesEnglish { fields["shiftTogglesEnglish"] = settings.shiftTogglesEnglish }
        if settings.usesASCIIPunctuation != previous.usesASCIIPunctuation { fields["usesASCIIPunctuation"] = settings.usesASCIIPunctuation }
        if settings.appPreviewOverrides != previous.appPreviewOverrides {
            fields["appPreviewOverrides"] = settings.appPreviewOverrides.mapValues(\.rawValue)
        }
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
        if let raw = fields["pinyinLayout"] as? String, let layout = PinyinLayout(rawValue: raw) {
            settings.pinyinLayout = layout
        }
        if let raw = fields["fuzzyInitials"] as? [String] { settings.fuzzyInitials = Set(raw.compactMap(FuzzyInitial.init(rawValue:))) }
        if let flag = fields["learnsWords"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
            settings.learnsWords = flag.boolValue
        }
        if let size = fields["candidatePageSize"] as? NSNumber, (5...10).contains(size.intValue),
           size.doubleValue == Double(size.intValue) { settings.candidatePageSize = size.intValue }
        if let raw = fields["translationDirection"] as? String, let direction = TranslationDirection(rawValue: raw) {
            settings.translationDirection = direction
        }
        if let raw = fields["pagingKeys"] as? String, let keys = InputSettings.PagingKeys(rawValue: raw) {
            settings.pagingKeys = keys
        }
        if let raw = fields["appPreviewOverrides"] as? [String: Any] {
            settings.appPreviewOverrides = raw.compactMapValues { ($0 as? String).flatMap(InputSettings.PreviewOverride.init(rawValue:)) }
                .filter { !$0.key.isEmpty && $0.value != .followGlobal }
        }
        if let flag = fields["shiftTogglesEnglish"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
            settings.shiftTogglesEnglish = flag.boolValue
        }
        if let flag = fields["usesASCIIPunctuation"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
            settings.usesASCIIPunctuation = flag.boolValue
        }
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
