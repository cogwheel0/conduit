import Flutter
import UIKit

private struct NativeDropdownOption {
    let id: String
    let label: String
    let subtitle: String?
    let sfSymbol: String?
    let enabled: Bool
    let destructive: Bool

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
        cancelLabel = (payload["cancelLabel"] as? String) ?? "Cancel"

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
final class NativeDropdownBridge {
    static let shared = NativeDropdownBridge()

    private static let channelName = "conduit/native_dropdown"

    private var channels: [FlutterMethodChannel] = []

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        channels.append(channel)
        channel.setMethodCallHandler { [weak self] call, result in
            DispatchQueue.main.async {
                self?.handle(call, result: result)
            }
        }
    }

    private func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "show":
            guard let configuration = NativeDropdownConfiguration(call.arguments)
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing dropdown options",
                    details: nil
                ))
                return
            }
            show(configuration, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func show(
        _ configuration: NativeDropdownConfiguration,
        result: @escaping FlutterResult
    ) {
        guard let presenter = topViewController() else {
            result(FlutterError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native dropdown",
                details: nil
            ))
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
                result(option.id)
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
                result(nil)
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
