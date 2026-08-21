import AppKit

// NSApplication holds its delegate weakly, so the instance lives in a static for the process.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var shared: AppDelegate?

    // Both must outlive didFinishLaunching: the core owns every part of the app, and a released
    // status item takes the menu bar icon with it.
    private var core: AppCore?
    private var statusItem: StatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        // LSUIElement is the plist half of "no Dock icon"; this is the runtime half.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before any scroll view exists. `set`, not `register`: overlay scrollers only.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let core = AppCore()
        statusItem = StatusItem(core: core)
        core.start()
        self.core = core
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the Settings window later must not quit the agent.
        false
    }
}
