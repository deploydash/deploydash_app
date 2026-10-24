import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // After launch, so the engine is running and the view controller is
    // registered: enabling earlier loses the update (no bridge, no engine
    // handshake) and leaves the tree empty.
    // Scan all windows: mainWindow may be nil when launched in background.
    if let viewController = NSApplication.shared.windows.compactMap({ $0.contentViewController as? FlutterViewController }).first {
      deploydash_enableSemantics(viewController.engine)
    } else {
      NSLog("DeployDash: no Flutter view controller at launch; accessibility tree stays VoiceOver-gated")
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    let relayHandled = ProtocolRelayCoordinator.shared.handle(urls: urls)
    super.application(application, open: urls)
    if relayHandled {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
