import Foundation
import AppKit
import ImageIO

@MainActor
final class NowPlayingStore: ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot.empty

    /// Hi-res (iTunes, 2000x2000) artwork for the current track, fetched when the player's own artwork is under 1200 px.
    @Published private var hiResByTrack: [String: Data] = [:]
    private var hiResRequested: Set<String> = []

    /// Best artwork for the current track: hi-res when available, else what the player reported.
    var artwork: Data? { snapshot.track.flatMap { hiResByTrack[$0.id] ?? $0.artwork } }

    /// Decoded artwork, cached so views don't re-decode the image on every update.
    var artworkImage: NSImage? {
        guard let track = snapshot.track, let data = artwork else { return nil }
        let key = "\(track.id)|\(data.count)"
        if let cached = imageCache, cached.key == key { return cached.image }
        let image = NSImage(data: data)
        imageCache = image.map { (key, $0) }
        return image
    }
    private var imageCache: (key: String, image: NSImage)?

    /// Small copy of the artwork for the blurred backdrop: blurring a 256 px image is far cheaper than a 2000 px one.
    var backdropImage: NSImage? {
        guard let track = snapshot.track, let data = artwork else { return nil }
        let key = "\(track.id)|\(data.count)"
        if let cached = backdropCache, cached.key == key { return cached.image }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        backdropCache = (key, image)
        return image
    }
    private var backdropCache: (key: String, image: NSImage)?
    private let filter = SourceFilter()
    /// Audio format of the current track, when the player exposes it.
    @Published private(set) var audioFormat: String?
    private var formatTrackID: String?

    private let backends: [NowPlayingBackend]
    private var raw: [PlaybackSnapshot]
    private var latest: [PlaybackSnapshot]
    private var emptySince: [Date?]
    private var active: Int?
    private var timer: Timer?
    private let grace: TimeInterval = 3

    var position: TimeInterval {
        var t = snapshot.elapsed
        if snapshot.isPlaying { t += Date().timeIntervalSince(snapshot.timestamp) }
        let duration = snapshot.track?.duration ?? 0
        return duration > 0 ? min(max(t, 0), duration) : max(t, 0)
    }

    /// Backends are in priority order; the first one reporting a track wins, and a lower one
    /// only takes over after the active one has had no track for more than 3 seconds.
    init(backends: [NowPlayingBackend]) {
        self.backends = backends
        latest = Array(repeating: .empty, count: backends.count)
        raw = latest
        emptySince = Array(repeating: Date(), count: backends.count)
        for (i, backend) in backends.enumerated() {
            backend.onUpdate = { [weak self] snap in self?.receive(snap, from: i) }
        }
        filter.onVerdict = { [weak self] in
            guard let self else { return }
            for i in raw.indices { apply(raw[i], at: i) }
            evaluate()
        }
    }

    /// Only the first backend runs normally; fallbacks (AppleScript polling is costly) start only while it has nothing.
    private var fallbacksRunning = false

    func start() {
        backends.first?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func send(_ c: TransportCommand) {
        backends[active ?? 0].send(c)
    }

    private func receive(_ snap: PlaybackSnapshot, from i: Int) {
        raw[i] = snap
        apply(snap, at: i)
        evaluate()
    }

    /// Anything that isn't Apple Music, Spotify or YouTube Music counts as nothing playing.
    private func apply(_ snap: PlaybackSnapshot, at i: Int) {
        var snap = snap
        if let track = snap.track, filter.allows(track) != true { snap = .empty }
        latest[i] = snap
        if snap.track != nil { emptySince[i] = nil } else if emptySince[i] == nil { emptySince[i] = Date() }
    }

    private func evaluate() {
        let now = Date()
        let best = latest.firstIndex { $0.track != nil }
        let activeSilent = active.map { latest[$0].track == nil && now.timeIntervalSince(emptySince[$0] ?? now) > grace } ?? true

        if let best {
            let holding = active.map { latest[$0].track == nil && !activeSilent } ?? false
            if !holding { active = best }
        } else if activeSilent {
            active = nil
        }
        let primaryIdle = latest.first?.track == nil && now.timeIntervalSince(emptySince.first.flatMap { $0 } ?? now) > grace
        if primaryIdle != fallbacksRunning {
            fallbacksRunning = primaryIdle
            backends.dropFirst().forEach { primaryIdle ? $0.start() : $0.stop() }
        }
        let next = active.map { latest[$0] } ?? .empty
        if next != snapshot { snapshot = next }
        if let track = next.track { fetchHiResIfNeeded(track) }
        if next.track?.id != formatTrackID { probeFormat(next.track) }
    }

    private func probeFormat(_ track: TrackInfo?) {
        formatTrackID = track?.id
        audioFormat = nil
        guard let track else { return }
        Task { [weak self] in
            let format = await AudioFormat.current(for: track)
            guard let self, self.formatTrackID == track.id else { return }
            self.audioFormat = format
        }
    }

    private static func pixelWidth(_ data: Data?) -> Int {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
        return props[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    private func fetchHiResIfNeeded(_ track: TrackInfo) {
        let id = track.id
        guard !hiResRequested.contains(id), Self.pixelWidth(track.artwork) < 1200 else { return }
        hiResRequested = [id]  // only the current track's cover is ever kept, so memory doesn't grow per song
        Task { [weak self] in
            let fromYouTubeMusic = !["com.apple.Music", "com.spotify.client"].contains(track.sourceBundleID ?? "")
            var url = fromYouTubeMusic ? await YouTubeMusicTab.artworkURL(for: track) : nil
            if url == nil { url = await staticArtworkURL(for: track) }
            guard let url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  Self.pixelWidth(data) > 0 else { return }
            guard let self, self.snapshot.track?.id == id else { return }
            self.hiResByTrack = [id: data]
        }
    }

    // MARK: Cleaning for lyric lookup

    private static let titleNoise = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^\)\]]*\b(official|lyrics?|audio|video|visuali[sz]er|hd|hq|4k|mv|m/v|remaster(ed)?|explicit|feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]"#,
        options: .caseInsensitive)
    private static let titleSuffix = try! NSRegularExpression(
        pattern: #"\s*[-|]\s*(official\s+(music\s+)?(video|audio)|lyric video|lyrics|audio|visuali[sz]er)\s*$|\s+(feat\.?|ft\.?|featuring)\s.*$"#,
        options: .caseInsensitive)
    private static let artistNoise = try! NSRegularExpression(
        pattern: #"\s*-\s*topic\s*$|\s*VEVO\s*$|\s+(feat\.?|ft\.?|featuring)\s.*$"#,
        options: .caseInsensitive)

    private static func strip(_ s: String, _ regexes: [NSRegularExpression]) -> String {
        var out = s
        for re in regexes {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? s : out
    }

    static func cleanedTitle(_ s: String) -> String { strip(s, [titleNoise, titleSuffix]) }
    static func cleanedArtist(_ s: String) -> String { strip(s, [artistNoise]) }
}
