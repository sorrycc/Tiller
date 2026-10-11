import AppKit

/// Handles navigation buttons before Chromium's child view takes the event.
/// Keeping this on the browser window also leaves Settings and popups alone.
@MainActor
final class BrowserWindow: NSWindow {
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.window === self,
              event.type == .otherMouseDown || event.type == .otherMouseUp || event.type == .otherMouseDragged,
              event.buttonNumber == 3 || event.buttonNumber == 4
        else {
            super.sendEvent(event)
            return
        }

        // AppKit numbers buttons from zero: 2 is the middle button, 3/4
        // are Back/Forward on Logitech and other standard five-button mice.
        // Consume the whole click so the page cannot navigate a second time.
        guard event.type == .otherMouseUp, attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if event.buttonNumber == 3 {
            onGoBack?()
        } else {
            onGoForward?()
        }
    }
}
