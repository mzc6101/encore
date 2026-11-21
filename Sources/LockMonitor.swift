import Foundation
import CoreGraphics

/// Reports screen lock/unlock via distributed notifications plus a 1 Hz poll of the session dictionary.
final class LockMonitor {
    private let onChange: (Bool) -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var isLocked = false

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    func start() {
        guard timer == nil else { return }
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                self?.update(locked)
            })
        }
        update(Self.sessionIsLocked())
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.update(Self.sessionIsLocked())
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    private func update(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        onChange(locked)
    }

    private static func sessionIsLocked() -> Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (dict?["CGSSessionScreenIsLocked"] as? Bool) ?? ((dict?["CGSSessionScreenIsLocked"] as? Int) == 1)
    }
}
