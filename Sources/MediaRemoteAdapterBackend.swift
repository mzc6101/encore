import Foundation

/// Streams now-playing data from ungive/mediaremote-adapter, run through the system perl
/// (an Apple-signed binary that is allowed to load MediaRemote).
final class MediaRemoteAdapterBackend: NowPlayingBackend {
    var onUpdate: ((PlaybackSnapshot) -> Void)?

    private let perlPath: String
    private let scriptURL: URL
    private let frameworkURL: URL
    private let queue = DispatchQueue(label: "encore.mediaremote-adapter")

    private var process: Process?
    private var wantsRunning = false
    private var backoff: TimeInterval = 1
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var artwork: Data?

    init(perlPath: String = "/usr/bin/perl", scriptURL: URL, frameworkURL: URL) {
        self.perlPath = perlPath
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
    }

    /// Checks the files exist and that `get` runs and exits cleanly. Blocks briefly; call off the hot path.
    static func isUsable(scriptURL: URL, frameworkURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scriptURL.path), fm.fileExists(atPath: frameworkURL.path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [scriptURL.path, frameworkURL.path, "get", "--no-artwork"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func start() {
        queue.async {
            self.wantsRunning = true
            self.launch()
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            self.process?.terminate()
            self.process = nil
        }
    }

    func send(_ command: TransportCommand) {
        let args: [String]
        switch command {
        case .play: args = ["send", "0"]
        case .pause: args = ["send", "1"]
        case .togglePlayPause: args = ["send", "2"]
        case .next: args = ["send", "4"]
        case .previous: args = ["send", "5"]
        case .seek(let t): args = ["seek", String(Int(max(0, t) * 1_000_000))]
        }
        queue.async {
            let p = self.makeProcess(args)
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
        }
    }

    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: perlPath)
        p.arguments = [scriptURL.path, frameworkURL.path] + args
        p.standardError = FileHandle.nullDevice
        return p
    }

    private func launch() {
        guard wantsRunning, process == nil else { return }
        let p = makeProcess(["stream", "--micros"])
        let pipe = Pipe()
        p.standardOutput = pipe
        buffer.removeAll()
        state = [:]
        artwork = nil

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.ingest(data) }
        }
        p.terminationHandler = { [weak self, weak p] _ in
            self?.queue.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.emit(.empty)
                guard self.wantsRunning else { return }
                let delay = self.backoff
                self.backoff = min(self.backoff * 2, 30)
                self.queue.asyncAfter(deadline: .now() + delay) { self.launch() }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            queue.asyncAfter(deadline: .now() + backoff) { self.launch() }
            backoff = min(backoff * 2, 30)
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["type"] as? String == "data",
                  let payload = json["payload"] as? [String: Any] else { continue }
            backoff = 1
            apply(payload, isDiff: json["diff"] as? Bool ?? false)
            emit(snapshot())
        }
    }

    private func apply(_ payload: [String: Any], isDiff: Bool) {
        if !isDiff {
            state = [:]
            artwork = nil
        }
        for (key, value) in payload {
            if value is NSNull {
                state[key] = nil
                if key == "artworkData" { artwork = nil }
            } else {
                state[key] = value
                if key == "artworkData", let b64 = value as? String { artwork = Data(base64Encoded: b64) }
            }
        }
    }

    private func snapshot() -> PlaybackSnapshot {
        guard let title = state["title"] as? String else { return .empty }
        func seconds(_ key: String) -> TimeInterval { (state[key] as? Double).map { $0 / 1_000_000 } ?? 0 }
        let timestamp = (state["timestampEpochMicros"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        let track = TrackInfo(
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            duration: seconds("durationMicros"),
            artwork: artwork,
            sourceBundleID: state["bundleIdentifier"] as? String)
        return PlaybackSnapshot(track: track, isPlaying: state["playing"] as? Bool ?? false,
                                elapsed: seconds("elapsedTimeMicros"), timestamp: timestamp)
    }

    private func emit(_ snapshot: PlaybackSnapshot) {
        DispatchQueue.main.async { self.onUpdate?(snapshot) }
    }
}
