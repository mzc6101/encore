import Foundation

struct TrackInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var artwork: Data?
    var sourceBundleID: String?

    var id: String { "\(artist)|\(title)|\(album)" }
}

enum TransportCommand: Equatable {
    case play, pause, togglePlayPause, next, previous, seek(TimeInterval)
}

struct PlaybackSnapshot: Equatable {
    var track: TrackInfo?
    var isPlaying: Bool
    var elapsed: TimeInterval
    var timestamp: Date

    static let empty = PlaybackSnapshot(track: nil, isPlaying: false, elapsed: 0, timestamp: .distantPast)
}

struct LyricLine: Equatable, Identifiable {
    var id: Int
    var time: TimeInterval
    var text: String
}

enum LyricsResult: Equatable {
    case none, loading
    case plain(String)
    case synced([LyricLine])
}

enum DisplayMode { case lockScreen, fullscreen }
