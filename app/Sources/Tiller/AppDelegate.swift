import AppKit
import CTillerCore

/// What this launch opens.
@MainActor
enum Launch {
    /// The profiles to open: the one `-profile` names by id or name, else
    /// the ones open when Tiller last quit, else the one used last. Never
    /// empty.
    static let profiles: [String] = {
        if let wanted = UserDefaults.standard.string(forKey: "profile"), let profile = Profiles.find(wanted) {
            return [profile.id]
        }
        let open = Profiles.lastOpen.map(\.id)
        return open.isEmpty ? [Profiles.lastUsed.id] : open
    }()

    /// The profile links given at launch open in: the one `-profile` names,
    /// else the one used last.
    static var linkProfile: String {
        if let wanted = UserDefaults.standard.string(forKey: "profile"), let profile = Profiles.find(wanted) {
            return profile.id
        }
        return Profiles.lastUsed.id
    }

    /// `-url`, then `-openURLs`, one per line, which carries links a launch
    /// passed on.
    nonisolated static var urls: [String] {
        var urls = (UserDefaults.standard.string(forKey: "openURLs") ?? "").split(separator: "\n").map(String.init)
        if let url = UserDefaults.standard.string(forKey: "url") { urls.insert(url, at: 0) }
        return urls
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One Settings window per profile, by profile id.
    private var settingsControllers: [String: SettingsWindowController] = [:]
    /// Links that arrived before launch finished.
    private var pendingURLs: [URL] = []
    private var launched = false

    /// A change of appearance redraws everything on its own; a change of
    /// accent needs a nudge.
    @objc private func themeChanged(_ notification: Notification) {
        Theme.applyAppearance()
        Theme.redrawAll()
    }

    /// The Settings of the profile whose window is in front.
    @objc func showSettings(_ sender: Any?) {
        guard let profile = ProfileContext.active else { return }
        settingsController(for: profile).showWindow(sender)
    }

    private func settingsController(for profile: ProfileContext) -> SettingsWindowController {
        if let controller = settingsControllers[profile.id] { return controller }
        let controller = SettingsWindowController(profile: profile)
        settingsControllers[profile.id] = controller
        return controller
    }

    /// Opens Settings on the pane titled `pane`, for `ui.settings` on the
    /// control socket and the agent's errors.
    func showSettings(pane: String, profile: ProfileContext? = nil) {
        guard let profile = profile ?? ProfileContext.active else { return }
        let controller = settingsController(for: profile)
        controller.showWindow(nil)
        controller.showPane(titled: pane)
    }

    /// The manual, in a new tab.
    @objc func openHelp(_ sender: Any?) {
        openInNewTab("https://github.com/sorrycc/Tiller/tree/main/docs")
    }

    @objc func openGitHub(_ sender: Any?) {
        openInNewTab("https://github.com/sorrycc/Tiller")
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        Task { await CommandLineTool.installAndReport() }
    }

    /// A profile in the Profiles menu. Its id is the item's represented object.
    @objc func openProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ProfileContext.open(id)
    }

    @objc func newProfile(_ sender: Any?) {
        ProfileNamePrompt.run("New Profile", button: "Create", on: nil) { name in
            ProfileContext.open(try Profiles.create(named: name).id)
        }
    }

    @objc func manageProfiles(_ sender: Any?) {
        showSettings(pane: ProfilesSettingsPane.paneTitle)
    }

    /// The Agent pane, from an error about the agent's command.
    func showAgentSettings(profile: ProfileContext? = nil) {
        showSettings(pane: "Agent", profile: profile)
    }

    @objc func manageExtensions(_ sender: Any?) {
        showSettings(pane: ExtensionsSettingsPane.paneTitle)
    }

    /// Opens `url` in a new tab of `profile`'s window, or of the window in
    /// front, for Settings and links in the agent panel.
    func openInNewTab(_ url: String, background: Bool = false, profile: ProfileContext? = nil) {
        (profile ?? ProfileContext.active)?.window?.openInNewTab(url, background: background)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tiller has tabs of its own. This keeps the system's Show Tab Bar and
        // Show All Tabs out of the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
        // Before the first window, so it never shows in the wrong appearance.
        Theme.applyAppearance()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(themeChanged(_:)), name: .themeDidChange, object: nil)
        center.addObserver(self, selector: #selector(profilesChanged(_:)), name: .profilesDidChange, object: nil)
        center.addObserver(self, selector: #selector(profileOpened(_:)), name: .profileDidOpen, object: nil)

        tiller_core_set_quit_handler {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.quitRequested() }
        }

        // Links from other apps and `-url` open in the profile used last,
        // or the one `-profile` names.
        let linkProfile = Launch.linkProfile
        let urls = Launch.urls + pendingURLs.map(\.absoluteString)
        pendingURLs = []
        launched = true
        var profiles = Launch.profiles
        if !urls.isEmpty && !profiles.contains(linkProfile) { profiles.append(linkProfile) }
        for id in profiles {
            ProfileContext.open(id, urls: id == linkProfile ? urls : [])
        }
        DownloadStore.shared.start()
        Updater.shared.start()
        // Extensions open their install pages within seconds of Chromium
        // starting; a launch still running well after that started fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            MainActor.assumeIsolated { ExtensionStore.shared.startedFine() }
        }
    }

    /// The first window to open asks about the default browser, and in debug
    /// builds runs the launch arguments that need one.
    @objc private func profileOpened(_ notification: Notification) {
        guard let profile = notification.object as? ProfileContext else { return }
        guard !askedOnce else { return }
        askedOnce = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak profile] in
            MainActor.assumeIsolated {
                // The default browser question waits for a launch without
                // this notice.
                if ExtensionStore.shared.skippedAfterCrash {
                    self?.explainSkippedExtensions(on: profile?.window?.window)
                } else {
                    DefaultBrowser.askOnce(on: profile?.window?.window)
                }
            }
        }
        #if DEBUG
        runDebugArguments(profile)
        #endif
    }

    private var askedOnce = false

    /// Says why this launch has no extensions, and offers Settings to switch
    /// off the one that crashed it.
    private func explainSkippedExtensions(on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Extensions Are Off for Now"
        alert.informativeText = "Tiller quit unexpectedly right after it last opened, which an extension "
            + "that opens a tab as Tiller starts can cause. Extensions load again the next time Tiller opens. "
            + "To keep one from loading, switch it off in Extensions settings."
        alert.addButton(withTitle: "Manage Extensions…")
        alert.addButton(withTitle: "OK")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.manageExtensions(nil) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    #if DEBUG
    private func runDebugArguments(_ target: ProfileContext) {
        let controller = target.window
        if let prompt = UserDefaults.standard.string(forKey: "agentPrompt") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak controller] in
                MainActor.assumeIsolated { controller?.sendAgentPrompt(prompt) }
            }
        }
        // `-addExtension <path>` adds an unpacked folder or a CRX file and
        // logs the result. It loads at the next launch.
        if let path = UserDefaults.standard.string(forKey: "addExtension") {
            Task {
                do {
                    let manifest = path.hasSuffix(".crx")
                        ? try await ExtensionStore.shared.addCRX(path) : try ExtensionStore.shared.addFolder(path)
                    NSLog("Tiller extension: added %@ (%@)", manifest.name, manifest.id)
                } catch {
                    NSLog("Tiller extension: %@", error.localizedDescription)
                }
            }
        }
        // `-importChrome YES` imports everything from Chrome's last-used
        // profile and logs the result. `-importChrome extensions,history`
        // imports only those.
        if let value = UserDefaults.standard.string(forKey: "importChrome"), value != "NO" {
            let names = Set(value.split(separator: ",").map(String.init))
            let kinds = value == "YES"
                ? Set(ImportKind.allCases) : Set(ImportKind.allCases.filter { names.contains("\($0)") })
            Task {
                do {
                    let (profiles, lastUsed) = try ChromeReader.profiles()
                    guard let profile = profiles.first(where: { $0.directory == lastUsed }) ?? profiles.first else { return }
                    for result in await ChromeImporter.run(profile: profile, into: target, kinds: kinds) {
                        NSLog("Tiller import: %@: %@", result.title, result.error?.localizedDescription ?? result.detail)
                    }
                } catch {
                    NSLog("Tiller import: %@", error.localizedDescription)
                }
            }
        }
    }
    #endif

    /// Web links and HTML files from other apps, with Tiller as the default
    /// browser or chosen in Open With. They open in the profile used last.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingURLs += urls
            return
        }
        IncomingLinks.route(urls)
    }

    /// Clicking the Dock icon with no window showing brings back the window
    /// of the profile used last.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        (ProfileContext.opened(Profiles.lastUsed.id) ?? ProfileContext.all.first)?.show()
        return false
    }

    /// Profiles were added, renamed, removed, opened or closed. With more
    /// than one, each window names its profile in the toolbar and title.
    @objc private func profilesChanged(_ notification: Notification) {
        let several = Profiles.all.count > 1
        for profile in ProfileContext.all {
            profile.window?.showProfile(name: several ? profile.name : nil)
            settingsControllers[profile.id]?.showProfile(name: several ? profile.name : nil)
        }
        settingsControllers = settingsControllers.filter { id, controller in
            if ProfileContext.opened(id) != nil { return true }
            controller.close()
            return false
        }
    }

    /// Cmd+Q, the Dock or logging out. Closes every tab of every profile,
    /// which closes their windows, and the core quits when the last browser
    /// is gone. The core closes only tabs that have a browser, so this can't
    /// be left to it: a restored tab that hasn't loaded yet would be
    /// selected, start, and keep Tiller running. The profiles open now open
    /// again at the next launch.
    fileprivate func quitRequested() {
        ProfileContext.isQuitting = true
        Profiles.setOpen(ProfileContext.all.map(\.id))
        let windows = ProfileContext.all.compactMap(\.window)
        if windows.isEmpty { return tiller_core_quit() }
        windows.forEach { $0.closeAllTabs() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
