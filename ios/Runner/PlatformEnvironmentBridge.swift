import Flutter
import Foundation

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
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isIOSAppOnMac":
        result(ProcessInfo.processInfo.isiOSAppOnMac)
      case "displayCornerRadius":
        result(Self.displayCornerRadii[Self.modelIdentifier])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// The device's model identifier, such as "iPhone18,3". The simulator
  /// reports the model it simulates, and an iOS app on a Mac its Mac model.
  private static let modelIdentifier: String = {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
  }()

  /// Radii of the screens' rounded corners in points, by model identifier: 0
  /// for a square screen. iOS offers no public way to ask, so these are the
  /// `DeviceCornerRadius` values Xcode's simulator profiles give each device.
  /// A model missing here reports none, and callers keep their own radius.
  private static let displayCornerRadii: [String: Double] = {
    let radii: [(Double, [String])] = [
    (0, [
      "iPad5,1", "iPad5,2", "iPad6,7", "iPad6,8", "iPad7,1", "iPad7,2",
      "iPad7,3", "iPad7,4", "iPad7,11", "iPad7,12", "iPad11,1", "iPad11,2",
      "iPad11,6", "iPad11,7", "iPad12,1", "iPad12,2", "iPhone8,2", "iPhone9,2",
      "iPhone9,4", "iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5",
      "iPhone12,8", "iPhone14,6"
    ]),
    (18, [
      "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4", "iPad8,5", "iPad8,6",
      "iPad8,7", "iPad8,8", "iPad8,9", "iPad8,10", "iPad8,11", "iPad8,12",
      "iPad11,3", "iPad11,4", "iPad13,1", "iPad13,2", "iPad13,4", "iPad13,5",
      "iPad13,6", "iPad13,7", "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
      "iPad13,16", "iPad13,17", "iPad14,3", "iPad14,4", "iPad14,5", "iPad14,6",
      "iPad14,8", "iPad14,9", "iPad14,10", "iPad14,11", "iPad15,3", "iPad15,4",
      "iPad15,5", "iPad15,6", "iPad16,8", "iPad16,9", "iPad16,10", "iPad16,11"
    ]),
    (21.5, [
      "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2"
    ]),
    (25, [
      "iPad13,18", "iPad13,19", "iPad15,7", "iPad15,8"
    ]),
    (30, [
      "iPad16,3", "iPad16,4", "iPad16,5", "iPad16,6", "iPad17,1", "iPad17,2",
      "iPad17,3", "iPad17,4"
    ]),
    (39, [
      "iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone11,4", "iPhone11,6",
      "iPhone12,3", "iPhone12,5"
    ]),
    (41.5, [
      "iPhone11,8", "iPhone12,1"
    ]),
    (44, [
      "iPhone13,1", "iPhone14,4"
    ]),
    (47, [
      "iPad19,1", "iPad19,2", "iPhone13,2", "iPhone13,3"
    ]),
    (47.33, [
      "iPhone14,2", "iPhone14,5", "iPhone14,7", "iPhone17,5", "iPhone18,5"
    ]),
    (53, [
      "iPhone13,4"
    ]),
    (53.33, [
      "iPhone14,3", "iPhone14,8"
    ]),
    (55, [
      "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5", "iPhone16,1",
      "iPhone16,2", "iPhone17,3", "iPhone17,4"
    ]),
    (59, [
      "iPhone19,4"
    ]),
    (62, [
      "iPhone17,1", "iPhone17,2", "iPhone18,1", "iPhone18,2", "iPhone18,3",
      "iPhone18,4", "iPhone19,2", "iPhone19,3", "iPhone19,7"
    ]),
    ]
    var byModel: [String: Double] = [:]
    for (radius, models) in radii {
      for model in models { byModel[model] = radius }
    }
    return byModel
  }()
}
