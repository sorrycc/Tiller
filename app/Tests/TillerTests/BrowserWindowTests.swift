import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
@MainActor
struct BrowserWindowTests {
    private func makeWindow() -> BrowserWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = MouseEventView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func send(_ type: NSEvent.EventType, button: Int, to window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )!
        let cgEvent = event.cgEvent!
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        NSApp.sendEvent(NSEvent(cgEvent: cgEvent)!)
    }

    @Test(arguments: [3, 4])
    func sideButtonNavigatesOnceOnRelease(button: Int) {
        let window = makeWindow()
        defer { window.close() }
        var back = 0
        var forward = 0
        window.onGoBack = { back += 1 }
        window.onGoForward = { forward += 1 }

        send(.otherMouseDown, button: button, to: window)
        send(.otherMouseDragged, button: button, to: window)
        #expect(back == 0 && forward == 0)
        send(.otherMouseUp, button: button, to: window)
        #expect(back == (button == 3 ? 1 : 0))
        #expect(forward == (button == 4 ? 1 : 0))
        // A page must not also receive the click and navigate a second time.
        #expect((window.contentView as! MouseEventView).buttons.isEmpty)
    }

    @Test(arguments: [2, 5, 6])
    func otherButtonsReachContent(button: Int) {
        let window = makeWindow()
        defer { window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        send(.otherMouseDown, button: button, to: window)
        send(.otherMouseUp, button: button, to: window)
        #expect(navigations == 0)
        #expect((window.contentView as! MouseEventView).buttons == [button, button])
    }

    @Test
    func ordinaryClicksReachContent() {
        let window = makeWindow()
        defer { window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        send(.leftMouseDown, button: 0, to: window)
        send(.leftMouseUp, button: 0, to: window)
        send(.rightMouseDown, button: 1, to: window)
        send(.rightMouseUp, button: 1, to: window)
        #expect(navigations == 0)
        #expect((window.contentView as! MouseEventView).buttons == [0, 0, 1, 1])
    }

    @Test
    func navigationBelongsToEventWindow() {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        var firstBack = 0
        var secondBack = 0
        first.onGoBack = { firstBack += 1 }
        second.onGoBack = { secondBack += 1 }
        first.makeKeyAndOrderFront(nil)

        send(.otherMouseDown, button: 3, to: second)
        send(.otherMouseUp, button: 3, to: second)
        #expect(firstBack == 0)
        #expect(secondBack == 1)
    }

    @Test
    func sheetPreventsNavigation() {
        let window = makeWindow()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        defer { window.endSheet(sheet); sheet.close(); window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        for button in [3, 4] {
            send(.otherMouseDown, button: button, to: window)
            send(.otherMouseUp, button: button, to: window)
        }
        #expect(navigations == 0)
    }

    @Test
    func modalWindowPreventsNavigation() {
        let window = makeWindow()
        let modal = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        modal.isReleasedWhenClosed = false
        let session = NSApp.beginModalSession(for: modal)
        defer { NSApp.endModalSession(session); modal.close(); window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        for button in [3, 4] {
            send(.otherMouseDown, button: button, to: window)
            send(.otherMouseUp, button: button, to: window)
        }
        #expect(navigations == 0)
    }
}

@MainActor
private final class MouseEventView: NSView {
    var buttons: [Int] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { buttons.append(event.buttonNumber) }
    override func mouseUp(with event: NSEvent) { buttons.append(event.buttonNumber) }
    override func rightMouseDown(with event: NSEvent) { buttons.append(event.buttonNumber) }
    override func rightMouseUp(with event: NSEvent) { buttons.append(event.buttonNumber) }
    override func otherMouseDown(with event: NSEvent) { buttons.append(event.buttonNumber) }
    override func otherMouseUp(with event: NSEvent) { buttons.append(event.buttonNumber) }
    override func otherMouseDragged(with event: NSEvent) { buttons.append(event.buttonNumber) }
}
