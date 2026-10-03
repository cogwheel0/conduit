import Flutter
import QuickLook
import UIKit

private final class NativeImageViewerItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String?) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Also reports dismissal from `viewDidDisappear`, so the session ends even
/// if Quick Look skips `previewControllerDidDismiss`.
private final class NativeImageViewerController: QLPreviewController {
    var onDismissed: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Ignore the share sheet or other screens covering the viewer.
        guard isBeingDismissed || presentingViewController == nil else { return }
        let onDismissed = self.onDismissed
        self.onDismissed = nil
        onDismissed?()
    }
}

private final class NativeImageViewerSession {
    let items: [NativeImageViewerItem]
    weak var controller: QLPreviewController?
    /// Set once UIKit finishes presenting the viewer.
    var isPresented = false
    let initialIndex: Int
    /// Window-space frame of the tapped thumbnail.
    let sourceFrame: CGRect?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var transitionImage: UIImage?

    init(
        items: [NativeImageViewerItem],
        initialIndex: Int,
        sourceFrame: CGRect?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.items = items
        self.initialIndex = initialIndex
        self.sourceFrame = sourceFrame
        self.completion = completion
    }

    func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }

    func sourceImage() -> UIImage? {
        if transitionImage == nil, let url = items[initialIndex].previewItemURL {
            transitionImage = UIImage(contentsOfFile: url.path)
        }
        return transitionImage
    }
}

/// Shows chat images in Quick Look, which provides paging, zoom, swipe to
/// dismiss, Live Text, and the system share sheet (including Save Image).
///
/// Dart downloads and writes the files before presenting, so server
/// credentials never reach this layer. Dart also deletes the files once
/// `present` completes, which happens after dismissal.
final class NativeImageViewerBridge: NSObject, NativeImageViewerHostApi {
    static let shared = NativeImageViewerBridge()

    private var session: NativeImageViewerSession?

    private override init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        NativeImageViewerHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    }

    func present(
        request: PlatformImageViewerRequest,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.present(request, completion: completion)
        }
    }

    private func present(
        _ request: PlatformImageViewerRequest,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if let session,
           session.controller == nil
            || (session.isPresented && session.controller?.presentingViewController == nil)
        {
            // The previous viewer is gone without reporting its dismissal.
            endSession(session)
        }
        guard session == nil else {
            completion(.failure(PigeonError(
                code: "ALREADY_PRESENTING",
                message: "An image viewer is already visible",
                details: nil
            )))
            return
        }

        let items = request.items.compactMap { item -> NativeImageViewerItem? in
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NativeImageViewerItem(url: url, title: item.title)
        }
        guard items.count == request.items.count, !items.isEmpty else {
            completion(.failure(PigeonError(
                code: "INVALID_ARGS",
                message: "Image viewer files are missing",
                details: nil
            )))
            return
        }

        guard let presenter = topViewController(),
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed,
              // A page Quick Look cannot render would show blank, so let the
              // Flutter viewer handle the whole gallery instead.
              items.allSatisfy({ QLPreviewController.canPreview($0) })
        else {
            completion(.failure(PigeonError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present the image viewer",
                details: nil
            )))
            return
        }

        let initialIndex = min(max(Int(request.initialIndex), 0), items.count - 1)
        let sourceFrame = request.sourceRect.map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        let session = NativeImageViewerSession(
            items: items,
            initialIndex: initialIndex,
            sourceFrame: sourceFrame,
            completion: completion
        )
        self.session = session

        let controller = NativeImageViewerController()
        session.controller = controller
        controller.onDismissed = { [weak self, weak session] in
            guard let self, let session else { return }
            self.endSession(session)
        }
        controller.dataSource = self
        controller.delegate = self
        controller.currentPreviewItemIndex = initialIndex
        // Quick Look only zooms from the source frame when presented full screen.
        controller.modalPresentationStyle = .fullScreen
        controller.overrideUserInterfaceStyle = NativeSheetTheme.shared.isDark ? .dark : .light

        // Quick Look defers its presentation while it prepares the zoom, so
        // `presentingViewController` is still nil when `present` returns.
        presenter.present(controller, animated: true) { [weak self, weak session, weak controller] in
            guard let self, let session else { return }
            guard let controller, controller.presentingViewController != nil else {
                if self.session === session {
                    self.session = nil
                }
                session.finish(.failure(PigeonError(
                    code: "PRESENTATION_FAILED",
                    message: "Unable to present the image viewer",
                    details: nil
                )))
                return
            }
            session.isPresented = true
        }
    }

    /// Completes `present` so Dart can delete the files and open the next viewer.
    private func endSession(_ session: NativeImageViewerSession) {
        if self.session === session {
            self.session = nil
        }
        session.finish(.success(()))
    }

    private func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController

        return topViewController(from: root)
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}

extension NativeImageViewerBridge: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        session?.items.count ?? 0
    }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> QLPreviewItem {
        guard let items = session?.items, items.indices.contains(index) else {
            return NativeImageViewerItem(url: URL(fileURLWithPath: NSTemporaryDirectory()), title: nil)
        }
        return items[index]
    }
}

extension NativeImageViewerBridge: QLPreviewControllerDelegate {
    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        guard let session, session.controller === controller else { return }
        endSession(session)
    }

    // The chat rows are Flutter content, so there is no UIKit view to zoom
    // from. Quick Look zooms from the thumbnail's frame instead, but only for
    // the tapped image; other pages fade.
    func previewController(
        _ controller: QLPreviewController,
        frameFor item: QLPreviewItem,
        inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>
    ) -> CGRect {
        guard let session,
              let frame = session.sourceFrame,
              isInitialItem(item, in: session)
        else { return .zero }
        view.pointee = controller.presentingViewController?.view.window
        return frame
    }

    func previewController(
        _ controller: QLPreviewController,
        transitionImageFor item: QLPreviewItem,
        contentRect: UnsafeMutablePointer<CGRect>
    ) -> UIImage? {
        guard let session, isInitialItem(item, in: session) else { return nil }
        return session.sourceImage()
    }

    func previewController(
        _ controller: QLPreviewController,
        editingModeFor previewItem: QLPreviewItem
    ) -> QLPreviewItemEditingMode {
        // The files are temporary copies that Dart deletes after dismissal.
        .disabled
    }

    private func isInitialItem(
        _ item: QLPreviewItem,
        in session: NativeImageViewerSession
    ) -> Bool {
        (item as? NativeImageViewerItem) === session.items[session.initialIndex]
    }
}
