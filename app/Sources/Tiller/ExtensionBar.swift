import AppKit

/// The toolbar's extension buttons: one for each pinned extension, then one
/// with a menu of every extension Chromium loaded at launch. Hidden while
/// none is running.
@MainActor
final class ExtensionBarView: NSStackView {
    /// Shows the extension's popup under `anchor`.
    var onPopup: ((ExtensionManifest, NSView) -> Void)?
    /// Opens a URL, such as an options page, in a new tab.
    var onOpen: ((String) -> Void)?
    /// The buttons changed, so the toolbar should make room.
    var onResize: (() -> Void)?

    private let menuButton = NSButton()

    var isEmpty: Bool { ExtensionStore.shared.running.isEmpty }

    init() {
        super.init(frame: .zero)
        spacing = 0
        menuButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
        menuButton.toolTip = "Extensions"
        menuButton.bezelStyle = .toolbar
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .extensionsDidChange, object: nil)
        reload(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pinning shows at once. What's loaded only changes at the next launch.
    @objc private func reload(_ notification: Notification?) {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let pinned = Set(ExtensionStore.shared.entries.filter(\.pinned).map(\.path))
        for manifest in ExtensionStore.shared.running where pinned.contains(manifest.folder) {
            let button = ExtensionButton(manifest: manifest)
            button.target = self
            button.action = #selector(pinnedClicked(_:))
            button.menu = contextMenu(for: manifest)
            addArrangedSubview(button)
        }
        addArrangedSubview(menuButton)
        onResize?()
    }

    @objc private func pinnedClicked(_ sender: ExtensionButton) {
        open(sender.manifest, from: sender)
    }

    /// The popup if it has one, else its options page.
    private func open(_ manifest: ExtensionManifest, from anchor: NSView) {
        if manifest.popupURL != nil {
            onPopup?(manifest, anchor)
        } else if let url = manifest.optionsURL {
            onOpen?(url)
        } else if let button = anchor as? NSButton, let menu = button.menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
        }
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        // Items keep the enabled state set here: one with neither a popup nor
        // an options page has nothing to open.
        menu.autoenablesItems = false
        for manifest in ExtensionStore.shared.running {
            let item = MenuActionItem(title: manifest.name) { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.open(manifest, from: sender)
            }
            item.image = manifest.image(size: 16)
            item.isEnabled = manifest.popupURL != nil || manifest.optionsURL != nil
            if let url = manifest.optionsURL, manifest.popupURL != nil {
                // Holding Option shows Options instead.
                menu.addItem(item)
                let options = MenuActionItem(title: "\(manifest.name) Options") { [weak self] in self?.onOpen?(url) }
                options.image = item.image
                options.keyEquivalentModifierMask = .option
                options.isAlternate = true
                menu.addItem(options)
            } else {
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Manage Extensions…", action: #selector(AppDelegate.manageExtensions(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    private func contextMenu(for manifest: ExtensionManifest) -> NSMenu {
        let menu = NSMenu()
        if let url = manifest.optionsURL {
            menu.addItem(MenuActionItem(title: "Options") { [weak self] in self?.onOpen?(url) })
        }
        menu.addItem(MenuActionItem(title: "Unpin") {
            let store = ExtensionStore.shared
            if let index = store.entries.firstIndex(where: { $0.path == manifest.folder }) {
                store.setPinned(false, at: index)
            }
        })
        menu.addItem(.separator())
        menu.addItem(withTitle: "Manage Extensions…", action: #selector(AppDelegate.manageExtensions(_:)), keyEquivalent: "")
        return menu
    }
}

/// A pinned extension's toolbar button.
private final class ExtensionButton: NSButton {
    let manifest: ExtensionManifest

    init(manifest: ExtensionManifest) {
        self.manifest = manifest
        super.init(frame: .zero)
        image = manifest.image(size: 16)
        toolTip = manifest.actionTitle ?? manifest.name
        bezelStyle = .toolbar
        setAccessibilityLabel(manifest.name)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// An extension's popup page in a popover, sized to the page the way Chrome
/// sizes popups, from 25×25 up to 800×600 points.
@MainActor
final class ExtensionPopover: NSObject, NSPopoverDelegate, TabDelegate {
    private static let minSize = NSSize(width: 25, height: 25)
    private static let maxSize = NSSize(width: 800, height: 600)
    private static let collapsedWidthThreshold: CGFloat = 100
    private static let fallbackSize = NSSize(width: 400, height: 600)
    private static let collapseCheckDelay: TimeInterval = 0.3
    private static let fixedSizeDefaultsKey = "extensionPopupsWithFixedSize"

    /// The popup opened a link in a new tab.
    var onOpenTab: ((String, Bool) -> Void)?
    /// The popup is gone, browser and all.
    var onClose: (() -> Void)?
    /// A Command or Control key press before the popup's page sees it. True
    /// if a menu took it.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    let manifest: ExtensionManifest
    private let popover = NSPopover()
    private let tab: Tab
    private var closing = false
    private var latestSize: NSSize = .zero
    private var fallbackEnabled = false
    private var collapseCheck: DispatchWorkItem?
    private var revealTimeout: DispatchWorkItem?
    private var revealed = false
    /// The profile's settings, which remember popups that need the fixed size.
    private let defaults: UserDefaults

    /// The popup runs in `profile`'s request context, like its tabs.
    init(manifest: ExtensionManifest, profile: ProfileContext) {
        self.manifest = manifest
        tab = Tab(profile: profile)
        defaults = profile.settings.defaults
        super.init()
    }

    func show(relativeTo anchor: NSView) {
        guard let url = manifest.popupURL else { return }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        fallbackEnabled = (defaults.stringArray(forKey: Self.fixedSizeDefaultsKey) ?? []).contains(manifest.id)
        popover.contentSize = fallbackEnabled ? Self.fallbackSize : container.frame.size
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if !fallbackEnabled {
            popover.contentViewController?.view.window?.alphaValue = 0
            let timeout = DispatchWorkItem { [weak self] in
                self?.reveal()
            }
            revealTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
        }
        // The browser needs its view in a window, so it starts once shown.
        tab.hostView.frame = container.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        container.addSubview(tab.hostView)
        tab.delegate = self
        tab.start(url: url)
        if fallbackEnabled {
            reveal()
        } else {
            tab.autoResize(min: Self.minSize, max: Self.maxSize)
        }
    }

    /// Shows a popup that was hidden until its size settled, so a first narrow
    /// layout doesn't flash on screen.
    private func reveal() {
        guard !closing, !revealed else { return }
        revealed = true
        revealTimeout?.cancel()
        revealTimeout = nil
        popover.contentViewController?.view.window?.alphaValue = 1
        tab.focus()
    }

    func close() {
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        collapseCheck?.cancel()
        collapseCheck = nil
        revealTimeout?.cancel()
        revealTimeout = nil
        guard !closing else { return }
        closing = true
        tab.close()
    }

    // MARK: TabDelegate

    func tab(_ tab: Tab, autoResizedTo size: NSSize) {
        guard !fallbackEnabled else { return }
        popover.contentSize = NSSize(width: max(size.width, Self.minSize.width), height: max(size.height, Self.minSize.height))
        latestSize = size
        guard !closing else { return }
        guard size.width < Self.collapsedWidthThreshold, size.height >= Self.maxSize.height else {
            collapseCheck?.cancel()
            collapseCheck = nil
            reveal()
            return
        }
        guard collapseCheck == nil else { return }

        // Some popups, like Bitwarden, set a width only when they detect a Chrome
        // popup. Here chrome.tabs.getCurrent() returns a tab, so they lay out at
        // their narrowest width, pushing their height to the limit. If they stay
        // narrow and at the maximum height, stop sizing to the page and give
        // them a fixed size.
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.closing, !self.fallbackEnabled,
                  self.latestSize.width < Self.collapsedWidthThreshold,
                  self.latestSize.height >= Self.maxSize.height else { return }
            self.collapseCheck = nil
            self.fallbackEnabled = true
            self.tab.disableAutoResize()
            self.popover.contentSize = Self.fallbackSize
            var fixedSizeIDs = defaults.stringArray(forKey: Self.fixedSizeDefaultsKey) ?? []
            if !fixedSizeIDs.contains(self.manifest.id) {
                fixedSizeIDs.append(self.manifest.id)
                defaults.set(fixedSizeIDs, forKey: Self.fixedSizeDefaultsKey)
            }
            self.reveal()
        }
        collapseCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseCheckDelay, execute: check)
    }

    func tab(_ tab: Tab, openInNewTab url: String, background: Bool) {
        onOpenTab?(url, background)
    }

    /// The popover closed, or the page called window.close().
    func tabReadyToClose(_ tab: Tab) {
        collapseCheck?.cancel()
        collapseCheck = nil
        revealTimeout?.cancel()
        revealTimeout = nil
        closing = true
        tab.detach()
        tab.hostView.removeFromSuperview()
        popover.close()
        onClose?()
    }

    func tabDidChange(_ tab: Tab) {}
    func tabProgressChanged(_ tab: Tab) {}
    func tab(_ tab: Tab, foundMatches count: Int, active: Int, final: Bool) {}
    /// Cmd+W closes the popup. Other shortcuts go to the menus first, as they
    /// do from a tab.
    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return onKeyEquivalent?(event) ?? false
    }
}
