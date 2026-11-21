import SwiftUI

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(max(0, t).rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// System-style media button: white symbol, faint circle on hover, spring squish on press.
struct MediaButton: View {
    let symbol: String
    let size: CGFloat
    var struck = false
    let action: () -> Void
    @StateObject private var hover = HoverState()

    final class HoverState: ObservableObject { @Published var on = false }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .contentTransition(.symbolEffect(.replace))
                .overlay {
                    // Struck out: a diagonal bar across the symbol (there is no slashed SF Symbol for it).
                    if struck {
                        Capsule().fill(.white).frame(width: 2.5, height: size * 1.5).rotationEffect(.degrees(-45))
                            .shadow(color: .black.opacity(0.45), radius: 0, x: 1.5)
                    }
                }
                .frame(width: size * 2, height: size * 2)
                .background(Circle().fill(.white.opacity(hover.on ? 0.12 : 0)))
        }
        .buttonStyle(GlassPressStyle())
        .focusEffectDisabled()
        .onHover { on in withAnimation(.easeOut(duration: 0.15)) { hover.on = on } }
    }
}

/// Liquid-glass press: squish on mouse-down, spring back with a little overshoot on release.
struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// Drag state holder (avoids the @State macro, which needs the SwiftUIMacros plugin missing from Command Line Tools).
final class ScrubDrag: ObservableObject { @Published var fraction: Double? }

/// Elapsed time, progress bar and remaining time on one row; drag the bar to seek.
struct InlineScrubber: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @StateObject private var drag = ScrubDrag()

    init(position: TimeInterval, duration: TimeInterval, onSeek: @escaping (TimeInterval) -> Void) {
        self.position = position
        self.duration = duration
        self.onSeek = onSeek
    }

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, drag.fraction ?? position / duration))
    }

    var body: some View {
        let shown = fraction * duration
        HStack(spacing: 14) {
            Text(formatTime(shown)).frame(minWidth: 38, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white.opacity(0.92)).frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: drag.fraction == nil ? 6 : 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in drag.fraction = min(1, max(0, v.location.x / max(1, geo.size.width))) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.x / max(1, geo.size.width)))
                        drag.fraction = nil
                        if duration > 0 { onSeek(f * duration) }
                    })
                .animation(.easeOut(duration: 0.15), value: drag.fraction == nil)
            }
            .frame(height: 20)
            Text("–" + formatTime(duration - shown)).frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }
}
