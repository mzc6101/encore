import AppKit

/// Encore only follows Apple Music, Spotify and YouTube Music. Browser audio counts only when the browser has a
/// YouTube Music tab open (checked once per track from its tab list), or it's the installed YouTube Music web app.
@MainActor
final class SourceFilter {
    private static let apps: Set<String> = ["com.apple.Music", "com.spotify.client"]
    /// Chromium web-app id of music.youtube.com (same in Chrome, Edge, Brave).
    private static let youTubeMusicWebApp = ".app.cinhimbnkkaeohfgghhklpknlkffjgod"
    private static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.Browser": "Arc", "com.apple.Safari": "Safari",
    ]

    var onVerdict: (() -> Void)?
    private var verdicts: [String: Bool] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "encore.source-filter")

    /// true: show it; false: ignore it; nil: still checking the browser.
    func allows(_ track: TrackInfo) -> Bool? {
        guard let source = track.sourceBundleID else { return false }
        if Self.apps.contains(source) || source.hasSuffix(Self.youTubeMusicWebApp) { return true }
        let browser = source.hasPrefix("com.apple.WebKit") ? "Safari" : Self.browsers[source]
        guard let browser else { return false }
        if let verdict = verdicts[track.id] { return verdict }
        if !pending.contains(track.id) { check(track.id, in: browser) }
        return nil
    }

    private func check(_ trackID: String, in browser: String) {
        pending.insert(trackID)
        let script = """
        tell application "\(browser)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (URL of t) contains "music.youtube.com" then return true
                end repeat
            end repeat
        end tell
        return false
        """
        queue.async { [weak self] in
            var error: NSDictionary?
            let isYouTubeMusic = NSAppleScript(source: script)?.executeAndReturnError(&error).booleanValue ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(trackID)
                if self.verdicts.count >= 200 { self.verdicts.removeAll() }
                self.verdicts[trackID] = isYouTubeMusic
                self.onVerdict?()
            }
        }
    }
}
