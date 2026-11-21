import AppKit
import SwiftUI

/// Shows Apple's lock-screen views without taking their clicks.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class OverlayWindow: NSWindow {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsKey }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class OverlayWindowController {
    private let rootView: AnyView
    private var window: OverlayWindow?
    private var lockSpace: UInt64?
    private var glassTimer: Timer?

    init(rootView: AnyView) { self.rootView = rootView }

    var isPresented: Bool { window != nil }

    /// ENCORE_DEBUG_LOCK=1 shows the lock layout in a normal window at launch, so it can be checked without locking.
    static let debugUnlocked = ProcessInfo.processInfo.environment["ENCORE_DEBUG_LOCK"] != nil

    func present(mode: DisplayMode, on screen: NSScreen?) {
        dismiss()
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let f = screen.frame
        let hosting = NSHostingView(rootView: rootView)
        // Lock screen: the system date, time, avatar, password field and message are Apple's own views, layered on top.
        if mode == .lockScreen, ProcessInfo.processInfo.environment["ENCORE_DEBUG_NOLOGIN"] == nil, let login = LoginUIHost.makeView(frame: NSRect(origin: .zero, size: f.size)) {
            let content = NSView(frame: NSRect(origin: .zero, size: f.size))
            hosting.frame = content.bounds
            hosting.autoresizingMask = [.width, .height]
            let overlay = PassThroughView(frame: content.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.addSubview(login)
            content.addSubview(hosting)
            content.addSubview(overlay)
            w.contentView = content
            w.allowsKey = false
        } else {
            w.contentView = hosting
        }
        w.setFrame(f, display: false)

        switch mode {
        case .fullscreen:
            w.level = .screenSaver
            w.onEscape = { [weak self] in self?.dismiss() }
        case .lockScreen:
            w.level = Self.debugUnlocked ? .screenSaver : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        }

        window = w
        w.orderFrontRegardless()
        // SwiftUI can rebuild the glass (entrance, track change), so re-thin its frost every couple of seconds while shown.
        glassTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak w] _ in
            MainActor.assumeIsolated { if let root = w?.contentView?.layer { GlassTuner.clarify(root) } }
        }
        glassTimer?.tolerance = 0.5
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak w] in
                if let root = w?.contentView?.layer { GlassTuner.clarify(root) }
            }
        }
        if mode == .fullscreen { w.makeKey() }

        if mode == .lockScreen, !Self.debugUnlocked, let space = SkyLightBridge.createLockLevelSpace() {
            lockSpace = space
            SkyLightBridge.add(window: w, toSpace: space)
            SkyLightBridge.show(space: space)
            // Only the player band takes clicks; the clock and login controls belong to loginwindow.
            SkyLightBridge.setEventShape(window: w, rects: [CGRect(x: 0, y: f.height * 0.255, width: f.width, height: f.height * 0.49)])
        }
    }

    func dismiss() {
        if let space = lockSpace, let w = window {
            SkyLightBridge.hide(space: space)
            SkyLightBridge.remove(window: w, fromSpace: space)
            SkyLightBridge.destroy(space: space)
        }
        lockSpace = nil
        glassTimer?.invalidate(); glassTimer = nil
        LoginUIHost.tearDown()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}
