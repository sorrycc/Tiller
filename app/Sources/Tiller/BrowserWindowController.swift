import AppKit

/// One profile's window holding its tabs. With tabs along the top, the toolbar has
/// back, forward, reload, the tabs, a new-tab button, extension buttons, the
/// profile's name when there are several, and the agent panel toggle, and the
/// address bar sits in a row under it. With tabs in a sidebar, the address
/// bar takes the tabs' place in the toolbar, and the page is a card between
/// the sidebar on the left and the agent panel on the right.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSSplitViewDelegate, TabDelegate, TabStripDelegate, AgentPanelDelegate
{
    var onClose: (() -> Void)?
    let profile: ProfileContext

    private let splitView = ChromeSplitView()
    private var tabLayout: TabLayout
    /// Holds the tabs while they are vertical. Hidden otherwise.
    private let sidebar = TabSidebarView()
    /// The sidebar's width while it isn't collapsed.
    private var sidebarWidth = TabSidebarView.defaultWidth
    private lazy var sidebarMinWidth = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
    private lazy var sidebarMaxWidth = sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
    /// Holds every tab's view. The selected one is on top, and the others are
    /// hidden unless an agent woke them.
    private let contentView = PageCardView()
    private let agentPanel: AgentPanelView
    /// Where the panel is going. It stays unhidden while it slides out.
    private var agentPanelShown: Bool
    /// Counts toggles, so a slide's completion knows a later toggle took over.
    private var agentToggleCount = 0
    private let agentButton = NSButton()
    /// A dot on the agent button while a chat works behind a hidden panel.
    private let agentBadge = AgentBadgeView()
    private let tabStrip = TabStripView()
    private let addressBar = AddressBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private var reloadItem: NSToolbarItem?
    /// Whether the reload button shows Stop, or nil before the first tab.
    private var showsStop: Bool?
    private let newTabButton = NSButton()
    /// Names the profile and opens the Profiles menu. Hidden with one profile.
    private let profileButton = NSButton()
    /// Extension buttons. Hidden when no extension is loaded.
    private let extensionBar = ExtensionBarView()
    /// Hidden until the first download of the run.
    private let downloadsButton = DownloadsButton()
    private var downloadsPopover: NSPopover?
    /// The extension popup while one is open.
    private var extensionPopover: ExtensionPopover?
    /// Nil while there is only one profile.
    private var profileName: String?
    private lazy var suggestions = AddressSuggestions(addressBar: addressBar, profile: profile)
    private lazy var findBar: FindBar = {
        let bar = FindBar()
        bar.onChange = { [weak self] text in self?.find(text) }
        bar.onStep = { [weak self] forward in self?.findAgain(forward: forward) }
        bar.onClose = { [weak self] in self?.hideFindBar(focusPage: true) }
        return bar
    }()
    /// Whether the find bar is up. It stays in the view while it fades out.
    private var findBarShown = false
    /// Asks about the selected tab's first camera or microphone request.
    private lazy var mediaBar: MediaPermissionBar = {
        let bar = MediaPermissionBar()
        bar.onAnswer = { [weak self] answer in self?.answerMediaBar(answer) }
        bar.onOpenSettings = { [weak self] in self?.openMediaSettings() }
        return bar
    }()
    /// Whether the media bar is up. It stays in the view while it fades out.
    private var mediaBarShown = false
    /// Shown over the selected tab while it is blank.
    private lazy var startPage: StartPageView = {
        let view = StartPageView(profile: profile)
        view.onOpen = { [weak self] url, disposition in self?.open(url, disposition) }
        return view
    }()
    /// Whether the start page is fading out, to be taken away when it ends.
    private var startPageFading = false
    /// The import sheet while it is up.
    private var chromeImport: ChromeImportController?
    /// The link under the mouse, at the bottom left of the page.
    private let statusBubble = StatusBubbleView()
    /// run_task at work on the selected tab: its step, a Stop button and a
    /// ring on what it acts on.
    private lazy var jevOverlay = JevOverlay(
        container: contentView,
        selectedTab: { [weak self] in self?.selectedTab?.id },
        hostView: { [weak self] id in self?.tabs.first { $0.id == id }?.hostView }
    )
    /// The tab whose page has the whole screen, while one does.
    private var fullscreenTab: Tab?
    /// Whether the window was in full screen already when the page took the
    /// screen, in which case leaving is the user's to do.
    private var windowWasFullScreen = false
    /// Set while AppKit animates into or out of full screen, when another
    /// toggle would be ignored.
    private var inFullScreenTransition = false
    /// A page gave the screen back while the window was still on its way
    /// into full screen, so the window leaves once it has arrived.
    private var leaveFullScreenWhenSettled = false
    /// Whether the window's full screen is one a page asked for, as opposed
    /// to one the user chose, which a page's exit must leave alone.
    private var windowFullScreenForPage = false

    /// The tab strip's width, kept to what the toolbar has room for. A larger
    /// preference makes the toolbar move the whole strip into its overflow menu.
    private lazy var tabStripWidth = tabStrip.widthAnchor.constraint(equalToConstant: 600)
    private lazy var tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 28)
    /// The address bar's size in the toolbar, fitted like the tab strip's.
    private lazy var addressWidth = addressBar.widthAnchor.constraint(equalToConstant: 600)
    private lazy var addressHeight = addressBar.heightAnchor.constraint(equalToConstant: Theme.Capsule.height)
    /// Holds the address bar while the tabs are along the top.
    private var addressAccessory: NSTitlebarAccessoryViewController?

    private var tabs: [Tab] = []
    private var selectedTab: Tab?
    /// Set while every tab closes for a quit or the window closing, so the
    /// session saved just before keeps them all. A page that cancels its
    /// beforeunload leaves tabs open, and the next thing done with the tabs
    /// clears it.
    private var closingAll = false
    /// Tabs an agent woke, each with the timer that hides it again.
    private var wakeTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// How long a tab stays awake after an agent's last click, type or screenshot.
    private static let wakeDuration: TimeInterval = 30
    /// Unloads tabs left unused past the profile's delay.
    private var unloadTimer: Timer?
    /// Unloads tabs when the Mac runs short of memory.
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// How often the timer looks for tabs to unload.
    private static let unloadCheckInterval: TimeInterval = 60

    /// Opens the `restored` tabs, then `url` in a selected tab after them. With
    /// no `url`, selects the restored tab at `selected`. One of the two must
    /// give at least one tab.
    init(profile: ProfileContext, restoring restored: [SessionStore.SavedTab], selected: Int, opening url: String?) {
        self.profile = profile
        tabLayout = profile.settings.tabLayout
        agentPanel = AgentPanelView(profile: profile, frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        agentPanelShown = profile.settings.defaults.bool(forKey: Self.agentVisibleKey)
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiller"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName(Self.autosaveName("TillerBrowserWindow", profile: profile))
        super.init(window: window)

        window.onGoBack = { [weak self] in self?.goBack(nil) }
        window.onGoForward = { [weak self] in self?.goForward(nil) }
        window.delegate = self
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentView)
        splitView.addArrangedSubview(agentPanel)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        // Above the page, so the sidebar and the panel keep their widths when
        // the window resizes, and under the priority of a divider drag (490),
        // which must win.
        splitView.setHoldingPriority(.init(270), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 2)
        splitView.delegate = self
        sidebarMinWidth.isActive = true
        sidebarMaxWidth.isActive = true
        sidebar.isHidden = tabLayout != .vertical
        sidebar.isCollapsed = profile.settings.sidebarCollapsed
        let savedWidth = profile.settings.defaults.double(forKey: Self.sidebarWidthKey)
        if savedWidth > 0 { sidebarWidth = savedWidth }
        agentPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        agentPanel.delegate = self
        agentPanel.isHidden = !agentPanelShown
        agentPanel.wantsLayer = true
        // Not the name used while there were two panes, whose saved widths
        // don't fit three.
        // Read before the name is set, since setting it saves the frames.
        let splitName = Self.autosaveName("TillerSplit", profile: profile)
        let hasSavedSplit = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames " + splitName) != nil
        splitView.autosaveName = splitName
        window.contentView = splitView
        window.toolbarStyle = .unified
        applyTheme()

        if !window.setFrameUsingName(Self.autosaveName("TillerBrowserWindow", profile: profile)) {
            // A profile's first window steps down from another one's.
            if let other = ProfileContext.all.compactMap({ $0.window?.window }).first(where: { $0 !== window && $0.isVisible }) {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
            } else {
                window.center()
            }
        }
        // With no widths saved yet, the split view would give the panel every
        // point the page can spare, since the panel holds its width harder.
        // The panel starts at its own width instead.
        if agentPanelShown, !hasSavedSplit {
            // Once the window has laid out, so the split view has its width.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let position = max(
                        self.splitView.bounds.width - Self.defaultAgentPanelWidth,
                        self.splitView.minPossiblePositionOfDivider(at: 1)
                    )
                    self.splitView.setPosition(position, ofDividerAt: 1)
                }
            }
        }

        configureControls()
        statusBubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusBubble, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            statusBubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.6),
        ])
        tabStrip.delegate = self
        applyTabLayout()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(passwordsChanged(_:)), name: .passwordsDidChange, object: profile.passwords)
        center.addObserver(self, selector: #selector(tabLayoutChanged(_:)), name: .tabLayoutDidChange, object: nil)
        center.addObserver(self, selector: #selector(themeChanged(_:)), name: .themeDidChange, object: nil)
        center.addObserver(self, selector: #selector(downloadsChanged(_:)), name: .downloadsDidChange, object: nil)
        center.addObserver(self, selector: #selector(downloadStarted(_:)), name: .downloadDidStart, object: nil)
        watchForUnloading()
        // Restored tabs load when first selected.
        for saved in restored {
            openTab(url: saved.isBlank ? "about:blank" : saved.url, select: false, restoring: saved, lazily: true)
        }
        if let url {
            openTab(url: url, select: true)
        } else {
            select(tabs[min(max(selected, 0), tabs.count - 1)])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The default profile keeps the names from before profiles shared a
    /// process; the others get their own, so their windows keep their places.
    private static func autosaveName(_ name: String, profile: ProfileContext) -> String {
        profile.id == Profiles.defaultID ? name : name + "." + profile.id
    }

    /// Whether `other` belongs to this window: a sheet, popover or child.
    func ownsChild(_ other: NSWindow) -> Bool {
        var parent = other.parent ?? other.sheetParent
        while let current = parent {
            if current === window { return true }
            parent = current.parent ?? current.sheetParent
        }
        return false
    }

    // MARK: Tabs

    /// Opens `url` in a new tab at `index`, or at the end. A `restoring` tab
    /// shows its saved title and isn't saved to history again. A tab opened
    /// `lazily` loads when it is first selected, and the caller updates the
    /// tab strip.
    @discardableResult
    private func openTab(
        url: String, select: Bool, at index: Int? = nil, restoring saved: SessionStore.SavedTab? = nil,
        lazily: Bool = false, adopting: Bool = false
    ) -> Tab {
        closingAll = false
        let tab = Tab(profile: profile)
        tab.delegate = self
        if let saved { tab.recordedVisit = (saved.url, saved.title) }
        let panelHadFocus = agentPanel.hasKeyboardFocus
        tabs.insert(tab, at: min(index ?? tabs.endIndex, tabs.endIndex))

        window?.layoutIfNeeded()
        tab.hostView.frame = contentView.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        tab.hostView.isHidden = true
        // Under the find bar, which shares this view.
        contentView.addSubview(tab.hostView, positioned: .below, relativeTo: nil)
        if lazily {
            tab.prepare(url: url, title: saved?.title ?? "")
            return tab
        }
        if adopting { tab.adoptPopup(url: url) } else { tab.start(url: url, title: saved?.title ?? "") }

        if select {
            self.select(tab)
        } else {
            tabStrip.update(tabs: tabs, selected: selectedTab)
            saveSession()
        }
        // An agent opening a tab shouldn't take the keyboard from its panel.
        if panelHadFocus { window?.makeFirstResponder(agentPanel.input) }
        return tab
    }

    /// `resumeSaving` is false only when a closing tab hands the selection on.
    private func select(_ tab: Tab, resumeSaving: Bool = true) {
        if resumeSaving { closingAll = false }
        if tab !== selectedTab {
            hideFindBar(focusPage: false)
            statusBubble.show("")
            if let fullscreenTab, fullscreenTab !== tab { fullscreenTab.exitFullscreen() }
        }
        if let old = selectedTab {
            old.lastActive = Date()
            if !isAwake(old) { old.hostView.isHidden = true }
        }
        // Over the tabs an agent keeps awake, and under the status bubble.
        // The find bar closed above.
        if tab !== selectedTab {
            contentView.addSubview(tab.hostView, positioned: .above, relativeTo: nil)
            contentView.addSubview(statusBubble, positioned: .above, relativeTo: nil)
            jevOverlay.bringToFront()
        }
        let changed = tab !== selectedTab
        selectedTab = tab
        if changed {
            jevOverlay.selectionChanged()
            updateMediaBar()
        }
        tab.lastActive = Date()
        tab.hostView.isHidden = false
        start(tab)
        tabStrip.update(tabs: tabs, selected: tab)
        showState(of: tab)
        addressBar.setProgress(tab.progress, loading: tab.isLoading, animated: false)
        saveSession()
        if tab.isBlank {
            openLocation(nil)
        } else {
            tab.focus()
        }
    }

    /// Starts a restored tab's browser, if it is still waiting.
    private func start(_ tab: Tab) {
        guard !tab.isStarted else { return }
        tab.hostView.frame = contentView.bounds
        tab.startIfNeeded()
    }

    /// Keeps a tab drawing behind the selected one for `wakeDuration`, so an
    /// agent can click, type and take screenshots in it. Chromium treats a
    /// hidden view's page as hidden: it stops drawing, and input to it stalls
    /// for seconds or is dropped. A covered view counts as visible.
    private func wake(_ tab: Tab) -> Bool {
        start(tab)
        let woke = tab.hostView.isHidden
        if woke {
            // Under the selected tab. Views are moved only while hidden: sorting
            // them all made Chromium count every hidden page as visible again.
            contentView.addSubview(tab.hostView, positioned: .below, relativeTo: nil)
            tab.hostView.isHidden = false
        }
        let key = ObjectIdentifier(tab)
        wakeTimers[key]?.cancel()
        let sleep = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.wakeTimers[ObjectIdentifier(tab)] = nil
                tab.lastActive = Date()
                if tab !== self.selectedTab { tab.hostView.isHidden = true }
            }
        }
        wakeTimers[key] = sleep
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeDuration, execute: sleep)
        return woke
    }

    private func isAwake(_ tab: Tab) -> Bool {
        wakeTimers[ObjectIdentifier(tab)] != nil
    }

    // MARK: Unloading

    /// Checks for tabs to unload every minute, and whenever the Mac reports
    /// memory pressure.
    private func watchForUnloading() {
        unloadTimer = Timer.scheduledTimer(withTimeInterval: Self.unloadCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.unload(self.unloadCandidates(unusedFor: self.profile.settings.tabUnloadDelay.interval))
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let event = source?.data else { return }
                self.memoryPressureChanged(critical: event.contains(.critical))
            }
        }
        source.resume()
        memoryPressure = source
    }

    /// Short of memory: the half of the background tabs unused longest
    /// unload, or all of them when it is critical. A tab just left gets a
    /// minute's grace before a warning takes it.
    private func memoryPressureChanged(critical: Bool) {
        let candidates = unloadCandidates(unusedFor: critical ? 0 : 60)
        unload(critical ? candidates : Array(candidates.prefix((candidates.count + 1) / 2)))
    }

    /// Loaded tabs that may unload, unused longest first: not the one in
    /// front, one an agent keeps awake or waits on, or one with the screen.
    private func unloadCandidates(unusedFor minimum: TimeInterval) -> [Tab] {
        guard profile.settings.unloadsInactiveTabs, !closingAll else { return [] }
        let now = Date()
        let waitedOn = Set(Self.loadWaiters.map { ObjectIdentifier($0.tab) })
        return tabs
            .filter { tab in
                tab.isStarted && tab !== selectedTab && tab !== fullscreenTab && !isAwake(tab)
                    && !waitedOn.contains(ObjectIdentifier(tab)) && now.timeIntervalSince(tab.lastActive) >= minimum
            }
            .sorted { $0.lastActive < $1.lastActive }
    }

    /// The core may keep a tab whose page is in use. Such a tab is tried again
    /// only once the delay has passed once more.
    private func unload(_ tabs: [Tab]) {
        for tab in tabs {
            tab.lastActive = Date()
            tab.unload()
        }
    }

    /// Asks a tab to close on the user's or an agent's behalf.
    private func requestClose(_ tab: Tab) {
        closingAll = false
        tab.close()
    }

    /// Takes the tab out of the window once CEF has agreed to close it.
    private func remove(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab === fullscreenTab { self.tab(tab, fullscreenChanged: false) }
        wakeTimers.removeValue(forKey: ObjectIdentifier(tab))?.cancel()
        failLoadWaits(for: tab)
        jevOverlay.tabClosed(tab.id)
        tab.detach()
        // Tearing down the view is what lets CEF finish closing the browser.
        tab.hostView.removeFromSuperview()
        tabs.remove(at: index)

        // The window closes and Tiller quits with it. The session saved before
        // still has this tab, so the next launch reopens it.
        guard !tabs.isEmpty else {
            selectedTab = nil
            tabStrip.update(tabs: [], selected: nil)
            window?.close()
            return
        }
        if !closingAll && !tab.isBlank {
            profile.session.pushClosedTab(.init(url: tab.url, title: tab.title), at: index)
        }
        if tab === selectedTab {
            selectedTab = nil
            let next = tabs[min(index, tabs.count - 1)]
            // While every tab closes, a tab that never loaded is left alone:
            // selecting it would start its browser, which keeps Tiller running
            // after the others are gone.
            if closingAll && !next.isStarted {
                tabStrip.update(tabs: tabs, selected: nil)
                updateMediaBar()
            } else {
                select(next, resumeSaving: false)
            }
        } else {
            tabStrip.update(tabs: tabs, selected: selectedTab)
            saveSession()
        }
    }

    /// Records the tabs for the next launch. Does nothing while they all close.
    private func saveSession() {
        guard !closingAll else { return }
        let selected = selectedTab.flatMap { selected in tabs.firstIndex { $0 === selected } } ?? 0
        profile.session.setOpenTabs(tabs.map { .init(url: $0.url, title: $0.title) }, selected: selected)
    }

    /// Saves the session as it stands and stops saving while every tab closes,
    /// so the next launch gets them all back.
    func freezeSession() {
        saveSession()
        closingAll = true
        profile.session.flush()
    }

    private func showState(of tab: Tab) {
        addressBar.show(tab.url)
        showLoading(tab.isLoading)
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        updateWindowTitle()
        addressBar.keyButton.isHidden = savedLogins(for: tab).isEmpty
        addressBar.showZoom(tab.zoomFactor)
        updateStartPage(for: tab)
    }

    /// Puts the start page over `tab` while it is blank, and takes it away once
    /// the page it goes to has arrived.
    private func updateStartPage(for tab: Tab) {
        if tab.isBlank || tab.isLeavingBlank {
            let fading = startPageFading
            startPageFading = false
            if startPage.superview === tab.hostView {
                // Blank again while it faded out: it comes back.
                guard fading else { return }
                withEasing(Theme.Duration.quick) { startPage.animator().alphaValue = 1 }
            } else {
                // Moved from a tab it was fading out over: its fade stops.
                startPage.layer?.removeAllAnimations()
                startPage.alphaValue = 1
                startPage.frame = tab.hostView.bounds
                startPage.autoresizingMask = [.width, .height]
                tab.hostView.addSubview(startPage, positioned: .above, relativeTo: nil)
            }
            startPage.reload()
        } else if startPage.superview === tab.hostView, !startPageFading {
            startPageFading = true
            // The page fades in from under it rather than cutting in.
            fadeOut(startPage) { [weak self] in
                guard let self, self.startPageFading else { return }
                self.startPageFading = false
                self.startPage.removeFromSuperview()
                self.startPage.alphaValue = 1
            }
        }
    }

    /// Saves the page to history once it has loaded, and again whenever its
    /// URL or title changes after that.
    private func recordHistory(_ tab: Tab) {
        guard tab.url.hasPrefix("http://") || tab.url.hasPrefix("https://") else { return }
        if let icon = tab.faviconPNG, icon != tab.recordedIcon {
            profile.history.setIcon(icon, for: tab.url)
            tab.recordedIcon = icon
        }
        guard !tab.isLoading else { return }
        if tab.recordedVisit?.url != tab.url {
            profile.history.recordVisit(url: tab.url, title: tab.title)
        } else if tab.recordedVisit?.title != tab.title {
            profile.history.setTitle(tab.title, for: tab.url)
        } else {
            return
        }
        tab.recordedVisit = (tab.url, tab.title)
    }

    // MARK: TabDelegate

    func tabDidChange(_ tab: Tab) {
        recordHistory(tab)
        saveSession()
        tabStrip.refresh(tab)
        loadStateChanged(tab)
        if tab === selectedTab {
            showState(of: tab)
            addressBar.setProgress(tab.progress, loading: tab.isLoading)
        }
    }

    func tab(_ tab: Tab, foundMatches count: Int, active: Int, final: Bool) {
        guard tab === selectedTab, findBarShown, !findBar.text.isEmpty else { return }
        findBar.showCount((count, active))
    }

    func tabProgressChanged(_ tab: Tab) {
        if tab === selectedTab { addressBar.setProgress(tab.progress, loading: tab.isLoading) }
    }

    func tab(_ tab: Tab, openInNewTab url: String, background: Bool) {
        openTab(url: url, select: !background, at: tabs.firstIndex { $0 === tab }.map { $0 + 1 })
    }

    func tab(_ tab: Tab, openPopup url: String, background: Bool) -> Tab? {
        openTab(url: url, select: !background, at: tabs.firstIndex { $0 === tab }.map { $0 + 1 }, adopting: true)
    }

    func tab(_ tab: Tab, statusChanged text: String) {
        guard tab === selectedTab else { return }
        statusBubble.show(text)
    }

    /// A page taking the screen takes the window to full screen with the
    /// sidebar and the panel out of the way; giving it back puts them back.
    func tab(_ tab: Tab, fullscreenChanged fullscreen: Bool) {
        guard let window else { return }
        if fullscreen {
            // A page behind the selected one, as one an agent works in,
            // can't have the screen: Chromium would hold it fullscreen all the same.
            guard tab === selectedTab else { return tab.exitFullscreen() }
            guard fullscreenTab == nil else { return }
            fullscreenTab = tab
            windowWasFullScreen = window.styleMask.contains(.fullScreen) && !windowFullScreenForPage
            leaveFullScreenWhenSettled = false
            statusBubble.show("")
            hideChromeForFullscreen()
            roundPage()
            if !windowWasFullScreen { enterFullScreenForPage() }
        } else {
            guard tab === fullscreenTab else { return }
            fullscreenTab = nil
            // Back to what the layout and the panel toggle say, not to a
            // snapshot: either may have changed meanwhile.
            sidebar.isHidden = tabLayout != .vertical
            agentPanel.isHidden = !agentPanelShown
            addressAccessory?.isHidden = false
            window.toolbar?.isVisible = true
            splitView.adjustSubviews()
            if tabLayout == .vertical { fitSidebar() }
            roundPage()
            guard !windowWasFullScreen, window.styleMask.contains(.fullScreen) else { return }
            if inFullScreenTransition {
                // Still arriving. Leave once there; a toggle now would be ignored.
                leaveFullScreenWhenSettled = true
                return
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.fullscreenTab == nil, let window = self.window,
                        window.styleMask.contains(.fullScreen), !self.inFullScreenTransition
                    else { return }
                    window.toggleFullScreen(nil)
                }
            }
        }
    }

    /// Takes the sidebar, the panel, the address bar and the toolbar out of
    /// the way of a page that has the screen.
    private func hideChromeForFullscreen() {
        sidebar.isHidden = true
        agentPanel.isHidden = true
        addressAccessory?.isHidden = true
        window?.toolbar?.isVisible = false
        splitView.adjustSubviews()
    }

    /// Takes the window to full screen for the page, on the next turn: this
    /// is reached from a Chromium callback, where AppKit won't start the
    /// transition. Nothing happens while the window is already there or on
    /// its way; `windowDidExitFullScreen` tries again after a way out.
    private func enterFullScreenForPage() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fullscreenTab != nil, let window = self.window,
                    !window.styleMask.contains(.fullScreen), !self.inFullScreenTransition
                else { return }
                self.windowFullScreenForPage = true
                window.toggleFullScreen(nil)
            }
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        inFullScreenTransition = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        guard leaveFullScreenWhenSettled else { return }
        leaveFullScreenWhenSettled = false
        if fullscreenTab == nil { window?.toggleFullScreen(nil) }
    }

    /// The page keeps the window's content area, with the chrome out of the
    /// way, as other browsers do when the screen itself can't be had.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        inFullScreenTransition = false
        leaveFullScreenWhenSettled = false
        windowFullScreenForPage = false
    }

    /// Leaving full screen by the green button or a gesture takes the page
    /// out of its fullscreen too. The window is on its way out already, so
    /// the page's exit mustn't toggle it again.
    func windowWillExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = true
        leaveFullScreenWhenSettled = false
        guard let fullscreenTab else { return }
        windowWasFullScreen = true
        fullscreenTab.exitFullscreen()
    }

    /// A page that took the screen again while the window was on its way
    /// out gets its full screen now.
    func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        windowFullScreenForPage = false
        if fullscreenTab != nil, !windowWasFullScreen { enterFullScreenForPage() }
    }

    /// While a page has the screen, the toolbar stays away unless the mouse
    /// goes to the top, as it does in other browsers.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        fullscreenTab == nil ? proposedOptions : proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .fullScreen])
    }

    func tabReadyToClose(_ tab: Tab) {
        remove(tab)
    }

    /// A tab brought to the front or woken while it unloaded loads again.
    func tabDidUnload(_ tab: Tab) {
        if tab === fullscreenTab { self.tab(tab, fullscreenChanged: false) }
        if tab === selectedTab || isAwake(tab) { start(tab) }
    }

    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool {
        performMenuKeyEquivalent(event)
    }

    // MARK: Camera and microphone

    /// Answers from the site's saved choice, or waits for the user, who sees
    /// the request on the tab once it is in front.
    func tab(_ tab: Tab, requestsMedia request: MediaRequest) {
        switch profile.settings.sitePermissions.decision(for: request.devices, origin: request.origin) {
        case .block:
            tab.answerMediaRequest(request, allow: false)
        case .allow:
            grantMedia(request, in: tab)
        case .ask:
            tab.mediaRequests.append(request)
            if tab === selectedTab { updateMediaBar() }
        }
    }

    func tabDroppedMediaRequests(_ tab: Tab) {
        if tab === selectedTab { updateMediaBar() }
    }

    /// Grants `request` once macOS lets Tiller use its devices, asking macOS
    /// first if it hasn't been asked. When it refuses, the request is denied
    /// and the tab says how to fix it.
    private func grantMedia(_ request: MediaRequest, in tab: Tab) {
        tab.mediaRequests.removeAll { $0.id == request.id }
        SystemMediaAccess.request(request.devices) { [weak self, weak tab] refused in
            guard let tab else { return }
            tab.answerMediaRequest(request, allow: refused.isEmpty)
            guard !refused.isEmpty else { return }
            tab.mediaRefused = refused
            if tab === self?.selectedTab { self?.updateMediaBar() }
        }
    }

    private func answerMediaBar(_ answer: MediaPermissionBar.Answer) {
        // A click on a bar fading out answers nothing.
        guard mediaBarShown, let tab = selectedTab, let content = mediaBar.content else { return }
        guard case .request(let request) = content else {
            tab.mediaRefused = []
            return updateMediaBar()
        }
        guard tab.mediaRequests.contains(request) else { return updateMediaBar() }
        let permissions = profile.settings.sitePermissions
        switch answer {
        case .block:
            permissions.set(.block, for: request.devices, origin: request.origin)
            tab.answerMediaRequest(request, allow: false)
        case .dismiss:
            tab.answerMediaRequest(request, allow: false)
        case .allowOnce:
            grantMedia(request, in: tab)
        case .allowAlways:
            permissions.set(.allow, for: request.devices, origin: request.origin)
            grantMedia(request, in: tab)
        }
        // A saved choice answers the site's other requests waiting here too.
        if answer == .block || answer == .allowAlways {
            for waiting in tab.mediaRequests where waiting.origin == request.origin {
                switch permissions.decision(for: waiting.devices, origin: waiting.origin) {
                case .block: tab.answerMediaRequest(waiting, allow: false)
                case .allow: grantMedia(waiting, in: tab)
                case .ask: break
                }
            }
        }
        updateMediaBar()
    }

    private func openMediaSettings() {
        guard let tab = selectedTab else { return }
        SystemMediaAccess.openSettings(for: tab.mediaRefused)
        tab.mediaRefused = []
        updateMediaBar()
    }

    /// Shows the selected tab's first request, or what macOS refused it, at
    /// the top left of the page, over everything else there. Hides the bar
    /// when there is neither.
    private func updateMediaBar() {
        let content: MediaPermissionBar.Content? =
            if let request = selectedTab?.mediaRequests.first {
                .request(request)
            } else if let refused = selectedTab?.mediaRefused, !refused.isEmpty {
                .refused(refused)
            } else {
                nil
            }
        guard let content else {
            guard mediaBarShown else { return }
            mediaBarShown = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
                mediaBar.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.mediaBarShown else { return }
                    self.mediaBar.removeFromSuperview()
                }
            }
            return
        }
        mediaBar.show(content)
        // Put back on top, as a tab selected since covers it.
        if contentView.subviews.last !== mediaBar {
            mediaBar.removeFromSuperview()
            mediaBar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(mediaBar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                mediaBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Padding.row),
                mediaBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Padding.panel),
                mediaBar.trailingAnchor.constraint(
                    lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Padding.panel),
            ])
        }
        guard !mediaBarShown else { return }
        mediaBarShown = true
        mediaBar.alphaValue = 0
        withEasing(Theme.Duration.quick) { mediaBar.animator().alphaValue = 1 }
        NSAccessibility.post(element: mediaBar, notification: .announcementRequested, userInfo: [
            .announcement: mediaBar.accessibilityLabel() ?? "",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Menu shortcuts win over the page, except the Edit menu's, so editors in
    /// the page keep their own undo, select all and so on.
    private func performMenuKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let menu = NSApp.mainMenu else { return false }
        for item in menu.items {
            // Of the Edit menu, only Find goes before the page.
            let submenu = item.submenu?.title == MainMenu.editTitle
                ? item.submenu?.item(withTitle: MainMenu.findTitle)?.submenu : item.submenu
            if submenu?.performKeyEquivalent(with: event) == true { return true }
        }
        return false
    }

    // MARK: TabStripDelegate

    func tabStrip(_ strip: TabStripView, select tab: Tab) {
        if tab !== selectedTab { select(tab) }
    }

    func tabStrip(_ strip: TabStripView, close tab: Tab) {
        requestClose(tab)
    }

    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }), tabs.indices.contains(index) else { return }
        closingAll = false
        tabs.insert(tabs.remove(at: from), at: index)
        tabStrip.update(tabs: tabs, selected: selectedTab)
        saveSession()
    }

    func tabStripNewTab(_ strip: TabStripView) {
        newTab(nil)
    }

    /// Right-click on a tab.
    func tabStrip(_ strip: TabStripView, menuFor tab: Tab) -> NSMenu? {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuActionItem(title: "New Tab") { [weak self] in self?.newTab(nil) })
        menu.addItem(.separator())
        let reload = MenuActionItem(title: "Reload") { [weak self] in
            // A tab that isn't loaded loads its page instead.
            if tab.isStarted { tab.reload() } else { self?.start(tab) }
        }
        reload.isEnabled = !tab.isBlank
        menu.addItem(reload)
        let duplicate = MenuActionItem(title: "Duplicate Tab") { [weak self] in self?.duplicate(tab) }
        duplicate.isEnabled = !tab.isBlank
        menu.addItem(duplicate)
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "Close Tab") { [weak self] in self?.requestClose(tab) })
        let others = MenuActionItem(title: "Close Other Tabs") { [weak self] in self?.closeTabs { $0 !== tab } }
        others.isEnabled = tabs.count > 1
        menu.addItem(others)
        // Stacked in the sidebar, the later tabs are below this one.
        let right = MenuActionItem(title: tabLayout == .vertical ? "Close Tabs Below" : "Close Tabs to the Right") { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTabs { candidate in self.tabs.firstIndex { $0 === candidate }.map { $0 > index } ?? false }
        }
        right.isEnabled = index < tabs.count - 1
        menu.addItem(right)
        return menu
    }

    /// Opens the same page in a new tab right after `tab`.
    private func duplicate(_ tab: Tab) {
        openTab(url: tab.url, select: true, at: tabs.firstIndex { $0 === tab }.map { $0 + 1 })
    }

    /// Asks every tab `keep` rejects to close. Each page's beforeunload may
    /// still keep its own tab.
    private func closeTabs(where close: (Tab) -> Bool) {
        closingAll = false
        for tab in tabs where close(tab) { tab.close() }
    }

    // MARK: Actions (also reached from the menu through the responder chain)

    @objc func newTab(_ sender: Any?) {
        let settings = profile.settings
        openTab(url: settings.newTabPage == .homepage ? settings.homepageURL : "about:blank", select: true)
    }

    /// Opens `url` in a new selected tab and brings the window forward. A
    /// `background` tab goes after the selected one and leaves it in front.
    func openInNewTab(_ url: String, background: Bool = false) {
        if background {
            openTab(url: url, select: false, at: selectedTab.flatMap { tab in tabs.firstIndex { $0 === tab } }.map { $0 + 1 })
            return
        }
        openTab(url: url, select: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func closeTab(_ sender: Any?) {
        if let selectedTab { requestClose(selectedTab) }
    }

    /// Cmd+Shift+T: opens the last closed tab where it was.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = profile.session.popClosedTab() else { return }
        openTab(url: closed.tab.url, select: true, at: closed.index, restoring: closed.tab)
    }

    @objc func selectNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    /// Cmd+1 to Cmd+8 pick that tab, Cmd+9 the last one. The number is the menu item's tag.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag, !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    private func selectTab(offset: Int) {
        guard let current = selectedTab, let index = tabs.firstIndex(where: { $0 === current }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    @objc func goBack(_ sender: Any?) { selectedTab?.goBack() }
    @objc func goForward(_ sender: Any?) { selectedTab?.goForward() }

    @objc func reloadOrStop(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        tab.isLoading ? tab.stop() : tab.reload()
    }

    @objc func reloadPage(_ sender: Any?) { selectedTab?.reload() }
    @objc func stopLoading(_ sender: Any?) { selectedTab?.stop() }
    @objc func printPage(_ sender: Any?) { selectedTab?.print() }
    @objc func showDevTools(_ sender: Any?) { selectedTab?.showDevTools() }
    /// Opens the page's source in a tab after it, as Chrome does.
    @objc func viewPageSource(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        openTab(url: "view-source:" + tab.url, select: true, at: tabs.firstIndex { $0 === tab }.map { $0 + 1 })
    }

    /// Moves the tabs between the toolbar and the sidebar.
    @objc func toggleTabSidebar(_ sender: Any?) {
        guard fullscreenTab == nil else { return }
        profile.settings.tabLayout = tabLayout == .vertical ? .horizontal : .vertical
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { zoom(1) }
    @objc func zoomOut(_ sender: Any?) { zoom(-1) }
    @objc func actualSize(_ sender: Any?) { zoom(0) }

    private func zoom(_ step: Int32) {
        guard let tab = selectedTab else { return }
        tab.zoom(step)
        // Chromium applies the zoom on its next turn.
        DispatchQueue.main.async { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab, tab === self.selectedTab else { return }
                self.addressBar.showZoom(tab.zoomFactor)
            }
        }
    }

    // MARK: Find

    @objc func showFindBar(_ sender: Any?) {
        guard selectedTab != nil else { return }
        if !findBarShown {
            findBarShown = true
            // Put back on top, in case a tab was selected over it while it
            // faded out.
            findBar.removeFromSuperview()
            findBar.translatesAutoresizingMaskIntoConstraints = false
            findBar.alphaValue = 0
            contentView.addSubview(findBar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                findBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Padding.row),
                findBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Padding.panel),
                // A narrow page squeezes the bar rather than cutting off its left side.
                findBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Padding.panel),
            ])
            withEasing(Theme.Duration.quick) { findBar.animator().alphaValue = 1 }
            if !findBar.text.isEmpty { find(findBar.text) }
        }
        window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
    }

    @objc func findNext(_ sender: Any?) { findAgain(forward: true) }
    @objc func findPrevious(_ sender: Any?) { findAgain(forward: false) }

    private func find(_ text: String) {
        guard let tab = selectedTab else { return }
        if text.isEmpty {
            tab.stopFinding()
            findBar.showCount(nil)
        } else {
            tab.find(text)
        }
    }

    private func findAgain(forward: Bool) {
        guard let tab = selectedTab, !findBar.text.isEmpty else { return showFindBar(nil) }
        if !findBarShown { showFindBar(nil) }
        tab.find(findBar.text, forward: forward, next: true)
    }

    /// Fades the bar out and takes it away, unless it is shown again first.
    /// The search stops and the focus moves at once.
    private func hideFindBar(focusPage: Bool) {
        guard findBarShown else { return }
        findBarShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
            findBar.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.findBarShown else { return }
                self.findBar.removeFromSuperview()
            }
        }
        selectedTab?.stopFinding()
        findBar.showCount(nil)
        if focusPage { selectedTab?.focus() }
    }

    /// Slides the panel in or out. The page resizes once, before sliding in and
    /// after sliding out, since Chromium laying it out every frame would stutter.
    @objc func toggleAgentPanel(_ sender: Any?) {
        // The chrome stays out of the way while a page has the screen.
        guard fullscreenTab == nil else { return }
        agentPanelShown.toggle()
        profile.settings.defaults.set(agentPanelShown, forKey: Self.agentVisibleKey)
        agentButton.state = agentPanelShown ? .on : .off
        updateAgentBadge()
        agentToggleCount += 1
        let count = agentToggleCount
        // The page's corner by the panel rounds before the panel slides in
        // and squares once it has slid out, so the page never shows a square,
        // unoutlined edge beside an empty gap.
        if agentPanelShown {
            roundPage()
            agentPanel.isHidden = false
            splitView.adjustSubviews()
            window?.makeFirstResponder(agentPanel.input)
            slideAgentPanel(to: 0, count: count)
        } else {
            selectedTab?.focus()
            slideAgentPanel(to: agentPanel.bounds.width, count: count) { [weak self] in
                self?.agentPanel.isHidden = true
                self?.splitView.adjustSubviews()
                self?.roundPage()
            }
        }
    }

    /// Moves the panel from wherever it is now to `offset` points right of its
    /// place, then runs `completion` unless another toggle came first.
    private func slideAgentPanel(to offset: CGFloat, count: Int, completion: (() -> Void)? = nil) {
        guard let layer = agentPanel.layer else {
            completion?()
            return
        }
        let key = "slide"
        let current = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
        // Coming out of hiding, start off the right edge.
        let start = layer.animation(forKey: key) == nil
            ? (offset == 0 ? agentPanel.bounds.width : 0) : current ?? 0
        layer.removeAnimation(forKey: key)
        let finish = { [weak self] in
            guard let self, self.agentToggleCount == count else { return }
            completion?()
            layer.removeAnimation(forKey: key)
        }
        if Theme.reduceMotion {
            return finish()
        }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = offset
        animation.duration = Theme.Duration.panel
        animation.timingFunction = CAMediaTimingFunction(name: offset == 0 ? .easeOut : .easeIn)
        // Stays at the end until `finish` hides the panel, so it doesn't flash back.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        layer.add(animation, forKey: key)
        CATransaction.commit()
    }

    /// The dot shows only while the panel is hidden, where the work would
    /// otherwise go unseen. The button says so too, for VoiceOver and the
    /// tooltip, which can't see the dot.
    private func updateAgentBadge() {
        let shown = agentPanel.isBusy && !agentPanelShown
        withEasing(Theme.Duration.quick) { agentBadge.animator().alphaValue = shown ? 1 : 0 }
        let label = shown ? "Agent (working)" : "Agent"
        agentButton.toolTip = label
        agentButton.setAccessibilityLabel(label)
    }

    private static let agentVisibleKey = "agentPanelVisible"
    /// The panel's width until the divider is dragged.
    private static let defaultAgentPanelWidth: CGFloat = 400
    private static let sidebarWidthKey = "sidebarWidth"

    // MARK: Scheduled prompts

    /// Sends a scheduled prompt in a new agent chat. The panel stays as it
    /// is; while hidden, its button's dot shows the run working.
    func runScheduledPrompt(_ schedule: ScheduledPrompt, completion: @escaping (String, AgentRunOutcome) -> Void) -> String {
        agentPanel.runScheduled(schedule, completion: completion)
    }

    func isAgentChatBusy(_ id: String) -> Bool {
        agentPanel.isChatBusy(id)
    }

    /// Brings the window forward with the panel showing the chat, for a
    /// scheduled run's notification.
    func showAgentChat(_ id: String) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if !agentPanelShown { toggleAgentPanel(nil) }
        agentPanel.openScheduled(id)
    }

    #if DEBUG
    /// For testing without typing: `open Tiller.app --args -agentPrompt "..."`.
    /// `-agentPasteImage YES` pastes the clipboard twice first.
    func sendAgentPrompt(_ text: String) {
        if !agentPanelShown { toggleAgentPanel(nil) }
        if UserDefaults.standard.bool(forKey: "agentPasteImage") {
            agentPanel.pasteAndSendForTesting(text)
        } else {
            agentPanel.send(text)
        }
        let stopAfter = UserDefaults.standard.double(forKey: "agentStopAfter")
        if stopAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { [weak self] in
                MainActor.assumeIsolated { self?.agentPanel.stopForTesting() }
            }
        }
    }
    #endif

    @objc func openLocation(_ sender: Any?) {
        // Already editing: keep what was typed and select it.
        if !addressBar.field.isEditing { window?.makeFirstResponder(addressBar.field) }
        addressBar.field.currentEditor()?.selectAll(nil)
    }

    /// Loads a suggestion picked from the address bar's list.
    /// Opens a URL chosen in the address bar, its suggestions or the start
    /// page. A new tab goes right after the selected one.
    private func open(_ url: String, _ disposition: OpenDisposition) {
        guard let tab = selectedTab else { return }
        switch disposition {
        case .currentTab:
            tab.load(url)
            addressBar.show(url)
            tab.focus()
        case .foregroundTab, .backgroundTab:
            let index = tabs.firstIndex { $0 === tab }.map { $0 + 1 }
            if disposition == .backgroundTab { addressBar.show(tab.url) }
            openTab(url: url, select: disposition == .foregroundTab, at: index)
        }
    }

    @objc private func addressEntered(_ sender: NSTextField) {
        let input = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        open(AddressInput.url(for: input, settings: profile.settings), .returnKey(OpenDisposition.currentFlags))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAgentPanel(_:)) {
            item.title = agentPanelShown ? "Hide Agent" : "Show Agent"
        }
        if item.action == #selector(toggleTabSidebar(_:)) {
            item.title = tabLayout == .vertical ? "Hide Tab Sidebar" : "Show Tab Sidebar"
        }
        if item.action == #selector(toggleSidebarCollapsed(_:)) {
            item.title = sidebar.isCollapsed ? "Expand Tab Sidebar" : "Collapse Tab Sidebar"
        }
        return switch item.action {
        case #selector(toggleAgentPanel(_:)), #selector(toggleTabSidebar(_:)): fullscreenTab == nil
        case #selector(toggleSidebarCollapsed(_:)): tabLayout == .vertical && fullscreenTab == nil
        case #selector(stopLoading(_:)): selectedTab?.isLoading ?? false
        case #selector(printPage(_:)), #selector(showDevTools(_:)):
            selectedTab.map { !$0.isBlank } ?? false
        case #selector(viewPageSource(_:)): selectedTab.map { !$0.isBlank && !$0.url.hasPrefix("view-source:") } ?? false
        case #selector(goBack(_:)): selectedTab?.canGoBack ?? false
        case #selector(goForward(_:)): selectedTab?.canGoForward ?? false
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): tabs.count > 1
        case #selector(reopenClosedTab(_:)): profile.session.hasClosedTabs
        case #selector(fillPassword(_:)): selectedTab.map { !savedLogins(for: $0).isEmpty } ?? false
        case #selector(findNext(_:)), #selector(findPrevious(_:)): !findBar.text.isEmpty
        case #selector(actualSize(_:)): selectedTab.map { abs($0.zoomFactor - 1) > 0.001 } ?? false
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)): selectedTab != nil
        // A blank tab has nothing to find in.
        case #selector(showFindBar(_:)): selectedTab.map { !$0.isBlank } ?? false
        default: true
        }
    }

    // MARK: Window

    /// Closes every tab first. Each page's beforeunload may still cancel its own
    /// close. The window closes when its last tab is gone.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabs.isEmpty { return true }
        closeAllTabs()
        return false
    }

    /// Closes every tab, for the window closing or Tiller quitting. Tabs that
    /// never loaded go right away; the others run their beforeunload first. The
    /// window closes with the last one, and Tiller quits with the window.
    func closeAllTabs() {
        freezeSession()
        tabs.forEach { $0.close() }
    }

    func windowDidResize(_ notification: Notification) {
        suggestions.hide()
        fitTabStrip()
    }

    /// The gap check, which lays out the whole window, waits out a live
    /// resize, so a drag doesn't lay it out twice for every step.
    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleToolbarGapCheck()
    }

    /// Room left after the window buttons, back, forward, reload, new tab, the
    /// extension buttons, the profile button and the agent button. The address
    /// bar gets the same in the tabs' place, plus the new-tab button's.
    private func fitTabStrip() {
        guard let width = window?.frame.width else { return }
        let profileWidth = profileName == nil ? 0 : fittedWidth(profileButton, cache: &profileButtonWidth) + 12
        let extensionsWidth = extensionBar.isEmpty ? 0 : fittedWidth(extensionBar, cache: &extensionBarWidth) + 12
        let downloadsWidth: CGFloat = showsToolbarItem(Item.downloads) ? 40 : 0
        tabStripWidth.constant = max(200, width - 370 + tabStripSlack - profileWidth - extensionsWidth - downloadsWidth)
        addressWidth.constant = max(200, width - 330 + addressSlack - profileWidth - extensionsWidth - downloadsWidth)
        scheduleToolbarGapCheck()
    }

    /// The profile button's and extension bar's fitting widths, which only
    /// change with their content, kept so a live resize doesn't lay them out
    /// at every step. Nil until measured, and again when the content changes.
    private var profileButtonWidth: CGFloat?
    private var extensionBarWidth: CGFloat?

    private func fittedWidth(_ view: NSView, cache: inout CGFloat?) -> CGFloat {
        if let width = cache { return width }
        let width = view.fittingSize.width
        cache = width
        return width
    }

    /// What the estimates in `fitTabStrip` leave over, learned from where
    /// the toolbar really put its items. The toolbar's spacing differs by
    /// macOS version, so a fixed estimate leaves a wide empty gap before the
    /// trailing buttons on some and would overflow them on others.
    private var tabStripSlack: CGFloat = 0
    private var addressSlack: CGFloat = 0
    private var toolbarGapCheckPending = false
    /// The most slack known to fit, lowered when the trailing buttons went
    /// into the overflow menu.
    private var slackCeiling: CGFloat = 400
    /// The space kept between the tabs' or address bar's group and the
    /// buttons at the end, about what the toolbar puts between groups.
    private static let toolbarGap: CGFloat = 10

    /// Whether the last pass widened the tabs, so a trailing button gone
    /// from the toolbar right after means they pushed it out.
    private var widenedToolbarLastPass = false
    /// Passes left to wait for the toolbar to place its items, as when the
    /// window is still being put together.
    private var toolbarGapRetries = 0

    private func scheduleToolbarGapCheck(after delay: TimeInterval = 0) {
        guard !toolbarGapCheckPending, window?.inLiveResize != true else { return }
        toolbarGapCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.toolbarGapCheckPending = false
            self.closeToolbarGap()
        }
    }

    /// Widens or narrows the tabs, or the address bar with the tabs in the
    /// sidebar, so the gap before the trailing buttons is `toolbarGap`.
    private func closeToolbarGap() {
        let widened = widenedToolbarLastPass
        widenedToolbarLastPass = false
        guard let window, fullscreenTab == nil, !window.styleMask.contains(.fullScreen) else { return }
        let vertical = tabLayout == .vertical
        let lead: NSView = vertical ? addressBar : newTabButton
        let trailing: [NSView] = [extensionBar, downloadsButton, profileButton, agentButton]
        window.layoutIfNeeded()
        // Only the trailing buttons the toolbar shows; one in the overflow
        // menu has no window.
        guard lead.window != nil, agentButton.window != nil, !agentButton.isHiddenOrHasHiddenAncestor else {
            guard widened else {
                // Not placed yet: look again shortly, a few times at most.
                if toolbarGapRetries < 5 {
                    toolbarGapRetries += 1
                    scheduleToolbarGapCheck(after: 0.2)
                }
                return
            }
            // The tabs just pushed the agent's button out. Back off, and
            // don't come this far again, so passes can't take turns pushing
            // the buttons out and pulling them back in.
            let old = vertical ? addressSlack : tabStripSlack
            let slack = max(-200, old - 12)
            slackCeiling = slack
            if vertical { addressSlack = slack } else { tabStripSlack = slack }
            fitTabStrip()
            return
        }
        toolbarGapRetries = 0
        let leadEnd = lead.convert(lead.bounds, to: nil).maxX
        let trailingStart = trailing
            .filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
            .map { $0.convert($0.bounds, to: nil).minX }
            .min() ?? leadEnd
        let excess = (trailingStart - leadEnd - Self.toolbarGap).rounded()
        guard abs(excess) >= 2 else { return }
        let old = vertical ? addressSlack : tabStripSlack
        let slack = min(slackCeiling, max(-200, old + excess))
        // At a limit, or with the width held at its minimum, nothing moves
        // and another pass would only measure the same gap again.
        guard slack != old else { return }
        if vertical { addressSlack = slack } else { tabStripSlack = slack }
        widenedToolbarLastPass = slack > old
        fitTabStrip()
    }

    // MARK: Downloads

    /// Shows the button with the first download and keeps its ring current.
    @objc private func downloadsChanged(_ notification: Notification) {
        downloadsButton.refresh()
        let shown = !DownloadStore.shared.downloads.isEmpty
        if showsToolbarItem(Item.downloads) != shown {
            showToolbarItem(Item.downloads, shown)
            fitTabStrip()
        }
        // Only while it is open: a closed one is never shown again, as the
        // next click makes a new one, and progress comes 4 times a second.
        guard let downloadsPopover, downloadsPopover.isShown else { return }
        (downloadsPopover.contentViewController as? DownloadsController)?.reload()
    }

    /// A load that became a download leaves the tab on its page, so the tab
    /// shouldn't keep the download's URL, or the session would fetch the file
    /// again at the next launch.
    @objc private func downloadStarted(_ notification: Notification) {
        guard let download = notification.userInfo?["download"] as? Download, download.tabID >= 0,
            let tab = tabs.first(where: { $0.browserID == download.tabID }) else { return }
        tab.dropPendingLoad(of: [download.url, download.originalURL])
    }

    @objc func showDownloads(_ sender: Any?) {
        if let downloadsPopover, downloadsPopover.isShown { return downloadsPopover.close() }
        // The button is away until the first download; the menu brings it out.
        if !showsToolbarItem(Item.downloads) {
            showToolbarItem(Item.downloads, true)
            fitTabStrip()
            window?.layoutIfNeeded()
        }
        guard downloadsButton.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = DownloadsController()
        downloadsPopover = popover
        popover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .maxY)
    }

    // MARK: Theme

    @objc private func themeChanged(_ notification: Notification) {
        applyTheme()
    }

    /// Under Claude or Qoder the window takes the theme's chrome, and the
    /// titlebar lets it show, rather than the system's material.
    private func applyTheme() {
        guard let window else { return }
        let themed = Settings.theme != .tiller
        window.titlebarAppearsTransparent = themed
        window.backgroundColor = themed ? Theme.chrome : NSColor.windowBackgroundColor
        // The agent button's "on" plate, which AppKit draws in the system accent.
        agentButton.bezelColor = themed ? Theme.accentFill : nil
        splitView.needsDisplay = true
    }

    // MARK: Tab layout

    @objc private func tabLayoutChanged(_ notification: Notification) {
        guard profile.settings.tabLayout != tabLayout else { return }
        tabLayout = profile.settings.tabLayout
        applyTabLayout()
        if fullscreenTab != nil { hideChromeForFullscreen() }
        if let selectedTab { tabStrip.update(tabs: tabs, selected: selectedTab) }
    }

    /// Puts the tabs and the address bar where `tabLayout` has them.
    private func applyTabLayout() {
        guard let window else { return }
        let vertical = tabLayout == .vertical
        // The bar moves, so the list goes at once rather than fading where it was.
        suggestions.hide(animated: false)
        if let addressAccessory, let index = window.titlebarAccessoryViewControllers.firstIndex(of: addressAccessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        addressAccessory = nil
        // Sizes that only hold in the toolbar.
        tabStripWidth.isActive = !vertical
        tabStripHeight.isActive = !vertical
        addressWidth.isActive = vertical
        addressHeight.isActive = vertical
        // What overflowed in the other layout says nothing about this one.
        slackCeiling = 400
        addressBar.inset = vertical ? 0 : 12
        tabStrip.orientation = vertical ? .vertical : .horizontal

        // A toolbar per layout, since the items differ.
        let toolbar = NSToolbar(identifier: vertical ? "TillerToolbarSidebar" : "TillerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        showToolbarItem(Item.extensions, !extensionBar.isEmpty)
        showToolbarItem(Item.downloads, !DownloadStore.shared.downloads.isEmpty)
        showToolbarItem(Item.profile, profileName != nil)
        if vertical {
            sidebar.show(tabStrip)
        } else {
            addressBar.frame.size.height = 40
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = addressBar
            accessory.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(accessory)
            addressAccessory = accessory
        }
        window.titlebarSeparatorStyle = vertical ? .none : .automatic
        splitView.hidesDividers = vertical
        sidebar.isHidden = !vertical
        roundPage()
        fitSidebar()
        fitTabStrip()
    }

    /// With tabs in the sidebar the page is a card, rounded where it meets
    /// the sidebar and the agent panel.
    private func roundPage() {
        contentView.isCard = tabLayout == .vertical && fullscreenTab == nil
        contentView.roundsTrailingCorner = agentPanelShown && fullscreenTab == nil
    }

    /// Gives the sidebar its collapsed width, or the one it had before.
    private func fitSidebar() {
        let collapsed = sidebar.isCollapsed
        let range = TabSidebarView.widthRange
        let width = collapsed
            ? TabSidebarView.collapsedWidth : min(max(sidebarWidth, range.lowerBound), range.upperBound)
        // Apart first, so the two never cross on the way.
        sidebarMinWidth.constant = 0
        sidebarMaxWidth.constant = collapsed ? width : range.upperBound
        sidebarMinWidth.constant = collapsed ? width : range.lowerBound
        guard !sidebar.isHidden else { return splitView.adjustSubviews() }
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(width, ofDividerAt: 0)
    }

    /// Collapses the sidebar to icons or expands it, from its button or the
    /// View menu.
    @objc func toggleSidebarCollapsed(_ sender: Any?) {
        guard tabLayout == .vertical, fullscreenTab == nil else { return }
        sidebar.isCollapsed.toggle()
        profile.settings.sidebarCollapsed = sidebar.isCollapsed
        fitSidebar()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !sidebar.isHidden, !sidebar.isCollapsed, sidebar.frame.width != sidebarWidth,
            TabSidebarView.widthRange.contains(sidebar.frame.width)
        else { return }
        sidebarWidth = sidebar.frame.width
        profile.settings.defaults.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    private static let reloadImage = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
    private static let stopImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")

    /// Turns Reload into Stop while the page loads. Only a change of state
    /// touches the button, since this runs on every update of the selected tab.
    private func showLoading(_ loading: Bool) {
        guard loading != showsStop else { return }
        showsStop = loading
        reloadButton.image = loading ? Self.stopImage : Self.reloadImage
        let label = loading ? "Stop" : "Reload"
        reloadButton.toolTip = label
        reloadItem?.label = label
    }

    /// Shows the profile's name in the toolbar and window title, or hides it
    /// when `name` is nil.
    func showProfile(name: String?) {
        profileName = name
        profileButton.title = name ?? ""
        profileButtonWidth = nil
        showToolbarItem(Item.profile, name != nil)
        updateWindowTitle()
        fitTabStrip()
    }

    /// The selected page's title, then the profile's name when there are
    /// several, for the Window menu, Mission Control and VoiceOver, where two
    /// profiles' windows need telling apart.
    private func updateWindowTitle() {
        let page = selectedTab?.displayTitle ?? "Tiller"
        window?.title = profileName.map { "\(page) – \($0)" } ?? page
    }

    @objc private func showProfilesMenu(_ sender: NSButton) {
        MainMenu.profiles.popUp(
            positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender
        )
    }

    /// The profile in front is the one a plain launch, links from other apps
    /// and the CLI pick.
    func windowDidBecomeKey(_ notification: Notification) {
        Profiles.markUsed(profile.id)
    }

    func windowWillClose(_ notification: Notification) {
        unloadTimer?.invalidate()
        memoryPressure?.cancel()
        extensionPopover?.close()
        agentPanel.shutDown()
        profile.session.flush()
        onClose?()
    }

    // MARK: Toolbar

    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let reload = NSToolbarItem.Identifier("reload")
        static let tabs = NSToolbarItem.Identifier("tabs")
        static let address = NSToolbarItem.Identifier("address")
        static let newTab = NSToolbarItem.Identifier("newTab")
        static let agent = NSToolbarItem.Identifier("agent")
        static let profile = NSToolbarItem.Identifier("profile")
        static let extensions = NSToolbarItem.Identifier("extensions")
        static let downloads = NSToolbarItem.Identifier("downloads")
    }

    private func configureControls() {
        for (button, name, tip, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack(_:))),
            (forwardButton, "chevron.right", "Forward", #selector(goForward(_:))),
            (reloadButton, "arrow.clockwise", "Reload", #selector(reloadOrStop(_:))),
            (newTabButton, "plus", "New Tab", #selector(newTab(_:))),
            (agentButton, "sparkles", "Agent", #selector(toggleAgentPanel(_:))),
        ] {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
            button.toolTip = tip
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
        }
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        profileButton.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profile")
        profileButton.imagePosition = .imageLeading
        profileButton.toolTip = "Profiles"
        profileButton.bezelStyle = .toolbar
        profileButton.target = self
        profileButton.action = #selector(showProfilesMenu(_:))
        agentButton.setButtonType(.pushOnPushOff)
        agentButton.state = agentPanel.isHidden ? .off : .on
        // Faded out rather than hidden, so it can ease in and out.
        agentBadge.alphaValue = 0
        agentBadge.translatesAutoresizingMaskIntoConstraints = false
        agentButton.addSubview(agentBadge)
        NSLayoutConstraint.activate([
            agentBadge.widthAnchor.constraint(equalToConstant: Theme.busyDot),
            agentBadge.heightAnchor.constraint(equalToConstant: Theme.busyDot),
            agentBadge.topAnchor.constraint(equalTo: agentButton.topAnchor, constant: 3),
            agentBadge.trailingAnchor.constraint(equalTo: agentButton.trailingAnchor, constant: -3),
        ])
        agentPanel.onBusyChange = { [weak self] _ in self?.updateAgentBadge() }
        downloadsButton.target = self
        downloadsButton.action = #selector(showDownloads(_:))
        // The two round buttons side by side take one size, the agent's, so
        // their circles match whatever glyph each shows.
        let round = agentButton.intrinsicContentSize
        NSLayoutConstraint.activate([
            downloadsButton.widthAnchor.constraint(equalToConstant: round.width),
            downloadsButton.heightAnchor.constraint(equalToConstant: round.height),
        ])

        addressBar.field.target = self
        addressBar.field.action = #selector(addressEntered(_:))
        sidebar.collapseButton.target = self
        sidebar.collapseButton.action = #selector(toggleSidebarCollapsed(_:))
        addressBar.keyButton.target = self
        addressBar.keyButton.action = #selector(fillPassword(_:))
        addressBar.zoomButton.target = self
        addressBar.zoomButton.action = #selector(actualSize(_:))
        suggestions.onOpen = { [weak self] url, disposition in self?.open(url, disposition) }
        extensionBar.onPopup = { [weak self] manifest, anchor in self?.showExtensionPopup(manifest, from: anchor) }
        extensionBar.onOpen = { [weak self] url in self?.openInNewTab(url) }
        extensionBar.onResize = { [weak self] in
            self?.extensionBarWidth = nil
            self?.fitTabStrip()
        }
    }

    /// Opens the extension's popup under `anchor`, closing any other first.
    /// Clicking the button of the one that's open just closes it.
    private func showExtensionPopup(_ manifest: ExtensionManifest, from anchor: NSView) {
        if let open = extensionPopover {
            open.close()
            if open.manifest.id == manifest.id { return }
        }
        let popover = ExtensionPopover(manifest: manifest, profile: profile)
        popover.onOpenTab = { [weak self, weak popover] url, background in
            guard let self else { return }
            self.openTab(url: url, select: !background)
            if !background { popover?.close() }
        }
        popover.onKeyEquivalent = { [weak self] event in self?.performMenuKeyEquivalent(event) ?? false }
        popover.onClose = { [weak self, weak popover] in
            if let self, self.extensionPopover === popover { self.extensionPopover = nil }
        }
        extensionPopover = popover
        popover.show(relativeTo: anchor)
    }

    /// Whether the toolbar shows the item `id`.
    private func showsToolbarItem(_ id: NSToolbarItem.Identifier) -> Bool {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == id }) else { return false }
        if #available(macOS 15, *) { return !item.isHidden }
        return true
    }

    /// Shows or hides the item `id`. NSToolbarItem.isHidden is macOS 15 and
    /// later; before that the item leaves the toolbar and comes back at its
    /// place in the default order.
    private func showToolbarItem(_ id: NSToolbarItem.Identifier, _ shown: Bool) {
        guard let toolbar = window?.toolbar else { return }
        if #available(macOS 15, *) {
            toolbar.items.first { $0.itemIdentifier == id }?.isHidden = !shown
            return
        }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == id }
        if !shown, let index {
            toolbar.removeItem(at: index)
        } else if shown, index == nil {
            let before = toolbarDefaultItemIdentifiers(toolbar).prefix { $0 != id }
            toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.filter { before.contains($0.itemIdentifier) }.count)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabLayout == .vertical
            ? [
                Item.back, Item.forward, Item.reload, Item.address, .flexibleSpace, Item.extensions, Item.downloads,
                Item.profile, Item.agent,
            ]
            : [
                Item.back, Item.forward, Item.reload, Item.tabs, Item.newTab, .flexibleSpace, Item.extensions,
                Item.downloads, Item.profile, Item.agent,
            ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.back: item.view = backButton; item.label = "Back"
        case Item.forward: item.view = forwardButton; item.label = "Forward"
        case Item.reload:
            item.view = reloadButton
            item.label = showsStop == true ? "Stop" : "Reload"
            reloadItem = item
        case Item.newTab: item.view = newTabButton; item.label = "New Tab"
        case Item.agent: item.view = agentButton; item.label = "Agent"
        case Item.extensions:
            item.view = extensionBar
            item.label = "Extensions"
        case Item.downloads:
            item.view = downloadsButton
            item.label = "Downloads"
        case Item.profile:
            item.view = profileButton
            item.label = "Profile"
        case Item.tabs:
            item.view = tabStrip
            item.label = "Tabs"
            fitTabStrip()
        case Item.address:
            item.view = addressBar
            item.label = "Address"
            // The bar draws its own capsule; without this the toolbar would
            // put a second piece of glass around it and the buttons before it.
            item.isBordered = false
            fitTabStrip()
        default: return nil
        }
        return item
    }
}

// MARK: Control socket

extension BrowserWindowController {
    /// Tab operations for tiller_mcp. Tab ids are CEF browser ids, the same ids
    /// the core's DevTools calls take. A missing `tab_id` means the selected tab.
    func control(_ method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "tabs.list":
            // Tabs that aren't loaded stay that way until a tool acts on them.
            return ["tabs": tabs.map(info)]
        case "jev.progress":
            return try jevOverlay.progress(params)
        case "tabs.info":
            // One tab's info, such as whether it is loading, without loading it.
            return info(try tab(for: params))
        case "tabs.resolve":
            // Before a tool reads or drives a tab: loads it if it isn't, and
            // says so, so the caller can wait for the page.
            let tab = try tab(for: params)
            let started = !tab.isStarted
            start(tab)
            var reply = info(tab)
            reply["started"] = started
            return reply
        case "tabs.new":
            let url = (params["url"] as? String).map { AddressInput.url(for: $0, settings: profile.settings) } ?? "about:blank"
            return info(openTab(url: url, select: params["select"] as? Bool ?? true))
        case "tabs.select":
            let tab = try tab(for: params)
            if tab !== selectedTab {
                let panelHadFocus = agentPanel.hasKeyboardFocus
                select(tab)
                if panelHadFocus { window?.makeFirstResponder(agentPanel.input) }
            }
            return info(tab)
        case "tabs.wake":
            // Before a click, type or screenshot. `woke` says the page was hidden
            // until now, so it may need a moment to draw.
            let tab = try tab(for: params)
            var reply = info(tab)
            reply["woke"] = wake(tab)
            return reply
        case "tabs.navigate":
            let tab = try tab(for: params)
            guard let input = params["url"] as? String, !input.isEmpty else { throw ControlError("navigate needs a url") }
            let url = AddressInput.url(for: input, settings: profile.settings)
            if tab.isStarted {
                tab.load(url)
            } else {
                // Straight to the new page, without loading the old one first.
                tab.hostView.frame = contentView.bounds
                tab.start(url: url)
            }
            tabDidChange(tab)
            return info(tab)
        case "tabs.wait_load":
            // Answers once the tab's load ends, or once `grace_ms` pass with
            // none starting, or at `timeout_ms` with a note. Event-driven, so
            // a tool call doesn't poll the tab list every few milliseconds.
            let tab = try tab(for: params)
            let grace = (params["grace_ms"] as? Double ?? 500) / 1000
            let timeout = (params["timeout_ms"] as? Double ?? 30_000) / 1000
            return ControlDeferred { [weak self] reply in
                guard let self else { return reply(.failure(ControlError("the window closed"))) }
                self.waitForLoad(of: tab, grace: grace, timeout: timeout, reply: reply)
            }
        case "tabs.close":
            let tab = try tab(for: params)
            requestClose(tab)
            return ["closing": tab.id]
        #if DEBUG
        case _ where method.hasPrefix("ui."):
            return try debugUI(String(method.dropFirst(3)), params: params)
        #endif
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    /// The tab `params` names, or the selected one. An agent using it counts
    /// as use, which keeps it from unloading.
    private func tab(for params: [String: Any]) throws -> Tab {
        guard let id = params["tab_id"] as? Int else {
            guard let selectedTab else { throw ControlError("no tab is open") }
            return selectedTab
        }
        guard let tab = tabs.first(where: { $0.id == id }) else { throw ControlError("no tab with id \(id)") }
        tab.lastActive = Date()
        return tab
    }

    private func info(_ tab: Tab) -> [String: Any] {
        [
            "id": tab.id,
            "url": tab.url,
            "title": tab.displayTitle,
            "loading": tab.isLoading,
            "loaded": tab.isStarted,
            "selected": tab === selectedTab,
        ]
    }

    // MARK: Waiting for loads

    /// A `tabs.wait_load` request in progress.
    private final class LoadWaiter {
        let tab: Tab
        let reply: (Result<Any, ControlError>) -> Void
        /// Whether the tab was seen loading since the wait began.
        var sawLoading: Bool
        var graceTimer: Timer?
        var timeoutTimer: Timer?

        init(tab: Tab, sawLoading: Bool, reply: @escaping (Result<Any, ControlError>) -> Void) {
            self.tab = tab
            self.sawLoading = sawLoading
            self.reply = reply
        }
    }

    private static var loadWaiters: [LoadWaiter] = []

    private func waitForLoad(of tab: Tab, grace: TimeInterval, timeout: TimeInterval, reply: @escaping (Result<Any, ControlError>) -> Void) {
        let waiter = LoadWaiter(tab: tab, sawLoading: tab.isLoading, reply: reply)
        Self.loadWaiters.append(waiter)
        // The timers find the waiter by id: they may fire after it is gone.
        let id = ObjectIdentifier(waiter)
        if !tab.isLoading {
            // Nothing has started yet. A click's navigation starts within a
            // moment; after that, there is nothing to wait for.
            waiter.graceTimer = Timer.scheduledTimer(withTimeInterval: grace, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let waiter = Self.loadWaiters.first(where: { ObjectIdentifier($0) == id }), !waiter.sawLoading
                    else { return }
                    self.finish(waiter, note: nil)
                }
            }
        }
        waiter.timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let waiter = Self.loadWaiters.first(where: { ObjectIdentifier($0) == id }) else { return }
                self.finish(waiter, note: "still loading after \(Int(timeout.rounded())) seconds")
            }
        }
    }

    /// A tab's loading state changed: waits on it move along.
    private func loadStateChanged(_ tab: Tab) {
        for waiter in Self.loadWaiters where waiter.tab === tab {
            if tab.isLoading {
                waiter.sawLoading = true
                waiter.graceTimer?.invalidate()
            } else if waiter.sawLoading {
                finish(waiter, note: nil)
            }
        }
    }

    private func finish(_ waiter: LoadWaiter, note: String?) {
        guard let index = Self.loadWaiters.firstIndex(where: { $0 === waiter }) else { return }
        Self.loadWaiters.remove(at: index)
        waiter.graceTimer?.invalidate()
        waiter.timeoutTimer?.invalidate()
        var result = info(waiter.tab)
        if let note { result["note"] = note }
        waiter.reply(.success(result))
    }

    /// The tab closed under a wait.
    private func failLoadWaits(for tab: Tab) {
        for waiter in Self.loadWaiters where waiter.tab === tab {
            Self.loadWaiters.removeAll { $0 === waiter }
            waiter.graceTimer?.invalidate()
            waiter.timeoutTimer?.invalidate()
            waiter.reply(.failure(ControlError("tab \(tab.id) closed")))
        }
    }
}

#if DEBUG
// MARK: UI driving for screenshots and tests

extension BrowserWindowController {
    /// `ui.<action>` on the control socket, for driving the window from a
    /// script without the keyboard or mouse: `agent` toggles the panel,
    /// `agentAction` runs one of the panel's buttons (`text` names it),
    /// `agentText` puts `text` in the message field, `runSchedule` runs the
    /// scheduled prompt named `text` now, `scheduleEditor` opens a new
    /// scheduled prompt with `text` as its prompt, `find` searches for
    /// `text`, `location` types `text` in the address bar, `downloads`,
    /// `sidebar` and `settings` open those, `appearance` forces `light` or
    /// `dark`, `tabLayout` puts the tabs at `horizontal` or `vertical`,
    /// `unloadTabs` unloads background tabs as critical memory pressure does,
    /// and `resize` sets the window to `width` by `height`.
    func debugUI(_ action: String, params: [String: Any]) throws -> Any {
        let text = params["text"] as? String ?? ""
        switch action {
        case "agent":
            toggleAgentPanel(nil)
        case "agentAction":
            agentPanel.performForTesting(text)
        case "agentText":
            agentPanel.setTextForTesting(text)
        case "runSchedule":
            guard let schedule = profile.schedules.schedules.first(where: { $0.name == text }) else {
                throw ControlError("no scheduled prompt named \(text)")
            }
            profile.scheduler.runNow(schedule.id)
        case "scheduleEditor":
            (NSApp.delegate as? AppDelegate)?.showSettings(pane: ScheduledSettingsPane.paneTitle, profile: profile)
            ScheduledSettingsPane.shown?.addForTesting(prompt: text)
        case "find":
            showFindBar(nil)
            findBar.field.stringValue = text
            find(text)
            findBar.field.currentEditor()?.selectedRange = NSRange(location: text.utf16.count, length: 0)
        case "location":
            openLocation(nil)
            if let editor = addressBar.field.currentEditor() as? NSTextView {
                editor.insertText(text, replacementRange: editor.selectedRange())
            }
        case "downloads":
            showDownloads(nil)
        case "sidebar":
            toggleSidebarCollapsed(nil)
        case "settings":
            (NSApp.delegate as? AppDelegate)?.showSettings(pane: text, profile: profile)
        case "tabLayout":
            guard let layout = TabLayout(rawValue: text) else { throw ControlError("no tab layout \(text)") }
            profile.settings.tabLayout = layout
        case "appearance":
            NSApp.appearance = switch text {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
        case "resize":
            guard let window, let width = params["width"] as? Double, let height = params["height"] as? Double else {
                throw ControlError("resize needs width and height")
            }
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
        case "unloadTabs":
            memoryPressureChanged(critical: true)
        case "focusPage":
            selectedTab?.focus()
        case "status":
            statusBubble.show(text)
        case "action":
            // Any menu action by selector name, such as `showDevTools:`.
            let selector = Selector(text)
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            let target: AnyObject? = responds(to: selector) ? self : window?.responds(to: selector) == true ? window : nil
            guard let target, NSApp.sendAction(selector, to: target, from: nil) else { throw ControlError("nothing took \(text)") }
        default:
            throw ControlError("unknown ui action \(action)")
        }
        return ["ok": true]
    }
}
#endif

// MARK: Agent panel

extension BrowserWindowController {
    func agentCommandContext(_ panel: AgentPanelView) -> [String: Any] {
        guard let tab = selectedTab else { return [:] }
        return ["tab_id": Int(tab.browserID), "url": tab.url, "title": tab.displayTitle]
    }

    func agentPanelContext(_ panel: AgentPanelView) -> String {
        guard let tab = selectedTab else { return "[Tiller: no tab is open]" }
        return "[Tiller: selected tab \(tab.id), \"\(tab.displayTitle)\", \(tab.isBlank ? "about:blank" : tab.url)]"
    }

    /// Widens the divider's grab area into the panel. The divider is a point
    /// wide, and the page beside it takes the mouse for itself.
    func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        if dividerIndex == 0 {
            // The sidebar's divider, grabbed from the sidebar's side.
            guard !sidebar.isHidden, !sidebar.isCollapsed else { return .zero }
            return NSRect(x: drawnRect.minX - 6, y: drawnRect.minY, width: drawnRect.width + 6, height: drawnRect.height)
        }
        guard !agentPanel.isHidden else { return .zero }
        return NSRect(x: drawnRect.minX, y: drawnRect.minY, width: drawnRect.width + 6, height: drawnRect.height)
    }
}

// MARK: History, passwords and import

extension BrowserWindowController {
    /// A page from the History menu. The URL is the item's represented object.
    /// Cmd and Cmd+Shift open it in a new tab, as a click on a link does.
    @objc func openHistoryItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? String else { return }
        open(url, .click(OpenDisposition.currentFlags))
    }

    @objc func clearHistory(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Removes every page from Tiller's history, including pages imported from Chrome, and forgets recently closed tabs. Cookies and saved passwords stay."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self.profile.history.clear()
                self.profile.session.clearClosedTabs()
                // So each open tab saves its favicon again.
                self.tabs.forEach { $0.recordedIcon = nil }
            }
        }
    }

    @objc func importFromChrome(_ sender: Any?) {
        guard let window, chromeImport == nil else { return }
        let controller = ChromeImportController(profile: profile)
        chromeImport = controller
        controller.begin(on: window) { [weak self] in self?.chromeImport = nil }
    }

    /// Fills the page's saved login. With several, asks which one from a menu
    /// under the key button.
    @objc func fillPassword(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        let logins = savedLogins(for: tab)
        if logins.count == 1 { return fill(logins[0], in: tab) }
        guard !logins.isEmpty else { return }
        let menu = NSMenu()
        for login in logins {
            let item = MenuActionItem(title: login.username.isEmpty ? "(no username)" : login.username) { [weak self] in
                self?.fill(login, in: tab)
            }
            menu.addItem(item)
        }
        let button = addressBar.keyButton
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
    }

    private func savedLogins(for tab: Tab) -> [PasswordStore.Entry] {
        SavedLogin.origin(of: tab.url).map { profile.passwords.logins(for: $0) } ?? []
    }

    private func fill(_ login: PasswordStore.Entry, in tab: Tab) {
        Task {
            do {
                let password = try await profile.passwords.password(for: login)
                guard tabs.contains(where: { $0 === tab }) else { return }
                tab.executeJavaScript(LoginFill.script(origin: login.origin, username: login.username, password: password))
            } catch {
                guard let window else { return }
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    @objc private func passwordsChanged(_ notification: Notification) {
        if let selectedTab { showState(of: selectedTab) }
    }
}

/// The link under the mouse, in a small plate at the bottom left of the page,
/// as other browsers show it. It fades in once a link is hovered and out
/// when the mouse leaves.
final class StatusBubbleView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var shownText = ""
    private var pendingShow: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Theme.Radius.row
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMaxXMaxYCorner]
        layer.backgroundColor = Theme.background.dynamic(alpha: 0.96).layerColor
        layer.borderWidth = Theme.hairlineWidth
        layer.borderColor = Theme.hairline.layerColor
    }

    /// Shows `text`, or hides the bubble when it is empty. The URL loses its
    /// scheme, which is noise where it shows.
    func show(_ text: String) {
        var shown = text
        for scheme in ["https://", "http://"] where shown.hasPrefix(scheme) { shown.removeFirst(scheme.count) }
        guard shown != shownText else { return }
        shownText = shown
        pendingShow?.cancel()
        pendingShow = nil
        if shown.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                // Under Reduce Motion the bubble goes at once.
                context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.shownText.isEmpty else { return }
                    self.isHidden = true
                }
            }
            return
        }
        label.stringValue = shown
        toolTip = text
        isHidden = false
        // A short wait keeps a sweep of the mouse across links from flashing.
        let show = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shownText.isEmpty else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.reduceMotion ? 0 : Theme.Duration.standard
                    self.animator().alphaValue = 1
                }
            }
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + (alphaValue > 0 ? 0 : 0.12), execute: show)
    }

    // Lets the page under it take the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Holds the tabs' pages. As a card its top corners are rounded where it
/// meets the sidebar and the agent panel, and a hairline sets it apart from
/// them, which a light page on the light window would otherwise run into.
/// The hairline is a bordered layer with the card's own continuous corners,
/// so it follows the clip exactly.
final class PageCardView: NSView {
    var isCard = false { didSet { needsDisplay = true } }
    /// Whether the corner next to the agent panel is rounded too.
    var roundsTrailingCorner = false {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    private let outline = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        outline.cornerCurve = .continuous
        outline.borderWidth = Theme.hairlineWidth
        // Above the pages, which are sublayers too.
        outline.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let corners: CACornerMask = roundsTrailingCorner
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner]
        layer.cornerRadius = isCard ? Theme.Radius.card : 0
        layer.masksToBounds = isCard
        layer.maskedCorners = corners
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.isHidden = !isCard
        outline.cornerRadius = Theme.Radius.card
        outline.maskedCorners = corners
        outline.borderColor = Theme.hairline.layerColor
        CATransaction.commit()
        if outline.superlayer == nil { layer.addSublayer(outline) }
    }

    override func layout() {
        super.layout()
        // The top and the sides next to the sidebar and the panel. The bottom
        // and an open trailing side are the window's edge, so the outline
        // reaches past them and the card's clip cuts those lines off.
        let overhang = Theme.hairlineWidth
        var frame = bounds
        frame.origin.y -= overhang
        frame.size.height += overhang
        if !roundsTrailingCorner { frame.size.width += overhang }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = frame
        CATransaction.commit()
    }
}

/// The dot on the agent button. Its color is set in `updateLayer`, so it
/// follows light and dark mode and the accent color as they change.
private final class AgentBadgeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.busyDot / 2
        layer?.backgroundColor = Theme.accentColor.layerColor
    }

    // Faded out, it is still there; clicks go to the button under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A menu item that runs a closure.
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { handler() }
}
