import Foundation
import Combine

/// Apple Music animated cover art without a token: find the song's album with the public iTunes Search API,
/// then read the motion video link from the album's public music.apple.com page. Cached per album, misses included.
final class AppleMusicMotionClient: @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var cache: [String: URL?] = [:]

    init(session: URLSession = .shared) { self.session = session }

    func motionArtwork(for track: TrackInfo, storefront: String) async -> URL? {
        guard let album = await albumPage(for: track, storefront: storefront) else { return nil }
        let key = album.absoluteString
        if let hit = locked({ cache[key] }) { return hit }
        let video = await squareVideo(onPage: album)
        locked {
            if cache.count >= 100 { cache.removeAll() }  // a few bytes each, but never unbounded
            cache[key] = video
        }
        return video
    }

    /// The album page of the first search hit whose title and lead artist both match, so we never animate the wrong cover.
    private func albumPage(for track: TrackInfo, storefront: String) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(track.title) \(track.artist)"), .init(name: "entity", value: "song"),
                        .init(name: "limit", value: "8"), .init(name: "country", value: storefront)]
        guard let url = c.url, let (data, _) = try? await session.data(from: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let hit = results.first { TrackMatch.matches(title: $0["trackName"] as? String, artist: $0["artistName"] as? String, track: track) }
        return (hit?["collectionViewUrl"] as? String).flatMap(URL.init(string:))
    }

    /// First HLS playlist after "motionDetailSquare" in the page's embedded data.
    private func squareVideo(onPage page: URL) async -> URL? {
        var req = URLRequest(url: page)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req), let html = String(data: data, encoding: .utf8),
              let start = html.range(of: "\"motionDetailSquare\"") else { return nil }
        let tail = String(html[start.upperBound...].prefix(4000)).replacingOccurrences(of: "\\u002F", with: "/")
        guard let m = tail.range(of: #"https://[^"\s]+\.m3u8"#, options: .regularExpression) else { return nil }
        return URL(string: String(tail[m]))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// Sharp static cover when the player only gives a thumbnail (YouTube Music sends 120 px): Apple's catalog first
/// (2000 px), then Deezer's (1400 px). Both are public, no account. The hit must match title and lead artist.
func staticArtworkURL(for track: TrackInfo) async -> URL? {
    let lead = TrackMatch.leadArtistName(track.artist)
    var apple = URLComponents(string: "https://itunes.apple.com/search")!
    apple.queryItems = [.init(name: "term", value: "\(track.title) \(lead)"), .init(name: "entity", value: "song"), .init(name: "limit", value: "8")]
    if let hit = await searchResults(apple.url, key: "results").first(where: {
        TrackMatch.matches(title: $0["trackName"] as? String, artist: $0["artistName"] as? String, track: track)
    }), let s = hit["artworkUrl100"] as? String {
        return URL(string: s.replacingOccurrences(of: #"/\d+x\d+bb"#, with: "/2000x2000bb", options: .regularExpression))
    }
    var deezer = URLComponents(string: "https://api.deezer.com/search")!
    deezer.queryItems = [.init(name: "q", value: "\(lead) \(track.title)"), .init(name: "limit", value: "5")]
    if let hit = await searchResults(deezer.url, key: "data").first(where: {
        TrackMatch.matches(title: $0["title"] as? String, artist: ($0["artist"] as? [String: Any])?["name"] as? String, track: track)
    }), let s = (hit["album"] as? [String: Any])?["cover_xl"] as? String {
        return URL(string: s.replacingOccurrences(of: "1000x1000", with: "1400x1400"))
    }
    return nil
}

private func searchResults(_ url: URL?, key: String) async -> [[String: Any]] {
    guard let url, let (data, _) = try? await URLSession.shared.data(from: url),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
    return json[key] as? [[String: Any]] ?? []
}

/// Loose but safe matching of catalog results to the playing track.
enum TrackMatch {
    /// Lowercased letters and digits only, with bracketed extras like "(Remastered)" dropped.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// "Drake, Future & X feat. Y" -> "Drake"
    static func leadArtistName(_ s: String) -> String {
        let first = s.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? s
        return (first.components(separatedBy: " feat").first ?? first).trimmingCharacters(in: .whitespaces)
    }

    /// Edits like "(Slowed)" usually have their own cover, so they only match the same kind of edit.
    private static let editWords = ["slowed", "sped up", "speed up", "reverb", "nightcore", "remix"]

    static func matches(title: String?, artist: String?, track: TrackInfo) -> Bool {
        guard let title, let artist else { return false }
        let want = normalize(track.title), got = normalize(title), lead = normalize(leadArtistName(track.artist))
        guard !lead.isEmpty, !want.isEmpty, normalize(leadArtistName(artist)) == lead else { return false }
        let a = track.title.lowercased(), b = title.lowercased()
        guard editWords.allSatisfy({ a.contains($0) == b.contains($0) }) else { return false }
        return got == want || (min(got.count, want.count) >= 4 && (got.contains(want) || want.contains(got)))
    }
}

/// Publishes the motion-artwork HLS URL for the current track (nil while loading, disabled, or unavailable).
@MainActor
final class MotionArtworkProvider: ObservableObject {
    @Published var url: URL?

    private let client: AppleMusicMotionClient
    private var bag = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var currentID: String?
    private var lastTrack: TrackInfo?

    init(client: AppleMusicMotionClient, store: NowPlayingStore) {
        self.client = client
        store.$snapshot
            .map { $0.track }
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in self?.load(track) }
            .store(in: &bag)
        Settings.shared.$useAnimatedArtwork.dropFirst()
            .sink { [weak self] _ in self?.load(self?.lastTrack) }
            .store(in: &bag)
    }

    private func load(_ track: TrackInfo?) {
        lastTrack = track
        task?.cancel()
        if currentID != track?.id { url = nil }
        currentID = track?.id
        guard let track, Settings.shared.useAnimatedArtwork else { url = nil; return }
        if let forced = ProcessInfo.processInfo.environment["ENCORE_DEBUG_MOTION"] { url = URL(string: forced); return }
        if Demo.isOn { url = nil; return }
        let client = client, storefront = Settings.shared.storefront
        task = Task { [weak self] in
            let video = await client.motionArtwork(for: track, storefront: storefront)
            guard !Task.isCancelled, let self, self.currentID == track.id else { return }
            self.url = video
        }
    }
}
