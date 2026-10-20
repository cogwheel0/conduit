import Flutter
import UIKit

// FLUTTER HOST ONLY. This is the Flutter app's implementation of
// `ConduitBridgeHost`; other hosts provide their own and do not copy
// this file.

/// Exposes one Flutter engine's messenger, and the app's key window, to the
/// native feature bridges.
///
/// The app delegate creates one for each engine it attaches: the shared
/// scene engine, or the implicit engine through its application registrar.
final class FlutterConduitBridgeHost: ConduitBridgeHost {
  let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  var presentingViewController: UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }?
      .rootViewController
  }

  var activeWindowScene: UIWindowScene? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
  }

  var appGroupIdentifier: String? {
    ConduitAppGroup.identifier()
  }
}
