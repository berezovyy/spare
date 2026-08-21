import AppKit

// NSApplication holds its delegate weakly, so the instance lives in a static for the process.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static var shared: AppDelegate?

  // The status item must outlive didFinishLaunching or the menu bar icon disappears.
  private var statusItem: NSStatusItem?

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
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "doc.on.clipboard",
      accessibilityDescription: "Spare"
    )
    item.button?.image?.isTemplate = true
    statusItem = item
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the Settings window later must not quit the agent.
    false
  }
}
