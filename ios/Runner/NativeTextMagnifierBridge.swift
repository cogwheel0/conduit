import Flutter
import UIKit

/// Maps Flutter's full-view logical coordinates into the native view's bounds.
struct NativeTextMagnifierGeometry {
  let point: CGPoint
  let caretRect: CGRect

  /// Rejects incomplete or non-finite geometry before handing it to UIKit.
  init?(_ arguments: [String: Any], in bounds: CGRect) {
    /// Decodes finite logical coordinates from the standard method codec.
    func number(_ key: String) -> CGFloat? {
      guard let value = arguments[key] as? Double, value.isFinite else { return nil }
      return CGFloat(value)
    }
    guard let viewWidth = number("viewWidth"), let viewHeight = number("viewHeight"),
      let x = number("x"), let y = number("y"),
      let caretX = number("caretX"), let caretY = number("caretY"),
      let caretWidth = number("caretWidth"), let caretHeight = number("caretHeight"),
      viewWidth > 0, viewHeight > 0, caretWidth >= 0, caretHeight >= 0,
      !bounds.isEmpty
    else { return nil }

    let scaleX = bounds.width / viewWidth
    let scaleY = bounds.height / viewHeight
    point = CGPoint(x: bounds.minX + x * scaleX, y: bounds.minY + y * scaleY)
    caretRect = CGRect(
      x: bounds.minX + caretX * scaleX,
      y: bounds.minY + caretY * scaleY,
      width: caretWidth * scaleX,
      height: caretHeight * scaleY
    )
  }
}

/// Lets UIKit draw, magnify and position the system text loupe.
/// Only geometry crosses the channel; draft text stays in Flutter.
@available(iOS 26.0, *)
@MainActor
final class NativeTextMagnifierBridge: NSObject, ConduitBridge {
  static let shared = NativeTextMagnifierBridge()

  private var channel: FlutterMethodChannel?
  private weak var host: ConduitBridgeHost?
  private var sessionID: Int?
  private var loupe: UITextLoupeSession?

  /// Keeps a loupe from surviving application deactivation.
  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(endSession),
      name: UIApplication.willResignActiveNotification, object: nil
    )
  }

  /// Replaces the host's channel and releases the previous engine's session.
  func attach(to host: ConduitBridgeHost) {
    endSession()
    channel?.setMethodCallHandler(nil)
    self.host = host
    let channel = FlutterMethodChannel(
      name: "app.cogwheel.conduit/text_magnifier", binaryMessenger: host.messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "begin", "move", "end":
        result(self?.handle(call) ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Fences movement and teardown against the overlay that owns the loupe.
  private func handle(_ call: FlutterMethodCall) -> Bool {
    guard let arguments = call.arguments as? [String: Any],
      let id = arguments["session"] as? Int
    else { return false }

    if call.method == "end" {
      if sessionID == id { endSession() }
      return true
    }
    guard let view = host?.presentingViewController?.viewIfLoaded,
      view.window != nil,
      let geometry = NativeTextMagnifierGeometry(arguments, in: view.bounds)
    else { return false }

    if call.method == "begin" {
      endSession()
      loupe = UITextLoupeSession.begin(
        at: geometry.point, fromSelectionWidgetView: nil, in: view
      )
      sessionID = loupe == nil ? nil : id
    }
    guard sessionID == id, let loupe else { return false }
    loupe.move(to: geometry.point, withCaretRect: geometry.caretRect, trackingCaret: true)
    return true
  }

  /// Releases UIKit's presentation after a gesture or application deactivation.
  @objc private func endSession() {
    loupe?.invalidate()
    loupe = nil
    sessionID = nil
  }
}
