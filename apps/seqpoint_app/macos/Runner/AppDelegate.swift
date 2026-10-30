import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var terminationPending = false

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationPending { return .terminateLater }
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return .terminateCancel
    }
    terminationPending = true
    // A sticky window creates another engine; always ask the main engine to drain.
    let channel = FlutterMethodChannel(
      name: "flutter/platform", binaryMessenger: controller.engine.binaryMessenger,
      codec: FlutterJSONMethodCodec.sharedInstance())
    channel.invokeMethod("System.requestAppExit", arguments: nil) { [weak self] result in
      let response = result as? [String: Any]
      self?.terminationPending = false
      sender.reply(toApplicationShouldTerminate: response?["response"] as? String == "exit")
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
