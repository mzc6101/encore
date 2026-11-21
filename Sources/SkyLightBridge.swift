import AppKit

/// All private SkyLight usage lives here (dlopen/dlsym only; nothing is linked).
enum SkyLightBridge {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias SetLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias DestroyFn = @convention(c) (Int32, UInt64) -> Void

    private struct Symbols {
        let connection: MainConnFn, create: SpaceCreateFn, setLevel: SetLevelFn
        let show: SpacesFn, hide: SpacesFn, add: WindowsSpacesFn, remove: WindowsSpacesFn, destroy: DestroyFn
        let lockLevel: Int32
    }

    /// Open-source fallback (SkyLightWindow); this machine's exported kSLSSpaceAbsoluteLevelScreenLock is 300.
    private static let fallbackLockLevel: Int32 = 400

    private static let symbols: Symbols? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "SLSMainConnectionID"), let cr = dlsym(h, "SLSSpaceCreate"),
              let sl = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let sh = dlsym(h, "SLSShowSpaces"),
              let hi = dlsym(h, "SLSHideSpaces"), let aw = dlsym(h, "SLSAddWindowsToSpaces"),
              let rw = dlsym(h, "SLSRemoveWindowsFromSpaces"), let de = dlsym(h, "SLSSpaceDestroy")
        else { return nil }
        let level = dlsym(h, "kSLSSpaceAbsoluteLevelScreenLock").map { $0.load(as: Int32.self) } ?? fallbackLockLevel
        return Symbols(
            connection: unsafeBitCast(c, to: MainConnFn.self), create: unsafeBitCast(cr, to: SpaceCreateFn.self),
            setLevel: unsafeBitCast(sl, to: SetLevelFn.self), show: unsafeBitCast(sh, to: SpacesFn.self),
            hide: unsafeBitCast(hi, to: SpacesFn.self), add: unsafeBitCast(aw, to: WindowsSpacesFn.self),
            remove: unsafeBitCast(rw, to: WindowsSpacesFn.self), destroy: unsafeBitCast(de, to: DestroyFn.self),
            lockLevel: level)
    }()

    static var isAvailable: Bool { symbols != nil }

    /// Creates a Space at the lock-screen absolute level (not yet shown). nil if symbols are missing.
    static func createLockLevelSpace() -> UInt64? {
        guard let s = symbols else { return nil }
        let cid = s.connection()
        let space = s.create(cid, 1, nil)
        guard space != 0 else { return nil }
        _ = s.setLevel(cid, space, s.lockLevel)
        return space
    }

    static func add(window: NSWindow, toSpace space: UInt64) {
        guard let s = symbols else { return }
        s.add(s.connection(), [window.windowNumber] as CFArray, [space] as CFArray)
    }

    static func remove(window: NSWindow, fromSpace space: UInt64) {
        guard let s = symbols else { return }
        s.remove(s.connection(), [window.windowNumber] as CFArray, [space] as CFArray)
    }

    static func show(space: UInt64) { symbols.map { $0.show($0.connection(), [space] as CFArray) } }
    static func hide(space: UInt64) { symbols.map { $0.hide($0.connection(), [space] as CFArray) } }
    static func destroy(space: UInt64) { symbols.map { $0.destroy($0.connection(), space) } }

    private typealias RegionFn = @convention(c) (UnsafePointer<CGRect>, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias EventShapeFn = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// Limits where the window receives mouse events (window-local, top-left origin); clicks elsewhere reach the window below.
    static func setEventShape(window: NSWindow, rects: [CGRect]) {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let s = symbols, let nr = dlsym(h, "CGSNewRegionWithRectList"),
              let se = dlsym(h, "SLSSetWindowEventShape"), let rr = dlsym(h, "CGSReleaseRegion") else { return }
        var region: UnsafeMutableRawPointer?
        guard unsafeBitCast(nr, to: RegionFn.self)(rects, Int32(rects.count), &region) == 0 else { return }
        _ = unsafeBitCast(se, to: EventShapeFn.self)(s.connection(), UInt32(window.windowNumber), region)
        _ = unsafeBitCast(rr, to: ReleaseFn.self)(region)
    }
}
