import SwiftUI

struct LyricsView: View {
    let result: LyricsResult
    let activeIndex: Int?
    let onSeek: ((TimeInterval) -> Void)?

    init(result: LyricsResult, activeIndex: Int?, onSeek: ((TimeInterval) -> Void)?) {
        self.result = result
        self.activeIndex = activeIndex
        self.onSeek = onSeek
    }

    var body: some View {
        switch result {
        case .none: message("No lyrics")
        case .loading: ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .plain(let text): plain(text)
        case .synced(let lines): synced(lines)
        }
    }

    private func message(_ s: String) -> some View {
        Text(s).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func plain(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 60)
        }
        .mask(fade)
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        row(line)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 240)
            }
            .scrollClipDisabled()
            .mask(fade)
            .onAppear {
                if let i = activeIndex, lines.indices.contains(i) { proxy.scrollTo(lines[i].id, anchor: .center) }
            }
            .onChange(of: activeIndex) { _, new in
                guard let new, lines.indices.contains(new) else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                    proxy.scrollTo(lines[new].id, anchor: .center)
                }
            }
        }
    }

    private func row(_ line: LyricLine) -> some View {
        // Focused: the current line is large and bright; neighbours shrink, fade and soften with distance.
        let distance = activeIndex.map { abs($0 - line.id) } ?? 2
        let active = distance == 0
        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.white)
            .padding(.vertical, 6).padding(.trailing, 12)  // room for the blur so glyph edges aren't cut off
            .scaleEffect(active ? 1 : 0.78, anchor: .leading)
            .opacity(active ? 1 : max(0.12, 0.42 - Double(distance - 1) * 0.12))
            .blur(radius: active ? 0 : min(4, Double(distance) * 1.5))
            .shadow(color: .black.opacity(0.35), radius: 10)  // legible over sharp artwork
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSeek?(line.time) }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: active)
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                               .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}
