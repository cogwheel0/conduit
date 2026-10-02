@preconcurrency import Flutter
import QuickLook
import UIKit

/// Presents only Conduit's staged local images. Authentication stays in Dart.
@MainActor
final class ImagePreviewBridge: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
    static let shared = ImagePreviewBridge()
    private var controller: QLPreviewController?
    private var item: NSURL?
    private var completion: FlutterResult?

    /// Registers preview and dismissal calls on the Flutter engine messenger.
    func configure(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "app.cogwheel.conduit/image_preview", binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                guard let self else { return result(FlutterError(code: "unavailable", message: "Preview unavailable", details: nil)) }
                switch call.method {
                case "open": self.open(call.arguments, result: result)
                case "dismiss":
                    if let controller = self.controller {
                        controller.dismiss(animated: false) {
                            if self.controller === controller { self.finish() }
                        }
                    }
                    result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            }
    }

    /// Validates the staging boundary and holds the result until Quick Look closes.
    private func open(_ arguments: Any?, result: @escaping FlutterResult) {
        guard controller == nil,
              let args = arguments as? [String: Any], let path = args["path"] as? String else {
            return result(FlutterError(code: "busy", message: "Preview unavailable", details: nil))
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        // path_provider_foundation maps getTemporaryDirectory() to cachesDirectory on iOS.
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("image_previews")
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path),
              QLPreviewController.canPreview(url as NSURL) else {
            return result(FlutterError(code: "unsupported", message: "Cannot preview this image", details: nil))
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return result(FlutterError(code: "unavailable", message: "No active window", details: nil))
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else {
            return result(FlutterError(code: "busy", message: "Window is closing", details: nil))
        }
        let preview = QLPreviewController()
        item = url as NSURL
        completion = result
        controller = preview
        preview.dataSource = self
        preview.delegate = self
        presenter.present(preview, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// Advertises the single image retained for the current presentation.
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { item == nil ? 0 : 1 }

    /// Supplies the retained local file for the advertised preview index.
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        // Quick Look calls only for indices advertised by numberOfPreviewItems.
        precondition(index == 0 && item != nil)
        return item!
    }

    /// Completes only the presentation that is still owned by this bridge.
    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        if self.controller === controller { finish() }
    }

    /// Releases the image and completes the pending Flutter call exactly once.
    private func finish() {
        controller = nil
        item = nil
        let result = completion
        completion = nil
        result?(nil)
    }
}
