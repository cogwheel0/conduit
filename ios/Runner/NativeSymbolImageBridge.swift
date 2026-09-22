import Flutter
import UIKit

/// Rasterizes SF Symbols for surfaces that Flutter paints itself.
///
/// UIKit draws the glyph, so Conduit never bundles Apple's artwork and the
/// symbol always matches the running system. Flutter-drawn avatars cache the
/// result, which keeps this off the scrolling path.
final class NativeSymbolImageBridge {
    static let shared = NativeSymbolImageBridge()

    /// Guards against a malformed or hostile request asking for a canvas that
    /// would cost real memory. Avatars need a few dozen points at most.
    private static let maximumPointSize: Double = 256
    private static let maximumScale: Double = 4

    private var channel: FlutterMethodChannel?

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "conduit/native_symbol_image",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            guard call.method == "render" else {
                result(FlutterMethodNotImplemented)
                return
            }
            result(Self.render(call.arguments))
        }
        self.channel = channel
    }

    private static func render(_ arguments: Any?) -> FlutterStandardTypedData? {
        guard let payload = arguments as? [String: Any],
              let name = payload["name"] as? String,
              !name.isEmpty,
              let pointSize = payload["pointSize"] as? Double,
              pointSize > 0,
              pointSize <= maximumPointSize,
              let scale = payload["scale"] as? Double,
              scale > 0,
              scale <= maximumScale
        else {
            return nil
        }

        let configuration = UIImage.SymbolConfiguration(
            pointSize: CGFloat(pointSize)
        )
        guard let symbol = UIImage(
            systemName: name,
            withConfiguration: configuration
        ) else {
            // The symbol is missing on this system version. The caller keeps
            // its own fallback glyph.
            return nil
        }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = CGFloat(scale)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: symbol.size,
            format: format
        )
        // White artwork leaves the tint to Flutter, which already matches the
        // glyph to the surrounding text colour.
        let image = renderer.image { _ in
            symbol
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(at: .zero)
        }
        guard let data = image.pngData() else { return nil }
        return FlutterStandardTypedData(bytes: data)
    }
}
