import Flutter
import UIKit

private func dropdownLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}

private struct NativeDropdownOption {
    let id: String
    let label: String
    let subtitle: String?
    let sfSymbol: String?
    let enabled: Bool
    let destructive: Bool

    init(_ option: PlatformDropdownOption) {
        id = option.id
        label = option.label
        subtitle = option.subtitle
        sfSymbol = option.sfSymbol
        enabled = option.enabled
        destructive = option.destructive
    }

    init?(_ payload: [String: Any]) {
        guard
            let id = payload["id"] as? String,
            !id.isEmpty,
            let label = payload["label"] as? String,
            !label.isEmpty
        else {
            return nil
        }

        self.id = id
        self.label = label
        subtitle = payload["subtitle"] as? String
        sfSymbol = payload["sfSymbol"] as? String
        enabled = payload["enabled"] as? Bool ?? true
        destructive = payload["destructive"] as? Bool ?? false
    }
}

private struct NativeDropdownConfiguration {
    let title: String?
    let message: String?
    let cancelLabel: String
    let options: [NativeDropdownOption]
    let sourceRect: CGRect?

    init?(_ request: PlatformDropdownRequest) {
        options = request.options.map(NativeDropdownOption.init)
        guard !options.isEmpty else {
            return nil
        }
        title = request.title
        message = request.message
        cancelLabel = request.cancelLabel
            ?? dropdownLocalized("native.cancel", "Cancel")
        if let rect = request.sourceRect {
            sourceRect = CGRect(
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height
            )
        } else {
            sourceRect = nil
        }
    }

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return nil
        }

        let rawOptions = payload["options"] as? [[String: Any]] ?? []
        options = rawOptions.compactMap(NativeDropdownOption.init)
        guard !options.isEmpty else {
            return nil
        }

        title = payload["title"] as? String
        message = payload["message"] as? String
        cancelLabel = (payload["cancelLabel"] as? String) ?? dropdownLocalized("native.cancel", "Cancel")

        if let rect = payload["sourceRect"] as? [String: Any],
           let x = rect["x"] as? NSNumber,
           let y = rect["y"] as? NSNumber,
           let width = rect["width"] as? NSNumber,
           let height = rect["height"] as? NSNumber {
            sourceRect = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
        } else {
            sourceRect = nil
        }
    }
}

/// Presents simple option lists with native UIKit menus/action sheets.
final class NativeDropdownBridge: NativeDropdownHostApi {
    static let shared = NativeDropdownBridge()

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        NativeDropdownHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    }

    func show(
        request: PlatformDropdownRequest,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let configuration = NativeDropdownConfiguration(request)
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: dropdownLocalized("native.missingDropdownOptions", "Missing dropdown options"),
                    details: nil
                )))
                return
            }
            self?.show(configuration, completion: completion)
        }
    }

    private func show(
        _ configuration: NativeDropdownConfiguration,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        guard let presenter = topViewController() else {
            completion(.failure(PigeonError(
                code: "PRESENTATION_FAILED",
                message: dropdownLocalized("native.unablePresentDropdown", "Unable to present native dropdown"),
                details: nil
            )))
            return
        }

        let controller = UIAlertController(
            title: configuration.title,
            message: configuration.message,
            preferredStyle: .actionSheet
        )

        configuration.options.forEach { option in
            let style: UIAlertAction.Style = option.destructive
                ? .destructive
                : .default
            let action = UIAlertAction(title: option.label, style: style) { _ in
                completion(.success(option.id))
            }
            action.isEnabled = option.enabled
            if let sfSymbol = option.sfSymbol,
               !sfSymbol.isEmpty {
                action.setValue(UIImage(systemName: sfSymbol), forKey: "image")
            }
            controller.addAction(action)
        }

        controller.addAction(
            UIAlertAction(title: configuration.cancelLabel, style: .cancel) { _ in
                completion(.success(nil))
            }
        )

        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            if let sourceRect = configuration.sourceRect {
                popover.sourceRect = presenter.view.convert(sourceRect, from: nil)
            } else {
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
            }
            popover.permittedArrowDirections = [.up, .down]
        }

        presenter.present(controller, animated: true)
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
