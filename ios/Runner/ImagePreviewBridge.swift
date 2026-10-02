@preconcurrency import Flutter
import QuickLook
import UIKit

/// Presents only Conduit's staged local images. Authentication stays in Dart.
@MainActor
final class ImagePreviewBridge: NSObject, QLPreviewControllerDataSource,
    @preconcurrency QLPreviewControllerDelegate, UIGestureRecognizerDelegate {
    static let shared = ImagePreviewBridge()
    private var controller: QLPreviewController?
    private var item: NSURL?
    private var completion: FlutterResult?
    private var dismissPan: UIPanGestureRecognizer?
    private var dragAnimation: UIViewPropertyAnimator?
    private var dragStart: CGFloat = 0
    private var closing = false

    /// Registers preview and dismissal calls on the Flutter engine messenger.
    func configure(messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "app.cogwheel.conduit/image_preview", binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                guard let self else { return result(FlutterError(code: "unavailable", message: "Preview unavailable", details: nil)) }
                switch call.method {
                case "open": self.open(call.arguments, result: result)
                case "dismiss":
                    if let controller = self.controller {
                        self.dismiss(controller)
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
        // A full-screen overlay keeps the source visible behind a drag. It
        // never uses the system sheet's presentation or dismissal gesture.
        preview.modalPresentationStyle = .overFullScreen
        closing = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragPreview(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self
        preview.view.addGestureRecognizer(pan)
        dismissPan = pan
        presenter.present(preview, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// Leave controls and zoomed image panning to Quick Look.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl || current is UINavigationBar || current is UIToolbar { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let controller, !closing, controller.presentedViewController == nil,
              controller.transitionCoordinator == nil,
              !hasZoomedContent(controller.view) else { return false }
        let velocity = pan.velocity(in: controller.view)
        return abs(velocity.y) > abs(velocity.x)
    }

    /// Quick Look's own recognizers must still receive image touches.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func hasZoomedContent(_ view: UIView) -> Bool {
        if let scroll = view as? UIScrollView,
           scroll.isZooming || scroll.isZoomBouncing || scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
            return true
        }
        return view.subviews.contains(where: hasZoomedContent)
    }

    /// Track the finger directly; a short drag returns to the full-screen view.
    @objc private func dragPreview(_ pan: UIPanGestureRecognizer) {
        guard let controller, !closing else { return }
        let view = controller.view!
        switch pan.state {
        case .began:
            dragStart = view.layer.presentation()?.affineTransform().ty ?? view.transform.ty
            dragAnimation?.stopAnimation(true)
            dragAnimation = nil
            view.transform = CGAffineTransform(translationX: 0, y: dragStart)
        case .changed:
            if hasZoomedContent(view) {
                // A second finger may start a pinch after this pan begins.
                pan.isEnabled = false
                pan.isEnabled = true
                return
            }
            view.transform = CGAffineTransform(translationX: 0, y: dragStart + pan.translation(in: view.superview).y)
        case .ended, .cancelled, .failed:
            let offset = view.transform.ty
            let velocity = pan.velocity(in: view.superview).y
            let completes = pan.state == .ended &&
                (abs(offset) > view.bounds.height * 0.2 || (abs(velocity) > 800 && offset * velocity > 0))
            let target = completes ? (offset < 0 ? -view.bounds.height : view.bounds.height) : 0
            closing = completes
            if UIAccessibility.isReduceMotionEnabled {
                view.transform = .identity
                if completes { dismiss(controller) }
                return
            }
            let remaining = target - offset
            let timing = UISpringTimingParameters(dampingRatio: 1,
                initialVelocity: CGVector(dx: 0, dy: remaining == 0 ? 0 : velocity / remaining))
            let animation = UIViewPropertyAnimator(duration: 0.25, timingParameters: timing)
            animation.addAnimations { view.transform = CGAffineTransform(translationX: 0, y: target) }
            animation.addCompletion { [weak self, weak controller] position in
                guard let self, let controller, self.controller === controller, position == .end else { return }
                self.dragAnimation = nil
                if completes { self.dismiss(controller) }
            }
            dragAnimation = animation
            animation.startAnimation()
        default: break
        }
    }

    /// All programmatic dismissal paths keep the staged item until UIKit closes.
    private func dismiss(_ controller: QLPreviewController) {
        closing = true
        dismissPan?.isEnabled = false
        dragAnimation?.stopAnimation(true)
        dragAnimation = nil
        guard self.controller === controller, !controller.isBeingDismissed else { return }
        if controller.isBeingPresented, let transition = controller.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.dismiss(controller)
            }
            return
        }
        // Dismiss the entire preview chain, including a native share sheet.
        let presenter = controller.presentingViewController ?? controller
        presenter.dismiss(animated: false) {
            if self.controller === controller { self.finish() }
        }
    }

    func previewControllerWillDismiss(_ controller: QLPreviewController) {
        guard self.controller === controller else { return }
        closing = true
        dismissPan?.isEnabled = false
        dragAnimation?.stopAnimation(true)
        dragAnimation = nil
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
        dragAnimation?.stopAnimation(true)
        dragAnimation = nil
        if let dismissPan { controller?.view.removeGestureRecognizer(dismissPan) }
        dismissPan = nil
        controller = nil
        item = nil
        let result = completion
        completion = nil
        result?(nil)
    }
}
