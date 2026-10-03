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
      guard call.method == "isIOSAppOnMac" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(ProcessInfo.processInfo.isiOSAppOnMac)
    }
    self.channel = channel
  }
}
