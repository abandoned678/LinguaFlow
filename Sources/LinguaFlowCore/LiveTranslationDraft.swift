import CoreGraphics
import Foundation

public enum LiveTranslationDraft {
    public static func sourceText(
        committed: SentenceSnapshot?,
        provisionalCandidate: String?
    ) -> String? {
        if case .text(let value) = evaluate(committed: committed, provisionalCandidate: provisionalCandidate) {
            return value
        }
        return nil
    }

    public enum State: Equatable, Sendable {
        case empty
        case text(String)
        case overlong
    }

    public static func evaluate(
        committed: SentenceSnapshot?,
        provisionalCandidate: String?
    ) -> State {
        let candidate = provisionalCandidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = committed?.isFinal == true && !candidate.isEmpty ? nil : committed
        if base?.isOverlong == true { return .overlong }
        let text = (base?.text ?? "") + candidate
        if text.count > 280 { return .overlong }
        return text.isEmpty ? .empty : .text(text)
    }
}

public enum UnifiedPanelLayout {
    public static let minimumWidth: CGFloat = 220
    public static let maximumWidth: CGFloat = 440
    public static let horizontalPadding: CGFloat = 12
    public static let verticalPadding: CGFloat = 12
    public static let rowSpacing: CGFloat = 4
    public static let screenMargin: CGFloat = 6
    public static let anchorGap: CGFloat = 6

    public static func size(
        contentWidths: [CGFloat],
        rowHeights: [CGFloat]
    ) -> CGSize {
        let measuredWidth = (contentWidths.max() ?? 0) + horizontalPadding * 2
        let width = min(max(measuredWidth, minimumWidth), maximumWidth)
        let rowsHeight = rowHeights.reduce(0, +)
        let spacing = CGFloat(max(0, rowHeights.count - 1)) * rowSpacing
        let height = rowsHeight + spacing + verticalPadding * 2
        return CGSize(width: ceil(width), height: ceil(height))
    }

    public static func origin(
        anchor: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let minimumX = visibleFrame.origin.x + screenMargin
        let maximumX = max(
            minimumX,
            visibleFrame.origin.x + visibleFrame.size.width - panelSize.width - screenMargin
        )
        let x = min(max(anchor.origin.x, minimumX), maximumX)

        let minimumY = visibleFrame.origin.y + screenMargin
        let maximumY = max(
            minimumY,
            visibleFrame.origin.y + visibleFrame.size.height - panelSize.height - screenMargin
        )
        let below = anchor.origin.y - panelSize.height - anchorGap
        let preferredY = below >= minimumY
            ? below
            : anchor.origin.y + anchor.size.height + anchorGap
        let y = min(max(preferredY, minimumY), maximumY)

        return CGPoint(x: x, y: y)
    }

    public static func firstUsableAnchor(
        candidates: [CGRect],
        fallback: CGRect? = nil,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        (candidates + [fallback].compactMap { $0 }).first { rect in
            guard
                rect.origin.x.isFinite,
                rect.origin.y.isFinite,
                rect.size.width.isFinite,
                rect.size.height.isFinite,
                rect.size.height > 1
            else {
                return false
            }

            return visibleFrames.contains { frame in
                frame.insetBy(dx: 1, dy: 1).contains(rect.origin)
            }
        }
    }
}
