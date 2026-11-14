import AppKit
import CTillerCore

@MainActor
protocol TabDelegate: AnyObject {
    /// Title, URL, loading state or favicon changed.
    func tabDidChange(_ tab: Tab)
    func tab(_ tab: Tab, openInNewTab url: String, background: Bool)
    /// beforeunload passed. The delegate removes the tab, which finishes the close.
    func tabReadyToClose(_ tab: Tab)
    func tab(_ tab: Tab, performKeyEquivalent event: NSEvent) -> Bool
    /// Load progress moved. Kept apart from `tabDidChange`, which is heavier
    /// and fires far less often.
    func tabProgressChanged(_ tab: Tab)
    /// A find in the page counted `count` matches and selected the `active`th.
    func tab(_ tab: Tab, foundMatches count: Int, active: Int, final: Bool)
    /// The page's size in points, once `autoResize` is on.
    func tab(_ tab: Tab, autoResizedTo size: NSSize)
    /// The link under the mouse, or an empty string once it leaves one.
    func tab(_ tab: Tab, statusChanged text: String)
    /// A page called `window.open`: a new tab, not yet started, for CEF to fill, or nil.
    func tab(_ tab: Tab, openPopup url: String, background: Bool) -> Tab?
    /// The page asked for the whole screen, as a video player does, or gave it back.
    func tab(_ tab: Tab, fullscreenChanged fullscreen: Bool)
    /// The tab's browser closed to save memory. The tab stays, and loads its
    /// page again when started.
    func tabDidUnload(_ tab: Tab)
    /// The page asked for the camera or microphone. Answer with
    /// `answerMediaRequest`, now or later.
    func tab(_ tab: Tab, requestsMedia request: MediaRequest)
    /// The page went away with `mediaRequests` and `mediaRefused` still up,
    /// which are cleared.
    func tabDroppedMediaRequests(_ tab: Tab)
    /// The page asked to open a link in another app, which waits in
    /// `appRequest` for the user. The tab's page stays where it was.
    func tab(_ tab: Tab, requestsApp request: AppRequest)
}

extension TabDelegate {
    func tab(_ tab: Tab, autoResizedTo size: NSSize) {}
    func tab(_ tab: Tab, statusChanged text: String) {}
    func tab(_ tab: Tab, openPopup url: String, background: Bool) -> Tab? { nil }
    func tab(_ tab: Tab, fullscreenChanged fullscreen: Bool) {}
    func tabDidUnload(_ tab: Tab) {}
    /// Pages outside a browser window's tabs, such as extension popups, get
    /// no camera or microphone.
    func tab(_ tab: Tab, requestsMedia request: MediaRequest) { tab.answerMediaRequest(request, allow: false) }
    func tabDroppedMediaRequests(_ tab: Tab) {}
    func tab(_ tab: Tab, requestsApp request: AppRequest) {}
}

/// One CEF browser and the view that hosts it, in its profile's request
/// context.
@MainActor
final class Tab {
    weak var delegate: TabDelegate?
    let hostView = BrowserHostView()
    let profile: ProfileContext
    /// What agents and the `tiller` tool call the tab. Unlike `browserID`, it
    /// stays the same while the tab waits to load or is unloaded.
    let id: Int

    private static var nextID = 1

    init(profile: ProfileContext) {
        self.profile = profile
        id = Self.nextID
        Self.nextID += 1
    }

    /// -1 while there is no browser.
    private(set) var browserID: Int32 = -1
    /// Whether the browser exists. A tab restored from the last session waits
    /// for its first selection, so a launch with many tabs loads only one page,
    /// and an unloaded tab waits the same way.
    private(set) var isStarted = false
    /// Waiting for CEF to create the browser of a script's `window.open`. The
    /// core still calls back into the tab, so closing waits for the browser.
    private var awaitsPopup = false
    private var closeWhenCreated = false
    /// CEF's view in `hostView`. Removing it is what destroys the browser.
    private var browserView: NSView?
    /// When the tab was last in front, woken or used by an agent, for
    /// unloading the ones left alone longest.
    var lastActive = Date()
    private(set) var url = ""
    /// The last URL the page actually went to. `url` runs ahead of it while
    /// a load requested here is still on its way.
    private(set) var committedURL = ""
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var favicon: NSImage?
    /// The favicon as the PNG CEF sent, for saving with history.
    private(set) var faviconPNG: Data?
    /// How much of the current load has finished, from 0 to 1.
    private(set) var progress: Double = 1
    /// The devices the page is recording from.
    private(set) var capturing: Set<MediaDevice> = []
    /// Camera and microphone requests waiting for the user, oldest first.
    var mediaRequests: [MediaRequest] = []
    /// The devices macOS refused the page's last request, which the tab
    /// offers to fix in System Settings. Empty when it hasn't.
    var mediaRefused: Set<MediaDevice> = []
    /// The page's latest request to open a link in another app, waiting for
    /// the user. A newer one replaces it, so a page can't pile them up.
    var appRequest: AppRequest?

    /// The URL and title last written to history, so each change is saved once.
    var recordedVisit: (url: String, title: String)?
    /// The favicon last saved for the start page.
    var recordedIcon: Data?
    /// Set when the address bar opened an address in the tab, so the page
    /// it lands on, after any redirects, counts as typed in history.
    var typedNavigation = false

    var isBlank: Bool { Self.isBlank(url) }

    private static func isBlank(_ url: String) -> Bool { url.isEmpty || url == "about:blank" }

    /// True from a load requested on the blank page until that page has had
    /// time to paint. Chromium shows its white blank page meanwhile, so the
    /// window keeps the start page up, which in dark mode saves a white flash.
    private(set) var isLeavingBlank = false
    /// Covers a browser created in dark mode until its first page has had
    /// time to paint, for the same reason.
    private var paintCover: NSView?
    private var paintWait: DispatchWorkItem?
    /// The longest wait from a page's arrival to showing it, for a page
    /// whose load neither ends nor nears its end sooner.
    private static let paintDelay: TimeInterval = 0.25
    /// The wait for a page that arrives with its load already done, as one
    /// from the back/forward cache does.
    private static let cachedPaintDelay: TimeInterval = 0.1
    /// True while such a page waits: its load's end and progress came
    /// before it painted, so only the wait shows it.
    private var waitsOutPaint = false
    /// The longest a cover stays up, should the page's arrival and load
    /// never be heard of.
    private static let coverLimit: TimeInterval = 2

    var displayTitle: String {
        if !title.isEmpty && title != url { return title }
        if isBlank { return "New Tab" }
        return URL(string: url)?.host() ?? url
    }

    /// Keeps `url` and `title` for a later `startIfNeeded`, and shows the
    /// site's saved favicon meanwhile.
    func prepare(url: String, title: String) {
        self.url = url
        self.title = title
        profile.history.icon(for: url) { [weak self] png in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isStarted, self.favicon == nil, let png else { return }
                    self.showFavicon(png)
                    // History has this icon already.
                    self.recordedIcon = png
                    self.delegate?.tabDidChange(self)
                }
            }
        }
    }

    /// Starts a prepared tab's browser. `hostView` must be in a window and sized.
    func startIfNeeded() {
        if !isStarted { start(url: url, title: title) }
    }

    /// Creates the browser inside `hostView`, which must already be in a window
    /// and sized. `title` shows until the page reports its own.
    func start(url: String, title: String = "") {
        isStarted = true
        self.url = url
        committedURL = url
        self.title = title
        let size = hostView.bounds.size
        let callbacks = makeCallbacks()
        let view = Unmanaged.passUnretained(hostView).toOpaque()
        let before = Set(hostView.subviews.map(ObjectIdentifier.init))
        browserID = tiller_browser_create(
            profile.context, Int32(id), view, Int32(size.width), Int32(size.height), url, callbacks)
        // CEF adds its view while creating the browser.
        browserView = hostView.subviews.last { !before.contains(ObjectIdentifier($0)) }
        coverUntilPainted()
    }

    /// In dark mode, hides the new browser's white first paint until the page arrives.
    private func coverUntilPainted() {
        let dark = hostView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard dark && !isBlank else { return }
        let cover = PaintCoverView(frame: hostView.bounds)
        hostView.addSubview(cover, positioned: .above, relativeTo: nil)
        paintCover = cover
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverLimit) { [weak self, weak cover] in
            MainActor.assumeIsolated {
                guard let self, let cover, self.paintCover === cover else { return }
                self.showPage()
            }
        }
    }

    private func makeCallbacks() -> TillerBrowserCallbacks {
        return TillerBrowserCallbacks(
            ctx: Unmanaged.passUnretained(self).toOpaque(),
            address_changed: { ctx, url in
                guard let ctx, let url else { return }
                Tab.from(ctx).addressChanged(String(cString: url))
            },
            title_changed: { ctx, title in
                guard let ctx, let title else { return }
                Tab.from(ctx).titleChanged(String(cString: title))
            },
            loading_state_changed: { ctx, loading, back, forward in
                guard let ctx else { return }
                Tab.from(ctx).loadingStateChanged(loading: loading, back: back, forward: forward)
            },
            favicon_changed: { ctx, png, len in
                guard let ctx else { return }
                let data = png.map { Data(bytes: $0, count: len) } ?? Data()
                Tab.from(ctx).faviconChanged(data)
            },
            open_tab: { ctx, url, background in
                guard let ctx, let url else { return }
                Tab.from(ctx).openTab(String(cString: url), background: background)
            },
            close_ready: { ctx in
                guard let ctx else { return }
                Tab.from(ctx).closeReady()
            },
            key_equivalent: { ctx, event in
                guard let ctx, let event else { return false }
                return Tab.from(ctx).keyEquivalent(UInt(bitPattern: event))
            },
            loading_progress: { ctx, progress in
                guard let ctx else { return }
                Tab.from(ctx).progressChanged(progress)
            },
            find_result: { ctx, count, active, final in
                guard let ctx else { return }
                Tab.from(ctx).findResult(count: Int(count), active: Int(active), final: final)
            },
            auto_resize: { ctx, width, height in
                guard let ctx else { return }
                Tab.from(ctx).autoResized(NSSize(width: Int(width), height: Int(height)))
            },
            copy_text: { ctx, text in
                guard ctx != nil, let text else { return }
                let string = String(cString: text)
                MainActor.assumeIsolated {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(string, forType: .string)
                }
            },
            status_changed: { ctx, text in
                guard let ctx else { return }
                Tab.from(ctx).statusChanged(text.map { String(cString: $0) } ?? "")
            },
            fullscreen_changed: { ctx, fullscreen in
                guard let ctx else { return }
                Tab.from(ctx).fullscreenChanged(fullscreen)
            },
            unload_ready: { ctx in
                guard let ctx else { return }
                Tab.from(ctx).unloadReady()
            },
            popup_tab: { ctx, url, background, tab, size, tabID in
                guard let ctx, let url, let tab, let size, let tabID else { return nil }
                let view = Tab.from(ctx).popupTab(
                    String(cString: url), background: background, callbacks: UInt(bitPattern: tab),
                    size: UInt(bitPattern: size), tabID: UInt(bitPattern: tabID))
                return UnsafeMutableRawPointer(bitPattern: view)
            },
            created: { ctx, id in
                guard let ctx else { return }
                Tab.from(ctx).created(id)
            },
            media_permission: { ctx, id, origin, audio, video in
                guard let ctx, let origin else { return }
                Tab.from(ctx).mediaRequested(id: id, origin: String(cString: origin), audio: audio, video: video)
            },
            media_requests_dropped: { ctx in
                guard let ctx else { return }
                Tab.from(ctx).mediaRequestsDropped()
            },
            media_access_changed: { ctx, audio, video in
                guard let ctx else { return }
                Tab.from(ctx).mediaAccessChanged(audio: audio, video: video)
            },
            external_url: { ctx, url, source, redirect in
                guard let ctx, let url else { return false }
                return Tab.from(ctx).externalURL(
                    String(cString: url), source: source.map { String(cString: $0) } ?? "", redirect: redirect)
            },
            copy_image: { ctx, png, len in
                guard ctx != nil, let png, len > 0 else { return }
                let data = Data(bytes: png, count: len)
                MainActor.assumeIsolated {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                }
            }
        )
    }

    nonisolated private func popupTab(
        _ url: String, background: Bool, callbacks: UInt, size: UInt, tabID: UInt
    ) -> UInt {
        MainActor.assumeIsolated {
            guard let callbacks = UnsafeMutablePointer<TillerBrowserCallbacks>(bitPattern: callbacks),
                  let size = UnsafeMutablePointer<Int32>(bitPattern: size),
                  let tabID = UnsafeMutablePointer<Int32>(bitPattern: tabID),
                  let tab = delegate?.tab(self, openPopup: url, background: background)
            else { return 0 }
            callbacks.pointee = tab.makeCallbacks()
            size[0] = Int32(tab.hostView.bounds.width)
            size[1] = Int32(tab.hostView.bounds.height)
            tabID.pointee = Int32(tab.id)
            return UInt(bitPattern: Unmanaged.passUnretained(tab.hostView).toOpaque())
        }
    }

    nonisolated private func created(_ id: Int32) {
        MainActor.assumeIsolated {
            awaitsPopup = false
            browserID = id
            // CEF added its view to the host view while creating the browser.
            browserView = hostView.subviews.last
            if closeWhenCreated { tiller_browser_close(id) } else { coverUntilPainted() }
        }
    }

    /// Marks a tab whose browser CEF creates itself, for a script's `window.open`.
    func adoptPopup(url: String) {
        isStarted = true
        awaitsPopup = true
        self.url = url
        committedURL = url
    }

    /// The page being waited for arrived: gives it a moment to paint, then
    /// shows it.
    private func pageArrived() {
        guard (isLeavingBlank || paintCover != nil), paintWait == nil else { return }
        let wait = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPage() }
        }
        paintWait = wait
        waitsOutPaint = progress >= 1
        let delay = waitsOutPaint ? Self.cachedPaintDelay : Self.paintDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: wait)
    }

    /// Stops waiting for a first paint, when it has likely happened or the
    /// load ended without one.
    private func showPage() {
        paintWait?.cancel()
        paintWait = nil
        waitsOutPaint = false
        if let cover = paintCover {
            // A new cover is a new view, so this one only ever goes.
            fadeOut(cover) { cover.removeFromSuperview() }
        }
        paintCover = nil
        guard isLeavingBlank else { return }
        isLeavingBlank = false
        delegate?.tabDidChange(self)
    }

    // MARK: Commands

    func load(_ url: String) {
        if isBlank && !Self.isBlank(url) && Self.isBlank(committedURL) { isLeavingBlank = true }
        self.url = url
        tiller_browser_load_url(browserID, url)
    }

    /// Puts `url` back to the page the tab is on, for a requested load of one
    /// of `urls` that turned out to be a download, which leaves the page
    /// where it was.
    func dropPendingLoad(of urls: [String]) {
        guard urls.contains(url), committedURL != url else { return }
        url = committedURL
        isLeavingBlank = false
        delegate?.tabDidChange(self)
    }

    func goBack() { tiller_browser_go_back(browserID) }
    func goForward() { tiller_browser_go_forward(browserID) }
    func reload() { tiller_browser_reload(browserID) }
    func stop() { tiller_browser_stop(browserID) }

    /// Zooms out (`step` < 0), back to 100% (0) or in (> 0).
    func zoom(_ step: Int32) { tiller_browser_zoom(browserID, step) }

    /// The zoom as a factor, 1 for 100%.
    var zoomFactor: Double { browserID < 0 ? 1 : tiller_browser_zoom_factor(browserID) }

    /// Highlights `text` in the page. With `next`, moves to the next or
    /// previous match of the text already searched for.
    func find(_ text: String, forward: Bool = true, next: Bool = false) {
        tiller_browser_find(browserID, text, forward, next)
    }

    func stopFinding() { tiller_browser_stop_finding(browserID) }

    /// Sizes the browser to its page between `min` and `max`, reporting each
    /// new size to the delegate.
    func autoResize(min: NSSize, max: NSSize) {
        tiller_browser_set_auto_resize(
            browserID, Int32(min.width), Int32(min.height), Int32(max.width), Int32(max.height))
    }

    /// Stops sizing the browser to its page; it follows the view's size again.
    func disableAutoResize() { tiller_browser_disable_auto_resize(browserID) }

    /// Runs `code` in the main frame. Does nothing once the tab has closed.
    func executeJavaScript(_ code: String) { tiller_browser_execute_js(browserID, code) }

    /// Opens the system print dialog for the page.
    func print() { tiller_browser_print(browserID) }

    /// Opens Chromium's developer tools in a window of their own.
    func showDevTools() { tiller_browser_show_dev_tools(browserID) }

    /// Takes the page out of the fullscreen it asked for.
    func exitFullscreen() { tiller_browser_exit_fullscreen(browserID) }

    func focus() {
        hostView.window?.makeFirstResponder(hostView)
        tiller_browser_set_focus(browserID, true)
    }

    /// Runs beforeunload, then calls `tabReadyToClose` unless the page cancels.
    func close() {
        if awaitsPopup {
            closeWhenCreated = true
        } else if browserID < 0 {
            delegate?.tabReadyToClose(self)
        } else {
            tiller_browser_close(browserID)
        }
    }

    /// Grants `request` everything it asked for, or denies it, and takes it
    /// off `mediaRequests`.
    func answerMediaRequest(_ request: MediaRequest, allow: Bool) {
        mediaRequests.removeAll { $0.id == request.id }
        tiller_media_permission_answer(request.id, allow)
    }

    /// Stops callbacks. Call before the tab is released.
    func detach() {
        if browserID >= 0 { tiller_browser_detach(browserID) }
    }

    /// Closes the browser to free its memory, keeping the tab, which loads
    /// its page again when next started. Back and forward history, scroll
    /// position and form contents go, as for a tab restored at launch. The
    /// core leaves a page in use alone; otherwise `tabDidUnload` follows.
    func unload() {
        guard isStarted, browserID >= 0 else { return }
        tiller_browser_unload(browserID)
    }

    /// The core agreed to unload: takes the browser's view away, which
    /// destroys the browser, and puts the tab back to waiting.
    private func finishUnload() {
        guard isStarted, browserID >= 0 else { return }
        tiller_browser_detach(browserID)
        browserView?.removeFromSuperview()
        browserView = nil
        browserID = -1
        isStarted = false
        // The page the tab was on, not one it was still on its way to.
        if !Self.isBlank(committedURL) { url = committedURL }
        isLoading = false
        progress = 1
        canGoBack = false
        canGoForward = false
        paintWait?.cancel()
        paintWait = nil
        waitsOutPaint = false
        paintCover?.removeFromSuperview()
        paintCover = nil
        isLeavingBlank = false
        capturing = []
        appRequest = nil
        // The core denied anything still asked when the browser closed.
        if !mediaRequests.isEmpty || !mediaRefused.isEmpty { mediaRequestsDropped() }
        delegate?.tabDidUnload(self)
        delegate?.tabDidChange(self)
    }

    // MARK: Callbacks from CEF, always on the main thread

    nonisolated private static func from(_ ctx: UnsafeMutableRawPointer) -> Tab {
        Unmanaged<Tab>.fromOpaque(ctx).takeUnretainedValue()
    }

    nonisolated private func addressChanged(_ url: String) {
        MainActor.assumeIsolated {
            self.url = url
            committedURL = url
            if !Self.isBlank(url) { pageArrived() }
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func titleChanged(_ title: String) {
        MainActor.assumeIsolated {
            self.title = title
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func loadingStateChanged(loading: Bool, back: Bool, forward: Bool) {
        MainActor.assumeIsolated {
            // A new load starts from nothing rather than the last one's end.
            if loading && !isLoading { progress = 0 }
            let ended = isLoading && !loading
            isLoading = loading
            canGoBack = back
            canGoForward = forward
            // A load that ended, loaded or not, has nothing more to wait for.
            if ended && !waitsOutPaint { showPage() }
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func progressChanged(_ progress: Double) {
        MainActor.assumeIsolated {
            self.progress = progress
            // Near its end, the page has most likely painted.
            if progress >= 0.9, paintWait != nil, !waitsOutPaint { showPage() }
            delegate?.tabProgressChanged(self)
        }
    }

    nonisolated private func findResult(count: Int, active: Int, final: Bool) {
        MainActor.assumeIsolated { delegate?.tab(self, foundMatches: count, active: active, final: final) }
    }

    nonisolated private func autoResized(_ size: NSSize) {
        MainActor.assumeIsolated { delegate?.tab(self, autoResizedTo: size) }
    }

    nonisolated private func statusChanged(_ text: String) {
        MainActor.assumeIsolated { delegate?.tab(self, statusChanged: text) }
    }

    nonisolated private func fullscreenChanged(_ fullscreen: Bool) {
        MainActor.assumeIsolated { delegate?.tab(self, fullscreenChanged: fullscreen) }
    }

    nonisolated private func mediaRequested(id: UInt64, origin: String, audio: Bool, video: Bool) {
        MainActor.assumeIsolated {
            var devices: Set<MediaDevice> = []
            if audio { devices.insert(.microphone) }
            if video { devices.insert(.camera) }
            let request = MediaRequest(id: id, origin: SitePermissions.origin(origin), devices: devices)
            guard let delegate else { return answerMediaRequest(request, allow: false) }
            delegate.tab(self, requestsMedia: request)
        }
    }

    nonisolated private func mediaRequestsDropped() {
        MainActor.assumeIsolated {
            guard !mediaRequests.isEmpty || !mediaRefused.isEmpty else { return }
            mediaRequests = []
            mediaRefused = []
            delegate?.tabDroppedMediaRequests(self)
        }
    }

    nonisolated private func mediaAccessChanged(audio: Bool, video: Bool) {
        MainActor.assumeIsolated {
            var devices: Set<MediaDevice> = []
            if audio { devices.insert(.microphone) }
            if video { devices.insert(.camera) }
            guard devices != capturing else { return }
            capturing = devices
            delegate?.tabDidChange(self)
        }
    }

    /// Hands `url` to the app macOS opens it with, at once when it was typed
    /// into the address bar, and otherwise once the user agrees. Returns
    /// false when no app other than Tiller opens it, which leaves Chromium
    /// to show that it can't.
    nonisolated private func externalURL(_ url: String, source: String, redirect: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard let link = URL(string: url), let app = ExternalApp.handling(link) else { return false }
            let typed = typedNavigation && !redirect && url == self.url
            if url == self.url {
                // The address bar goes back to the page, which stays.
                typedNavigation = false
                let never = committedURL == url
                self.url = never ? "about:blank" : committedURL
                if never { committedURL = self.url }
                isLeavingBlank = false
                delegate?.tabDidChange(self)
            }
            if typed {
                NSWorkspace.shared.open(link)
                return true
            }
            let website = source.hasPrefix("https://") || source.hasPrefix("http://")
            delegate?.tab(self, requestsApp: AppRequest(url: link, origin: website ? SitePermissions.origin(source) : "", app: app))
            return true
        }
    }

    nonisolated private func faviconChanged(_ png: Data) {
        MainActor.assumeIsolated {
            // Pages send the same icon again, as on each navigation.
            guard png != (faviconPNG ?? Data()) else { return }
            showFavicon(png)
            delegate?.tabDidChange(self)
        }
    }

    private func showFavicon(_ png: Data) {
        faviconPNG = png.isEmpty ? nil : png
        favicon = png.isEmpty ? nil : NSImage(data: png)
        favicon?.size = NSSize(width: 16, height: 16)
    }

    nonisolated private func openTab(_ url: String, background: Bool) {
        MainActor.assumeIsolated { delegate?.tab(self, openInNewTab: url, background: background) }
    }

    nonisolated private func unloadReady() {
        // As for a close, the view goes on the next turn of the run loop.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { finishUnload() }
        }
    }

    nonisolated private func closeReady() {
        // CEF is inside its close sequence here. Remove the view on the next
        // turn of the run loop rather than from inside the callback.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { delegate?.tabReadyToClose(self) }
        }
    }

    /// `event` is the NSEvent's address, which crosses into the main actor as a
    /// plain integer because raw pointers aren't Sendable.
    nonisolated private func keyEquivalent(_ event: UInt) -> Bool {
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: event) else { return false }
            let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
            // CEF can pair a key event with a mouse NSEvent, and reading the
            // characters of a non-key event raises an AppKit assertion.
            guard event.type == .keyDown else { return false }
            return delegate?.tab(self, performKeyEquivalent: event) ?? false
        }
    }
}

/// Hosts CEF's view and keeps it the size of the tab area.
/// The window's background over a page that hasn't painted yet.
private final class PaintCoverView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.background.layerColor
    }

    // Clicks wait for the page rather than landing on what can't be seen.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BrowserHostView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }

    // A cover or start page fading out, at alpha 0 already, lets clicks
    // through to the page it is uncovering.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for view in subviews.reversed() where view.alphaValue > 0 {
            if let hit = view.hitTest(local) { return hit }
        }
        return self
    }
}
