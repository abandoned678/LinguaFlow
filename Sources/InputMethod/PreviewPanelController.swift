import AppKit
import InputCore
import OSLog
import RimeInput

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PreviewPanelController {
    enum TranslationState: Equatable {
        case hidden
        case waiting
        case loading
        case result(String)
        case message(String)
        case action(String, button: String)
    }

    enum CandidateTarget: Equatable {
        case candidate(Int), previousPage, nextPage
    }

    struct CandidateInteraction {
        let owner: ObjectIdentifier
        let revision: UInt64
        let canPageBackward: Bool
        let canPageForward: Bool
        let perform: (CandidateTarget) -> Void

        func matches(_ other: Self) -> Bool {
            owner == other.owner && revision == other.revision
        }
    }

    static let shared = PreviewPanelController()

    private let panel: NSPanel
    private let previewView: PreviewView
    private let scrollView = NSScrollView(frame: .zero)
    private var activeOwner: ObjectIdentifier?

    private init() {
        previewView = PreviewView(frame: .zero)
        panel = PreviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = previewView
        panel.contentView = scrollView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    func update(
        owner: AnyObject,
        isComposing: Bool,
        sourceText: String?,
        candidates: [RimeCandidate],
        highlightedIndex: Int,
        translation: TranslationState,
        direction: TranslationDirection,
        spellingCorrection: EnglishSpellingCorrection?,
        settings: InputSettings,
        candidateInteraction: CandidateInteraction?,
        action: (() -> Void)?
    ) {
        activeOwner = ObjectIdentifier(owner)
        previewView.update(
            isComposing: isComposing,
            sourceText: sourceText,
            candidates: Array(candidates.prefix(5)),
            highlightedIndex: highlightedIndex,
            translation: translation,
            direction: direction,
            spellingCorrection: spellingCorrection,
            settings: settings,
            candidateInteraction: candidateInteraction,
            action: action
        )
    }

    var hasContent: Bool { previewView.hasContent }

    func ownsPanel(_ owner: AnyObject) -> Bool {
        activeOwner == ObjectIdentifier(owner)
    }

    func show(owner: AnyObject, near anchor: NSRect, clientWindowLevel: CGWindowLevel?) {
        guard activeOwner == ObjectIdentifier(owner) else { return }

        if let clientWindowLevel {
            let level = NSWindow.Level(rawValue: Int(clientWindowLevel) + 1)
            if panel.level != level { panel.level = level }
        }

        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(anchor) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let content = previewView.preferredSize
        let maxHeight = max(1, visibleFrame.height - UnifiedPanelLayout.screenMargin * 2)
        let size = NSSize(width: content.width, height: min(content.height, maxHeight))
        let scrolls = content.height > size.height
        if scrollView.hasVerticalScroller != scrolls { scrollView.hasVerticalScroller = scrolls }
        let ignoresMouseEvents = !previewView.hasAction && !previewView.hasCandidateInteraction && !scrolls
        if panel.ignoresMouseEvents != ignoresMouseEvents { panel.ignoresMouseEvents = ignoresMouseEvents }
        if panel.contentRect(forFrameRect: panel.frame).size != size {
            panel.setContentSize(size)
        }
        let origin = UnifiedPanelLayout.origin(anchor: anchor, panelSize: size, visibleFrame: visibleFrame)

        if abs(panel.frame.origin.x - origin.x) > 0.5
            || abs(panel.frame.origin.y - origin.y) > 0.5
        {
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide(owner: AnyObject, relinquishOwnership: Bool = true) {
        guard activeOwner == nil || activeOwner == ObjectIdentifier(owner) else { return }
        panel.orderOut(nil)
        if relinquishOwnership {
            activeOwner = nil
            previewView.clear()
            panel.ignoresMouseEvents = true
        }
    }
}

private final class PreviewActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class PreviewView: NSView {
    private static let timing = OSSignposter(
        subsystem: "com.abandoned678.inputmethod.SentenceAlong", category: "InputTiming"
    )
    private(set) var preferredSize = NSSize(width: UnifiedPanelLayout.minimumWidth, height: 28)
    private var isComposing = false
    private var sourceText: String?
    private var candidates: [RimeCandidate] = []
    private var highlightedIndex = 0
    private var translation: PreviewPanelController.TranslationState = .hidden
    private var direction = TranslationDirection.chineseToEnglish
    private var spellingCorrection: EnglishSpellingCorrection?
    private var action: (() -> Void)?
    private var candidateInteraction: PreviewPanelController.CandidateInteraction?
    private var pressedCandidate: PreviewPanelController.CandidateTarget?
    private var candidateBounds: [(PreviewPanelController.CandidateTarget, NSRect)] = []
    private let actionButton = PreviewActionButton(frame: .zero)
    private let actionHeight: CGFloat = 24

    private var layout = InputSettings.PreviewLayout.standard
    private var size = InputSettings.PreviewSize.standard
    private var shortcutKeyCode = SentenceReplacementShortcut.defaultKeyCode
    private var regularFont = NSFont.systemFont(ofSize: 14)
    private var labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var shortcutFont = NSFont.systemFont(ofSize: 10)
    private var labelColumnWidth: CGFloat { layout == .compact ? 0 : ceil(26 * size.fontScale) }
    private var lineHeight: CGFloat { ceil(20 * size.fontScale) }
    private var candidateHeight: CGFloat { ceil(23 * size.fontScale) }
    private var candidateGap: CGFloat { 4 }
    private var candidateInset: CGFloat { 5 }
    private var shortcutHeight: CGFloat { ceil(16 * size.fontScale) }
    private var reservedTranslationHeight: CGFloat = 0

    var hasAction: Bool { action != nil }
    var hasCandidateInteraction: Bool { candidateInteraction != nil && !candidates.isEmpty }
    var hasContent: Bool {
        headerContent != nil || !candidates.isEmpty || spellingCorrection != nil || translationText != nil
    }

    private var contentX: CGFloat { UnifiedPanelLayout.horizontalPadding }
    private var valueX: CGFloat { contentX + labelColumnWidth }
    private var valueWidth: CGFloat { bounds.width - valueX - contentX }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("随键译输入、纠错与翻译预览")
        actionButton.target = self
        actionButton.action = #selector(performPreviewAction)
        actionButton.controlSize = .small
        actionButton.bezelStyle = .rounded
        actionButton.isHidden = true
        addSubview(actionButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        isComposing: Bool,
        sourceText: String?,
        candidates: [RimeCandidate],
        highlightedIndex: Int,
        translation: PreviewPanelController.TranslationState,
        direction: TranslationDirection,
        spellingCorrection: EnglishSpellingCorrection?,
        settings: InputSettings,
        candidateInteraction: PreviewPanelController.CandidateInteraction?,
        action: (() -> Void)?
    ) {
        let highlightChanged = self.highlightedIndex != highlightedIndex
        let layoutChanged = self.isComposing != isComposing
            || self.sourceText != sourceText
            || self.candidates != candidates
            || self.translation != translation
            || self.direction != direction
            || self.spellingCorrection != spellingCorrection
            || layout != settings.previewLayout
            || size != settings.previewSize
            || shortcutKeyCode != settings.replacementKeyCode
            || self.candidateInteraction?.canPageBackward != candidateInteraction?.canPageBackward
            || self.candidateInteraction?.canPageForward != candidateInteraction?.canPageForward

        let sameSentence: Bool
        if let sourceText, let previous = self.sourceText {
            sameSentence = sourceText.hasPrefix(previous) || previous.hasPrefix(sourceText)
        } else {
            sameSentence = false
        }
        if size != settings.previewSize || layout != settings.previewLayout || translation == .hidden || !sameSentence {
            reservedTranslationHeight = 0
        }
        if size != settings.previewSize {
            let scale = settings.previewSize.fontScale
            regularFont = NSFont.systemFont(ofSize: 14 * scale)
            labelFont = NSFont.systemFont(ofSize: 11 * scale, weight: .medium)
            shortcutFont = NSFont.systemFont(ofSize: 10 * scale)
        }
        size = settings.previewSize
        layout = settings.previewLayout
        shortcutKeyCode = settings.replacementKeyCode
        self.isComposing = isComposing
        self.sourceText = sourceText
        self.candidates = candidates
        self.highlightedIndex = highlightedIndex
        self.translation = translation
        self.direction = direction
        self.spellingCorrection = spellingCorrection
        let sameCandidates = candidateInteraction.map { interaction in
            self.candidateInteraction?.matches(interaction) == true
        } ?? false
        if !sameCandidates { pressedCandidate = nil }
        self.candidateInteraction = candidateInteraction
        self.action = action
        if layoutChanged {
            candidateBounds.removeAll(keepingCapacity: true)
            let interval = Self.timing.beginInterval("Measure panel")
            preferredSize = calculateSize()
            Self.timing.endInterval("Measure panel", interval)
            if frame.size != preferredSize { frame.size = preferredSize }
            if case .action(_, let title) = translation, action != nil {
                actionButton.title = title
                actionButton.sizeToFit()
                actionButton.frame.origin = NSPoint(x: valueX, y: bounds.height - actionHeight)
                actionButton.isHidden = false
            } else {
                actionButton.isHidden = true
            }
        }
        if layoutChanged || highlightChanged {
            needsDisplay = true
            setAccessibilityValue(accessibilityText)
        }
    }

    func clear() {
        update(isComposing: false, sourceText: nil, candidates: [], highlightedIndex: 0,
               translation: .hidden, direction: direction, spellingCorrection: nil,
               settings: InputSettings(), candidateInteraction: nil, action: nil)
    }

    @objc private func performPreviewAction() {
        action?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard hasCandidateInteraction else { return }
        pressedCandidate = candidateTarget(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedCandidate = nil }
        guard let pressedCandidate, let candidateInteraction,
              candidateTarget(at: convert(event.locationInWindow, from: nil)) == pressedCandidate
        else { return }
        candidateInteraction.perform(pressedCandidate)
    }

    private func candidateTarget(at point: NSPoint) -> PreviewPanelController.CandidateTarget? {
        candidateBounds.first(where: { $0.1.contains(point) })?.0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Fade only the outer point of the background so text stays sharp.
        let backgroundColor = NSColor.windowBackgroundColor
        let edgeLayers: [(inset: CGFloat, opacity: CGFloat)] = [(0, 0.2), (0.5, 0.45), (1, 0.955)]
        for layer in edgeLayers {
            let rect = bounds.insetBy(dx: layer.inset, dy: layer.inset)
            let radius = 6 - layer.inset
            backgroundColor.withAlphaComponent(layer.opacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }

        var y = UnifiedPanelLayout.verticalPadding
        if let header = headerContent {
            let height = max(lineHeight, textHeight(header.value, width: valueWidth))
            drawLabeledText(label: header.label, value: header.value, y: y, height: height)
            y += height + UnifiedPanelLayout.rowSpacing
        }

        candidateBounds.removeAll(keepingCapacity: true)
        if !candidates.isEmpty {
            drawCandidates(y: y)
            y += candidateRowHeight + UnifiedPanelLayout.rowSpacing
        }

        if let spellingCorrection {
            drawCorrection(spellingCorrection, y: y)
            y += lineHeight + UnifiedPanelLayout.rowSpacing
        }

        if translationText != nil {
            if headerContent != nil || !candidates.isEmpty || spellingCorrection != nil {
                NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: contentX, y: y - UnifiedPanelLayout.rowSpacing / 2))
                divider.line(to: NSPoint(x: bounds.width - contentX, y: y - UnifiedPanelLayout.rowSpacing / 2))
                divider.lineWidth = 0.5
                divider.stroke()
            }
            drawTranslation(y: y)
        }
    }

    private var headerContent: (label: String, value: String)? {
        guard layout == .standard, !isComposing, let sourceText, !sourceText.isEmpty else { return nil }
        return (direction.sourceLabel, sourceText)
    }

    private var translationText: String? {
        switch translation {
        case .hidden:
            nil
        case .waiting:
            layout == .compact && isComposing ? nil : "等待翻译"
        case .loading:
            layout == .compact && isComposing ? nil : "正在翻译…"
        case .result(let value), .message(let value), .action(let value, _):
            value
        }
    }

    private var shortcutHint: String { "\(SentenceReplacementShortcut.label(for: shortcutKeyCode)) 替换当前句" }

    private func calculateSize() -> NSSize {
        var widths: [CGFloat] = []
        if let header = headerContent { widths.append(labeledTextWidth(header.value)) }
        if !candidates.isEmpty { widths.append(candidateRowWidth) }
        if let spellingCorrection {
            widths.append(labeledTextWidth("\(spellingCorrection.original) → \(spellingCorrection.replacement)   Tab 接受"))
        }
        if let translationText { widths.append(labeledTextWidth(translationText)) }
        if case .result = translation { widths.append(textWidth(shortcutHint, font: shortcutFont) + labelColumnWidth) }
        if case .action(_, let title) = translation { widths.append(textWidth(title, font: regularFont) + labelColumnWidth + 26) }

        let width = UnifiedPanelLayout.size(contentWidths: widths, rowHeights: []).width
        let textWidth = width - contentX * 2 - labelColumnWidth
        var heights: [CGFloat] = []
        if let header = headerContent { heights.append(max(lineHeight, textHeight(header.value, width: textWidth))) }
        if !candidates.isEmpty { heights.append(candidateRowHeight) }
        if spellingCorrection != nil { heights.append(lineHeight) }
        if let translationText {
            var height = max(lineHeight, textHeight(translationText, width: textWidth))
            if case .result = translation { height += shortcutHeight }
            if case .action = translation { height += actionHeight }
            if layout == .standard {
                reservedTranslationHeight = min(max(reservedTranslationHeight, height, lineHeight + shortcutHeight), lineHeight * 3)
                height = max(height, reservedTranslationHeight)
            }
            heights.append(height)
        }
        return UnifiedPanelLayout.size(contentWidths: widths, rowHeights: heights)
    }

    private func drawLabeledText(label: String, value: String, y: CGFloat, height: CGFloat) {
        if labelColumnWidth > 0 {
            drawText(
                label,
                in: NSRect(x: contentX, y: y + 2, width: labelColumnWidth - 2, height: lineHeight),
                color: .secondaryLabelColor,
                font: labelFont,
                lineBreakMode: .byClipping
            )
        }
        drawText(
            value,
            in: NSRect(x: valueX, y: y, width: valueWidth, height: height),
            color: .labelColor,
            font: regularFont,
            lineBreakMode: .byWordWrapping
        )
    }

    private struct CandidateItem {
        let target: PreviewPanelController.CandidateTarget
        let title: String
        let width: CGFloat
        let active: Bool
        let highlighted: Bool
    }

    private var candidateItems: [CandidateItem] {
        var items = candidates.enumerated().map { index, candidate in
            CandidateItem(
                target: .candidate(index),
                title: candidateTitle(at: index, candidate: candidate),
                width: candidateWidth(at: index, candidate: candidate),
                active: hasCandidateInteraction,
                highlighted: index == highlightedIndex
            )
        }
        if let interaction = candidateInteraction, interaction.canPageBackward || interaction.canPageForward {
            let width = ceil(24 * size.fontScale)
            items += [
                CandidateItem(target: .previousPage, title: "‹", width: width, active: interaction.canPageBackward, highlighted: false),
                CandidateItem(target: .nextPage, title: "›", width: width, active: interaction.canPageForward, highlighted: false),
            ]
        }
        return items
    }

    private func candidateFrames(items: [CandidateItem], width: CGFloat, y: CGFloat) -> [(CandidateItem, NSRect)] {
        var x = contentX
        var rowY = y
        let maximumX = contentX + width
        return items.map { item in
            let itemWidth = min(item.width, width)
            if x > contentX, x + itemWidth > maximumX {
                x = contentX
                rowY += candidateHeight + UnifiedPanelLayout.rowSpacing
            }
            defer { x += itemWidth + candidateGap }
            return (item, NSRect(x: x, y: rowY, width: itemWidth, height: candidateHeight))
        }
    }

    private func drawCandidates(y: CGFloat) {
        let items = candidateFrames(items: candidateItems, width: bounds.width - contentX * 2, y: y)
        for (item, rect) in items {
            let isNavigation: Bool
            switch item.target {
            case .candidate: isNavigation = false
            case .previousPage, .nextPage: isNavigation = true
            }
            if item.active { candidateBounds.append((item.target, rect)) }
            if item.highlighted || isNavigation {
                let fill = item.highlighted
                    ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                    : NSColor.labelColor.withAlphaComponent(0.08)
                fill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let color: NSColor = item.highlighted
                ? .controlAccentColor : (isNavigation && !item.active ? .tertiaryLabelColor : .labelColor)
            drawText(
                item.title,
                in: rect.insetBy(dx: candidateInset, dy: 2),
                color: color,
                font: regularFont,
                lineBreakMode: .byTruncatingTail
            )
        }
    }

    private func drawTranslation(y: CGFloat) {
        guard let translationText else { return }

        if labelColumnWidth > 0, case .result = translation {
            drawText(
                direction.targetLabel,
                in: NSRect(x: contentX, y: y + 2, width: labelColumnWidth - 2, height: lineHeight),
                color: .secondaryLabelColor,
                font: labelFont,
                lineBreakMode: .byClipping
            )
        }

        let availableWidth = valueWidth
        let height = textHeight(translationText, width: availableWidth)
        let color: NSColor = translation == .loading || translation == .waiting ? .secondaryLabelColor : .labelColor
        drawText(
            translationText,
            in: NSRect(x: valueX, y: y, width: availableWidth, height: height),
            color: color,
            font: regularFont,
            lineBreakMode: .byWordWrapping
        )

        if case .result = translation {
            drawText(
                shortcutHint,
                in: NSRect(x: valueX, y: y + height + 2, width: availableWidth, height: shortcutHeight),
                color: .tertiaryLabelColor,
                font: shortcutFont,
                lineBreakMode: .byClipping
            )
        }
    }

    private func drawCorrection(_ correction: EnglishSpellingCorrection, y: CGFloat) {
        if labelColumnWidth > 0 {
            drawText(
                "纠错",
                in: NSRect(x: contentX, y: y + 2, width: labelColumnWidth - 2, height: lineHeight),
                color: .systemOrange,
                font: labelFont,
                lineBreakMode: .byClipping
            )
        }
        drawText(
            "\(correction.original) → \(correction.replacement)   Tab 接受",
            in: NSRect(x: valueX, y: y, width: valueWidth, height: lineHeight),
            color: .labelColor,
            font: regularFont,
            lineBreakMode: .byTruncatingTail
        )
    }

    private var candidateRowWidth: CGFloat {
        let widths = candidateItems.map(\.width)
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * candidateGap
    }

    private var candidateRowHeight: CGFloat {
        candidateFrames(items: candidateItems, width: UnifiedPanelLayout.maximumWidth - contentX * 2, y: 0)
            .last?.1.maxY ?? 0
    }

    private func candidateWidth(at index: Int, candidate: RimeCandidate) -> CGFloat {
        textWidth(candidateTitle(at: index, candidate: candidate), font: regularFont) + candidateInset * 2
    }

    private func candidateTitle(at index: Int, candidate: RimeCandidate) -> String {
        let prefix = "\(index + 1) \(candidate.text)"
        guard
            direction == .englishToChinese,
            let comment = candidate.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
            !comment.isEmpty
        else {
            return prefix
        }
        return "\(prefix) · \(comment)"
    }

    private func labeledTextWidth(_ value: String) -> CGFloat {
        labelColumnWidth + textWidth(value, font: regularFont)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: regularFont]
        )
        return ceil(rect.height)
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        color: NSColor,
        font: NSFont,
        lineBreakMode: NSLineBreakMode
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private var accessibilityText: String {
        let candidateText = candidates.enumerated().map { index, candidate in
            candidateTitle(at: index, candidate: candidate)
        }.joined(separator: "，")
        let values = [
            headerContent.map { "\($0.label) \($0.value)" },
            candidateText.isEmpty ? nil : "候选 \(candidateText)",
            spellingCorrection.map { "纠错 \($0.original) 改为 \($0.replacement)" },
            translationText.map { "\(direction.targetLabel) \($0)" },
        ]
        return values.compactMap { $0 }.joined(separator: "。")
    }
}
