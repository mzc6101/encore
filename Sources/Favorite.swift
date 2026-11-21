import AppKit

/// Favourite / like for the current track, where the player allows it: Music's favourite, or the like
/// button of a YouTube Music tab (needs "Allow JavaScript from Apple Events" in the browser). nil = not reachable.
enum Favorite {
    private static let queue = DispatchQueue(label: "encore.favorite")

    static func state(for track: TrackInfo) async -> Bool? { await run(track, toggle: false) }
    static func toggle(for track: TrackInfo) async -> Bool? { await run(track, toggle: true) }

    private static func run(_ track: TrackInfo, toggle: Bool) async -> Bool? {
        guard let source = track.sourceBundleID else { return nil }
        let out: String?
        if source == "com.apple.Music" {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: source).isEmpty else { return nil }
            let read = #"tell application "Music" to return (favorited of current track) as text"#
            let script = toggle ? #"tell application "Music" to set favorited of current track to not (favorited of current track)"# + "\n" + read : read
            out = await withCheckedContinuation { cont in
                queue.async {
                    var error: NSDictionary?
                    cont.resume(returning: NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue)
                }
            }
        } else {
            // Like-button state lives on the player bar; clicking it flips LIKE <-> INDIFFERENT.
            let js = "(function(){var r=document.querySelector('ytmusic-player-bar ytmusic-like-button-renderer');if(!r)return 'none';"
                + "var s=r.getAttribute('like-status');if(\(toggle)){var b=r.querySelector('#button-shape-like button')||r.querySelector('.like');"
                + "if(!b)return 'none';b.click();return s==='LIKE'?'INDIFFERENT':'LIKE';}return s;})()"
            out = await YouTubeMusicTab.run(js, source: source)
        }
        switch out {
        case "true", "LIKE": return true
        case "false", "INDIFFERENT", "DISLIKE": return false
        default: return nil
        }
    }
}
