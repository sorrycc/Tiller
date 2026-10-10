import AppKit
import CTillerCore

RenameMigration.run()
ProfileMigration.run()

// One Tiller runs every profile. When one is running already, it opens the
// profile and links this launch was given, and comes forward.
if let running = Profiles.claimApp() {
    let profile = UserDefaults.standard.string(forKey: "profile")
    let urls = Launch.urls
    if profile != nil || !urls.isEmpty {
        let override = ProcessInfo.processInfo.environment["TILLER_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        if let socket = override ?? Profiles.lastOpen.first.map({ Profiles.socketPath(for: $0.id) }) {
            _ = ControlClient.open(profile: profile, urls: urls, socket: socket)
        }
    }
    NSRunningApplication(processIdentifier: running)?.activate()
    exit(0)
}
SingleProcessMigration.run()

// tiller_core_start installs the NSApplication subclass CEF needs, so it has to
// run before anything touches NSApp. Chromium only loads extensions at startup.
// The first profile to open gets Chromium's global request context and is
// Chromium's startup profile. Its folders exist first, so Chromium checks the
// same paths it was given.
let firstCachePath = Profiles.cachePath(for: Launch.profiles[0])
try? FileManager.default.createDirectory(atPath: firstCachePath, withIntermediateDirectories: true)
let code = tiller_core_start(
    Profiles.chromiumRoot, firstCachePath, ExtensionStore.shared.launchArgument, Settings.remoteDebuggingEnabled ? 9222 : 0
)
if code != 0 { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// CEF runs [NSApp run] and returns after the last browser closes.
tiller_core_run()
