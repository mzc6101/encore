import AppKit

/// Hosts Apple's own lock-screen views (clock, date, avatar, password box, custom message) from the private
/// LoginUIKit framework. Everything is reached by dlopen + class name + KVC/IMP calls; nothing is linked.
///
/// The hosted views are display-only. Encore never reads, stores or forwards a password or keystroke: LoginUIKit
/// has no authentication of its own, and the window that shows these views lets input fall through to loginwindow.
@MainActor
enum LoginUIHost {
    private static let framework = "/System/Library/PrivateFrameworks/LoginUIKit.framework/LoginUIKit"
    private static let loaded = dlopen(framework, RTLD_NOW) != nil && NSClassFromString("LUI2UIController") != nil

    private static var controller: NSObject?
    private static var users: NSObject?
    private static var container: NSView?

    static var isAvailable: Bool { loaded }

    /// Builds a fresh login UI and returns its screen-sized container view, or nil if LoginUIKit is unusable.
    static func makeView(frame: NSRect) -> NSView? {
        tearDown()
        guard loaded, let cls = NSClassFromString("LUI2UIController") as? NSObject.Type else { return nil }
        quietWiFi()  // before init: the Wi-Fi item starts querying as soon as it's created
        let ui = cls.init()
        guard let clock = object(ui, "bigTimeViewController") as? NSViewController,
              let root = clock.view.superview else { return nil }
        // Detach from Apple's (never shown) window and hide its full-screen opaque vibrancy helper.
        root.removeFromSuperview()
        root.subviews.filter { String(describing: type(of: $0)) == "LUI2VibrancyShadowView" }.forEach { $0.isHidden = true }
        clearBackground(root)
        root.frame = frame
        root.autoresizingMask = [.width, .height]

        // While Encore is showing, the custom lock message is hidden; the user's name goes under the avatar instead.
        (object(ui, "messageViewController") as? NSViewController)?.view.isHidden = true

        controller = ui
        container = root
        startUsers(ui)
        return root
    }

    static func tearDown() {
        container?.removeFromSuperview()
        users?.perform(NSSelectorFromString("stop"))
        container = nil; users = nil; controller = nil
    }

    // MARK: Private

    /// The Wi-Fi status item can't reach the Wi-Fi service from our process and re-queries it in a tight loop
    /// (~60% CPU). Turn its query/monitor methods into no-ops in this process only; the icon keeps its last state.
    private static func quietWiFi() {
        guard let cls = NSClassFromString("LUI2WiFiController") else { return }
        let noop: @convention(block) (AnyObject) -> Void = { _ in }
        for name in ["_beginUIStateQuery", "_requeryUIState", "_invalidateCachedUIStateAfterConnectionLoss", "startMonitoring", "startScanning"] {
            if let m = class_getInstanceMethod(cls, NSSelectorFromString(name)) {
                method_setImplementation(m, imp_implementationWithBlock(noop))
            }
        }
    }

    /// Apple's container paints its own full-screen dim and gradient layers; hide them so our artwork shows through,
    /// and reveal the password field container. Re-applied because LoginUIKit re-lays out after the user list loads.
    private static func clearBackground(_ root: NSView) {
        let apply = {
            let size = root.bounds.size
            for l in root.layer?.sublayers ?? [] where l.frame.width >= size.width && l.delegate == nil {
                if String(describing: type(of: l)) == "LUI2NoAnimationLayer" || l is CAGradientLayer { l.isHidden = true }
            }
            root.subviews.filter { $0.frame.size == CGSize(width: 228, height: 28) }.forEach { $0.isHidden = false }
        }
        apply()
        for delay in [0.5, 1.5, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if container === root { apply() } } }
    }

    private static func object(_ target: NSObject, _ key: String) -> NSObject? {
        target.responds(to: NSSelectorFromString(key)) ? target.value(forKey: key) as? NSObject : nil
    }

    private static func setBool(_ target: NSObject, _ selector: String, _ value: Bool) {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(target.method(for: sel), to: Fn.self)(target, sel, value)
    }

    /// The user list loads asynchronously; hand it to the collection controller once it arrives.
    private static func startUsers(_ ui: NSObject) {
        guard let cls = NSClassFromString("LUIUserController") as AnyObject?,
              let shared = cls.perform(NSSelectorFromString("sharedUserController"))?.takeUnretainedValue() as? NSObject,
              let collection = object(ui, "userCollectionViewController") else { return }
        users = shared
        shared.perform(NSSelectorFromString("start"))
        setBool(collection, "setSingleUserLayoutOnly:", true)
        if let password = object(ui, "passwordViewController") { setBool(password, "setEnabled:", true) }
        setBool(ui, "setPasswordRequired:", true)
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard controller === ui, let list = shared.value(forKey: "users") as? [Any], !list.isEmpty else { return }
                collection.perform(NSSelectorFromString("setUsers:"), with: list)
                collection.perform(NSSelectorFromString("showAvatarPasswordEntry"))
                if let root = container { placeName(in: root, message: object(ui, "messageViewController") as? NSViewController) }
            }
        }
    }

    private static let nameTag = 0x4E414D45  // "NAME"

    /// The user's full name, centred under the avatar (Apple's own label sits beside it in this layout).
    private static func placeName(in root: NSView, message: NSViewController?) {
        message?.view.isHidden = true
        guard let avatar = firstView(in: root, named: "LUI2TrackedImageView") else { return }
        let a = avatar.convert(avatar.bounds, to: root)
        let label = root.viewWithTag(nameTag) as? NSTextField ?? {
            let l = NameLabel(labelWithString: NSFullUserName())
            l.font = .systemFont(ofSize: 15, weight: .semibold)
            l.textColor = .white
            l.alignment = .center
            l.shadow = { let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.35); s.shadowBlurRadius = 6; return s }()
            root.addSubview(l)
            return l
        }()
        label.frame = NSRect(x: a.midX - 160, y: a.minY - 30, width: 320, height: 20)
    }

    private static func firstView(in v: NSView, named name: String) -> NSView? {
        if String(describing: type(of: v)) == name, !v.isHidden { return v }
        for s in v.subviews { if let hit = firstView(in: s, named: name) { return hit } }
        return nil
    }
}

private final class NameLabel: NSTextField {
    override var tag: Int { get { 0x4E414D45 } set {} }
}
