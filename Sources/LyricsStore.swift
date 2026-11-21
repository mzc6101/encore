import Foundation
import Combine

/// Fetches lyrics when the track changes and tracks the active line at ~30 Hz.
@MainActor
final class LyricsStore: ObservableObject {
    @Published var result: LyricsResult = .none
    @Published var activeIndex: Int?

    private let store: NowPlayingStore
    private let client: LRCLibClient
    private var cancellable: AnyCancellable?
    private var fetchTask: Task<Void, Never>?
    private var timer: Timer?
    private var currentTrackID: String?

    init(store: NowPlayingStore, client: LRCLibClient) {
        self.store = store
        self.client = client
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = store.$snapshot
            .map { $0.track }
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in self?.trackChanged(track) }
        // Lines change every few seconds, so 10 Hz with tolerance is plenty and keeps CPU wakeups low.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        cancellable = nil
        timer?.invalidate(); timer = nil
        fetchTask?.cancel(); fetchTask = nil
    }

    private func trackChanged(_ track: TrackInfo?) {
        fetchTask?.cancel()
        activeIndex = nil
        currentTrackID = track?.id
        guard let track else { result = .none; return }
        result = .loading

        var query = track
        query.title = NowPlayingStore.cleanedTitle(track.title)
        query.artist = NowPlayingStore.cleanedArtist(track.artist)
        let id = track.id
        fetchTask = Task { [weak self, client] in
            let fetched = ProcessInfo.processInfo.environment["ENCORE_DEBUG_LYRICS"] != nil
                ? .synced((0..<150).map { LyricLine(id: $0, time: Double($0) * 2.5, text: "Placeholder lyric line number \($0 + 1)") })
                : await client.lyrics(for: query)
            guard !Task.isCancelled, let self, self.currentTrackID == id else { return }
            self.result = fetched
            self.tick()
        }
    }

    private func tick() {
        if !store.snapshot.isPlaying, activeIndex != nil { return }  // paused: the line can't change
        guard case .synced(let lines) = result else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        let index = lines.activeIndex(at: store.position)
        if index != activeIndex { activeIndex = index }
    }
}
