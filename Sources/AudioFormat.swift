import AppKit

/// Audio format badge text ("Lossless", "AAC 256 kbps"). Only Music exposes this, via AppleScript; others return nil.
enum AudioFormat {
    private static let queue = DispatchQueue(label: "encore.audio-format")

    static func current(for track: TrackInfo) async -> String? {
        guard track.sourceBundleID == "com.apple.Music",
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
        let script = """
        tell application "Music" to tell current track to return (kind as text) & "|" & (bit rate as text) & "|" & (sample rate as text)
        """
        let raw: String? = await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                cont.resume(returning: NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue)
            }
        }
        guard let parts = raw?.split(separator: "|", omittingEmptySubsequences: false).map(String.init), parts.count == 3 else { return nil }
        let kind = parts[0].lowercased(), bitRate = Int(parts[1]) ?? 0, sampleRate = Int(parts[2]) ?? 0
        if kind.contains("lossless") || kind.contains("alac") {
            return sampleRate > 48000 ? "Hi-Res Lossless" : "Lossless"
        }
        return bitRate > 0 ? "AAC \(bitRate) kbps" : nil
    }
}
