import Flutter
import UIKit

public final class NativeAdaptiveToolboxPlugin: NSObject, FlutterPlugin, UIPopoverPresentationControllerDelegate {
    private let channel: FlutterMethodChannel
    private weak var menu: UIAlertController?

    private init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "native_adaptive_toolbox/menu",
                                          binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(NativeAdaptiveToolboxPlugin(channel: channel), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "dismissMenu":
            if let menu = menu {
                menu.dismiss(animated: false)
                didCloseMenu()
            }
            result(nil)
        case "showMenu":
            result(showMenu(call.arguments))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func showMenu(_ arguments: Any?) -> Bool {
        guard #available(iOS 13.0, *), menu == nil,
              let args = arguments as? [String: Any],
              let rect = args["rect"] as? [NSNumber], rect.count == 4,
              let items = args["items"] as? [[String: String]], !items.isEmpty,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                  .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
              var presenter = window.rootViewController else { return false }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { return false }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for (index, item) in items.enumerated() {
            sheet.addAction(UIAlertAction(title: item["label"], style: .default) { [weak self] _ in
                self?.channel.invokeMethod("onAction", arguments: index)
                self?.didCloseMenu()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.didCloseMenu()
        })
        if let popover = sheet.popoverPresentationController {
            // Flutter supplies physical pixels. UIKit anchors the popover in points.
            let points = rect.map { CGFloat($0.doubleValue) / window.screen.scale }
            popover.sourceView = window
            popover.sourceRect = CGRect(x: points[0], y: points[1],
                                        width: max(1, points[2] - points[0]),
                                        height: max(1, points[3] - points[1]))
            popover.delegate = self
        }
        sheet.presentationController?.delegate = self
        menu = sheet
        presenter.present(sheet, animated: true)
        return true
    }

    private func didCloseMenu() {
        menu = nil
        channel.invokeMethod("onDismiss", arguments: nil)
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === menu { didCloseMenu() }
    }
}
