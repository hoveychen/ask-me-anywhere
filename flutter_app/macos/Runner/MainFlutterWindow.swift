import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Dock-tile red-dot badge: Dart pushes the unread count over `ama/dock`.
    // This is the Dock badge, distinct from the notification-centre badge.
    let dockChannel = FlutterMethodChannel(
      name: "ama/dock",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    dockChannel.setMethodCallHandler { call, result in
      guard call.method == "setBadge" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let count = (call.arguments as? Int) ?? 0
      DispatchQueue.main.async {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
      }
      result(nil)
    }

    super.awakeFromNib()
  }
}
