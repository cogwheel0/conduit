import Flutter
import ObjectiveC.runtime
import UIKit
import UniformTypeIdentifiers

/// Exposes native iOS paste events from Flutter's text input view to Dart.
final class NativePasteBridge {
    static let shared = NativePasteBridge()

    private static let channelName = "conduit/native_paste"
    private static var didSwizzle = false

    private var channel: FlutterMethodChannel?

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        Self.installSwizzlesIfNeeded()
    }

    private static func installSwizzlesIfNeeded() {
        guard !didSwizzle else { return }
        didSwizzle = true

        // Only swizzle the base class. FlutterSecureTextInputView inherits
        // from FlutterTextInputView, so the swizzle applies automatically.
        // Swizzling both causes infinite recursion: the subclass swizzle
        // sees the parent's already-swizzled Method, making the exchange
        // a no-op and leaving conduit_canPerformAction pointing at itself.
        guard let targetClass = NSClassFromString("FlutterTextInputView")
        else { return }
        swizzlePaste(for: targetClass)
        swizzleCanPerformAction(for: targetClass)
        swizzlePasteConfiguration(for: targetClass)
    }

    private static func swizzlePaste(for targetClass: AnyClass) {
        let originalSelector = #selector(UIResponder.paste(_:))
        let swizzledSelector = #selector(
            UIResponder.conduit_handlePaste(_:))

        guard
            let originalMethod = class_getInstanceMethod(
                targetClass,
                originalSelector
            ),
            let swizzledMethod = class_getInstanceMethod(
                UIResponder.self,
                swizzledSelector
            )
        else {
            return
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod,
           let newMethod = class_getInstanceMethod(targetClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, newMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    private static func swizzleCanPerformAction(for targetClass: AnyClass) {
        let originalSelector = #selector(
            UIResponder.canPerformAction(_:withSender:))
        let swizzledSelector = #selector(
            UIResponder.conduit_canPerformAction(_:withSender:))

        guard
            let originalMethod = class_getInstanceMethod(
                targetClass,
                originalSelector
            ),
            let swizzledMethod = class_getInstanceMethod(
                UIResponder.self,
                swizzledSelector
            )
        else {
            return
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod,
           let newMethod = class_getInstanceMethod(targetClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, newMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    private static func swizzlePasteConfiguration(for targetClass: AnyClass) {
        let originalSelector = #selector(getter: UIResponder.pasteConfiguration)
        let swizzledSelector = #selector(
            getter: UIResponder.conduit_pasteConfiguration
        )

        guard
            let originalMethod = class_getInstanceMethod(
                targetClass,
                originalSelector
            ),
            let swizzledMethod = class_getInstanceMethod(
                UIResponder.self,
                swizzledSelector
            )
        else {
            return
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod,
           let newMethod = class_getInstanceMethod(targetClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, newMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    fileprivate func handlePasteAction() -> Bool {
        guard let payload = buildPayload() else {
            return false
        }

        guard let kind = payload["kind"] as? String, kind == "images" else {
            return false
        }

        DispatchQueue.main.async { [channel] in
            channel?.invokeMethod("onPaste", arguments: payload)
        }
        return true
    }

    private func buildPayload() -> [String: Any]? {
        let pasteboard = UIPasteboard.general
        let imageItems = extractImageItems(from: pasteboard)
        if !imageItems.isEmpty {
            return [
                "kind": "images",
                "items": imageItems,
            ]
        }

        if let text = pasteboard.string, !text.isEmpty {
            return [
                "kind": "text",
                "text": text,
            ]
        }

        return nil
    }

    private func extractImageItems(
        from pasteboard: UIPasteboard
    ) -> [[String: Any]] {
        let supportedTypes: [(UTType, String)] = [
            (.gif, "image/gif"),
            (.png, "image/png"),
            (.jpeg, "image/jpeg"),
            (.webP, "image/webp"),
            (.tiff, "image/tiff"),
            (.heic, "image/heic"),
            (.heif, "image/heif"),
            (.bmp, "image/bmp"),
        ]

        let itemCount = max(pasteboard.numberOfItems, 1)
        var results: [[String: Any]] = []

        for index in 0..<itemCount {
            let indexSet = IndexSet(integer: index)
            var matched = false

            for (type, mimeType) in supportedTypes {
                guard
                    let dataArray = pasteboard.data(
                        forPasteboardType: type.identifier,
                        inItemSet: indexSet
                    ),
                    let data = dataArray.first,
                    !data.isEmpty
                else {
                    continue
                }

                results.append([
                    "mimeType": mimeType,
                    "data": FlutterStandardTypedData(bytes: data),
                ])
                matched = true
                break
            }

            if matched { continue }

            if let images = pasteboard.images,
               index < images.count,
               let data = images[index].pngData() {
                results.append([
                    "mimeType": "image/png",
                    "data": FlutterStandardTypedData(bytes: data),
                ])
            }
        }

        return results
    }
}

extension UIResponder {
    @objc func conduit_handlePaste(_ sender: Any?) {
        if NativePasteBridge.shared.handlePasteAction() {
            return
        }

        conduit_handlePaste(sender)
    }

    @objc func conduit_canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        if action == #selector(UIResponder.paste(_:)), isFirstResponder {
            return true
        }

        return conduit_canPerformAction(action, withSender: sender)
    }

    @objc var conduit_pasteConfiguration: UIPasteConfiguration? {
        get {
            UIPasteConfiguration(acceptableTypeIdentifiers: [
                UTType.image.identifier,
                UTType.png.identifier,
                UTType.jpeg.identifier,
                UTType.gif.identifier,
                UTType.webP.identifier,
                UTType.tiff.identifier,
                UTType.heic.identifier,
                UTType.heif.identifier,
                UTType.bmp.identifier,
                UTType.text.identifier,
                UTType.plainText.identifier,
            ])
        }
        set {
            // Ignore setter; the swizzled getter defines accepted types.
        }
    }
}
