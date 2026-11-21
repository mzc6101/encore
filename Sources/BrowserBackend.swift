import AppKit
import Foundation

/// AppleScript-driven backend for Music.app, Spotify and YouTube Music tabs in Safari / Chrome.
final class BrowserBackend: NowPlayingBackend {
    enum Player {
        case music, spotify, safariYTM, chromeYTM

        var bundleID: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            case .safariYTM: "com.apple.Safari"
            case .chromeYTM: "com.google.Chrome"
            }
        }
        var appName: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            case .safariYTM: "Safari"
            case .chromeYTM: "Google Chrome"
            }
        }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    private struct Reading {
        var player: Player
        var window = 0
        var tab = 0
        var track: TrackInfo
        var isPlaying: Bool
        var elapsed: TimeInterval
        var artworkURL: URL?
    }

    var onUpdate: ((PlaybackSnapshot) -> Void)?

    private static let sep = "\u{1F}"
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "encore.browser-backend")
    private var timer: DispatchSourceTimer?
    private var target: Reading?
    private var last = PlaybackSnapshot.empty
    private var artworkKey: String?
    private var artworkData: Data?
    private var downloading: String?

    init(pollInterval: TimeInterval = 1.0) {
        self.pollInterval = pollInterval
    }

    static func permissionHint() -> String {
        """
        Allow Encore under System Settings > Privacy & Security > Automation for Music, Spotify, Safari and Chrome. \
        For YouTube Music enable Safari > Develop > Allow JavaScript from Apple Events, \
        or Chrome > View > Developer > Allow JavaScript from Apple Events.
        """
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.pollInterval)
            t.setEventHandler { self.poll() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func send(_ command: TransportCommand) {
        queue.async {
            guard let t = self.target else { return }
            switch t.player {
            case .music, .spotify:
                let verb: String
                switch command {
                case .play: verb = "play"
                case .pause: verb = "pause"
                case .togglePlayPause: verb = "playpause"
                case .next: verb = "next track"
                case .previous: verb = "previous track"
                case .seek(let s): verb = "set player position to \(s)"
                }
                _ = self.run("tell application \"\(t.player.appName)\" to \(verb)")
            case .safariYTM, .chromeYTM:
                _ = self.run(Self.wrap(js: Self.controlJS(command), in: t))
            }
            self.poll()
        }
    }

    // MARK: Polling

    private func poll() {
        var readings: [Reading] = []
        if Player.spotify.isRunning, let r = readSpotify() { readings.append(r) }
        if Player.music.isRunning, let r = readMusic() { readings.append(r) }
        for p in [Player.safariYTM, .chromeYTM] where p.isRunning { readings += readYTM(p) }

        guard let chosen = readings.first(where: \.isPlaying) ?? readings.first else {
            target = nil
            emit(.empty)
            return
        }
        target = chosen
        var track = chosen.track
        track.artwork = artwork(for: chosen)
        emit(PlaybackSnapshot(track: track, isPlaying: chosen.isPlaying, elapsed: chosen.elapsed, timestamp: Date()))
    }

    /// Emits only when something a consumer cannot extrapolate has changed.
    private func emit(_ snap: PlaybackSnapshot) {
        let predicted = last.isPlaying ? last.elapsed + snap.timestamp.timeIntervalSince(last.timestamp) : last.elapsed
        let unchanged = snap.track == last.track && snap.isPlaying == last.isPlaying
            && abs(snap.elapsed - predicted) < 1.5
        guard !unchanged else { return }
        last = snap
        DispatchQueue.main.async { self.onUpdate?(snap) }
    }

    // MARK: Artwork

    private func artwork(for r: Reading) -> Data? {
        if let url = r.artworkURL {
            let key = url.absoluteString
            if key == artworkKey { return artworkData }
            if downloading != key {
                downloading = key
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    self.queue.async {
                        self.downloading = nil
                        guard let data, NSImage(data: data) != nil else { return }
                        self.artworkKey = key
                        self.artworkData = data
                        self.poll()
                    }
                }.resume()
            }
            return nil
        }
        guard r.player == .music else { return nil }
        if artworkKey != r.track.id {
            artworkKey = r.track.id
            let data = run("tell application \"Music\" to return raw data of artwork 1 of current track")?.data
            artworkData = data.flatMap { NSImage(data: $0) != nil ? $0 : nil }
        }
        return artworkData
    }

    // MARK: Readers

    private func readMusic() -> Reading? {
        let src = """
        set d to ASCII character 31
        tell application "Music"
            if player state is stopped then return ""
            set t to current track
            return (name of t) & d & (artist of t) & d & (album of t) & d & (duration of t) & d & player position & d & (player state as text)
        end tell
        """
        guard let f = run(src)?.stringValue?.components(separatedBy: Self.sep), f.count >= 6 else { return nil }
        let track = TrackInfo(title: f[0], artist: f[1], album: f[2], duration: Self.number(f[3]),
                              artwork: nil, sourceBundleID: Player.music.bundleID)
        return Reading(player: .music, track: track, isPlaying: f[5] == "playing", elapsed: Self.number(f[4]))
    }

    private func readSpotify() -> Reading? {
        let src = """
        set d to ASCII character 31
        tell application "Spotify"
            if player state is stopped then return ""
            set t to current track
            return (name of t) & d & (artist of t) & d & (album of t) & d & (duration of t) & d & player position & d & (player state as text) & d & (artwork url of t)
        end tell
        """
        guard let f = run(src)?.stringValue?.components(separatedBy: Self.sep), f.count >= 7 else { return nil }
        let track = TrackInfo(title: f[0], artist: f[1], album: f[2], duration: Self.number(f[3]) / 1000,
                              artwork: nil, sourceBundleID: Player.spotify.bundleID)
        return Reading(player: .spotify, track: track, isPlaying: f[5] == "playing",
                       elapsed: Self.number(f[4]), artworkURL: URL(string: f[6]))
    }

    private static let readJS = """
    (function(){var m=navigator.mediaSession.metadata,v=document.querySelector('video');\
    if(!m||!v)return '';var a=m.artwork&&m.artwork.length?m.artwork[m.artwork.length-1].src:'';\
    return JSON.stringify({t:m.title,a:m.artist,al:m.album,art:a,d:v.duration,p:v.currentTime,playing:!v.paused})})()
    """

    private func readYTM(_ player: Player) -> [Reading] {
        let call = player == .safariYTM
            ? "do JavaScript \"\(Self.escape(Self.readJS))\" in t"
            : "execute t javascript \"\(Self.escape(Self.readJS))\""
        let src = """
        set d to ASCII character 31
        set out to ""
        tell application "\(player.appName)"
            repeat with w in windows
                set wid to id of w
                repeat with i from 1 to (count of tabs of w)
                    set t to tab i of w
                    try
                        if (URL of t) contains "music.youtube.com" then
                            set r to \(call)
                            set out to out & wid & d & i & d & r & linefeed
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return out
        """
        guard let output = run(src)?.stringValue else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: Self.sep)
            guard f.count == 3, let window = Int(f[0]), let tab = Int(f[1]),
                  let obj = try? JSONSerialization.jsonObject(with: Data(f[2].utf8)) as? [String: Any],
                  let title = obj["t"] as? String else { return nil }
            let track = TrackInfo(title: title, artist: obj["a"] as? String ?? "", album: obj["al"] as? String ?? "",
                                  duration: (obj["d"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0,
                                  artwork: nil, sourceBundleID: player.bundleID)
            return Reading(player: player, window: window, tab: tab, track: track,
                           isPlaying: obj["playing"] as? Bool ?? false, elapsed: obj["p"] as? Double ?? 0,
                           artworkURL: Self.largeArtworkURL(obj["art"] as? String))
        }
    }

    // MARK: Helpers

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func wrap(js: String, in r: Reading) -> String {
        let target = "tab \(r.tab) of window id \(r.window)"
        return r.player == .safariYTM
            ? "tell application \"Safari\" to do JavaScript \"\(escape(js))\" in \(target)"
            : "tell application \"Google Chrome\" to execute (\(target)) javascript \"\(escape(js))\""
    }

    private static func controlJS(_ c: TransportCommand) -> String {
        func click(_ sel: String) -> String { "document.querySelector('ytmusic-player-bar \(sel)').click()" }
        let video = "var v=document.querySelector('video');"
        switch c {
        case .togglePlayPause: return click(".play-pause-button")
        case .play: return video + "if(v&&v.paused){\(click(".play-pause-button"))}"
        case .pause: return video + "if(v&&!v.paused){\(click(".play-pause-button"))}"
        case .next: return click(".next-button")
        case .previous: return click(".previous-button")
        case .seek(let t): return video + "if(v)v.currentTime=\(t)"
        }
    }

    private static func largeArtworkURL(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        let big = s.replacingOccurrences(of: #"=w\d+-h\d+.*$"#, with: "=w600-h600", options: .regularExpression)
        return URL(string: big)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
