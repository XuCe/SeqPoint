import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var terminationPending = false

  private var pendingGatewayInvite = false
  private var gatewayChannel: FlutterMethodChannel?

  func attachGateway(to controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "seqpoint/gateway", binaryMessenger: controller.engine.binaryMessenger)
    gatewayChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "take" else { result(FlutterMethodNotImplemented); return }
      let pending = self?.pendingGatewayInvite ?? false
      self?.pendingGatewayInvite = false
      result(pending)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard urls.contains(where: { $0.absoluteString == "seqpoint-gateway://open/paste" }) else {
      super.application(application, open: urls)
      return
    }
    pendingGatewayInvite = true
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    gatewayChannel?.invokeMethod("open", arguments: nil)
  }

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
