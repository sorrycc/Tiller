import AppKit

/// The list that opens above the message field while it holds a `/` and the
/// start of a skill's name: matching skills with what they do. Arrow keys
/// move the selection, and Tab, Return or a click completes the name. It
/// sits on the same material as the address bar's suggestions.
final class SkillPicker: NSVisualEffectView {
    var onPick: ((AgentSkill) -> Void)?

    private let stack = NSStackView()
    private var rows: [SkillPickerRow] = []
    private(set) var skills: [AgentSkill] = []
    private var selected = 0
    private static let maxRows = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Skills")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Skills whose name starts with `query` come first, then those that
    /// have it elsewhere in the name. Returns whether any matched.
    @discardableResult
    func show(_ all: [AgentSkill], matching query: String) -> Bool {
        let query = query.lowercased()
        let starts = all.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = query.isEmpty ? [] : all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        let matches = Array((starts + contains).prefix(Self.maxRows))
        if matches != skills {
            skills = matches
            selected = 0
            rows.forEach { $0.removeFromSuperview() }
            rows = matches.enumerated().map { index, skill in
                let row = SkillPickerRow(skill: skill)
                row.onHover = { [weak self] in self?.select(index) }
                row.onClick = { [weak self] in self?.onPick?(skill) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                return row
            }
            select(0)
        }
        if isHidden && !matches.isEmpty && !Theme.reduceMotion {
            // It fades in over the transcript rather than popping up. It
            // hides at once, as the keys it takes go back to the field then.
            alphaValue = 0
            isHidden = false
            withEasing(Theme.Duration.quick) { animator().alphaValue = 1 }
        } else {
            isHidden = matches.isEmpty
            alphaValue = 1
        }
        return !matches.isEmpty
    }

    func moveSelection(by offset: Int) {
        guard !skills.isEmpty else { return }
        select((selected + offset + skills.count) % skills.count)
        // The keyboard stays in the message field, so VoiceOver is told
        // which skill Tab or Return would now insert.
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "/" + skills[selected].name,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    var selectedSkill: AgentSkill? { skills.indices.contains(selected) ? skills[selected] : nil }

    private func select(_ index: Int) {
        selected = index
        for (i, row) in rows.enumerated() {
            row.isSelected = i == index
            row.setAccessibilitySelected(i == index)
        }
        setAccessibilitySelectedChildren(rows.indices.contains(index) ? [rows[index]] : [])
    }

    // A material view doesn't reliably call `updateLayer`, so the plate's
    // shape and border are set when it joins a window and when the
    // appearance changes, as the suggestions plate does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shapePlate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shapePlate()
    }

    private func shapePlate() {
        guard let layer else { return }
        layer.cornerRadius = Theme.Radius.plate
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Theme.hairlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Theme.hairline.layerColor
        }
    }
}

/// One skill in the picker: `/name`, its argument hint, and its description.
private final class SkillPickerRow: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    private let name: NSTextField
    private let hint: NSTextField
    private let badge: NSTextField
    private let hasHint: Bool
    /// Between the name, the hint, the spacer and the badge.
    private static let spacing: CGFloat = 6
    private static let sideInset: CGFloat = 8

    init(skill: AgentSkill) {
        let argumentHint = skill.argumentHint ?? ""
        name = NSTextField(labelWithString: "/" + skill.name)
        hint = NSTextField(labelWithString: argumentHint)
        badge = NSTextField(labelWithString: skill.origin == .command ? "Command" : skill.origin == .library ? "Tiller" : "")
        hasHint = !argumentHint.isEmpty
        super.init(frame: .zero)
        wantsLayer = true
        name.font = .systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hint.font = .systemFont(ofSize: Theme.FontSize.caption)
        hint.textColor = Theme.tertiaryText
        // Never cut: a hint broken mid-token misleads, so `layout()` hides
        // it when it doesn't fit whole. It gives way to the row's width, and
        // under the split view's holding priority, so a long hint can't
        // widen the panel.
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.isHidden = !hasHint
        badge.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        badge.textColor = Theme.secondaryText
        badge.isHidden = skill.origin == .user
        let top = NSStackView(views: [name, hint, NSView(), badge])
        top.spacing = Self.spacing
        let description = NSTextField(labelWithString: skill.description.isEmpty ? " " : skill.description)
        description.font = .systemFont(ofSize: Theme.FontSize.caption)
        description.textColor = Theme.secondaryText
        description.lineBreakMode = .byTruncatingTail
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [top, description])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        toolTip = skill.description.isEmpty ? nil : skill.description
        setAccessibilityRole(.button)
        setAccessibilityLabel("/" + skill.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the hint only when the name, the hint and the badge all fit on
    /// the line. Decided before the stack lays out, so it lays out once.
    override func layout() {
        if hasHint, bounds.width > 0 {
            let available = bounds.width - 2 * Self.sideInset
            // The spacer between the hint and the badge adds one gap even at zero width.
            let badgeWidth = badge.isHidden ? 0 : Self.spacing + ceil(badge.intrinsicContentSize.width)
            let needed = ceil(name.intrinsicContentSize.width) + Self.spacing
                + ceil(hint.intrinsicContentSize.width) + Self.spacing + badgeWidth
            let hide = needed > available
            if hint.isHidden != hide { hint.isHidden = hide }
        }
        super.layout()
    }

    override var wantsUpdateLayer: Bool { true }

    /// The mouse selects the row it is over, so a pressed row is a selected
    /// one, and deepens its tint rather than turning grey.
    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let fill: NSColor = isSelected
            ? Theme.accent(isPressed ? Theme.Accent.selectedHover : Theme.Accent.selected)
            : Theme.fill(hovered: false, pressed: isPressed)
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = fill.layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.selectionOutline(selected: isSelected).layerColor
        // Tertiary text is too faint on the accent's wash.
        hint.textColor = isSelected || Theme.increaseContrast ? Theme.secondaryText : Theme.tertiaryText
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Drives a `SkillPicker` for a text view: opens it while the text is a `/`
/// and the start of a name, moves through it with the arrow keys, and puts
/// `/name ` in the text on Tab, Return or a click. The chat's message field
/// and the scheduled prompt editor both use it.
@MainActor
final class SkillCompletion {
    let picker = SkillPicker()
    /// What `/` can call, read when the picker opens.
    var skills: () -> [AgentSkill]
    private weak var textView: NSTextView?
    /// The skills offered while the picker is open.
    private var offered: [AgentSkill]?

    init(textView: NSTextView, skills: @escaping () -> [AgentSkill]) {
        self.textView = textView
        self.skills = skills
        picker.isHidden = true
        picker.onPick = { [weak self] skill in self?.complete(skill) }
    }

    var isShown: Bool { !picker.isHidden }

    /// Call when the text changes.
    func update() {
        guard let text = textView?.string, text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return hide() }
        let skills = offered ?? self.skills()
        offered = skills
        picker.show(skills, matching: String(text.dropFirst()))
    }

    func hide() {
        picker.isHidden = true
        offered = nil
    }

    /// The text view's `doCommandBy` while the picker is open. Returns
    /// whether the picker took the command.
    func handle(_ selector: Selector) -> Bool {
        guard isShown else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            picker.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            picker.moveSelection(by: 1)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            if let skill = picker.selectedSkill { complete(skill) }
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        default:
            return false
        }
        return true
    }

    /// Puts `/name ` in the field, keeping it undoable.
    func complete(_ skill: AgentSkill) {
        guard let textView else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        let replacement = "/" + skill.name + " "
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        hide()
        textView.window?.makeFirstResponder(textView)
    }

    /// The skill a message starting with `/name` calls, among `skills`.
    static func skill(calledBy text: String, in skills: [AgentSkill]) -> AgentSkill? {
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        return skills.first { $0.name == name }
    }
}
