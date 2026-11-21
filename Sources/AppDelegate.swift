import AppKit
import SwiftUI

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private var statusItem: NSStatusItem?
    private var store: NowPlayingStore!
    private var overlay: OverlayWindowController!
    private var lockOverlay: OverlayWindowController!
    private var lockMonitor: LockMonitor!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Encore keeps its own small caches; the default HTTP disk cache only piled up covers and album pages.
        URLCache.shared = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0)
        removeStaleHTTPCache()
        store = NowPlayingStore(backends: makeBackends())
        let lyrics = LyricsStore(store: store, client: LRCLibClient(cacheDirectory: cacheDirectory()))
        let motion = MotionArtworkProvider(
            client: AppleMusicMotionClient(), store: store)
        store.start(); lyrics.start()

        overlay = OverlayWindowController(rootView: AnyView(
            NowPlayingView(store: store, lyrics: lyrics, motion: motion, mode: .fullscreen)))
        lockOverlay = OverlayWindowController(rootView: AnyView(
            NowPlayingView(store: store, lyrics: lyrics, motion: motion, mode: .lockScreen)))
        if OverlayWindowController.debugUnlocked {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.lockOverlay.present(mode: .lockScreen, on: NSScreen.main) }
        }

        lockMonitor = LockMonitor { [weak self] locked in self?.lockChanged(locked) }
        lockMonitor.start()
        setUpStatusItem()
    }

    private func makeBackends() -> [NowPlayingBackend] {
        var backends: [NowPlayingBackend] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter") {
            let script = res.appendingPathComponent("mediaremote-adapter.pl")
            let framework = res.appendingPathComponent("MediaRemoteAdapter.framework")
            if MediaRemoteAdapterBackend.isUsable(scriptURL: script, frameworkURL: framework) {
                backends.append(MediaRemoteAdapterBackend(scriptURL: script, frameworkURL: framework))
            }
        }
        backends.append(BrowserBackend())
        return backends
    }

    private func removeStaleHTTPCache() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "Encore")
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    private func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Encore").appendingPathComponent("lyrics", isDirectory: true)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note.house", accessibilityDescription: "Encore")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Fullscreen Player", action: #selector(showFullscreen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Encore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func showFullscreen() {
        if overlay.isPresented { overlay.dismiss(); return }
        NSApp.activate(ignoringOtherApps: true)
        overlay.present(mode: .fullscreen, on: NSScreen.main)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Encore Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func lockChanged(_ locked: Bool) {
        guard locked else { lockOverlay.dismiss(); return }
        let hasTrack = store.snapshot.track != nil
        guard hasTrack, Settings.shared.showOnLockScreen, !lockOverlay.isPresented else { return }
        overlay.dismiss()
        lockOverlay.present(mode: .lockScreen, on: NSScreen.main)
    }
}
