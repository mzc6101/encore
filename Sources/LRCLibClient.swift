import Foundation
import CryptoKit

/// LRCLIB lyrics client. `lyrics(for:)` never throws; network failures yield `.none` and are not cached.
final class LRCLibClient {
    private struct Entry: Codable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private enum Outcome { case found(Entry), notFound, failed }

    private static let base = "https://lrclib.net/api"
    private static let userAgent = "Encore/0.1 (https://github.com/mzc6101)"
    private static let negativeTTL: TimeInterval = 7 * 24 * 3600
    private static let durationTolerance: TimeInterval = 8

    private let session: URLSession
    private let cacheDirectory: URL

    init(session: URLSession = .shared, cacheDirectory: URL) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        DispatchQueue.global(qos: .utility).async { Self.prune(cacheDirectory, keep: 500) }
    }

    /// Keep only the newest `keep` cached lyric files (~5 KB each), so the cache can't grow forever.
    private static func prune(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    /// Default location: ~/Library/Application Support/Encore/Lyrics
    static var defaultCacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Encore/Lyrics", isDirectory: true)
    }

    func lyrics(for track: TrackInfo) async -> LyricsResult {
        guard !track.title.isEmpty else { return .none }
        if let cached = readCache(track) { return cached }

        var failed = false
        var entry: Entry?

        let albums = track.album.isEmpty ? [nil] : [track.album, nil]
        for album in albums {
            switch await get(track, album: album) {
            case .found(let e): entry = e
            case .failed: failed = true
            case .notFound: break
            }
            if entry != nil || Task.isCancelled { break }
        }
        if entry == nil && !Task.isCancelled {
            switch await search(track) {
            case .found(let e): entry = e
            case .failed: failed = true
            case .notFound: break
            }
        }
        if Task.isCancelled { return .none }

        if let entry {
            writeCache(track, entry)
            return Self.result(from: entry)
        }
        if !failed { writeCache(track, Entry()) }   // definitive miss: remember for a week
        return .none
    }

    // MARK: Network

    private func get(_ track: TrackInfo, album: String?) async -> Outcome {
        var items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if track.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
        guard let (data, status) = await request("get", items) else { return .failed }
        if status == 404 { return .notFound }
        guard status == 200, let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return .failed }
        return .found(entry)
    }

    private func search(_ track: TrackInfo) async -> Outcome {
        let items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        guard let (data, status) = await request("search", items) else { return .failed }
        guard status == 200, let all = try? JSONDecoder().decode([Entry].self, from: data) else {
            return status == 404 ? .notFound : .failed
        }
        let candidates = all.filter { e in
            track.duration <= 0 || e.duration == nil || abs(e.duration! - track.duration) <= Self.durationTolerance
        }
        func gap(_ e: Entry) -> Double { track.duration > 0 ? abs((e.duration ?? track.duration) - track.duration) : 0 }
        func hasSynced(_ e: Entry) -> Bool { !(e.syncedLyrics ?? "").isEmpty }
        // Prefer synced lyrics, then the closest duration.
        let best = candidates.min { a, b in
            hasSynced(a) != hasSynced(b) ? hasSynced(a) : gap(a) < gap(b)
        }
        return best.map { .found($0) } ?? .notFound
    }

    private func request(_ path: String, _ items: [URLQueryItem]) async -> (Data, Int)? {
        var comps = URLComponents(string: "\(Self.base)/\(path)")!
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        return (data, status)
    }

    // MARK: Mapping

    private static func result(from e: Entry) -> LyricsResult {
        if e.instrumental == true { return .none }
        if let s = e.syncedLyrics, !s.isEmpty {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let p = e.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return .plain(p) }
        return .none
    }

    // MARK: Disk cache (SHA256 of track id)

    private func cacheURL(_ track: TrackInfo) -> URL {
        let hash = SHA256.hash(data: Data(track.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash + ".json")
    }

    private func readCache(_ track: TrackInfo) -> LyricsResult? {
        let url = cacheURL(track)
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        let isMiss = entry.instrumental != true && (entry.syncedLyrics ?? "").isEmpty && (entry.plainLyrics ?? "").isEmpty
        if isMiss, let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) > Self.negativeTTL { return nil }
        return Self.result(from: entry)
    }

    private func writeCache(_ track: TrackInfo, _ entry: Entry) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: cacheURL(track), options: .atomic) }
    }
}
