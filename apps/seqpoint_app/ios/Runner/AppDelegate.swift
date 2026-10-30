import Flutter
import UIKit
import UserNotifications
import SeqpointSyncthing

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let syncQueue = DispatchQueue(label: "com.seqpoint.syncthing")
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SeqpointSyncthing") else { return }
    FlutterMethodChannel(name: "seqpoint/syncthing", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "start" || call.method == "stop" else {
          result(FlutterMethodNotImplemented); return
        }
        let arguments = call.arguments as? [String: String]
        if call.method == "start" && (arguments?["home"] == nil ||
            arguments?["address"] == nil || arguments?["apiKey"] == nil) {
          result(FlutterError(code: "arguments", message: "Missing engine configuration", details: nil))
          return
        }
        self?.syncQueue.async {
          var error: NSError?
          let success = call.method == "start"
            ? MobileStart(arguments?["home"], arguments?["address"], arguments?["apiKey"], &error)
            : MobileStop(&error)
          DispatchQueue.main.async {
            result(success ? nil : FlutterError(code: "engine", message: "Syncthing operation failed", details: nil))
          }
        }
      }
  }
}
