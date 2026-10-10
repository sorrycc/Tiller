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
    /// The page asked for the whole screen, as a video player does, or gave it back.
    func tab(_ tab: Tab, fullscreenChanged fullscreen: Bool)
}

extension TabDelegate {
    func tab(_ tab: Tab, autoResizedTo size: NSSize) {}
    func tab(_ tab: Tab, statusChanged text: String) {}
    func tab(_ tab: Tab, fullscreenChanged fullscreen: Bool) {}
}

/// One CEF browser and the view that hosts it, in its profile's request
/// context.
@MainActor
final class Tab {
    weak var delegate: TabDelegate?
    let hostView = BrowserHostView()
    let profile: ProfileContext

    init(profile: ProfileContext) {
        self.profile = profile
    }

    private(set) var browserID: Int32 = -1
    /// Whether the browser exists. A tab restored from the last session waits
    /// for its first selection, so a launch with many tabs loads only one page.
    private(set) var isStarted = false
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

    /// The URL and title last written to history, so each change is saved once.
    var recordedVisit: (url: String, title: String)?
    /// The favicon last saved for the start page.
    var recordedIcon: Data?

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
    /// From a page's arrival to its likely first paint.
    private static let paintDelay: TimeInterval = 0.25

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
        let callbacks = TillerBrowserCallbacks(
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
            }
        )
        let view = Unmanaged.passUnretained(hostView).toOpaque()
        browserID = tiller_browser_create(profile.context, view, Int32(size.width), Int32(size.height), url, callbacks)
        let dark = hostView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark && !isBlank {
            let cover = PaintCoverView(frame: hostView.bounds)
            hostView.addSubview(cover, positioned: .above, relativeTo: nil)
            paintCover = cover
        }
    }

    /// The page being waited for arrived: gives it a moment to paint, then
    /// shows it.
    private func pageArrived() {
        guard (isLeavingBlank || paintCover != nil), paintWait == nil else { return }
        let wait = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPage() }
        }
        paintWait = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.paintDelay, execute: wait)
    }

    /// Stops waiting for a first paint, when it has likely happened or the
    /// load ended without one.
    private func showPage() {
        paintWait?.cancel()
        paintWait = nil
        paintCover?.removeFromSuperview()
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
        if browserID < 0 {
            delegate?.tabReadyToClose(self)
        } else {
            tiller_browser_close(browserID)
        }
    }

    /// Stops callbacks. Call before the tab is released.
    func detach() {
        if browserID >= 0 { tiller_browser_detach(browserID) }
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
            if ended { showPage() }
            delegate?.tabDidChange(self)
        }
    }

    nonisolated private func progressChanged(_ progress: Double) {
        MainActor.assumeIsolated {
            self.progress = progress
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

    nonisolated private func faviconChanged(_ png: Data) {
        MainActor.assumeIsolated {
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
        layer?.backgroundColor = NSColor.windowBackgroundColor.layerColor
    }

    // Clicks wait for the page rather than landing on what can't be seen.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BrowserHostView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}
