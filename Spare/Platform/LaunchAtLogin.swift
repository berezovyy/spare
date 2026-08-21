import Foundation
import ServiceManagement

/// The login item lives in `SMAppService`, never in UserDefaults: the service is the truth, and
/// Debug's bundle id registers a separate item from Release's, which is what keeps them apart.
enum LaunchAtLogin {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration throws for an unsigned or moved bundle; log it rather than trap the app.
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Spare: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
