import AppKit

/// ENCORE_DEMO=1: a made-up track with generated cover art and original lyrics, and no system lock-screen views,
/// for screenshots with no personal or third-party content. ENCORE_DEMO_NOLYRICS=1 shows the no-lyrics layout.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["ENCORE_DEMO"] != nil
    static let noLyrics = ProcessInfo.processInfo.environment["ENCORE_DEMO_NOLYRICS"] != nil

    static func snapshot() -> PlaybackSnapshot {
        let track = TrackInfo(title: "Night Swim", artist: "Encore Demo", album: "Demo", duration: 214, artwork: artwork())
        return PlaybackSnapshot(track: track, isPlaying: true, elapsed: 64, timestamp: Date())
    }

    static var lyrics: LyricsResult {
        guard !noLyrics else { return .none }
        let lines = [
            "City lights are fading slow", "Every window glowing gold", "We were running through the rain",
            "Calling out each other's names", "Hold the moment, let it stay", "Turn the radio up again",
            "All the streets are open wide", "Nothing left to hide tonight", "Underneath the silver sky",
            "We could stay up, you and I", "Every echo sounds like home", "Never have to walk alone",
        ]
        return .synced((0..<72).map { LyricLine(id: $0, time: Double($0) * 3, text: lines[$0 % lines.count]) })
    }

    /// Abstract cover drawn on the fly: dusk gradient with soft glowing orbs.
    private static func artwork() -> Data? {
        let size = 1400
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(size), space = CGColorSpaceCreateDeviceRGB()
        let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.06, green: 0.05, blue: 0.22, alpha: 1),
                                                          CGColor(red: 0.55, green: 0.12, blue: 0.45, alpha: 1),
                                                          CGColor(red: 0.98, green: 0.52, blue: 0.32, alpha: 1)] as CFArray,
                             locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        for (x, y, r, c) in [(0.3, 0.32, 0.34, CGColor(red: 1, green: 0.78, blue: 0.4, alpha: 0.9)),
                             (0.72, 0.62, 0.26, CGColor(red: 0.35, green: 0.85, blue: 1, alpha: 0.6)),
                             (0.58, 0.18, 0.18, CGColor(red: 1, green: 0.4, blue: 0.6, alpha: 0.55))] {
            let glow = CGGradient(colorsSpace: space, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            let p = CGPoint(x: x * s, y: y * s)
            ctx.drawRadialGradient(glow, startCenter: p, startRadius: 0, endCenter: p, endRadius: r * s, options: [])
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
