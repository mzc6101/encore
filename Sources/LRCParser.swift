import Foundation

enum LRCParser {
    /// Parses LRC text into time-sorted lines. Supports several timestamps per line,
    /// `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]`, an `[offset:ms]` tag, and ignores
    /// metadata tags such as `[ar:...]` and inline word-sync `<mm:ss.xx>` tags.
    static func parse(_ lrc: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var entries: [(time: TimeInterval, text: String)] = []

        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = timestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
            }
            guard !times.isEmpty else { continue }
            let text = stripWordTags(String(rest)).trimmingCharacters(in: .whitespaces)
            for t in times { entries.append((t, text)) }
        }

        entries.sort { $0.time < $1.time }
        while entries.first?.text.isEmpty == true { entries.removeFirst() }
        return entries.enumerated().map { LyricLine(id: $0.offset, time: max(0, $0.element.time - offset), text: $0.element.text) }
    }

    /// "mm:ss", "mm:ss.xx", "mm:ss.xxx" -> seconds; nil for non-time tags.
    private static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let m = Int(parts[0]), let s = Double(parts[1]), s >= 0 else { return nil }
        return Double(m) * 60 + s
    }

    private static func stripWordTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        return s.replacingOccurrences(of: "<[0-9]+:[0-9.]+>", with: "", options: .regularExpression)
    }
}

extension Array where Element == LyricLine {
    /// Index of the last line whose time <= t, or nil before the first line. Requires time-sorted lines.
    func activeIndex(at t: TimeInterval) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
