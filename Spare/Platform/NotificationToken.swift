import Foundation

/// RAII handle for a block observation, so `removeObserver` can run in a nonisolated deinit.
/// Teardown is `tokens = []`; nothing anywhere pairs an `addObserver` with a manual removal.
final class NotificationToken {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol, center: NotificationCenter) {
        self.token = token
        self.center = center
    }

    deinit {
        center.removeObserver(token)
    }
}
