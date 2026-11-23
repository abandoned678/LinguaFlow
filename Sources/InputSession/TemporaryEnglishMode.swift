/// The temporary input mode belongs to the current host input session.
public struct TemporaryEnglishMode {
    public private(set) var isEnglish = false
    public private(set) var pendingShiftKey: UInt16?

    private var overlappingShifts = false

    public init() {}

    public mutating func activate(continuingSameClient: Bool) {
        guard !continuingSameClient else { return }
        cancelGesture()
        isEnglish = false
    }

    public mutating func cancelGesture() {
        pendingShiftKey = nil
        overlappingShifts = false
    }

    public mutating func shiftDown(_ key: UInt16) {
        // IMK can deliver the same flagsChanged edge twice for a physical tap.
        guard pendingShiftKey != key else { return }
        if pendingShiftKey != nil { overlappingShifts = true }
        pendingShiftKey = key
    }

    public mutating func acceptsRelease(_ key: UInt16) -> Bool {
        defer { cancelGesture() }
        return !overlappingShifts && pendingShiftKey == key
    }

    public mutating func toggle() { isEnglish.toggle() }
}
