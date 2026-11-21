import SwiftUI
import AppKit
import AVFoundation

/// Looping, muted, aspect-fill motion artwork. Shows `fallback` (static artwork) until the video is ready.
struct MotionArtworkView: NSViewRepresentable {
    let url: URL?
    let fallback: Data?
    var isPlaying: Bool = true

    init(url: URL?, fallback: Data?, isPlaying: Bool = true) {
        self.url = url
        self.fallback = fallback
        self.isPlaying = isPlaying
    }

    func makeNSView(context: Context) -> MotionHostView { MotionHostView() }

    func updateNSView(_ view: MotionHostView, context: Context) {
        view.setFallback(fallback)
        view.setURL(url)
        view.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ view: MotionHostView, coordinator: ()) { view.teardown() }
}

final class MotionHostView: NSView {
    /// Closing the overlay removes the view from its window: stop streaming right away rather than waiting on SwiftUI.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            let wanted = currentURL
            teardown()
            resumeURL = wanted
        } else if player == nil, let url = resumeURL {
            setURL(url)  // moved back into a window (layout change): pick the stream up again
        }
    }

    private var resumeURL: URL?

    private let imageLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var readyObs: NSKeyValueObservation?
    private var currentURL: URL?
    private var fallbackData: Data?
    private var playing = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setFallback(_ data: Data?) {
        guard data != fallbackData else { return }
        fallbackData = data
        imageLayer.contents = data.flatMap { NSImage(data: $0) }
    }

    func setURL(_ url: URL?) {
        resumeURL = nil
        guard url != currentURL else { return }
        teardown()
        currentURL = url
        guard let url else { return }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredMaximumResolution = CGSize(width: 2048, height: 2048)  // no 4K streams for a lock screen
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: item)
        playerLayer.player = p
        readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.playerLayer.opacity = ready ? 1 : 0 }
        }
        player = p
        if playing { p.play() }
    }

    func setPlaying(_ on: Bool) {
        playing = on
        if on { player?.play() } else { player?.pause() }
    }

    func teardown() {
        readyObs = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        playerLayer.opacity = 0
        player = nil
        currentURL = nil
    }
}
