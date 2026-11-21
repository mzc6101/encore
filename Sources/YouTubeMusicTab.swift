import AppKit

/// Talks to the open YouTube Music page (tab or installed web app) through the browser's AppleScript.
/// Needs the browser's "Allow JavaScript from Apple Events"; every call returns nil when that's off.
enum YouTubeMusicTab {
    private static let queue = DispatchQueue(label: "encore.ytm-tab")
    private static let chromium: [(prefix: String, app: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("com.brave.Browser", "Brave Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge"), ("company.thebrowser.Browser", "Arc"),
    ]

    /// Runs `js` (single quotes only) in the first music.youtube.com tab of the browser that's playing.
    static func run(_ js: String, source: String) async -> String? {
        let tabLoop: (String, String) -> String = { app, exec in
            """
            tell application "\(app)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) contains "music.youtube.com" then return (\(exec))
                    end repeat
                end repeat
            end tell
            return ""
            """
        }
        let script: String
        if let browser = chromium.first(where: { source.hasPrefix($0.prefix) }) {
            guard running(browser.prefix) else { return nil }
            script = tabLoop(browser.app, "execute t javascript \"\(js)\"")
        } else if source.hasPrefix("com.apple.Safari") || source.hasPrefix("com.apple.WebKit") {
            guard running("com.apple.Safari") else { return nil }
            script = tabLoop("Safari", "do JavaScript \"\(js)\" in t")
        } else {
            return nil
        }
        let out: String? = await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                cont.resume(returning: NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue)
            }
        }
        return out?.isEmpty == false ? out : nil
    }

    /// The page's own cover for the playing song, at full size (Google's image URLs take any size).
    static func artworkURL(for track: TrackInfo) async -> URL? {
        let js = "(function(){var m=navigator.mediaSession&&navigator.mediaSession.metadata;"
            + "if(!m||!m.artwork||!m.artwork.length)return '';return m.title+'\\\\n'+m.artwork[m.artwork.length-1].src;})()"
        guard let source = track.sourceBundleID, let out = await run(js, source: source) else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count == 2, TrackMatch.normalize(parts[0]) == TrackMatch.normalize(track.title) else { return nil }
        let full = parts[1].replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w1400-h1400", options: .regularExpression)
        return URL(string: full)
    }

    private static func running(_ bundlePrefix: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundlePrefix }
    }
}
