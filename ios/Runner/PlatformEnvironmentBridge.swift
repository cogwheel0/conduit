import Flutter
import Foundation
import UIKit

private let platformEnvironmentChannelName = "app.cogwheel.conduit/platform_environment"

/// Answers questions about the process the app runs in.
final class PlatformEnvironmentBridge: ConduitBridge {
  static let shared = PlatformEnvironmentBridge()

  private var channel: FlutterMethodChannel?

  private init() {}

  func attach(to host: ConduitBridgeHost) {
    let channel = FlutterMethodChannel(
      name: platformEnvironmentChannelName,
      binaryMessenger: host.messenger
    )
    channel.setMethodCallHandler { [weak host] call, result in
      switch call.method {
      case "isIOSAppOnMac":
        result(ProcessInfo.processInfo.isiOSAppOnMac)
      case "displayCornerRadius":
        result(Self.displayCornerRadius(of: host?.activeWindowScene?.screen))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// The radius of the screen's rounded corners in points, or nil when the
  /// system does not report one.
  ///
  /// UIKit publishes it only as a private screen property, so this reads it
  /// only when the screen answers to it, and callers keep their own radius
  /// otherwise.
  private static func displayCornerRadius(of screen: UIScreen?) -> Double? {
    let key = "_displayCornerRadius"
    guard let screen, screen.responds(to: NSSelectorFromString(key)),
          let radius = screen.value(forKey: key) as? CGFloat,
          radius.isFinite, radius >= 0 else {
      return nil
    }
    return Double(radius)
  }
}
