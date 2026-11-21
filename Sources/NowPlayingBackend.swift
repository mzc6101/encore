import Foundation

protocol NowPlayingBackend: AnyObject {
    /// Always invoked on the main queue.
    var onUpdate: ((PlaybackSnapshot) -> Void)? { get set }
    func start()
    func stop()
    func send(_ command: TransportCommand)
}
