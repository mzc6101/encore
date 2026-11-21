import SwiftUI
import AppKit

/// Artwork card and a clear Liquid Glass card (title, progress, controls): centred, or on the left with lyrics on the right.
struct NowPlayingView: View {
    @ObservedObject var store: NowPlayingStore
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var motion: MotionArtworkProvider
    @ObservedObject private var settings = Settings.shared
    let mode: DisplayMode

    @StateObject private var ui = UIState()
    @Namespace private var ns

    /// View-local state (avoids the @State macro, unavailable with Command Line Tools only).
    final class UIState: ObservableObject {
        @Published var showLyrics = true
        @Published var presented = false
        @Published var bounce = false
        @Published var compact = false
        @Published var favorite = false
    }

    private static let spring = Animation.spring(response: 0.5, dampingFraction: 0.62)

    init(store: NowPlayingStore, lyrics: LyricsStore, motion: MotionArtworkProvider, mode: DisplayMode) {
        self.store = store
        self.lyrics = lyrics
        self.motion = motion
        self.mode = mode
    }

    private var track: TrackInfo? { store.snapshot.track }

    private var hasLyrics: Bool {
        switch lyrics.result { case .synced, .plain: true; default: false }
    }
    /// Lyrics column shows only when there are lyrics; otherwise the player centres.
    private var lyricsOn: Bool { settings.lyricsEnabled && ui.showLyrics && hasLyrics }
    /// Full-screen animated artwork, used only in the centred (lyrics off) layout.
    private var fullBleed: Bool { settings.useAnimatedArtwork && motion.url != nil && !lyricsOn }
    private static let cardWidth: CGFloat = 440
    private static let cardHeight: CGFloat = 170

    var body: some View {
        GeometryReader { geo in
            // Lock screen: stay between the bottom of the system clock (~25%) and the lock message (~75%).
            let lock = mode == .lockScreen
            let top = geo.size.height * (lock ? 0.255 : 0.1)
            let height = geo.size.height * (lock ? 0.49 : 0.8)
            Group {
                if lyricsOn {
                    HStack(spacing: 56) {
                        playerColumn(height: height)
                        LyricsView(result: lyrics.result, activeIndex: lyrics.activeIndex) { store.send(.seek($0)) }
                            .frame(maxWidth: 640)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.95))))
                    }
                    .padding(.horizontal, 60)
                } else if fullBleed {
                    VStack { Spacer(minLength: 0); card.matchedGeometryEffect(id: "card", in: ns) }
                } else {
                    playerColumn(height: height)
                }
            }
            // Entrance: rise, sharpen and spring into place; small bounce on each new track.
            .scaleEffect((ui.presented ? 1 : 0.86) * (ui.bounce ? 0.97 : 1))
            .offset(y: ui.presented ? 0 : 40)
            .blur(radius: ui.presented ? 0 : 14)
            .opacity(ui.presented ? 1 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .offset(y: top)
        }
        // Backdrop goes behind, not in the stack: its fill image would otherwise size the whole layout.
        .background { backdrop }
        .clipped()
        .preferredColorScheme(.dark)
        .animation(Self.spring, value: lyricsOn)
        .onAppear {
            withAnimation(Self.spring) { ui.presented = true }
            updateCapture()
        }
        .onDisappear {
            ui.presented = false
            AudioLevels.shared.stop()
        }
        .onChange(of: store.snapshot.isPlaying) { _, _ in updateCapture() }
        .onChange(of: track?.id) { _, _ in
            ui.bounce = true
            withAnimation(Self.spring) { ui.bounce = false }
        }
        .task(id: track?.id) {
            ui.favorite = false
            if let track, let state = await Favorite.state(for: track) { ui.favorite = state }
        }
    }

    /// Live waveform: capture audio levels only while the player is on screen and music is playing.
    private func updateCapture() {
        let debugWithoutAudio = OverlayWindowController.debugUnlocked && ProcessInfo.processInfo.environment["ENCORE_DEBUG_AUDIO"] == nil
        if store.snapshot.isPlaying && !debugWithoutAudio { AudioLevels.shared.start() } else { AudioLevels.shared.stop() }
    }

    // MARK: Pieces

    /// Full-screen animated artwork, or a blurred copy of the cover behind the artwork card.
    private var backdrop: some View {
        ZStack {
            Color.black
            if fullBleed {
                MotionArtworkView(url: motion.url, fallback: store.artwork, isPlaying: store.snapshot.isPlaying)
            } else if let image = store.backdropImage {
                Image(nsImage: image).resizable().scaledToFill()
                    .blur(radius: 34).saturation(1.6).scaleEffect(1.2)
                Color.black.opacity(0.3)
            }
            // Just enough shade at the top to keep the system clock legible on bright covers.
            LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Self.spring) { ui.compact.toggle() } }
        .animation(.easeInOut(duration: 0.8), value: track?.id)
    }

    /// Artwork card above the glass card. Tap the artwork to hide the progress row.
    private func playerColumn(height: CGFloat) -> some View {
        let side = min(height - Self.cardHeight - 16, Self.cardWidth)
        return VStack(spacing: 16) {
            artworkCard
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .scaleEffect(store.snapshot.isPlaying ? 1 : 0.94)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: store.snapshot.isPlaying)
                .onTapGesture { withAnimation(Self.spring) { ui.compact.toggle() } }
                .matchedGeometryEffect(id: "art", in: ns)
            card
                .matchedGeometryEffect(id: "card", in: ns)
                .offset(y: ui.presented ? 0 : 24)
                .animation(Self.spring.delay(0.08), value: ui.presented)
        }
    }

    private var artworkCard: some View {
        ZStack { artworkContent.id(track?.id).transition(.opacity.combined(with: .scale(scale: 1.08))) }
            .animation(.easeInOut(duration: 0.5), value: track?.id)
    }

    @ViewBuilder private var artworkContent: some View {
        if settings.useAnimatedArtwork, motion.url != nil {
            MotionArtworkView(url: motion.url, fallback: store.artwork, isPlaying: store.snapshot.isPlaying)
        } else if let image = store.artworkImage {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(.white.opacity(0.1))
                Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                VStack(spacing: 1) {
                    Text(track?.title ?? "Not Playing").font(.system(size: 17, weight: .bold))
                    if let artist = track?.artist, !artist.isEmpty {
                        Text(artist).font(.system(size: 17)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 56)
                HStack {
                    if let format = store.audioFormat {
                        Text(format).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    Spacer()
                    WaveformBars(levels: AudioLevels.shared, isPlaying: store.snapshot.isPlaying)
                }
            }
            if !ui.compact {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    InlineScrubber(position: store.position, duration: track?.duration ?? 0) { store.send(.seek($0)) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            HStack {
                MediaButton(symbol: "quote.bubble", size: 19, struck: !hasLyrics) {
                    withAnimation(Self.spring) { ui.showLyrics.toggle() }
                }
                .opacity(settings.lyricsEnabled ? (hasLyrics && ui.showLyrics ? 1 : 0.55) : 0)
                .disabled(!settings.lyricsEnabled || !hasLyrics)
                Spacer()
                HStack(spacing: 30) {
                    MediaButton(symbol: "backward.fill", size: 22) { store.send(.previous) }
                    MediaButton(symbol: store.snapshot.isPlaying ? "pause.fill" : "play.fill", size: 30) { store.send(.togglePlayPause) }
                    MediaButton(symbol: "forward.fill", size: 22) { store.send(.next) }
                }
                Spacer()
                MediaButton(symbol: ui.favorite ? "star.fill" : "star", size: 19) {
                    guard let track else { return }
                    Task { if let state = await Favorite.toggle(for: track) { withAnimation(.spring) { ui.favorite = state } } }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 10)
        .frame(width: Self.cardWidth)
        .glassEffect((settings.useClearGlass ? Glass.clear : .regular).interactive(), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }
}
