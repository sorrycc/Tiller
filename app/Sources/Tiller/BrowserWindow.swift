import AppKit

/// Handles navigation buttons before Chromium's child view takes the event.
/// Keeping this on the browser window also leaves Settings and popups alone.
@MainActor
class BrowserWindow: NSWindow {
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.window === self,
              event.type == .otherMouseDown || event.type == .otherMouseUp || event.type == .otherMouseDragged,
              event.buttonNumber == 3 || event.buttonNumber == 4
        else {
            sendEventToAppKit(event)
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

    // A separate dispatch boundary lets tests check forwarding without an
    // active window or view hit-testing.
    func sendEventToAppKit(_ event: NSEvent) {
        super.sendEvent(event)
    }
}
