import AppKit

/// A transcript row holding wrapping text, which needs to know the width it
/// gets to report its height.
@MainActor
protocol TranscriptRow: NSView {
    func fit(width: CGFloat)
}

/// The scrolling column of messages. Flipped so rows stack from the top.
final class TranscriptView: NSView {
    private let stack = NSStackView()
    /// The same as the composer's, so messages line up with it.
    private static let inset: CGFloat = 12
    private var lastWidth: CGFloat = 0
    /// The "Thinking…" row while the agent has nothing to show yet.
    private var thinking: ThinkingRowView?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { stack.arrangedSubviews.allSatisfy { $0 is ThinkingRowView } }

    /// The group taking tool calls until any other row, or `closeToolGroup()`.
    private var openGroup: ToolGroupView?

    /// Tool calls that follow one another go into one group; any other row
    /// ends the group. Whatever the agent was busy with has ended.
    func add(_ row: NSView) {
        hideThinking()
        activity = nil
        if let call = row as? ToolRowView, !call.tool.hasPrefix("/") {
            if let openGroup {
                openGroup.add(call)
                needsLayout = true
            } else {
                let group = ToolGroupView(first: call)
                add(group)
                openGroup = group
            }
            return
        }
        closeToolGroup()
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if lastWidth > 0 { Self.fit(row, width: lastWidth) }
        needsLayout = true
    }

    /// Ends the current run of tool calls, folding them under their header.
    func closeToolGroup() {
        openGroup?.close()
        openGroup = nil
    }

    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        openGroup = nil
        thinking = nil
        staleRows.removeAll()
    }

    /// Puts a "Thinking…" row after the last row, until something else
    /// comes. It leaves a run of tool calls open: the next call joins it.
    func showThinking() {
        guard thinking == nil else { return }
        let row = ThinkingRowView()
        row.activity = activity
        thinking = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        needsLayout = true
    }

    /// What the agent is busy with, which the Thinking row says in place of
    /// its phrases, with a line of detail under it; nil when unknown.
    var activity: (text: String, detail: String?)? {
        didSet { thinking?.activity = activity }
    }

    /// When the Thinking row showing came.
    var waitStarted: Date? { thinking?.started }

    #if DEBUG
    var thinkingForTesting: ThinkingRowView? { thinking }
    #endif

    func hideThinking() {
        thinking?.removeFromSuperview()
        thinking = nil
    }

    var isThinking: Bool { thinking != nil }

    /// Whether the bottom of the transcript is in view, give or take a line.
    /// The clip runs under the scroll view's bottom inset, which isn't text.
    func isNearBottom(of scrollView: NSScrollView) -> Bool {
        scrollView.contentView.bounds.maxY - scrollView.contentInsets.bottom >= frame.height - 40
    }

    /// Only a width change re-measures every row; new rows are measured as
    /// they are added. While the window or panel is being resized, only the
    /// rows within a screen of the visible ones are, every frame; the rest
    /// wait for the drag to end, or to be scrolled near.
    override func layout() {
        let width = bounds.width - 2 * Self.inset
        if width != lastWidth, width > 0 {
            lastWidth = width
            if inLiveResize {
                staleRows = Set(stack.arrangedSubviews.map(ObjectIdentifier.init))
            } else {
                staleRows.removeAll()
                for row in stack.arrangedSubviews { Self.fit(row, width: width) }
            }
        }
        if !staleRows.isEmpty {
            let visible = visibleRect
            fitStaleRows(near: inLiveResize ? visible.insetBy(dx: 0, dy: -visible.height) : nil)
        }
        super.layout()
    }

    /// Rows not yet measured for the current width.
    private var staleRows = Set<ObjectIdentifier>()

    /// The stale rows within `rect`, or all of them.
    private func fitStaleRows(near rect: NSRect?) {
        for row in stack.arrangedSubviews where staleRows.contains(ObjectIdentifier(row)) {
            if let rect, !convert(row.bounds, from: row).intersects(rect) { continue }
            staleRows.remove(ObjectIdentifier(row))
            Self.fit(row, width: lastWidth)
        }
    }

    /// A scroll during a resize brings stale rows near, which are measured
    /// on the next layout.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipScrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipScrolled(_ notification: Notification) {
        if inLiveResize, !staleRows.isEmpty { needsLayout = true }
    }

    /// The rest of the rows are measured once the drag ends. A transcript
    /// scrolled to the end stays there, though the rows above grew or shrank.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard !staleRows.isEmpty else { return }
        let scrollView = enclosingScrollView
        let follow = scrollView.map(isNearBottom(of:)) ?? false
        fitStaleRows(near: nil)
        guard follow, let scrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        // The clip spans the insets, so the top rests at minus the top inset.
        let clip = scrollView.contentView, insets = scrollView.contentInsets
        let y = max(-insets.top, frame.height - clip.bounds.height + insets.bottom)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// A chat hidden through a resize measures its rows when shown.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if !staleRows.isEmpty { needsLayout = true }
    }

    private static func fit(_ row: NSView, width: CGFloat) {
        if let row = row as? TranscriptRow {
            row.fit(width: width)
        } else if let label = row as? NSTextField, label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
        }
    }
}

// MARK: Rows

/// A user message: its images, then a tinted bubble with its text, on the right.
final class UserMessageView: NSView, TranscriptRow {
    private let bubble = NSView()
    private let label: NSTextField
    /// Room kept free to the bubble's left, so it reads as a reply side.
    private static let leftMargin: CGFloat = 36
    private static let padding = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    /// `onOpenImage` gets the index of a clicked image.
    init(text: String, images: [NSImage] = [], onOpenImage: ((Int) -> Void)? = nil) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        label.isSelectable = true
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = Theme.Radius.plate
        bubble.layer?.cornerCurve = .continuous
        let grid = ThumbnailGrid(side: 64, alignment: .trailing)
        grid.images = images
        grid.onOpen = onOpenImage
        for view in [grid, bubble, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(grid)
        addSubview(bubble)
        bubble.addSubview(label)
        bubble.isHidden = text.isEmpty
        let p = Self.padding
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftMargin),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.isEmpty
                ? grid.bottomAnchor.constraint(equalTo: bottomAnchor)
                : bubble.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: images.isEmpty ? 0 : 6),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.leftMargin),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: p.top),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -p.bottom),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p.left),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -p.right),
        ])
        if !text.isEmpty { bubble.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - Self.leftMargin - Self.padding.left - Self.padding.right
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        bubble.layer?.backgroundColor = Theme.accent(Theme.Accent.bubble).layerColor
    }
}

/// Square image thumbnails in rows that wrap to the grid's width. Clicking one
/// opens it; with `onRemove` set, each also gets a remove button.
final class ThumbnailGrid: NSView {
    enum Alignment { case leading, trailing }

    var onOpen: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    /// Only the thumbnails are kept; the images given are let go once they
    /// are drawn small.
    var images: [NSImage] {
        get { [] }
        set { rebuild(with: newValue) }
    }

    private let side: CGFloat
    private let alignment: Alignment
    private var thumbnails: [ThumbnailView] = []
    private static let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    init(side: CGFloat, alignment: Alignment) {
        self.side = side
        self.alignment = alignment
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild(with images: [NSImage]) {
        thumbnails.forEach { $0.removeFromSuperview() }
        thumbnails = images.enumerated().map { index, image in
            // VoiceOver tells the images apart by name, or else by place.
            let label = image.name() ?? "Image \(index + 1)"
            let thumbnail = ThumbnailView(image: image, label: label, removable: onRemove != nil)
            thumbnail.onOpen = { [weak self] in self?.onOpen?(index) }
            thumbnail.onRemove = { [weak self] in self?.onRemove?(index) }
            addSubview(thumbnail)
            return thumbnail
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Before the grid has a width, everything goes in one row.
    private var perRow: Int {
        guard bounds.width > 0 else { return max(1, thumbnails.count) }
        return max(1, Int((bounds.width + Self.spacing) / (side + Self.spacing)))
    }

    override var intrinsicContentSize: NSSize {
        let rows = (thumbnails.count + perRow - 1) / perRow
        return NSSize(width: NSView.noIntrinsicMetric, height: rows == 0 ? 0 : CGFloat(rows) * (side + Self.spacing) - Self.spacing)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let perRow = perRow
        for (index, thumbnail) in thumbnails.enumerated() {
            let column = CGFloat(index % perRow), row = CGFloat(index / perRow)
            let offset = column * (side + Self.spacing)
            let x = alignment == .leading ? offset : bounds.width - side - offset
            thumbnail.frame = NSRect(x: x, y: row * (side + Self.spacing), width: side, height: side)
        }
    }
}

/// One thumbnail: the image filling a rounded square, with an optional
/// remove button in its corner. The square shows a copy of the image shrunk
/// to its size: a screenshot's full bitmap would otherwise sit in the
/// layer for every thumbnail in a long chat.
private final class ThumbnailView: NSView {
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private let image: NSImage

    init(image: NSImage, label: String, removable: Bool) {
        self.image = Self.thumbnail(of: image, side: 128)
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Click to preview"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        guard removable else { return }
        let remove = ThumbnailRemoveButton()
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.toolTip = "Remove"
        remove.setAccessibilityLabel("Remove Image")
        remove.target = self
        remove.action = #selector(removeClicked(_:))
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeClicked(_ sender: Any?) { onRemove?() }

    /// `image` cropped to a square from its middle and drawn `side` points
    /// wide, which is enough for a thumbnail on any screen.
    private static func thumbnail(of image: NSImage, side: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > side || size.height > side, size.width > 0, size.height > 0 else { return image }
        let crop = min(size.width, size.height)
        let source = NSRect(x: (size.width - crop) / 2, y: (size.height - crop) / 2, width: crop, height: crop)
        let thumbnail = NSImage(size: NSSize(width: side, height: side))
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: source, operation: .copy, fraction: 1)
        thumbnail.unlockFocus()
        return thumbnail
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = Theme.Radius.row
        layer.cornerCurve = .continuous
        layer.borderWidth = Theme.hairlineWidth
        layer.borderColor = Theme.hairline.layerColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

/// The cross in a thumbnail's corner. It stays in view, since the image
/// under it can be any color, and its plate darkens under the mouse so it
/// reads as the thing a click will hit.
private final class ThumbnailRemoveButton: NSButton {
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateImage() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateImage() {
        let plate = NSColor.black.withAlphaComponent(isHovered ? 0.8 : 0.6)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove Image")?
            .withSymbolConfiguration(.init(paletteColors: [.white, plate]))
    }

    /// Only this area is replaced, so the ones AppKit keeps for the tooltip stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// One tool call: a spinner, then a check or a cross, beside the tool and
/// what it acted on. A running call shows its arguments on a few lines under
/// its name, and after a few seconds how long it has run; a finished one
/// keeps a single line. A failed call adds the first line of its error. The
/// whole input shows on hover. With `disclosure`, the row is the clickable
/// header of a `ToolGroupView`, with a chevron for its state. A reasoning
/// row is a step too, which a click opens to its text.
final class ToolRowView: NSView, TranscriptRow {
    enum Outcome { case running, done, failed, unfinished }

    /// The tool's name without the MCP server prefix.
    private(set) var tool: String
    private(set) var outcome = Outcome.running
    /// Called when the call finishes, whichever way.
    var onFinish: (() -> Void)?
    /// Called when a disclosure row is clicked.
    var onToggle: (() -> Void)?
    var isExpanded = false {
        didSet {
            chevron?.image = Self.chevronImage(expanded: isExpanded)
            if chevron != nil { setAccessibilityExpanded(isExpanded) }
        }
    }

    /// The icon column and the text column that the Thinking row and error
    /// boxes share, so their icons and text line up down the transcript.
    static let iconLeading: CGFloat = 9
    static let iconWidth: CGFloat = 14
    static let textLeading = iconLeading + iconWidth + 7

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let chevron: NSImageView?
    private var detail: String
    private var heading: NSAttributedString
    /// What a running run_task is doing now, under its goal, or the last
    /// line a running command printed, set in code type.
    private var progress: (text: String, isOutput: Bool)?
    /// When the call started, and the timer that shows how long it has run.
    private let started = Date()
    private var ticker: Timer?
    /// A reasoning row's whole text, shown under its heading when open.
    private var body: String?

    /// `detail` is what `detail(_:)` made of the call's input, and `full`
    /// what `full(_:detail:)` did. A `finished` row, as a saved chat's are,
    /// starts with its outcome and never spins.
    init(name: String, detail: String, full: String? = nil, disclosure: Bool = false, finished: (isError: Bool?, summary: String)? = nil) {
        tool = Self.tool(name)
        self.detail = detail
        heading = Self.heading(tool: tool, detail: detail)
        chevron = disclosure ? NSImageView(image: Self.chevronImage(expanded: false)!) : nil
        super.init(frame: .zero)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        icon.isHidden = true
        // Without this, a line cut by the limit ends at a word break with no
        // ellipsis when the text would have wrapped there.
        label.cell?.truncatesLastVisibleLine = true
        if !disclosure, let tip = full ?? (detail.isEmpty ? nil : detail) {
            // The label covers most of the row, and a tooltip is the view's
            // under the mouse.
            toolTip = tip
            label.toolTip = tip
        }
        for view in [spinner, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeading),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            icon.heightAnchor.constraint(equalToConstant: Self.iconWidth),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeading),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        if let chevron {
            chevron.contentTintColor = Theme.tertiaryText
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                chevron.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 12),
                label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            ])
            label.isSelectable = false
            // VoiceOver reads the row as one disclosure control, not its parts.
            setAccessibilityElement(true)
            label.setAccessibilityElement(false)
            setAccessibilityRole(.disclosureTriangle)
        } else {
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9).isActive = true
        }
        if let finished {
            finish(isError: finished.isError, summary: finished.summary)
        } else {
            showHeading()
            spinner.startAnimation(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A stretch of reasoning: "Thought for 12s" and its first heading or
    /// line. When there is more, a click opens the whole text under it.
    convenience init(reasoning text: String, seconds: Double?) {
        let title = Self.reasoningTitle(text)
        let plain = text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let more = plain != title
        self.init(name: "thinking", detail: title, disclosure: more, finished: (false, ""))
        let name = seconds.map { "Thought for " + ThinkingRowView.duration(max(1, $0)) } ?? "Thought"
        heading = Self.heading(name: name, detail: title)
        icon.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Reasoning")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.tertiaryText
        if more {
            body = plain
            onToggle = { [weak self] in
                guard let self else { return }
                self.isExpanded.toggle()
                self.showHeading()
            }
        } else if !title.isEmpty {
            toolTip = title
            label.toolTip = title
        }
        setAccessibilityLabel(heading.string)
        showHeading()
    }

    /// Codex's summaries start with a bold heading; other reasoning with
    /// its first line.
    private static func reasoningTitle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("**"), let end = trimmed.dropFirst(2).range(of: "**") {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<end.lowerBound])
        }
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    #if DEBUG
    var textForTesting: String { label.stringValue }
    #endif

    /// Fills in a call whose row showed before its input was complete.
    func fill(detail: String, full: String?) {
        guard chevron == nil else { return }
        self.detail = detail
        heading = Self.heading(tool: tool, detail: detail)
        if let tip = full ?? (detail.isEmpty ? nil : detail) {
            toolTip = tip
            label.toolTip = tip
        }
        showHeading()
    }

    // How long a call has run counts only while the row is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicker()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTicker()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTicker()
    }

    private func updateTicker() {
        let ticking = outcome == .running && chevron == nil && window != nil && !isHiddenOrHasHiddenAncestor
        guard ticking != (ticker != nil) else { return }
        ticker?.invalidate()
        ticker = nil
        guard ticking else { return }
        showHeading()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.started) >= ThinkingRowView.elapsedDelay else { return }
                self.showHeading()
            }
        }
    }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - 39 - (chevron == nil ? 0 : 18)
    }

    /// Changes what the row says. A group header counts its calls as they come.
    func update(name: String, detail: String) {
        tool = Self.tool(name)
        self.detail = detail
        heading = Self.heading(tool: tool, detail: detail)
        showHeading()
        setAccessibilityLabel(heading.string)
    }

    /// A running call's arguments get lines of their own under its name,
    /// broken anywhere, as a script has few spaces to break at. Otherwise
    /// they follow the name on one line, cut at its end.
    private func showHeading() {
        let running = outcome == .running && chevron == nil
        let wrapped = running && !detail.isEmpty
        let text: NSMutableAttributedString
        if running {
            let elapsed = Date().timeIntervalSince(started)
            text = NSMutableAttributedString(attributedString: Self.heading(name: Self.displayName(of: tool), detail: ""))
            if elapsed >= ThinkingRowView.elapsedDelay {
                text.append(NSAttributedString(string: "  " + ThinkingRowView.duration(elapsed), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: Theme.tertiaryText,
                ]))
            }
            if wrapped { text.append(Self.heading(name: "", detail: detail, separator: "\n")) }
        } else {
            text = NSMutableAttributedString(attributedString: heading)
        }
        if running, let progress {
            text.append(Self.subline(progress.text, color: progress.isOutput ? Theme.secondaryText : Theme.accentColor, code: progress.isOutput))
        }
        let open = isExpanded && body != nil
        if open, let body {
            text.append(NSAttributedString(string: "\n" + body, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: Theme.secondaryText,
            ]))
        }
        label.attributedStringValue = text
        label.lineBreakMode = open ? .byWordWrapping : wrapped ? .byCharWrapping : .byTruncatingTail
        label.maximumNumberOfLines = open ? 0 : wrapped ? (progress == nil ? 4 : 5) : running && progress != nil ? 2 : 1
        label.invalidateIntrinsicContentSize()
    }

    /// A line under the heading: a run_task's step, a command's output, or
    /// how it ended.
    private static func subline(_ text: String, color: NSColor, code: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: "\n" + text, attributes: [
            .font: code ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 11),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// What a running run_task is doing, from the window's reports of it,
    /// or with `isOutput` the last line a running command printed.
    func showProgress(_ text: String, isOutput: Bool = false) {
        guard outcome == .running, progress?.text != text else { return }
        progress = (text, isOutput)
        showHeading()
        setAccessibilityValue(text)
    }

    /// A group header spins only while one of its calls runs; between
    /// calls it shows an empty circle.
    func setRunning(_ running: Bool) {
        guard outcome == .running else { return }
        if running {
            icon.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            icon.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Waiting")?
                .withSymbolConfiguration(.init(pointSize: Theme.Symbol.row, weight: .medium))
            icon.contentTintColor = Theme.tertiaryText
            icon.isHidden = false
        }
    }

    /// A nil `isError` means the call never finished: the agent stopped first.
    func finish(isError: Bool?, summary: String) {
        spinner.stopAnimation(nil)
        ticker?.invalidate()
        ticker = nil
        icon.isHidden = false
        isHovered = false
        // Only a failure gets a color: a long run would otherwise be a
        // column of green. A run_task that ended short of its goal still
        // succeeded as a call, and gets a warning.
        let ending = isError == false && tool == "run_task" ? Self.taskEnding(summary) : nil
        let (symbol, description, color): (String, String, NSColor) = switch (isError, ending) {
        case (_, (let symbol, let description, let color)?): (symbol, description, color)
        case (true?, _): ("xmark.circle.fill", "Failed", Theme.danger)
        case (false?, _): ("checkmark.circle.fill", "Done", Theme.tertiaryText)
        case (nil, _): ("minus.circle.fill", "Didn't finish", Theme.tertiaryText)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = color
        outcome = switch isError {
        case true?: .failed
        case false?: .done
        case nil: .unfinished
        }
        showHeading()
        if isError == true || tool.hasPrefix("/"), !summary.isEmpty {
            let text = NSMutableAttributedString(attributedString: heading)
            text.append(NSAttributedString(string: "\n" + summary, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: isError == true ? Theme.danger : Theme.secondaryText,
            ]))
            label.attributedStringValue = text
            label.maximumNumberOfLines = tool.hasPrefix("/") ? 7 : 3
            label.invalidateIntrinsicContentSize()
        } else if let ending, !summary.isEmpty {
            let text = NSMutableAttributedString(attributedString: heading)
            text.append(Self.subline(summary, color: ending.color == Theme.tertiaryText ? Theme.secondaryText : ending.color))
            label.attributedStringValue = text
            label.maximumNumberOfLines = 2
            label.toolTip = [toolTip, summary].compactMap { $0 }.joined(separator: "\n\n")
            label.invalidateIntrinsicContentSize()
        }
        progress = nil
        onFinish?()
    }

    /// The mark for how a run_task ended, from its result's first line:
    /// tiller_mcp's summary, such as "Done in 2.4 s, 5 steps".
    static func taskEnding(_ summary: String) -> (symbol: String, description: String, color: NSColor)? {
        if summary.hasPrefix("Done") { return ("checkmark.circle.fill", "Done", Theme.tertiaryText) }
        if summary.hasPrefix("Blocked") || summary.hasPrefix("Out of steps") {
            return ("exclamationmark.triangle.fill", "Didn't get there", Theme.warning)
        }
        if summary.hasPrefix("Stopped") { return ("stop.circle.fill", "Stopped", Theme.tertiaryText) }
        if summary.hasPrefix("Error") { return ("xmark.circle.fill", "Failed", Theme.danger) }
        return nil
    }

    // Clicks anywhere on a disclosure row toggle it, the label included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return chevron != nil && hit != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if chevron != nil { isPressed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        if chevron != nil { isPressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if chevron != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard chevron != nil else { return false }
        onToggle?()
        return true
    }

    // A disclosure row takes keyboard focus, and Space or Return toggles it.
    // Only under Full Keyboard Access, as a button does: otherwise a click
    // on the row would take the keyboard from the message field.
    override var acceptsFirstResponder: Bool { chevron != nil && NSApp.isFullKeyboardAccessEnabled }

    override func keyDown(with event: NSEvent) {
        // Space, Return and the keypad's Enter.
        if chevron != nil, [49, 36, 76].contains(event.keyCode) {
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row).fill()
    }

    override var wantsUpdateLayer: Bool { true }

    /// A clickable header darkens a little under the mouse, and more while pressed.
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let alpha = chevron == nil ? Theme.Fill.rest
            : isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        // A fill this faint goes with Increase Contrast; an edge stays.
        layer?.borderWidth = Theme.increaseContrast ? Theme.hairlineWidth : 0
        layer?.borderColor = Theme.hairline.layerColor
    }

    /// Only this area is replaced, so the ones AppKit keeps for the tooltip stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard chevron != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private static func tool(_ name: String) -> String {
        // Chats saved before the rename from Mini carry the old server name.
        let prefix = ["mcp__tiller__", "mcp__mini__"].first { name.hasPrefix($0) }
        return prefix.map { String(name.dropFirst($0.count)) } ?? name
    }

    /// What a tool is called in the transcript: Tiller's and the CLIs'
    /// built-in tools by what they do, anything else as named.
    static func displayName(of tool: String) -> String {
        switch tool {
        case "read_page": "Read page"
        case "click": "Click"
        case "type": "Type"
        case "select": "Choose option"
        case "run_task": "Run task"
        case "navigate": "Open page"
        case "new_tab": "New tab"
        case "select_tab": "Select tab"
        case "close_tab": "Close tab"
        case "list_tabs": "List tabs"
        case "screenshot": "Screenshot"
        case "eval_js": "Run script"
        case "list_skills": "List skills"
        case "read_skill": "Read skill"
        case "save_skill": "Save skill"
        case "list_schedules": "List schedules"
        case "save_schedule": "Save schedule"
        case "delete_schedule": "Delete schedule"
        case "run_schedule": "Run schedule"
        case "Read": "Read file"
        case "Write": "Write file"
        case "Edit", "MultiEdit": "Edit file"
        case "Bash", "run_command", "run_terminal_command": "Run command"
        case "view_file", "read_file": "Read file"
        case "write_to_file", "write": "Write file"
        case "replace_file_content", "multi_replace_file_content", "search_replace": "Edit file"
        case "grep_search", "find_by_name", "list_dir", "grep": "Search files"
        case "read_url_content": "Fetch"
        case "search_web": "Search the web"
        case "Grep", "Glob": "Search files"
        case "WebFetch": "Fetch"
        case "WebSearch": "Search the web"
        case "TodoWrite": "Plan"
        case "Task": "Subtask"
        case "thinking": "Thought"
        default: tool
        }
    }

    private static func heading(tool: String, detail: String, separator: String = "  ") -> NSAttributedString {
        heading(name: displayName(of: tool), detail: detail, separator: separator)
    }

    private static func heading(name: String, detail: String, separator: String = "  ") -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Theme.text,
        ])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: separator + detail, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Theme.secondaryText,
            ]))
        }
        return text
    }

    private static func chevronImage(expanded: Bool) -> NSImage? {
        NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Hide steps" : "Show steps")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    /// The arguments worth showing: where it acts, and what it types or runs.
    /// URLs lose their scheme and scripts their line breaks, so a row's one
    /// line holds what matters.
    static func detail(_ input: [String: Any]) -> String {
        let string = parts(input).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return string.count > 80 ? String(string.prefix(80)) + "…" : string
    }

    /// The same arguments whole, line breaks kept, for the row's tooltip:
    /// nil when `detail` already shows them all.
    static func full(_ input: [String: Any], detail: String) -> String? {
        let string = parts(input).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard string != detail else { return nil }
        return string.count > 2000 ? String(string.prefix(2000)) + "…" : string
    }

    private static func parts(_ input: [String: Any]) -> [String] {
        var parts: [String] = []
        if let url = input["url"] {
            var address = "\(url)"
            for scheme in ["https://", "http://"] where address.hasPrefix(scheme) { address.removeFirst(scheme.count) }
            parts.append(address)
        }
        if let ref = input["ref"] { parts.append("ref \(ref)") } else if let selector = input["selector"] { parts.append("\(selector)") }
        if let text = input["text"] { parts.append("\"\(text)\"") }
        if let option = input["option"] { parts.append("\"\(option)\"") }
        if let goal = input["goal"] { parts.append("\(goal)") }
        if let expression = input["expression"] { parts.append("\(expression)") }
        if let command = input["command"] { parts.append("\(command)") }
        if let pattern = input["pattern"] { parts.append("\(pattern)") }
        if let path = input["file_path"] ?? input["path"] { parts.append("\(path)") }
        if parts.isEmpty, let tab = input["tab_id"] { parts.append("tab \(tab)") }
        // A skill or schedule by name.
        if parts.isEmpty, let name = input["name"] { parts.append("\(name)") }
        return parts
    }
}

/// A run of tool calls between messages, under a header that counts them.
/// While the run is under way only its newest call shows, each taking the
/// last one's place, and all of them fold under the header when it ends;
/// clicking the header shows every call. A run of one call is just that
/// call, with no header.
final class ToolGroupView: NSView, TranscriptRow {
    private let header = ToolRowView(name: "", detail: "", disclosure: true)
    private let stack = NSStackView()
    private let rows = NSStackView()
    private var calls: [ToolRowView] = []
    private(set) var isOpen = true
    /// Set once the user clicked the header: closing then leaves their choice alone.
    private var toggled = false
    private var width: CGFloat = 0
    /// How far the calls sit in from the header. None when there is no header.
    private var indent: CGFloat { calls.count > 1 ? 12 : 0 }
    private var rowsLeading: NSLayoutConstraint!
    private var rowsWidth: NSLayoutConstraint!

    init(first: ToolRowView) {
        super.init(frame: .zero)
        for list in [stack, rows] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
            list.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(rows)
        header.onToggle = { [weak self] in
            guard let self else { return }
            toggled = true
            setExpanded(!header.isExpanded)
        }
        header.toolTip = "Show steps"
        rowsLeading = rows.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
        rowsWidth = rows.widthAnchor.constraint(equalTo: stack.widthAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsLeading, rowsWidth,
        ])
        add(first)
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ call: ToolRowView) {
        calls.append(call)
        call.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(call)
        call.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        call.onFinish = { [weak self] in self?.updateHeader() }
        rowsLeading.constant = indent
        rowsWidth.constant = -indent
        if width > 0 { fit(width: width) }
        updateHeader()
        if isPeeking, calls.count > 1, window != nil, !Theme.reduceMotion {
            // It takes the last call's place, fading in rather than popping.
            call.alphaValue = 0
            withEasing(Theme.Duration.quick) { call.animator().alphaValue = 1 }
        }
    }

    /// While the run is under way and the user hasn't opened or closed the
    /// header, the newest call shows below it.
    private var isPeeking: Bool { isOpen && !toggled && !header.isExpanded }

    /// The run ended: the header takes its outcome and the calls fold away.
    func close() {
        guard isOpen else { return }
        isOpen = false
        if !toggled { setExpanded(false) }
        updateHeader()
    }

    func fit(width: CGFloat) {
        self.width = width
        header.fit(width: width)
        for call in calls { call.fit(width: width - indent) }
    }

    private func setExpanded(_ expanded: Bool) {
        header.isExpanded = expanded
        header.toolTip = expanded ? "Hide steps" : "Show steps"
        updateHeader()
    }

    private func updateHeader() {
        // One call has no header to reopen it from, so it stays in view.
        header.isHidden = calls.count < 2
        let hideRows = !header.isExpanded && !isPeeking && calls.count > 1
        if !hideRows {
            // Left alone while the rows fold, so they don't grow as they fade.
            for (index, call) in calls.enumerated() {
                call.isHidden = isPeeking && index < calls.count - 1
            }
        }
        if rows.isHidden && !hideRows {
            // Shown again from the header, the calls fade in rather than pop.
            rows.alphaValue = 0
            rows.isHidden = false
            withEasing(Theme.Duration.quick) { rows.animator().alphaValue = 1 }
        } else if hideRows && !rows.isHidden && window != nil && !Theme.reduceMotion {
            // And fade out before they fold, as when a turn ends.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.quick
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                rows.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // Unless they were opened again meanwhile.
                    guard let self, !self.header.isExpanded else { return }
                    self.rows.isHidden = true
                    self.rows.alphaValue = 1
                }
            }
        } else {
            rows.isHidden = hideRows
            rows.alphaValue = 1
        }
        var names: [String] = []
        for call in calls {
            let name = ToolRowView.displayName(of: call.tool).lowercased()
            if !names.contains(name) { names.append(name) }
        }
        let failed = calls.filter { $0.outcome == .failed }.count
        header.update(
            name: "\(calls.count) steps" + (failed > 0 ? " · \(failed) failed" : ""),
            detail: names.joined(separator: ", ")
        )
        guard !isOpen else {
            header.setRunning(calls.contains { $0.outcome == .running })
            return
        }
        let settled = calls.allSatisfy { $0.outcome == .done || $0.outcome == .failed }
        header.finish(isError: failed > 0 ? true : settled ? false : nil, summary: "")
    }
}

/// What shows between sending a message and the agent's first words or
/// step, and between steps: a small bobbing boat and what the agent is busy
/// with where that's known, a sailing phrase where it isn't. A wait of more
/// than a few seconds counts up beside it, so a long one reads as work under
/// way rather than a hang.
final class ThinkingRowView: NSView {
    private static let phrases = [
        "Setting sail…", "Reading the wind…", "Charting a course…", "Trimming the sails…",
        "Holding the tiller…", "Tacking…", "Scanning the horizon…", "Riding the swell…",
    ]
    private static let phraseInterval = 3
    /// Waits shorter than this show no time, so quick steps don't flicker.
    static let elapsedDelay: TimeInterval = 3

    let started = Date()
    /// Replaces the phrases while set, with an optional line under it.
    var activity: (text: String, detail: String?)? {
        didSet { update() }
    }

    private let label: NSTextField
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var bottomToBoat: NSLayoutConstraint!
    private var bottomToDetail: NSLayoutConstraint!
    private var phrase: Int
    private var timer: Timer?
    private var ticks = 0

    init() {
        phrase = Int.random(in: 0..<Self.phrases.count)
        label = NSTextField(labelWithString: Self.phrases[phrase])
        super.init(frame: .zero)
        let boat = BoatView()
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.secondaryText
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = Theme.tertiaryText
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = Theme.tertiaryText
        detailLabel.isHidden = true
        for field in [label, detailLabel] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [boat, label, elapsedLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The boat and text sit in a tool row's columns, so the boat stays
        // put when the next step's row takes this one's place.
        bottomToBoat = boat.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        bottomToDetail = detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        NSLayoutConstraint.activate([
            boat.centerXAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.iconLeading + ToolRowView.iconWidth / 2),
            boat.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bottomToBoat,
            boat.widthAnchor.constraint(equalToConstant: 16),
            boat.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.textLeading),
            label.centerYAnchor.constraint(equalTo: boat.centerYAnchor),
            elapsedLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            elapsedLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            elapsedLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            detailLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: boat.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
        ])
        // The phrases are decoration; VoiceOver hears one plain word, or
        // what the agent is busy with.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Working")
        for field in [label, elapsedLabel, detailLabel] { field.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    /// The main line, and the detail line under it when shown.
    var textForTesting: (main: String, detail: String?) {
        (label.stringValue, detailLabel.isHidden ? nil : detailLabel.stringValue)
    }
    #endif

    /// The phrase and time change only while the row is on screen: in a
    /// window, and not in a hidden chat or panel, which a turn can run on in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTimer()
    }

    private func updateTimer() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        guard visible != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        updateElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        updateElapsed()
        ticks += 1
        if activity == nil, ticks % Self.phraseInterval == 0 { nextPhrase() }
    }

    private func updateElapsed() {
        let elapsed = Date().timeIntervalSince(started)
        elapsedLabel.stringValue = elapsed < Self.elapsedDelay ? "" : Self.duration(elapsed)
    }

    /// "8s", or "2m 05s".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return whole < 60 ? "\(whole)s" : String(format: "%dm %02ds", whole / 60, whole % 60)
    }

    private func update() {
        label.stringValue = activity.map { $0.text + "…" } ?? Self.phrases[phrase]
        label.alphaValue = 1
        setAccessibilityLabel(activity?.text ?? "Working")
        let detail = activity?.detail.flatMap { $0.isEmpty ? nil : $0 }
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        bottomToBoat.isActive = detail == nil
        bottomToDetail.isActive = detail != nil
    }

    private func nextPhrase() {
        phrase = (phrase + 1 + Int.random(in: 0..<Self.phrases.count - 1)) % Self.phrases.count
        let text = Self.phrases[phrase]
        guard !Theme.reduceMotion else { label.stringValue = text; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            label.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Unless the agent said what it's doing meanwhile.
                guard let self, self.activity == nil else { return }
                self.label.stringValue = text
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.label.animator().alphaValue = 1
                }
            }
        }
    }
}

/// Tiller's boat, drawn small and in one color: a hull and sail that bob and
/// rock above a wave line while the agent works, and sit still when the
/// system asks for less motion.
private final class BoatView: NSView {
    private let boat = CAShapeLayer()
    private let wave = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(wave)
        layer?.addSublayer(boat)
        wave.fillColor = nil
        wave.lineWidth = 1.2
        wave.lineCap = .round
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        boat.fillColor = Theme.secondaryText.cgColor
        wave.strokeColor = Theme.tertiaryText.cgColor
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, boat.frame.size != size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.frame = bounds
        wave.path = Self.wavePath(width: size.width)
        // The boat rocks about the middle of its hull.
        boat.bounds = bounds
        boat.anchorPoint = CGPoint(x: 0.5, y: 4.5 / size.height)
        boat.position = CGPoint(x: size.width / 2, y: 4.5)
        boat.path = Self.boatPath()
        CATransaction.commit()
        startAnimating()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startAnimating()
    }

    override func viewDidHide() {
        super.viewDidHide()
        boat.removeAllAnimations()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        startAnimating()
    }

    private func startAnimating() {
        boat.removeAllAnimations()
        guard window != nil, !isHiddenOrHasHiddenAncestor, !Theme.reduceMotion else { return }
        let bob = CABasicAnimation(keyPath: "position.y")
        bob.fromValue = boat.position.y - 0.75
        bob.toValue = boat.position.y + 0.75
        bob.duration = 0.8
        let rock = CABasicAnimation(keyPath: "transform.rotation.z")
        rock.fromValue = -6 * CGFloat.pi / 180
        rock.toValue = 6 * CGFloat.pi / 180
        // Rocking at a different pace than bobbing keeps it from looking
        // mechanical.
        rock.duration = 1.1
        for (animation, key) in [(bob, "bob"), (rock, "rock")] {
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            boat.add(animation, forKey: key)
        }
    }

    /// A hull, mast and sail in a 16-point box, origin at the bottom left.
    private static func boatPath() -> CGPath {
        let path = CGMutablePath()
        // Hull: a wide deck tapering to a narrower keel.
        path.move(to: CGPoint(x: 2, y: 6.5))
        path.addLine(to: CGPoint(x: 14, y: 6.5))
        path.addLine(to: CGPoint(x: 11.5, y: 3))
        path.addLine(to: CGPoint(x: 4.5, y: 3))
        path.closeSubpath()
        // Mast.
        path.addRect(CGRect(x: 7.4, y: 6.5, width: 1.2, height: 8.5))
        // Sail, leaning off the mast toward the bow.
        path.move(to: CGPoint(x: 9, y: 14.5))
        path.addLine(to: CGPoint(x: 13.5, y: 7.5))
        path.addLine(to: CGPoint(x: 9, y: 7.5))
        path.closeSubpath()
        return path
    }

    /// One gentle wave along the bottom.
    private static func wavePath(width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let y: CGFloat = 1.5
        path.move(to: CGPoint(x: 0.5, y: y))
        let step = (width - 1) / 4
        for i in 0..<4 {
            let x = 0.5 + CGFloat(i) * step
            path.addQuadCurve(to: CGPoint(x: x + step, y: y), control: CGPoint(x: x + step / 2, y: i.isMultiple(of: 2) ? y + 1.2 : y - 1.2))
        }
        return path
    }
}

/// A quiet line in the middle, such as "Stopped".
final class NoteView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        label.textColor = Theme.secondaryText
        // A long one, such as a scheduled run's name, loses its middle and
        // keeps the whole text in its tooltip.
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// An error from the agent or its process, in a red-tinted box.
final class ErrorMessageView: NSView, TranscriptRow {
    private let label: NSTextField
    private let action: (() -> Void)?
    /// Room on either side of the button's title.
    private static let buttonPadding: CGFloat = 8

    /// `action` adds a button under the text, such as Try Again.
    init(text: String, action: (title: String, run: () -> Void)? = nil) {
        label = NSTextField(wrappingLabelWithString: text)
        self.action = action?.run
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        label.isSelectable = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!)
        icon.contentTintColor = Theme.danger
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.iconLeading),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.textLeading),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        guard let action else {
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8).isActive = true
            return
        }
        // A plate at rest, so it reads as a button among the panel's
        // borderless ones without a stock bezel.
        let button = HoverButton()
        button.restFill = Theme.Fill.rest
        button.title = action.title
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        button.contentTintColor = Theme.text
        let titleWidth = (action.title as NSString).size(withAttributes: [.font: button.font as Any]).width
        button.target = self
        button.action = #selector(run(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            // The title lines up with the text above.
            button.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: 2 - Self.buttonPadding),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            button.widthAnchor.constraint(equalToConstant: ceil(titleWidth) + 2 * Self.buttonPadding),
            button.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { action?() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - ToolRowView.textLeading - 10
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.card
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.danger.dynamic(alpha: 0.1).layerColor
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.danger.dynamic(alpha: 0.25).layerColor
    }
}

// MARK: Markdown

/// Renders the agent's markdown: headings, lists, quotes and fenced code by
/// line, bold, italics, code and links within a line, and pipe tables as
/// grids. Other block syntax stays as typed.
@MainActor
enum AgentMarkdown {
    private static let bodySize: CGFloat = 13
    /// The room a list marker gets before its item's text, wide enough for
    /// "10." so numbered and bulleted items' text start at one column. Each
    /// level of nesting indents by as much.
    private static let listIndent: CGFloat = 20

    /// A pipe table, its cells as written. They are rendered when drawn, so a
    /// table still streaming in renders only the cells it gained.
    struct Table {
        /// The lines it was parsed from, to tell whether it changed.
        let source: String
        let header: [String]
        let rows: [[String]]
        let alignments: [NSTextAlignment]

        /// The cell's text rendered for its column, from a cache.
        @MainActor
        func cell(_ text: String, header: Bool, column: Int) -> NSAttributedString {
            AgentMarkdown.cell(text, header: header, alignment: alignments[min(column, alignments.count - 1)])
        }
    }

    /// The pieces of a message. Text and quotes stay as written and are
    /// rendered when a view takes them, so a block a streamed answer isn't
    /// adding to any more costs nothing on the next render.
    enum Block {
        case text(String)
        case table(Table)
        /// A fenced code block, with the language named after the opening fence.
        case code(language: String, text: String)
        /// Lines quoted with `>`, without the markers.
        case quote(String)
        /// A horizontal rule.
        case rule
    }

    static func label(_ text: String) -> MarkdownMessageView {
        let view = MarkdownMessageView()
        view.text = text
        return view
    }

    /// The message as runs of text with the code blocks, tables, quotes and
    /// rules between them. A fence still open at the end, as while an answer
    /// streams, is a code block too.
    static func blocks(_ text: String) -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var pending: [String] = []
        func flush() {
            defer { pending.removeAll() }
            guard pending.contains(where: { !$0.allSatisfy(\.isWhitespace) }) else { return }
            blocks.append(.text(pending.joined(separator: "\n")))
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("```") { end += 1 }
                blocks.append(.code(language: language, text: lines[(index + 1)..<end].joined(separator: "\n")))
                index = end + 1
                continue
            }
            if let (table, end) = table(in: lines, at: index) {
                flush()
                blocks.append(.table(table))
                index = end
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var end = index
                var quoted: [String] = []
                while end < lines.count {
                    let inner = lines[end].trimmingCharacters(in: .whitespaces)
                    guard inner.hasPrefix(">") else { break }
                    var content = inner.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    end += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                index = end
                continue
            }
            // A line of dashes under a paragraph underlines a heading; on its
            // own, like a line of stars or underscores, it is a rule.
            if let last = pending.last, !last.trimmingCharacters(in: .whitespaces).isEmpty, !isBlockStart(last),
                let level = setextLevel(trimmed)
            {
                // The whole paragraph is the heading, not just its last line.
                var start = pending.count - 1
                while start > 0, !pending[start - 1].trimmingCharacters(in: .whitespaces).isEmpty, !isBlockStart(pending[start - 1]) {
                    start -= 1
                }
                let heading = pending[start...].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                pending.replaceSubrange(start..., with: [String(repeating: "#", count: level) + " " + heading])
                index += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            // A long run of text ends at a paragraph break, so a streamed
            // answer only renders and lays out its last few paragraphs on
            // each tick rather than everything since the last table or
            // fence. Shorter runs stay whole, so they select as one.
            if trimmed.isEmpty, pending.count(where: { !$0.allSatisfy(\.isWhitespace) }) >= longTextRun {
                flush()
                index += 1
                continue
            }
            pending.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    /// The lines of text past which a run is split at its next blank line.
    private static let longTextRun = 12

    /// Three or more of the same of `-`, `*` or `_`, spaces allowed between.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// 1 for a line of `=`, 2 for a line of `-`, else nil.
    private static func setextLevel(_ line: String) -> Int? {
        guard line.count >= 3, let first = line.first, "=-".contains(first), line.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Whether a line already starts a heading or list item, which a line of
    /// dashes after it doesn't turn into a heading.
    private static func isBlockStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        return trimmed.first?.isNumber == true && trimmed.contains(". ")
    }

    /// The table whose header is the line at `start`, and the line after its
    /// last row. A table is a header, a line of dashes, then rows.
    private static func table(in lines: [String], at start: Int) -> (Table, Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = cells(lines[start])
        let delimiter = cells(lines[start + 1])
        guard !delimiter.isEmpty, delimiter.count == header.count, lines[start + 1].contains("-"),
            delimiter.allSatisfy({ cell in
                var dashes = Substring(cell)
                if dashes.hasPrefix(":") { dashes = dashes.dropFirst() }
                if dashes.hasSuffix(":") { dashes = dashes.dropLast() }
                return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
            })
        else { return nil }
        let alignments: [NSTextAlignment] = delimiter.map { cell in
            if cell.hasSuffix(":") { return cell.hasPrefix(":") ? .center : .right }
            return .left
        }
        var end = start + 2
        var rows: [[String]] = []
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|"), !trimmed.hasPrefix("```") else { break }
            var row = Array(cells(trimmed).prefix(header.count))
            row += Array(repeating: "", count: header.count - row.count)
            rows.append(row)
            end += 1
        }
        let table = Table(source: lines[start..<end].joined(separator: "\n"), header: header, rows: rows, alignments: alignments)
        return (table, end)
    }

    /// Cells rendered before, by alignment, weight and text. Streaming
    /// renders a table again with every row it gains, and all but the last
    /// row's cells are as they were.
    private static var renderedCells: [String: NSAttributedString] = [:]

    fileprivate static func cell(_ text: String, header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
        let key = "\(header ? "H" : "B")\(alignment.rawValue)" + text
        if let cached = renderedCells[key] { return cached }
        let rendered = inline(text, font: header ? .systemFont(ofSize: bodySize, weight: .semibold) : body)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        style.alignment = alignment
        rendered.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: rendered.length))
        if renderedCells.count >= renderedLinesLimit { renderedCells.removeAll(keepingCapacity: true) }
        renderedCells[key] = rendered
        return rendered
    }

    /// A quote's lines, rendered and dimmed.
    static func renderQuote(_ source: String) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: render(source))
        dim(text)
        return text
    }

    /// Dims `text` but its links, which keep their color so they still
    /// read as links.
    private static func dim(_ text: NSMutableAttributedString) {
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: Theme.secondaryText, range: range) }
        }
    }

    /// A table line's cells. A pipe after a backslash or inside backticks
    /// does not end a cell.
    private static func cells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = []
        var current = ""
        var inCode = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current)
        // The pipes at either end of the line border the table.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inFence = false
        var previousBlank = false
        // The indents of the list markers the line is nested under, outermost
        // first: an item's level is its place among them, however many
        // spaces each level is indented by.
        var markers: [Int] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            // Runs of blank lines collapse into paragraph spacing.
            if !inFence && trimmed.isEmpty {
                previousBlank = true
                continue
            }
            if index > 0 && result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            }
            var list = ListContext.none
            if !inFence {
                let leading = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                if listItem(trimmed) != nil {
                    while let last = markers.last, last > leading { markers.removeLast() }
                    if markers.last != leading { markers.append(leading) }
                    list = .item(depth: markers.count - 1)
                } else if leading > 0 {
                    // An indented line goes on with the item it is indented under.
                    while let last = markers.last, last >= leading { markers.removeLast() }
                    if !markers.isEmpty { list = .continuation(depth: markers.count - 1) }
                } else {
                    markers.removeAll()
                }
            }
            let start = result.length
            result.append(rendered(line, trimmed: trimmed, inFence: inFence, list: list))
            if previousBlank, start > 0 {
                // A gap before the paragraph that followed a blank line.
                let range = NSRange(location: start, length: result.length - start)
                result.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                    let style = ((value as? NSParagraphStyle) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
                    style.paragraphSpacingBefore = 6
                    result.addAttribute(.paragraphStyle, value: style, range: subrange)
                }
            }
            previousBlank = false
        }
        return result
    }

    /// Where a line sits in a list, which the lines before it decide.
    private enum ListContext: Hashable {
        case none
        /// A list item, at a level from 0.
        case item(depth: Int)
        /// An indented line after an item, which lines up with its text.
        case continuation(depth: Int)

        var key: String {
            switch self {
            case .none: "B"
            case .item(let depth): "L\(depth) "
            case .continuation(let depth): "C\(depth) "
            }
        }
    }

    /// Lines rendered before, by their text after an F in a fence, or the
    /// key of their place in a list outside. A streamed answer renders again
    /// with every few words, and all but its last line are the same each time.
    private static var renderedLines: [String: NSAttributedString] = [:]
    private static let renderedLinesLimit = 4000

    private static func rendered(_ line: String, trimmed: String, inFence: Bool, list: ListContext) -> NSAttributedString {
        let key = (inFence ? "F" : list.key) + line
        if let cached = renderedLines[key] { return cached }
        let text = inFence ? code(line) : block(line, trimmed: trimmed, list: list)
        if renderedLines.count >= renderedLinesLimit { renderedLines.removeAll(keepingCapacity: true) }
        renderedLines[key] = text
        return text
    }

    private static let body = NSFont.systemFont(ofSize: bodySize)

    private static func paragraph(indent: CGFloat = 0, firstLineIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent ?? indent
        if indent > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
        return style
    }

    /// A list item's marker and text: a bullet, a number, or a task's box.
    private enum ListMarker {
        case bullet
        case number(Substring)
        case task(done: Bool)
    }

    private static func listItem(_ trimmed: String) -> (marker: ListMarker, text: Substring)? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let rest = trimmed.dropFirst(2)
            // A task with no text yet, as while it streams in, is a task too.
            for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where rest.hasPrefix(box) || rest == box.dropLast() {
                return (.task(done: done), rest.dropFirst(4))
            }
            return (.bullet, rest)
        }
        if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
            trimmed[dot...].hasPrefix(". ") {
            return (.number(trimmed[..<dot]), trimmed[dot...].dropFirst(2))
        }
        return nil
    }

    private static func block(_ line: String, trimmed: String, list: ListContext) -> NSAttributedString {
        // Headings: "# Title" to "###### Title".
        if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
            trimmed.distance(from: trimmed.startIndex, to: hashes) <= 6, trimmed[hashes] == " " {
            let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
            let size: CGFloat = level == 1 ? 16 : level == 2 ? 15 : 14
            let text = inline(String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces),
                              font: .systemFont(ofSize: size, weight: .semibold))
            let style = paragraph()
            style.paragraphSpacingBefore = 4
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            return text
        }
        if case .item(let depth) = list, let (marker, rest) = listItem(trimmed) {
            // Every kind of marker sits in the same column before the text.
            let indent = listIndent * CGFloat(depth + 1)
            let prefix = switch marker {
            case .bullet: "•"
            case .number(let number): "\(number)."
            case .task(let done): done ? "☑" : "☐"
            }
            let markerColor: NSColor = if case .task = marker { Theme.secondaryText } else { Theme.text }
            let text = inline(rest, font: body)
            // A finished task's text is dimmed, so what is left stands out.
            if case .task(true) = marker { dim(text) }
            text.insert(NSAttributedString(string: prefix + "\t", attributes: [.font: body, .foregroundColor: markerColor]), at: 0)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: indent, firstLineIndent: indent - listIndent),
                              range: NSRange(location: 0, length: text.length))
            return text
        }
        if case .continuation(let depth) = list {
            let text = inline(trimmed, font: body)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: listIndent * CGFloat(depth + 1)),
                              range: NSRange(location: 0, length: text.length))
            return text
        }
        if trimmed.hasPrefix(">") {
            let text = inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), font: body)
            let range = NSRange(location: 0, length: text.length)
            dim(text)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: 10), range: range)
            return text
        }
        let text = inline(line, font: body)
        text.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func code(_ line: String) -> NSAttributedString {
        let style = paragraph(indent: 10)
        style.lineSpacing = 1
        return NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.FontSize.secondary, weight: .regular),
            .foregroundColor: Theme.text,
            .backgroundColor: Theme.fill(Theme.Fill.rest),
            .paragraphStyle: style,
        ])
    }

    /// Bold, italics, inline code and links in one line.
    private static func inline<S: StringProtocol>(_ text: S, font: NSFont) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: String(text), options: options)) ?? AttributedString(String(text))
        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: whole)
        result.addAttribute(.foregroundColor, value: Theme.text, range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: range)
                result.addAttribute(.backgroundColor, value: Theme.fill(Theme.Fill.rest), range: range)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
                }
            }
        }
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            result.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
        return result
    }
}

/// An agent message: its text, with each table drawn as a grid.
final class MarkdownMessageView: NSView, TranscriptRow {
    private let stack = NSStackView()
    private var width: CGFloat = 0
    private lazy var stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
    /// Copy and the time, under a turn's last text once the turn has ended.
    private var actions: ResponseActionsView?
    /// Keeps the actions in view without the mouse, for the newest response.
    var isPinned = false {
        didSet { actions?.isPinned = isPinned }
    }
    private var isHovered = false {
        didSet { actions?.isHovered = isHovered }
    }

    var text = "" {
        didSet { if text != oldValue { rebuild() } }
    }

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackBottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Adds the row with Copy and `date` under the text, once. A response
    /// saved before responses had times has none.
    func showActions(date: Date?) {
        guard actions == nil else { return }
        let actions = ResponseActionsView(date: date) { [weak self] in self?.text ?? "" }
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.isPinned = isPinned
        actions.isHovered = isHovered
        addSubview(actions)
        stackBottom.isActive = false
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 4),
            // Lines the copy glyph up with the text rather than the button's edge.
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.actions = actions
        updateTrackingAreas()
    }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        for view in stack.arrangedSubviews { fit(view) }
    }

    /// Only a response with actions tracks the mouse, to show them.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard actions != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func fit(_ view: NSView) {
        guard width > 0 else { return }
        if let row = view as? TranscriptRow {
            row.fit(width: width)
        } else if let label = view as? NSTextField {
            label.preferredMaxLayoutWidth = width
        }
    }

    /// Keeps the views whose kind of block is unchanged, and the text of
    /// those whose source is unchanged, so a streamed answer only renders
    /// and lays out the block it is still adding to.
    private func rebuild() {
        let blocks = AgentMarkdown.blocks(text)
        for (index, block) in blocks.enumerated() {
            let existing = index < stack.arrangedSubviews.count ? stack.arrangedSubviews[index] : nil
            switch block {
            case .text(let source):
                if let label = existing as? TranscriptLinkLabel {
                    label.show(source)
                } else {
                    let label = TranscriptLinkLabel(wrappingLabelWithString: "")
                    label.isSelectable = true
                    // Lets links in the text be clicked.
                    label.allowsEditingTextAttributes = true
                    label.show(source)
                    place(label, at: index, replacing: existing)
                }
            case .table(let table):
                if let view = existing as? MarkdownTableView {
                    view.table = table
                } else {
                    let view = MarkdownTableView()
                    view.table = table
                    place(view, at: index, replacing: existing)
                }
            case .code(let language, let code):
                if let view = existing as? MarkdownCodeView {
                    view.set(language: language, code: code)
                } else {
                    let view = MarkdownCodeView()
                    view.set(language: language, code: code)
                    place(view, at: index, replacing: existing)
                }
            case .quote(let source):
                if let view = existing as? MarkdownQuoteView {
                    view.source = source
                } else {
                    let view = MarkdownQuoteView()
                    view.source = source
                    place(view, at: index, replacing: existing)
                }
            case .rule:
                if !(existing is MarkdownRuleView) { place(MarkdownRuleView(), at: index, replacing: existing) }
            }
        }
        for view in stack.arrangedSubviews.dropFirst(blocks.count) { view.removeFromSuperview() }
    }

    private func place(_ view: NSView, at index: Int, replacing existing: NSView?) {
        existing?.removeFromSuperview()
        stack.insertArrangedSubview(view, at: index)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fit(view)
    }
}

/// Under an agent's response: a button that copies its text, and when it came.
private final class ResponseActionsView: NSView {
    private let copyButton = CopyButton(name: "Copy Response")
    private let timeLabel = NSTextField(labelWithString: "")
    var isPinned = false { didSet { updateVisibility() } }
    var isHovered = false { didSet { updateVisibility() } }
    private var isCopyFocused = false { didSet { updateVisibility() } }

    init(date: Date?, text: @escaping () -> String) {
        super.init(frame: .zero)
        copyButton.string = text
        copyButton.onCopiedChange = { [weak self] in self?.updateVisibility() }
        // Tabbing to the button shows the row, so it isn't focused unseen.
        copyButton.onFocusChange = { [weak self] focused in self?.isCopyFocused = focused }
        timeLabel.font = .systemFont(ofSize: Theme.FontSize.caption)
        timeLabel.textColor = Theme.secondaryText
        if let date {
            timeLabel.stringValue = Self.timeText(date)
            timeLabel.toolTip = date.formatted(date: .complete, time: .shortened)
        }
        timeLabel.isHidden = date == nil
        for view in [copyButton, timeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            copyButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
            timeLabel.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 4),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The time today, then the date and time, with the year if not this one.
    static func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }

    /// Shown for the newest response, under the mouse, with keyboard focus,
    /// and while it says "Copied".
    private func updateVisibility() {
        let shown = isPinned || isHovered || isCopyFocused || copyButton.isShowingCopied
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
            animator().alphaValue = shown ? 1 : 0
        }
    }
}

private final class TranscriptHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let contentWidth = documentView?.frame.width ?? 0
        let overflowsHorizontally = contentWidth - contentView.bounds.width > 1
        let scrollsHorizontally = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        guard overflowsHorizontally && scrollsHorizontally else {
            if let enclosingScrollView {
                enclosingScrollView.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
            return
        }
        super.scrollWheel(with: event)
    }
}

/// A markdown table: a bold header, a rule between rows, and cells that wrap
/// to the transcript's width. One whose columns can't wrap that narrow and
/// stay readable keeps them wider and scrolls sideways instead.
final class MarkdownTableView: NSView, TranscriptRow {
    private let scroll = TranscriptHorizontalScrollView()
    private let content = MarkdownTableContentView()
    private var width: CGFloat = 0
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    var table: AgentMarkdown.Table? {
        didSet {
            content.table = table
            relayout()
        }
    }

    init() {
        super.init(frame: .zero)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        relayout()
    }

    private func relayout() {
        guard width > 0 else { return }
        content.arrange(width: width)
        content.frame = NSRect(origin: .zero, size: content.tableSize)
        if height.constant != content.tableSize.height { height.constant = content.tableSize.height }
        updateFade()
    }

    @objc private func scrolled(_ notification: Notification) {
        updateFade()
    }

    /// Fades the edges where more of the table lies, so a clipped table reads
    /// as one that scrolls.
    private func updateFade() {
        let visible = scroll.contentView.bounds
        let hiddenLeft = visible.minX > 1
        let hiddenRight = content.tableSize.width - visible.maxX > 1
        guard hiddenLeft || hiddenRight else {
            scroll.layer?.mask = nil
            return
        }
        let mask = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let fade = min(0.2, 28 / max(1, visible.width))
        let clear = NSColor.clear.layerColor, opaque = NSColor.black.layerColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroll.bounds
        mask.colors = [hiddenLeft ? clear : opaque, opaque, opaque, hiddenRight ? clear : opaque]
        mask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        scroll.layer?.mask = mask
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateFade()
    }
}

/// The table itself, laid out for a width and drawn at its own size.
final class MarkdownTableContentView: NSView {
    private static let padding = NSSize(width: 8, height: 5)
    /// Narrower than this, a column's words would break mid-word.
    private static let minimumColumn: CGFloat = 72

    private var labels: [[TranscriptLinkLabel]] = []
    /// Each label's width when its text is on one line, measured once.
    private var naturalWidths: [ObjectIdentifier: CGFloat] = [:]
    /// Each label's height at the column width it was last measured for, so
    /// a row streaming in doesn't measure every row above it again.
    private var heights: [ObjectIdentifier: (width: CGFloat, height: CGFloat)] = [:]
    private var width: CGFloat = 0
    private(set) var tableSize = NSSize.zero
    /// Where each row starts, and the bottom of the last.
    private var rowEdges: [CGFloat] = []

    /// Cells whose text and alignment are as before keep their labels, so a
    /// table streaming in only renders the row it gained.
    var table: AgentMarkdown.Table? {
        didSet {
            guard let table, table.source != oldValue?.source else { return }
            let rows = [table.header] + table.rows
            let before = oldValue.map { [$0.header] + $0.rows } ?? []
            let sameAlignments = oldValue?.alignments == table.alignments
            for (r, row) in rows.enumerated() {
                if r >= labels.count { labels.append([]) }
                for (c, text) in row.enumerated() {
                    let kept = sameAlignments && c < labels[r].count && r < before.count && c < before[r].count && before[r][c] == text
                    if kept { continue }
                    let rendered = table.cell(text, header: r == 0, column: c)
                    if c < labels[r].count {
                        let label = labels[r][c]
                        label.attributedStringValue = rendered
                        naturalWidths[ObjectIdentifier(label)] = nil
                        heights[ObjectIdentifier(label)] = nil
                    } else {
                        let label = TranscriptLinkLabel(wrappingLabelWithString: "")
                        label.isSelectable = true
                        label.allowsEditingTextAttributes = true
                        label.attributedStringValue = rendered
                        addSubview(label)
                        labels[r].append(label)
                    }
                }
                while labels[r].count > row.count { remove(labels[r].removeLast()) }
            }
            while labels.count > rows.count { labels.removeLast().forEach(remove) }
            if width > 0 { arrange(width: width) }
        }
    }

    private func remove(_ label: TranscriptLinkLabel) {
        naturalWidths[ObjectIdentifier(label)] = nil
        heights[ObjectIdentifier(label)] = nil
        label.removeFromSuperview()
    }

    override var isFlipped: Bool { true }

    /// Lays the cells out for `width`: narrow columns keep their natural
    /// width, the wide ones share what is left, and none goes under the
    /// minimum, so `tableSize` may come out wider than asked.
    func arrange(width: CGFloat) {
        self.width = width
        arrange()
    }

    private func measure(_ label: NSTextField, width: CGFloat) -> NSSize {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let size = label.cell?.cellSize(forBounds: bounds) ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func naturalWidth(of label: TranscriptLinkLabel) -> CGFloat {
        let key = ObjectIdentifier(label)
        if let width = naturalWidths[key] { return width }
        let width = measure(label, width: .greatestFiniteMagnitude).width
        naturalWidths[key] = width
        return width
    }

    private func height(of label: TranscriptLinkLabel, width: CGFloat) -> CGFloat {
        let key = ObjectIdentifier(label)
        if let cached = heights[key], cached.width == width { return cached.height }
        let height = measure(label, width: width).height
        heights[key] = (width, height)
        return height
    }

    private func arrange() {
        guard width > 0, let columns = labels.first?.count, columns > 0 else { return }
        let padding = Self.padding
        let natural = (0..<columns).map { column in
            labels.compactMap { column < $0.count ? naturalWidth(of: $0[column]) : nil }.max() ?? 0
        }
        // Narrow columns keep their width; the wide ones share what is left.
        let available = max(width - CGFloat(columns) * 2 * padding.width, CGFloat(columns) * Self.minimumColumn)
        var widths = natural
        if natural.reduce(0, +) > available {
            var remaining = available
            var left = columns
            var cap: CGFloat?
            for column in (0..<columns).sorted(by: { natural[$0] < natural[$1] }) {
                if cap == nil, natural[column] > remaining / CGFloat(left) {
                    cap = max(floor(remaining / CGFloat(left)), Self.minimumColumn)
                }
                if let cap {
                    widths[column] = cap
                } else {
                    remaining -= natural[column]
                    left -= 1
                }
            }
        }
        var y: CGFloat = 0
        rowEdges = [0]
        for row in labels {
            let heights = row.enumerated().map { self.height(of: $1, width: widths[min($0, columns - 1)]) }
            let height = heights.max() ?? 0
            var x: CGFloat = 0
            for (column, label) in row.enumerated() where column < columns {
                label.frame = NSRect(x: x + padding.width, y: y + padding.height, width: widths[column], height: heights[column])
                x += widths[column] + 2 * padding.width
            }
            y += height + 2 * padding.height
            rowEdges.append(y)
        }
        tableSize = NSSize(width: widths.reduce(0, +) + CGFloat(columns) * 2 * padding.width, height: y)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rowEdges.count > 1 else { return }
        // The outline's stroke centers on the frame's edge, so it is inset by half.
        let line = Theme.hairlineWidth
        let frame = NSRect(origin: .zero, size: tableSize).insetBy(dx: line / 2, dy: line / 2)
        // The same corners as a code block, so the two read as one kind of box.
        let outline = NSBezierPath(roundedRect: frame, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        Theme.fill(Theme.Fill.rest).setFill()
        NSRect(x: 0, y: 0, width: tableSize.width, height: rowEdges[1]).fill()
        Theme.hairline.setFill()
        for edge in rowEdges.dropFirst().dropLast() {
            NSRect(x: 0, y: edge - line / 2, width: tableSize.width, height: line).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.hairline.setStroke()
        outline.lineWidth = line
        outline.stroke()
    }
}

/// A fenced code block: a header strip naming the language, with a copy
/// button that shows under the mouse, over monospaced text on a rounded
/// plate. Long lines don't wrap; the text scrolls sideways under a fade at
/// the edge where more of it lies, as tables do.
final class MarkdownCodeView: NSView, TranscriptRow {
    private let header = NSView()
    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = CopyButton(name: "Copy Code")
    private let rule = NSView()
    private let scroll = TranscriptHorizontalScrollView()
    /// Holds the text with the padding around it, at the text's own width.
    private let document = NSView()
    private let label = MarkdownCodeView.codeLabel()
    private var code = ""
    /// The text's size, measured when it changes: it doesn't wrap, so a new
    /// width leaves it as it was.
    private var textSize = NSSize.zero
    private var width: CGFloat = 0
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    private var isHovered = false { didSet { updateButtons() } }
    private var isCopyFocused = false { didSet { updateButtons() } }

    private static let headerHeight: CGFloat = 24
    private static let padding = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    /// A borderless text field's cell still insets its text 2pt on each side.
    private static let cellInset: CGFloat = 4
    private static let font = NSFont.monospacedSystemFont(ofSize: Theme.FontSize.secondary, weight: .regular)

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        languageLabel.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        languageLabel.textColor = Theme.secondaryText

        copyButton.string = { [weak self] in self?.code ?? "" }
        copyButton.onCopiedChange = { [weak self] in self?.updateButtons() }
        copyButton.alphaValue = 0
        // Tabbing to the button shows it, so it isn't focused unseen.
        copyButton.onFocusChange = { [weak self] focused in self?.isCopyFocused = focused }

        rule.wantsLayer = true

        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .automatic
        document.addSubview(label)
        scroll.documentView = document
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        for view in [header, rule, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [languageLabel, copyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            languageLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Self.padding.left),
            languageLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -3),
            copyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: Theme.hairlineWidth),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(language: String, code: String) {
        if languageLabel.stringValue != language {
            languageLabel.stringValue = language.isEmpty ? "Code" : language
        }
        guard code != self.code else { return }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        // Streaming only adds to the end, so the lines before the last one
        // keep their widths; any other change measures every line again.
        let kept = code.hasPrefix(self.code) ? max(0, lineWidths.count - 1) : 0
        lineWidths.removeSubrange(kept...)
        lineWidths += lines[kept...].map { Self.width(of: $0) }
        self.code = code
        label.stringValue = code.isEmpty ? " " : code
        // What the label's own size would be: its widest line, and a line
        // height for each line, an empty last one included.
        let measured = code.isEmpty
            ? Self.measure(" ")
            : NSSize(width: lineWidths.max() ?? 0, height: CGFloat(lines.count) * Self.lineHeight)
        // Rounded up, plus the cell's 2pt inset on each side: a fractional or
        // inset-less width clips the last glyph of the longest line.
        textSize = NSSize(width: ceil(measured.width) + Self.cellInset, height: ceil(measured.height))
        relayout()
    }

    /// Each line's width, as `measure` gives it.
    private var lineWidths: [CGFloat] = []

    /// Measures text one line at a time, set up as `label` is, so the lines'
    /// widths and heights add up to what `label` measures for them together.
    private static let measuringLabel = codeLabel()
    private static let lineHeight = measure(" ").height

    private static func measure(_ text: String) -> NSSize {
        measuringLabel.stringValue = text
        return measuringLabel.intrinsicContentSize
    }

    /// An empty line takes no width among others.
    private static func width(of line: Substring) -> CGFloat {
        line.isEmpty ? 0 : measure(String(line)).width
    }

    private static func codeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.maximumNumberOfLines = 0
        return label
    }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        relayout()
    }

    /// The text sits at its own size inside the scrolling view, with the
    /// padding around it, and the block is as tall as the text.
    private func relayout() {
        let p = Self.padding
        let size = textSize
        let documentWidth = max(size.width + p.left + p.right, width)
        document.frame = NSRect(x: 0, y: 0, width: documentWidth, height: size.height + p.top + p.bottom)
        // The document isn't flipped, so the bottom padding is the origin.
        label.frame = NSRect(x: p.left, y: p.bottom, width: size.width, height: size.height)
        let total = Self.headerHeight + Theme.hairlineWidth + size.height + p.top + p.bottom
        if height.constant != total { height.constant = total }
        updateFade()
    }

    @objc private func scrolled(_ notification: Notification) {
        updateFade()
    }

    /// Fades the edges where more of the text lies.
    private func updateFade() {
        let visible = scroll.contentView.bounds
        let documentWidth = scroll.documentView?.frame.width ?? 0
        let hiddenLeft = visible.minX > 1
        let hiddenRight = documentWidth - visible.maxX > 1
        guard hiddenLeft || hiddenRight else {
            scroll.layer?.mask = nil
            return
        }
        let mask = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let fade = min(0.2, 28 / max(1, visible.width))
        let clear = NSColor.clear.layerColor, opaque = NSColor.black.layerColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroll.bounds
        mask.colors = [hiddenLeft ? clear : opaque, opaque, opaque, hiddenRight ? clear : opaque]
        mask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        scroll.layer?.mask = mask
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    /// The copy button shows under the mouse, with keyboard focus, and
    /// while it says "Copied".
    private func updateButtons() {
        let shown = isHovered || isCopyFocused || copyButton.isShowingCopied
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
            copyButton.animator().alphaValue = shown ? 1 : 0
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.fill(Theme.Fill.rest).layerColor
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.hairline.layerColor
        rule.layer?.backgroundColor = Theme.hairline.layerColor
    }

    /// Only this area is replaced, so the ones AppKit keeps for tooltips stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// A button that says when it gains or loses keyboard focus, for one that
/// hides until it is wanted.
private class FocusReportingButton: HoverButton {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// A borderless button that copies `string`, then shows a green checkmark
/// for a moment and tells VoiceOver it copied.
private final class CopyButton: FocusReportingButton {
    /// What to copy, read when clicked.
    var string: () -> String = { "" }
    /// Called when it starts and stops saying "Copied".
    var onCopiedChange: (() -> Void)?
    var isShowingCopied: Bool { copiedReset != nil }
    private let name: String
    private var copiedReset: DispatchWorkItem?

    private static let copiedImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        setAccessibilityLabel(name)
        showCopy()
        target = self
        action = #selector(copyString(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showCopy() {
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        contentTintColor = Theme.secondaryText
        toolTip = name
    }

    @objc private func copyString(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string(), forType: .string)
        image = Self.copiedImage
        contentTintColor = Theme.success
        toolTip = "Copied"
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "Copied",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showCopy()
                self.copiedReset = nil
                self.onCopiedChange?()
            }
        }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
        onCopiedChange?()
    }
}

/// A block quote: dimmed text beside a bar as tall as the quote.
final class MarkdownQuoteView: NSView, TranscriptRow {
    private let bar = NSView()
    private let label = TranscriptLinkLabel(wrappingLabelWithString: "")
    private static let inset: CGFloat = 14

    /// The quoted lines, without their markers.
    var source = "" {
        didSet {
            guard source != oldValue else { return }
            label.attributedStringValue = AgentMarkdown.renderQuote(source)
        }
    }

    init() {
        super.init(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.cornerCurve = .continuous
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        for view in [bar, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - Self.inset
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        bar.layer?.backgroundColor = Theme.tertiaryText.layerColor
    }
}

/// A horizontal rule.
final class MarkdownRuleView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hairline.layerColor
    }
}

/// A transcript label whose web links open in Tiller tabs rather than the
/// default browser. A click opens and selects a tab, Cmd+click opens one
/// behind the current tab. Other links, such as mailto:, go to their apps.
final class TranscriptLinkLabel: NSTextField {
    /// The markdown the label shows, so the same text again isn't rendered
    /// or laid out again.
    private var source: String?

    func show(_ markdown: String) {
        guard markdown != source else { return }
        source = markdown
        attributedStringValue = AgentMarkdown.render(markdown)
    }

    /// The field editor's delegate is the label it edits, so it asks here.
    @objc func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let app = NSApp.delegate as? AppDelegate else { return false }
        let background = OpenDisposition.click(OpenDisposition.currentFlags) == .backgroundTab
        // In the window the link is in, which has the chat's profile.
        let profile = (window?.windowController as? BrowserWindowController)?.profile
        app.openInNewTab(url.absoluteString, background: background, profile: profile)
        return true
    }
}
