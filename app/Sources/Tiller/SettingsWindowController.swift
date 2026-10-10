import AppKit
import UniformTypeIdentifiers

/// A profile's Settings window (Cmd+,), with General, Passwords, Extensions,
/// Agent, Providers, Skills, Scheduled and Profiles panes. Every change is
/// saved as it is made, in the profile, except the appearance, accent color,
/// agent shortcut, updates, remote debugging and extensions, which every
/// profile shares.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabViewController()
    let profileID: String

    init(profile: ProfileContext) {
        profileID = profile.id
        // Read before the first tab is added, which selects it and saves it.
        let lastPane = UserDefaults.standard.string(forKey: SettingsTabViewController.lastPaneKey)
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String)] = [
            (GeneralSettingsPane(profile: profile), "gearshape"),
            (PasswordsSettingsPane(profile: profile), "key"),
            (ExtensionsSettingsPane(profile: profile), "puzzlepiece.extension"),
            (AgentSettingsPane(profile: profile), "sparkles"),
            (ProvidersSettingsPane(profile: profile), "server.rack"),
            (SkillsSettingsPane(profile: profile), "wand.and.stars"),
            (ScheduledSettingsPane(profile: profile), "calendar.badge.clock"),
            (ProfilesSettingsPane(profile: profile), "person.2"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: ScrollingPaneController(pane))
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        // Reopens where it was left, on the pane last shown. Each profile's
        // window keeps its own place.
        window.setFrameAutosaveName(profile.id == Profiles.defaultID ? "Settings" : "Settings." + profile.id)
        super.init(window: window)
        if let lastPane { showPane(titled: lastPane) }
        tabs.fitWindow(animate: false)
        showProfile(name: Profiles.all.count > 1 ? profile.name : nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        let opening = window?.isVisible == false
        super.showWindow(sender)
        if opening { tabs.clearFocus() }
    }

    /// With several profiles, the title says whose settings these are.
    func showProfile(name: String?) {
        tabs.profileName = name
        tabs.updateTitle()
    }

    func showPane(titled title: String) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.viewController?.title == title }) {
            tabs.selectedTabViewItemIndex = index
        }
    }

    /// Cmd+W is File > Close Tab, which otherwise only browser windows answer.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

/// Sizes the window to each pane as it is picked, keeping its top edge in
/// place and easing the height, as System Settings does. Every pane has the
/// same width, so only the height moves.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    static let lastPaneKey = "SettingsLastPane"
    /// The profile's name, shown after the pane's while there are several.
    var profileName: String?

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let title = item?.viewController?.title {
            UserDefaults.standard.set(title, forKey: Self.lastPaneKey)
        }
        updateTitle()
        fitWindow(animate: true)
        clearFocus()
    }

    /// Opens a pane with nothing in it focused, as System Settings does,
    /// rather than with the first text field's ring lit as if being edited.
    /// AppKit picks that field once the pane is in the window, so this waits
    /// a turn.
    func clearFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window, window.firstResponder is NSTextView else { return }
            window.makeFirstResponder(nil)
        }
    }

    /// The pane's title, then the profile's name when there are several.
    /// The window follows this controller's title, which AppKit sets to the
    /// pane's on each switch.
    func updateTitle() {
        guard let pane = tabView.selectedTabViewItem?.label else { return }
        title = profileName.map { "\(pane) – \($0)" } ?? pane
    }

    /// The window's content takes the selected pane's size. Animates only
    /// while the window is on screen.
    func fitWindow(animate: Bool) {
        guard let window = view.window,
            let pane = tabView.selectedTabViewItem?.viewController as? ScrollingPaneController
        else { return }
        let size = pane.fittedSize(on: window.screen)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animate && window.isVisible && !Theme.reduceMotion)
    }
}

/// Holds a pane in a scroll view, so a pane taller than the screen scrolls
/// instead of pushing the window off it. The window takes the pane's own
/// height whenever it fits, and every pane's width.
@MainActor
final class ScrollingPaneController: NSViewController {
    private let pane: NSViewController

    init(_ pane: NSViewController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
        title = pane.title
        addChild(pane)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // A flipped document starts scrolled to the top, not the bottom.
        let document = FlippedView()
        document.addSubview(pane.view)
        scroll.documentView = document
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            pane.view.topAnchor.constraint(equalTo: document.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            pane.view.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            // The tab view controller fits the window to the pane, so a
            // form narrower than the lists is held to their width.
            pane.view.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsPane.paneWidth),
        ])
        view = scroll
    }

    // The pane's own preferred size stops here. Passed up, the tab view
    // controller would snap the window to it, at the pane's own width.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {}

    /// The pane's height, held to what the screen has room for, at the
    /// width every pane shares. The tab view controller sizes the window to
    /// it; a preferredContentSize would make the controller snap there instead.
    func fittedSize(on screen: NSScreen?) -> NSSize {
        _ = view
        var size = pane.preferredContentSize
        if size == .zero { size = pane.view.fittingSize }
        size.width = max(size.width, SettingsPane.paneWidth)
        if let screen = screen ?? NSScreen.main {
            // Room under the title bar and toolbar, with a margin.
            let room = screen.visibleFrame.height - 140
            size.height = min(size.height, max(300, room))
        }
        return size
    }
}

/// A view whose origin is its top left, for a scroll view's document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A list pane's table. Delete and Forward Delete send Edit > Delete up the
/// responder chain, where the pane removes the selected rows after asking.
final class SettingsTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if modifiers.isEmpty, key == 0x7F || key == NSDeleteFunctionKey,
            NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: self)
        {
            return
        }
        super.keyDown(with: event)
    }
}

/// A text view in a rounded box. The box's border takes the keyboard focus
/// color while the text view has focus, as a text field's focus ring does.
final class BoxedTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { showFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { showFocus(false) }
        return resigned
    }

    private func showFocus(_ focused: Bool) {
        var view = superview
        while let current = view, !(current is NSBox) { view = current.superview }
        guard let box = view as? NSBox else { return }
        box.borderColor = focused ? .keyboardFocusIndicatorColor : Theme.hairline
        box.borderWidth = focused ? 2 : Theme.hairlineWidth
    }
}

/// A two-column form: right-aligned labels, controls on the right, and short
/// notes under some controls.
@MainActor
class SettingsPane: NSViewController {
    let grid = NSGridView()
    static let controlWidth: CGFloat = 360
    /// The size of the table in each list pane, so the window keeps one
    /// width and the button row stays put when switching between them.
    static let tableWidth: CGFloat = 640
    static let tableHeight: CGFloat = 280
    /// The width of every pane: a list pane's table and its margins. Forms
    /// sit centered in it.
    static let paneWidth: CGFloat = tableWidth + 2 * Theme.Padding.sheet

    let profile: ProfileContext
    var settings: ProfileSettings { profile.settings }

    init(title: String, profile: ProfileContext) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        self.view = view
        buildRows()
        grid.column(at: 0).xPlacement = .trailing
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Subclasses add their rows here.
    func buildRows() {}

    /// A labeled row. VoiceOver reads the label as the control's title; a
    /// row of several controls links its main one with `linkLabel`.
    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        let title = NSTextField(labelWithString: label)
        if !(control is NSStackView) { control.setAccessibilityTitleUIElement(title) }
        return grid.addRow(with: [title, control])
    }

    /// Gives `control` the label of `row` as its title for VoiceOver.
    static func linkLabel(of row: NSGridRow, to control: NSView) {
        control.setAccessibilityTitleUIElement(row.cell(at: 0).contentView)
    }

    /// A note under the control in the row above.
    func addNote(_ note: NSTextField) {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -4
        // Sets the note's control apart from the one that follows.
        row.bottomPadding = 6
    }

    static func note(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A note of up to two lines that wraps within `width`, for under a
    /// table. It keeps room for both, since the pane is sized once.
    static func wrappingNote(width: CGFloat) -> NSTextField {
        let label = note()
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        // A cut third line ends in an ellipsis; `show` puts the whole text
        // of a warning in the tooltip.
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = width
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return label
    }

    static func show(_ text: String, in note: NSTextField, warning: Bool = false) {
        note.stringValue = text
        note.textColor = warning ? .systemRed : .secondaryLabelColor
        note.toolTip = warning ? text : nil
    }

    /// A text cell for a list pane's table, reused from `table` when it has
    /// one. The text is centered in the row, as checkboxes and icons are,
    /// and comes back with the default color and no tooltip.
    static func textCell(_ table: NSTableView, _ text: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("text")
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView, let label = cell.textField {
            label.stringValue = text
            label.textColor = .labelColor
            label.toolTip = nil
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// `scroll` with a dimmed label over the middle of its rows, for a table
    /// with no rows. Hide the label while there are rows.
    static func withPlaceholder(_ scroll: NSScrollView, _ text: String) -> (box: NSView, label: NSTextField) {
        let box = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        label.textColor = .secondaryLabelColor
        for view in [scroll, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        let header = scroll.documentView.flatMap { ($0 as? NSTableView)?.headerView?.frame.height } ?? 0
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -header / 2),
        ])
        return (box, label)
    }

    /// The least width of a column of pop-ups.
    static let popUpWidth: CGFloat = 180

    static func fixWidth(_ view: NSView, _ width: CGFloat = controlWidth) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    static func popUp<T: RawRepresentable<String>>(
        _ cases: [T], title: (T) -> String, image: ((T) -> NSImage?)? = nil, selected: T, target: AnyObject,
        action: Selector
    ) -> NSPopUpButton where T: Equatable {
        let button = NSPopUpButton()
        fill(button, cases, title: title, image: image, selected: selected)
        button.target = target
        button.action = action
        return button
    }

    /// Replaces the pop-up's items with `cases`, `selected` picked.
    static func fill<T: RawRepresentable<String>>(
        _ button: NSPopUpButton, _ cases: [T], title: (T) -> String, image: ((T) -> NSImage?)? = nil, selected: T
    ) where T: Equatable {
        button.removeAllItems()
        for value in cases {
            let icon = image?(value)
            // The pop-up leaves only a couple of points after an item's
            // image; a leading space makes it about six.
            button.addItem(withTitle: icon == nil ? title(value) : " " + title(value))
            button.lastItem?.representedObject = value.rawValue
            icon?.size = NSSize(width: 16, height: 16)
            button.lastItem?.image = icon
        }
        button.selectItem(at: cases.firstIndex(of: selected) ?? 0)
    }
}

// MARK: General

final class GeneralSettingsPane: SettingsPane, NSTextFieldDelegate {
    private let homepageField = NSTextField()
    private var launchPopUp: NSPopUpButton?
    private var newTabPopUp: NSPopUpButton?
    private var tabLayoutPopUp: NSPopUpButton?
    private var appearancePopUp: NSPopUpButton?
    private var accentPopUp: NSPopUpButton?
    private var remoteDebuggingButton: NSButton?
    private var searchPopUp: NSPopUpButton?
    private let templateField = NSTextField()
    private let templateNote = SettingsPane.note()
    private let defaultBrowserButton = NSButton(title: "Make Default", target: nil, action: nil)
    private let defaultBrowserStatus = NSTextField(labelWithString: "")

    init(profile: ProfileContext) { super.init(title: "General", profile: profile) }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        defaultBrowserButton.target = self
        defaultBrowserButton.action = #selector(makeDefaultBrowser(_:))
        let defaultBrowser = NSStackView(views: [defaultBrowserButton, defaultBrowserStatus])
        defaultBrowser.spacing = 8
        Self.linkLabel(of: addRow("Default browser:", defaultBrowser), to: defaultBrowserButton)
        addNote(Self.note("For every profile. Links open in the profile used last."))
        showDefaultBrowserState()
        for name in [NSApplication.didBecomeActiveNotification, .defaultBrowserDidChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(defaultBrowserChanged(_:)), name: name, object: nil
            )
        }

        homepageField.stringValue = settings.homepage
        homepageField.placeholderString = Settings.defaultHomepage
        homepageField.delegate = self
        addRow("Homepage:", Self.fixWidth(homepageField))
        addNote(Self.note("Opens at launch and in new tabs, as chosen below."))

        let launchPopUp = Self.popUp(
            LaunchTabs.allCases, title: \.displayName, selected: settings.launchTabs,
            target: self, action: #selector(launchTabsChanged(_:))
        )
        self.launchPopUp = launchPopUp
        addRow("At launch, open:", launchPopUp)

        let newTabPopUp = Self.popUp(
            NewTabPage.allCases, title: \.displayName, selected: settings.newTabPage,
            target: self, action: #selector(newTabPageChanged(_:))
        )
        self.newTabPopUp = newTabPopUp
        addRow("New tabs open with:", newTabPopUp)

        let tabLayoutPopUp = Self.popUp(
            TabLayout.allCases, title: \.displayName, selected: settings.tabLayout,
            target: self, action: #selector(tabLayoutChanged(_:))
        )
        self.tabLayoutPopUp = tabLayoutPopUp
        addRow("Show tabs:", tabLayoutPopUp)

        let appearancePopUp = Self.popUp(
            Appearance.allCases, title: \.displayName, selected: Settings.appearance,
            target: self, action: #selector(appearanceChanged(_:))
        )
        self.appearancePopUp = appearancePopUp
        addRow("Appearance:", appearancePopUp)

        let accentPopUp = Self.popUp(
            AccentTheme.allCases, title: \.displayName, image: { Self.swatch($0.color) }, selected: Settings.accentTheme,
            target: self, action: #selector(accentChanged(_:))
        )
        self.accentPopUp = accentPopUp
        addRow("Accent color:", accentPopUp)
        addNote(Self.note("Selections, chat bubbles and busy dots. Pages follow the appearance."))

        let remoteDebugging = NSButton(
            checkboxWithTitle: "Allow remote debugging (CDP)", target: self, action: #selector(remoteDebuggingChanged(_:))
        )
        remoteDebugging.state = Settings.remoteDebuggingEnabled ? .on : .off
        remoteDebuggingButton = remoteDebugging
        Self.linkLabel(of: addRow("Remote debugging:", remoteDebugging), to: remoteDebugging)
        addNote(Self.note("For every profile. Takes effect on next launch."))

        let searchPopUp = Self.popUp(
            SearchEngine.allCases, title: \.displayName, selected: settings.searchEngine,
            target: self, action: #selector(searchEngineChanged(_:))
        )
        self.searchPopUp = searchPopUp
        addRow("Search engine:", searchPopUp)

        // One width for them all, so their right edges line up; a longer
        // title can still widen its own.
        for popUp in [launchPopUp, newTabPopUp, tabLayoutPopUp, appearancePopUp, accentPopUp, searchPopUp] {
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.popUpWidth).isActive = true
        }

        templateField.stringValue = settings.searchTemplate
        templateField.placeholderString = "https://example.com/search?q=%s"
        templateField.delegate = self
        addRow("Custom search URL:", Self.fixWidth(templateField))
        addNote(templateNote)
        showTemplateState()

        if Updater.isAvailable {
            let automatic = NSButton(checkboxWithTitle: "Check automatically", target: self, action: #selector(automaticUpdatesChanged(_:)))
            automatic.state = Updater.shared.automaticallyChecks ? .on : .off
            let betas = NSButton(checkboxWithTitle: "Include beta versions", target: self, action: #selector(betaUpdatesChanged(_:)))
            betas.state = Updater.includesBetas ? .on : .off
            let updates = NSStackView(views: [automatic, betas])
            updates.orientation = .vertical
            updates.alignment = .leading
            updates.spacing = 6
            Self.linkLabel(of: addRow("Updates:", updates), to: automatic)
            addNote(Self.note("For every profile."))
        }
    }

    /// An import from Chrome may have changed these while the window was closed.
    override func viewWillAppear() {
        super.viewWillAppear()
        showDefaultBrowserState()
        homepageField.stringValue = settings.homepage
        templateField.stringValue = settings.searchTemplate
        launchPopUp?.selectItem(at: LaunchTabs.allCases.firstIndex(of: settings.launchTabs) ?? 0)
        newTabPopUp?.selectItem(at: NewTabPage.allCases.firstIndex(of: settings.newTabPage) ?? 0)
        tabLayoutPopUp?.selectItem(at: TabLayout.allCases.firstIndex(of: settings.tabLayout) ?? 0)
        appearancePopUp?.selectItem(at: Appearance.allCases.firstIndex(of: Settings.appearance) ?? 0)
        accentPopUp?.selectItem(at: AccentTheme.allCases.firstIndex(of: Settings.accentTheme) ?? 0)
        remoteDebuggingButton?.state = Settings.remoteDebuggingEnabled ? .on : .off
        searchPopUp?.selectItem(at: SearchEngine.allCases.firstIndex(of: settings.searchEngine) ?? 0)
        showTemplateState()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === homepageField {
            settings.homepage = field.stringValue
        } else if field === templateField {
            settings.searchTemplate = field.stringValue
            showTemplateState()
        }
    }

    @objc private func makeDefaultBrowser(_ sender: NSButton) {
        DefaultBrowser.makeDefault { [weak self] _ in self?.showDefaultBrowserState() }
    }

    /// Another app may have taken over as the default while Tiller was in the background.
    @objc private func defaultBrowserChanged(_ notification: Notification) {
        showDefaultBrowserState()
    }

    private func showDefaultBrowserState() {
        let isDefault = DefaultBrowser.isDefault
        defaultBrowserButton.isHidden = isDefault
        defaultBrowserButton.isEnabled = DefaultBrowser.isAvailable
        defaultBrowserStatus.stringValue = isDefault
            ? "Tiller is the default browser."
            : DefaultBrowser.isAvailable ? "" : "Only Tiller.app can be the default."
    }

    @objc private func launchTabsChanged(_ sender: NSPopUpButton) {
        guard let tabs = (sender.selectedItem?.representedObject as? String).flatMap(LaunchTabs.init) else { return }
        settings.launchTabs = tabs
    }

    @objc private func newTabPageChanged(_ sender: NSPopUpButton) {
        guard let page = (sender.selectedItem?.representedObject as? String).flatMap(NewTabPage.init) else { return }
        settings.newTabPage = page
    }

    @objc private func tabLayoutChanged(_ sender: NSPopUpButton) {
        guard let layout = (sender.selectedItem?.representedObject as? String).flatMap(TabLayout.init) else { return }
        settings.tabLayout = layout
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard let appearance = (sender.selectedItem?.representedObject as? String).flatMap(Appearance.init) else { return }
        Settings.appearance = appearance
    }

    @objc private func accentChanged(_ sender: NSPopUpButton) {
        guard let theme = (sender.selectedItem?.representedObject as? String).flatMap(AccentTheme.init) else { return }
        Settings.accentTheme = theme
    }

    @objc private func remoteDebuggingChanged(_ sender: NSButton) {
        Settings.remoteDebuggingEnabled = sender.state == .on
    }

    /// A dot of `color` for a pop-up item. Drawn on demand, so it follows
    /// light and dark mode.
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            color.setFill()
            dot.fill()
            Theme.hairline.setStroke()
            dot.lineWidth = 1
            dot.stroke()
            return true
        }
    }

    @objc private func automaticUpdatesChanged(_ sender: NSButton) {
        Updater.shared.automaticallyChecks = sender.state == .on
    }

    @objc private func betaUpdatesChanged(_ sender: NSButton) {
        Updater.includesBetas = sender.state == .on
    }

    @objc private func searchEngineChanged(_ sender: NSPopUpButton) {
        guard let engine = (sender.selectedItem?.representedObject as? String).flatMap(SearchEngine.init) else { return }
        settings.searchEngine = engine
        showTemplateState()
        if engine == .custom { view.window?.makeFirstResponder(templateField) }
    }

    private func showTemplateState() {
        let custom = settings.searchEngine == .custom
        templateField.isEnabled = custom
        if custom && !Settings.isValidSearchTemplate(settings.searchTemplate) {
            Self.show("Needs an http(s) URL with %s. Google is used until then.", in: templateNote, warning: true)
        } else {
            Self.show("Put %s where the search terms go.", in: templateNote)
        }
    }
}

// MARK: Passwords

/// Saved passwords: site and username, a field to search them, and buttons
/// to copy a password or remove logins. Passwords come in through Tiller >
/// Import from Chrome.
final class PasswordsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let table = SettingsTableView()
    private let searchField = NSSearchField()
    private let copyButton = NSButton(title: "Copy Password", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let removeAllButton = NSButton(title: "Remove All…", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: SettingsPane.tableWidth)
    private var placeholder: NSTextField?
    private var entries: [PasswordStore.Entry] { profile.passwords.entries }
    /// The entries the search matches, which the table shows.
    private var filtered: [PasswordStore.Entry] = []
    private let profile: ProfileContext

    init(profile: ProfileContext) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = "Passwords"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("site", "Website", 340.0), ("username", "Username", 240.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.allowsMultipleSelection = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Saved Passwords")
        self.placeholder = placeholder

        searchField.placeholderString = "Search websites and usernames"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(search(_:))

        copyButton.target = self
        copyButton.action = #selector(copyPassword(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll(_:))
        let buttons = NSStackView(views: [copyButton, removeButton, NSView(), removeAllButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [searchField, tableBox, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsPane.tableWidth),
            // The search field comes out of the table's height, so the pane
            // is the same size as the other lists.
            scroll.heightAnchor.constraint(
                equalToConstant: SettingsPane.tableHeight - searchField.fittingSize.height - stack.spacing),
            searchField.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .passwordsDidChange, object: profile.passwords)
        reload(nil)
    }

    /// Filters again and keeps the same logins selected, so a selection
    /// never moves onto rows the user didn't pick.
    @objc private func reload(_ notification: Notification?) {
        let selectedIDs = Set(selectedEntries.map(\.id))
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = query.isEmpty
            ? entries
            : entries.filter {
                $0.origin.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
            }
        table.reloadData()
        table.selectRowIndexes(
            IndexSet(filtered.indices.filter { selectedIDs.contains(filtered[$0].id) }), byExtendingSelection: false)
        updateControls()
    }

    @objc private func search(_ sender: NSSearchField) {
        reload(nil)
    }

    private func updateControls() {
        copyButton.isEnabled = table.selectedRowIndexes.count == 1
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        removeAllButton.isEnabled = !entries.isEmpty
        placeholder?.stringValue = entries.isEmpty ? "No Saved Passwords" : "No Matches"
        placeholder?.isHidden = !filtered.isEmpty
        SettingsPane.show(
            entries.isEmpty
                ? "No saved passwords. Bring them over with Tiller > Import from Chrome…"
                : "\(entries.count) saved. On a page with a saved login, the key in the address bar fills it.",
            in: note
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let entry = filtered[row]
        let text = column?.identifier.rawValue == "site"
            ? HistoryStore.bare(entry.origin)
            : (entry.username.isEmpty ? "(no username)" : entry.username)
        let cell = SettingsPane.textCell(tableView, text)
        if column?.identifier.rawValue == "site" { cell.textField?.toolTip = entry.origin }
        return cell
    }

    /// Typing a site's name selects its row.
    func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        guard filtered.indices.contains(row), column?.identifier.rawValue == "site" else { return nil }
        return HistoryStore.bare(filtered[row].origin)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    private var selectedEntries: [PasswordStore.Entry] {
        table.selectedRowIndexes.compactMap { filtered.indices.contains($0) ? filtered[$0] : nil }
    }

    /// Edit > Copy copies the selected login's password.
    @objc func copy(_ sender: Any?) {
        copyPassword(sender)
    }

    /// Edit > Delete and the Delete key remove the selected logins, after asking.
    @objc func delete(_ sender: Any?) {
        guard removeButton.isEnabled else { return NSSound.beep() }
        remove(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): copyButton.isEnabled
        case #selector(delete(_:)): removeButton.isEnabled
        default: true
        }
    }

    @objc private func copyPassword(_ sender: Any?) {
        guard table.selectedRowIndexes.count == 1, let entry = selectedEntries.first else { return }
        Task {
            do {
                let password = try await self.profile.passwords.password(for: entry)
                // Marked concealed and transient, so clipboard managers leave
                // it out of their history, and kept off Universal Clipboard.
                let pasteboard = NSPasteboard.general
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                pasteboard.setString(password, forType: .string)
                for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
                    pasteboard.setString("", forType: NSPasteboard.PasteboardType(marker))
                }
                SettingsPane.show("Copied the password for \(HistoryStore.bare(entry.origin)).", in: note)
            } catch {
                SettingsPane.show(error.localizedDescription, in: note, warning: true)
            }
        }
    }

    /// Asks first: a removed password comes back only with another import.
    @objc private func remove(_ sender: Any?) {
        let picked = selectedEntries
        guard !picked.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = picked.count == 1
            ? "Remove the password for \(HistoryStore.bare(picked[0].origin))?"
            : "Remove \(picked.count) saved passwords?"
        alert.informativeText = "Removes \(picked.count == 1 ? "it" : "them") from Tiller. Chrome keeps its own."
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    try self.profile.passwords.remove(Set(picked.map(\.id)))
                    self.table.deselectAll(nil)
                    self.updateControls()
                } catch {
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }

    @objc private func removeAll(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all saved passwords?"
        alert.informativeText = "Removes \(entries.count) passwords from Tiller. Chrome keeps its own."
        alert.addButton(withTitle: "Remove All")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    try self.profile.passwords.removeAll()
                } catch {
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }
}

// MARK: Extensions

/// The profile's extensions, with switches to turn them on and pin them to
/// the toolbar, and buttons to add, configure and remove them. Chromium loads
/// extensions at launch, so turning one on or off applies at the next launch.
final class ExtensionsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    static let paneTitle = "Extensions"

    private let table = SettingsTableView()
    private let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let addCRXButton = NSButton(title: "Add CRX File…", target: nil, action: nil)
    private let optionsButton = NSButton(title: "Options", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: SettingsPane.tableWidth)
    private var placeholder: NSTextField?
    private var store: ExtensionStore { .shared }
    private let profile: ProfileContext

    init(profile: ProfileContext) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = Self.paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [
            ("on", "On", 30.0), ("name", "Extension", 250.0), ("version", "Version", 80.0),
            ("pinned", "Pinned", 56.0), ("status", "Status", 140.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.allowsMultipleSelection = true
        table.style = .inset
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openOptions(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Extensions")
        self.placeholder = placeholder

        for (button, action) in [
            (addFolderButton, #selector(addFolder(_:))),
            (addCRXButton, #selector(addCRX(_:))),
            (optionsButton, #selector(openOptions(_:))),
            (removeButton, #selector(remove(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addFolderButton, addCRXButton, optionsButton, NSView(), removeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [tableBox, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsPane.tableWidth),
            scroll.heightAnchor.constraint(equalToConstant: SettingsPane.tableHeight),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .extensionsDidChange, object: nil)
        reload(nil)
    }

    @objc private func reload(_ notification: Notification?) {
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected.filteredIndexSet { $0 < store.entries.count }, byExtendingSelection: false)
        updateControls()
    }

    private func updateControls() {
        optionsButton.isEnabled = selectedManifest?.optionsURL != nil
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        placeholder?.isHidden = !store.entries.isEmpty
        let text: String
        if store.entries.isEmpty {
            text = "No extensions. Add an unpacked folder or a CRX file, or bring Chrome's over with Tiller > Import from Chrome…"
        } else if store.needsRestart {
            text = "Changes apply the next time Tiller opens."
        } else {
            text = "\(store.running.count) of \(store.entries.count) running. Chrome's tab and window APIs don't see Tiller's tabs."
        }
        SettingsPane.show(text, in: note)
    }

    /// The selected extension, when exactly one is selected and running.
    private var selectedManifest: ExtensionManifest? {
        guard table.selectedRowIndexes.count == 1, store.entries.indices.contains(table.selectedRow) else { return nil }
        let entry = store.entries[table.selectedRow]
        guard store.isLoaded(entry), store.loadError(forFolder: entry.path) == nil else { return nil }
        return try? store.manifest(for: entry).get()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.entries.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard store.entries.indices.contains(row) else { return nil }
        let entry = store.entries[row]
        let manifest = store.manifest(for: entry)
        switch column?.identifier.rawValue {
        case "on", "pinned":
            let isOn = column?.identifier.rawValue == "on"
            let checkbox = NSButton(
                checkboxWithTitle: "", target: self, action: isOn ? #selector(toggleEnabled(_:)) : #selector(togglePinned(_:)))
            checkbox.tag = row
            checkbox.state = (isOn ? entry.enabled : entry.pinned) ? .on : .off
            // The box has no title of its own, so VoiceOver gets the extension's name.
            let name = (try? manifest.get().name) ?? (entry.path as NSString).lastPathComponent
            checkbox.setAccessibilityLabel(isOn ? "\(name) On" : "\(name) Pinned")
            return checkbox
        case "name":
            let label = NSTextField(labelWithString: (try? manifest.get().name) ?? (entry.path as NSString).lastPathComponent)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = entry.path
            let icon = NSImageView(image: (try? manifest.get().image(size: 16))
                ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)!)
            let stack = NSStackView(views: [icon, label])
            stack.spacing = 6
            return stack
        case "version":
            return SettingsPane.textCell(tableView, (try? manifest.get().version) ?? "")
        default:
            let cell = SettingsPane.textCell(tableView, status(of: entry, manifest))
            guard let label = cell.textField else { return cell }
            label.textColor = .secondaryLabelColor
            if case .failure(let error) = manifest {
                label.textColor = .systemRed
                label.toolTip = error.localizedDescription
            } else if store.isLoaded(entry), let error = store.loadError(forFolder: entry.path) {
                label.textColor = .systemRed
                label.toolTip = error
            }
            return cell
        }
    }

    private func status(of entry: ExtensionStore.Entry, _ manifest: Result<ExtensionManifest, Error>) -> String {
        if case .failure(let error) = manifest {
            if case ExtensionError.noManifest = error { return "Folder missing" }
            return "Can't be loaded"
        }
        if store.isLoaded(entry) && store.loadError(forFolder: entry.path) != nil {
            return "Failed to load"
        }
        switch (store.isLoaded(entry), entry.enabled) {
        case (true, true): return "Running"
        case (true, false): return "Stops at next launch"
        case (false, true): return "Starts at next launch"
        case (false, false): return "Off"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        store.setEnabled(sender.state == .on, at: sender.tag)
    }

    @objc private func togglePinned(_ sender: NSButton) {
        store.setPinned(sender.state == .on, at: sender.tag)
    }

    @objc private func addFolder(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose an unpacked extension's folder, the one with manifest.json in it"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    let manifest = try self.store.addFolder(url.path)
                    SettingsPane.show("Added \(manifest.name). It starts the next time Tiller opens.", in: self.note)
                } catch {
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }

    @objc private func addCRX(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "crx") ?? .data]
        panel.message = "Choose a Chrome extension package"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    do {
                        let manifest = try await self.store.addCRX(url.path)
                        SettingsPane.show("Added \(manifest.name). It starts the next time Tiller opens.", in: self.note)
                    } catch {
                        SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                    }
                }
            }
        }
    }

    /// Edit > Delete and the Delete key remove the selected extensions, after asking.
    @objc func delete(_ sender: Any?) {
        guard removeButton.isEnabled else { return NSSound.beep() }
        remove(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(delete(_:)) ? removeButton.isEnabled : true
    }

    @objc private func openOptions(_ sender: Any?) {
        guard let url = selectedManifest?.optionsURL else { return }
        (NSApp.delegate as? AppDelegate)?.openInNewTab(url, profile: profile)
    }

    /// Asks first: an extension Tiller copied or unpacked is deleted with it.
    @objc private func remove(_ sender: Any?) {
        let indexes = table.selectedRowIndexes
        let names = indexes.compactMap { store.entries.indices.contains($0) ? store.entries[$0] : nil }
            .map { (try? store.manifest(for: $0).get())?.name ?? ($0.path as NSString).lastPathComponent }
        guard !names.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Remove “\(names[0])”?" : "Remove \(names.count) extensions?"
        alert.informativeText = "Its files are deleted from Tiller. The folder or file it was added from stays."
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.remove(at: indexes)
                self.table.deselectAll(nil)
            }
        }
    }
}

// MARK: Agent

final class AgentSettingsPane: SettingsPane, NSTextFieldDelegate, NSTextViewDelegate {
    private var agentPopUp: NSPopUpButton?
    /// Picks which CLI's path `pathField` shows.
    private var pathKindPopUp: NSPopUpButton?
    private let pathField = NSTextField()
    private let pathNote = SettingsPane.note()
    /// Picks which CLI's model options `modelButton` shows.
    private var modelKindPopUp: NSPopUpButton?
    private lazy var modelButton = NSButton(title: "", target: self, action: #selector(chooseModel(_:)))
    private var modelKind: AgentChoice {
        (modelKindPopUp?.selectedItem?.representedObject as? String).flatMap(AgentChoice.init) ?? profile.providers.current
    }
    /// What the lookup found, for kinds whose lookup has finished. Nil values mean not found.
    private var detected: [AgentKind: String?] = [:]
    /// The CLI whose path is being edited.
    private var pathKind: AgentKind {
        (pathKindPopUp?.selectedItem?.representedObject as? String).flatMap(AgentKind.init) ?? profile.providers.current.kind
    }
    private var instructionsView: NSTextView?
    private let folderField = NSTextField()
    private let folderNote = SettingsPane.note()
    private let shortcutRecorder = ShortcutRecorder()
    private lazy var restoreShortcutButton = NSButton(
        title: "Restore Default", target: self, action: #selector(restoreShortcut(_:))
    )
    private let shortcutNote = SettingsPane.note()

    /// Paths need more room than General's controls.
    private static let wideControlWidth: CGFloat = 460

    init(profile: ProfileContext) { super.init(title: "Agent", profile: profile) }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let popUp = Self.popUp(
            profile.providers.all, title: profile.providers.displayName, image: { $0.logo(size: 16) }, selected: profile.providers.current,
            target: self, action: #selector(agentChanged(_:))
        )
        agentPopUp = popUp
        AgentMenuAvailability.watch(popUp, providers: profile.providers)
        addRow("New chats use:", popUp)
        addNote(Self.note("A running chat keeps its agent."))
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: nil
        )

        let tabsPopUp = NSPopUpButton()
        for count in Settings.agentTabsRange {
            tabsPopUp.addItem(withTitle: "\(count)")
            tabsPopUp.lastItem?.tag = count
        }
        tabsPopUp.selectItem(withTag: settings.agentTabs)
        tabsPopUp.target = self
        tabsPopUp.action = #selector(tabsChanged(_:))
        addRow("Chat tabs:", tabsPopUp)
        addNote(Self.note("At most this many chats open at once. The rest stay in history."))

        shortcutRecorder.shortcut = Settings.agentShortcut
        shortcutRecorder.onRecord = { [weak self] shortcut in self?.shortcutRecorded(shortcut) }
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let shortcutRow = NSStackView(views: [shortcutRecorder, restoreShortcutButton])
        shortcutRow.spacing = 8
        Self.linkLabel(of: addRow("Show and hide:", shortcutRow), to: shortcutRecorder)
        addNote(shortcutNote)
        showShortcutState()

        // One row serves every CLI: the popup picks whose path the field shows.
        let kindPopUp = Self.popUp(
            AgentKind.allCases, title: \.displayName, image: { $0.logo(size: 16) }, selected: profile.providers.current.kind,
            target: self, action: #selector(pathKindChanged(_:))
        )
        pathKindPopUp = kindPopUp
        pathField.delegate = self
        let choosePath = NSButton(title: "Choose…", target: self, action: #selector(choosePath(_:)))
        let pathRow = NSStackView(views: [kindPopUp, pathField, choosePath])
        pathRow.spacing = 8
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        Self.linkLabel(of: addRow("Command:", Self.fixWidth(pathRow, Self.wideControlWidth)), to: pathField)
        addNote(pathNote)
        loadPathField()

        // Like the command row, the popup picks whose options the button shows.
        let modelKindPopUp = Self.popUp(
            profile.providers.all, title: profile.providers.displayName, image: { $0.logo(size: 16) }, selected: profile.providers.current,
            target: self, action: #selector(modelKindChanged(_:))
        )
        self.modelKindPopUp = modelKindPopUp
        AgentMenuAvailability.watch(modelKindPopUp, providers: profile.providers)
        modelButton.bezelStyle = .push
        modelButton.lineBreakMode = .byTruncatingTail
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modelRow = NSStackView(views: [modelKindPopUp, modelButton])
        modelRow.spacing = 8
        Self.linkLabel(of: addRow("Model:", Self.fixWidth(modelRow, Self.wideControlWidth)), to: modelButton)
        let modelNote = Self.note("Model, thinking effort, context window and fast mode for new chats, where the CLI has them. Each chat can change its own from the model button.")
        modelNote.lineBreakMode = .byWordWrapping
        modelNote.preferredMaxLayoutWidth = Self.wideControlWidth
        addNote(modelNote)
        showModelOptions()
        NotificationCenter.default.addObserver(
            self, selector: #selector(modelsChanged(_:)), name: .agentModelsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(providersChanged(_:)), name: .agentProvidersDidChange, object: nil
        )

        let checkboxes = AgentTool.allCases.enumerated().map { index, tool in
            let checkbox = NSButton(checkboxWithTitle: tool.displayName, target: self, action: #selector(toolChanged(_:)))
            checkbox.tag = index
            checkbox.state = settings.agentToolEnabled(tool) ? .on : .off
            return checkbox
        }
        let tools = NSStackView(views: checkboxes)
        tools.orientation = .vertical
        tools.alignment = .leading
        tools.spacing = 6
        let toolsRow = addRow("Allowed tools:", tools)
        toolsRow.rowAlignment = .none
        toolsRow.cell(at: 0).yPlacement = .top
        let toolsNote = Self.note(
            "They run without asking, and pages can try to steer the agent. Codex always reads and runs "
                + "read-only commands, and Run commands lifts its sandbox. Antigravity CLI always has them all. Defaults for new chats; each chat can change its own from the tools button."
        )
        toolsNote.lineBreakMode = .byWordWrapping
        toolsNote.preferredMaxLayoutWidth = Self.wideControlWidth
        addNote(toolsNote)

        folderField.stringValue = settings.agentFolder
        folderField.placeholderString = "An empty folder"
        folderField.delegate = self
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))
        let folderRow = NSStackView(views: [Self.fixWidth(folderField, Self.wideControlWidth - 90), choose])
        folderRow.spacing = 8
        Self.linkLabel(of: addRow("Working folder:", folderRow), to: folderField)
        addNote(folderNote)
        showFolderState()

        let scroll = BoxedTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // A rounded box like the text fields above it.
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = Theme.Radius.small
        box.borderColor = Theme.hairline
        box.fillColor = Theme.fill(Theme.Fill.rest)
        box.contentViewMargins = NSSize(width: 1, height: 1)
        box.contentView = scroll
        box.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let textView = scroll.documentView as! NSTextView
        textView.drawsBackground = false
        textView.string = settings.agentInstructions
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.delegate = self
        textView.setAccessibilityLabel("Extra instructions")
        instructionsView = textView
        let row = addRow("Extra instructions:", Self.fixWidth(box, Self.wideControlWidth))
        row.rowAlignment = .none
        row.cell(at: 0).yPlacement = .top
        addNote(Self.note("Added after Tiller's prompt. Applies from the next new chat."))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadPathField()
        detectPaths()
    }

    /// Looks up each CLI off the main thread, since it may start a login shell.
    private func detectPaths() {
        Task { [weak self] in
            for kind in AgentKind.allCases {
                let path = await Task.detached { AgentEnvironment.detectedExecutable(for: kind) }.value
                guard let self else { return }
                self.detected[kind] = .some(path)
                self.showPathState()
            }
        }
    }

    /// Shows the picked CLI's path in the field.
    private func loadPathField() {
        pathField.stringValue = settings.defaults.string(forKey: pathKind.pathDefaultsKey) ?? ""
        showPathState()
    }

    @objc private func pathKindChanged(_ sender: NSPopUpButton) {
        loadPathField()
    }

    private func showPathState() {
        let kind = pathKind
        let found = detected[kind]
        pathField.placeholderString = switch found {
        case .none: "Looking for \(kind.rawValue)…"
        case .some(let path?): path
        case .some(nil): "\(kind.rawValue) not found"
        }
        if let path = settings.agentPath(for: kind) {
            if FileManager.default.isExecutableFile(atPath: path) {
                Self.show("Tiller runs this file for \(kind.displayName).", in: pathNote)
            } else {
                Self.show("Not an executable file.", in: pathNote, warning: true)
            }
        } else if case .some(nil) = found {
            Self.show("Not found. Install \(kind.displayName), or choose its file.", in: pathNote, warning: true)
        } else {
            Self.show("Leave empty to find it automatically.", in: pathNote)
        }
    }

    private func showFolderState() {
        guard let folder = settings.agentFolderPath else {
            Self.show("Leave empty so no project's files or instructions load.", in: folderNote)
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue {
            Self.show("Its instructions and project settings load too.", in: folderNote)
        } else {
            Self.show("Not a folder.", in: folderNote, warning: true)
        }
    }

    private func showModelOptions() {
        let kind = modelKind
        let options = settings.agentModelOptions(for: kind)
        modelButton.title = options.isDefault ? "\(profile.providers.displayName(kind))'s own" : options.summary(for: kind)
    }

    @objc private func modelKindChanged(_ sender: NSPopUpButton) {
        showModelOptions()
        if modelKind.provider == nil { AgentModelCatalog.refresh(modelKind.kind, profile: profile) }
    }

    /// Providers added, renamed or removed in their pane show here too.
    @objc private func providersChanged(_ notification: Notification) {
        for popUp in [agentPopUp, modelKindPopUp].compactMap({ $0 }) {
            let selected = (popUp.selectedItem?.representedObject as? String).flatMap(AgentChoice.init)
            Self.fill(
                popUp, profile.providers.all, title: profile.providers.displayName, image: { $0.logo(size: 16) },
                selected: selected.flatMap { profile.providers.exists($0) ? $0 : nil } ?? profile.providers.current
            )
        }
        showModelOptions()
    }

    @objc private func modelsChanged(_ notification: Notification) {
        showModelOptions()
    }

    @objc private func chooseModel(_ sender: NSButton) {
        let kind = modelKind
        AgentModelMenu.popUp(
            below: sender, kind: kind, profile: profile, options: settings.agentModelOptions(for: kind)
        ) { [weak self] options in
            self?.settings.setAgentModelOptions(options, for: kind)
            self?.showModelOptions()
        }
    }

    @objc private func toolChanged(_ sender: NSButton) {
        guard AgentTool.allCases.indices.contains(sender.tag) else { return }
        settings.setAgentTool(AgentTool.allCases[sender.tag], enabled: sender.state == .on)
    }

    @objc private func chooseFolder(_ sender: NSButton) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose the folder the agent works in"
        if let current = settings.agentFolderPath { panel.directoryURL = URL(fileURLWithPath: current) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.folderField.stringValue = url.path
                self.settings.agentFolder = url.path
                self.showFolderState()
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === folderField {
            settings.agentFolder = folderField.stringValue
            showFolderState()
            return
        }
        guard notification.object as? NSTextField === pathField else { return }
        settings.setAgentPath(pathField.stringValue, for: pathKind)
        showPathState()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = instructionsView else { return }
        settings.agentInstructions = textView.string
    }

    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let kind = (sender.selectedItem?.representedObject as? String).flatMap(AgentChoice.init) else { return }
        profile.providers.current = kind
    }

    @objc private func tabsChanged(_ sender: NSPopUpButton) {
        settings.agentTabs = sender.selectedTag()
    }

    private func shortcutRecorded(_ shortcut: Shortcut?) {
        if let shortcut {
            if shortcut.modifiers.isDisjoint(with: [.command, .control]) {
                return Self.show("Use a combination with ⌘ or ⌃.", in: shortcutNote, warning: true)
            }
            if let title = MainMenu.conflict(with: shortcut) {
                return Self.show("\(shortcut.displayString) is used by \(title).", in: shortcutNote, warning: true)
            }
        }
        Settings.agentShortcut = shortcut
        MainMenu.applyAgentShortcut()
        showShortcutState()
    }

    @objc private func restoreShortcut(_ sender: Any?) {
        Settings.resetAgentShortcut()
        MainMenu.applyAgentShortcut()
        showShortcutState()
    }

    private func showShortcutState() {
        shortcutRecorder.shortcut = Settings.agentShortcut
        restoreShortcutButton.isEnabled = Settings.agentShortcut != Settings.defaultAgentShortcut
        Self.show(
            Settings.agentShortcut == nil
                ? "No shortcut. Click to record one."
                : "Click to record another. Delete clears it, Escape cancels.",
            in: shortcutNote
        )
    }

    /// The panel's picker changed the agent.
    @objc private func currentAgentChanged(_ notification: Notification) {
        agentPopUp?.selectItem(at: profile.providers.all.firstIndex(of: profile.providers.current) ?? 0)
    }

    @objc private func choosePath(_ sender: NSButton) {
        guard let window = view.window else { return }
        let kind = pathKind
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(kind.displayName) executable"
        if let current = settings.agentPath(for: kind) ?? detected[kind] ?? nil {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settings.setAgentPath(url.path, for: kind)
                if self.pathKind == kind { self.loadPathField() }
            }
        }
    }
}


// MARK: Skills

/// Tiller's skill library: skills every agent can call with `/name`, with a
/// switch for each and buttons to add, reveal and remove them. Agents load the
/// library when they start, so a change applies from a chat's next start.
final class SkillsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    static let paneTitle = "Skills"

    private let table = SettingsTableView()
    private let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let addArchiveButton = NSButton(title: "Add Archive…", target: nil, action: nil)
    private let addGitButton = NSButton(title: "Add from Git…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: SettingsPane.tableWidth)
    private var placeholder: NSTextField?
    private var isInstalling = false {
        didSet { updateControls() }
    }
    private var store: AgentSkillStore { profile.skills }
    private let profile: ProfileContext

    init(profile: ProfileContext) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = Self.paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [
            ("on", "On", 30.0), ("name", "Skill", 150.0), ("description", "Description", 280.0), ("source", "Source", 90.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.allowsMultipleSelection = true
        table.style = .inset
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(reveal(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Skills")
        self.placeholder = placeholder

        for (button, action) in [
            (addFolderButton, #selector(addFolder(_:))),
            (addArchiveButton, #selector(addArchive(_:))),
            (addGitButton, #selector(addGit(_:))),
            (revealButton, #selector(reveal(_:))),
            (removeButton, #selector(remove(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addFolderButton, addArchiveButton, addGitButton, NSView(), revealButton, removeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [tableBox, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsPane.tableWidth),
            scroll.heightAnchor.constraint(equalToConstant: SettingsPane.tableHeight),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .agentSkillsDidChange, object: profile.skills)
        reload(nil)
        showDefaultNote()
    }

    @objc private func reload(_ notification: Notification?) {
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected.filteredIndexSet { $0 < store.entries.count }, byExtendingSelection: false)
        updateControls()
    }

    private func updateControls() {
        for button in [addFolderButton, addArchiveButton, addGitButton] { button.isEnabled = !isInstalling }
        revealButton.isEnabled = table.selectedRowIndexes.count == 1
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty && !isInstalling
        placeholder?.isHidden = !store.entries.isEmpty
    }

    private func showDefaultNote() {
        SettingsPane.show(
            "Every agent can call these with /name, besides its own skills. Changes apply when a chat's agent next "
                + "starts. Agents can also create and improve skills here when you ask them to.",
            in: note
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.entries.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard store.entries.indices.contains(row) else { return nil }
        let entry = store.entries[row]
        let skill = store.skill(for: entry)
        switch column?.identifier.rawValue {
        case "on":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            checkbox.tag = row
            checkbox.state = entry.enabled ? .on : .off
            // The box has no title of its own, so VoiceOver gets the skill's name.
            checkbox.setAccessibilityLabel("\(entry.name) On")
            return checkbox
        case "name":
            let cell = SettingsPane.textCell(tableView, entry.name)
            cell.textField?.toolTip = store.folder(for: entry.name)
            return cell
        case "description":
            let cell = SettingsPane.textCell(tableView, skill?.description ?? "SKILL.md is missing")
            cell.textField?.textColor = skill == nil ? .systemRed : .secondaryLabelColor
            cell.textField?.toolTip = skill?.description
            return cell
        default:
            let cell = SettingsPane.textCell(tableView, entry.source.displayName)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.toolTip = entry.origin.isEmpty ? nil : entry.origin
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        store.setEnabled(sender.state == .on, at: sender.tag)
    }

    @objc private func addFolder(_ sender: Any?) {
        choose(
            files: false, types: [],
            message: "Choose a skill's folder, the one with SKILL.md in it, or a folder of skills"
        ) { [weak self] path in
            guard let self else { return }
            self.installing { try await self.store.addFolder(path) }
        }
    }

    @objc private func addArchive(_ sender: Any?) {
        choose(
            files: true, types: [.zip, UTType(filenameExtension: "skill") ?? .data],
            message: "Choose a .zip or .skill archive with one or more skills"
        ) { [weak self] path in
            guard let self else { return }
            self.installing { try await self.store.addArchive(path) }
        }
    }

    @objc private func addGit(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Skills from Git"
        alert.informativeText = "A repository URL, owner/repo on GitHub, or a link to a folder on GitHub. "
            + "Tiller adds the skill at its root, or every skill in the folders inside."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://github.com/owner/repo"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !input.isEmpty else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                SettingsPane.show("Cloning \(input)…", in: self.note)
                self.installing { try await self.store.addGit(input) }
            }
        }
    }

    private func choose(files: Bool, types: [UTType], message: String, then add: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.message = message
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { add(url.path) }
        }
    }

    private func installing(_ work: @escaping () async throws -> [String]) {
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                let names = try await work()
                let list = names.count > 3 ? "\(names.count) skills" : names.joined(separator: ", ")
                SettingsPane.show("Added \(list). Agents load \(names.count == 1 ? "it" : "them") when a chat next starts.", in: note)
            } catch {
                SettingsPane.show(error.localizedDescription, in: note, warning: true)
            }
        }
    }

    /// Edit > Delete and the Delete key remove the selected skills, after asking.
    @objc func delete(_ sender: Any?) {
        guard removeButton.isEnabled else { return NSSound.beep() }
        remove(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(delete(_:)) ? removeButton.isEnabled : true
    }

    @objc private func reveal(_ sender: Any?) {
        guard table.selectedRowIndexes.count == 1, store.entries.indices.contains(table.selectedRow) else { return }
        let folder = store.folder(for: store.entries[table.selectedRow].name)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder + "/SKILL.md")])
    }

    /// Asks first: the skill's files leave the library.
    @objc private func remove(_ sender: Any?) {
        let indexes = table.selectedRowIndexes
        let names = indexes.compactMap { store.entries.indices.contains($0) ? store.entries[$0].name : nil }
        guard !names.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Remove “\(names[0])”?" : "Remove \(names.count) skills?"
        alert.informativeText = "The skill is deleted from Tiller's library. Agents stop seeing it when they next start."
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.remove(at: indexes)
                self.table.deselectAll(nil)
                self.showDefaultNote()
            }
        }
    }
}

// MARK: Profiles

/// Every profile, with buttons to open, add, rename and delete them. Each open
/// profile is a separate Tiller.
final class ProfilesSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    static let paneTitle = "Profiles"

    private let table = SettingsTableView()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let addButton = NSButton(title: "New Profile…", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: SettingsPane.tableWidth)
    private var profiles: [Profile] = []
    /// The profile whose Settings these are.
    private let current: ProfileContext

    init(profile: ProfileContext) {
        current = profile
        super.init(nibName: nil, bundle: nil)
        title = Self.paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("name", "Name", 380.0), ("status", "Status", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openProfile(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [
            (openButton, #selector(openProfile(_:))),
            (addButton, #selector(addProfile(_:))),
            (renameButton, #selector(renameProfile(_:))),
            (deleteButton, #selector(deleteProfile(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [openButton, addButton, renameButton, NSView(), deleteButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [scroll, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsPane.tableWidth),
            scroll.heightAnchor.constraint(equalToConstant: SettingsPane.tableHeight),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .profilesDidChange, object: nil)
        reload(nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload(nil)
    }

    @objc private func reload(_ notification: Notification?) {
        let selectedID = selectedProfile?.id
        profiles = Profiles.all
        table.reloadData()
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateControls()
    }

    private var selectedProfile: Profile? {
        profiles.indices.contains(table.selectedRow) ? profiles[table.selectedRow] : nil
    }

    private func updateControls() {
        let selected = selectedProfile
        openButton.isEnabled = selected != nil
        renameButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected.map { ProfileContext.opened($0.id) == nil } ?? false
        SettingsPane.show(
            "Each profile keeps its own cookies, history, tabs, passwords, settings and chats, "
                + "and opens in a window of its own. An open profile can't be deleted.",
            in: note
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let profile = profiles[row]
        let text: String
        if column?.identifier.rawValue == "name" {
            text = profile.name
        } else if profile.id == current.id {
            text = "These settings"
        } else {
            text = ProfileContext.opened(profile.id) != nil ? "Open" : ""
        }
        let cell = SettingsPane.textCell(tableView, text)
        if column?.identifier.rawValue == "status" { cell.textField?.textColor = .secondaryLabelColor }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func openProfile(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        ProfileContext.open(profile.id)
    }

    @objc private func addProfile(_ sender: Any?) {
        ProfileNamePrompt.run("New Profile", button: "Create", on: view.window) { name in
            ProfileContext.open(try Profiles.create(named: name).id)
        }
    }

    @objc private func renameProfile(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        ProfileNamePrompt.run("Rename \(profile.name)", button: "Rename", initial: profile.name, on: view.window) { name in
            try Profiles.rename(profile.id, to: name)
        }
    }

    /// Edit > Delete and the Delete key delete the selected profile, after asking.
    @objc func delete(_ sender: Any?) {
        guard deleteButton.isEnabled else { return NSSound.beep() }
        deleteProfile(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(delete(_:)) ? deleteButton.isEnabled : true
    }

    @objc private func deleteProfile(_ sender: Any?) {
        guard let window = view.window, let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = "Its cookies, history, tabs, passwords, settings and chats go too. "
            + "Its folder moves to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                do {
                    try Profiles.delete(profile.id)
                } catch {
                    guard let self else { return }
                    SettingsPane.show(error.localizedDescription, in: self.note, warning: true)
                }
            }
        }
    }
}
