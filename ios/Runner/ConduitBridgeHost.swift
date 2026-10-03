import Flutter
import UIKit

// Conduit's native feature bridges run under more than one host: the shipping
// Flutter app (this Runner) and any other iOS host. A bridge that depends
// only on the types in this file can be copied into any host unchanged.
//
// Host types stay in each host's composition root and never appear in a
// bridge: the app delegate, engines, view controllers, scene delegates and
// plugin registrars. `tool/check_package_boundaries.dart` enforces this for
// every host-agnostic file it lists.

/// What a native feature bridge may ask of the app that hosts it.
///
/// Members are read on the main thread.
protocol ConduitBridgeHost: AnyObject {
  /// Carries method channels, event channels and Pigeon APIs to Dart.
  var messenger: FlutterBinaryMessenger { get }

  /// Root of the key window's view hierarchy. Bridges that present native UI
  /// walk its presented controllers to find the top-most one.
  var presentingViewController: UIViewController? { get }

  /// The foreground-active window scene, for system APIs that take a scene.
  var activeWindowScene: UIWindowScene? { get }

  /// App group shared with the share extension and the widget, if any.
  var appGroupIdentifier: String? { get }
}

extension ConduitBridgeHost {
  /// Container of `appGroupIdentifier`; nil without the app group entitlement.
  var appGroupContainerURL: URL? {
    guard let appGroupIdentifier else { return nil }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  }

  /// Preferences shared through `appGroupIdentifier`.
  var appGroupUserDefaults: UserDefaults? {
    guard let appGroupIdentifier else { return nil }
    return UserDefaults(suiteName: appGroupIdentifier)
  }
}

/// A native feature bridge that a host attaches to its messenger.
protocol ConduitBridge: AnyObject {
  /// Wires the bridge's channels on `host.messenger`.
  ///
  /// Hosts call this again when they attach a new messenger, so an
  /// implementation replaces whatever it registered before.
  @MainActor func attach(to host: ConduitBridgeHost)
}

/// Supplies the bridge host to entry points the host does not own, such as
/// the CarPlay scene. The application delegate of every host conforms.
protocol ConduitBridgeHostProvider: AnyObject {
  /// Returns the running host, starting it first if necessary, or nil when
  /// it could not start.
  @MainActor func ensureBridgeHost() -> ConduitBridgeHost?
}

extension UIApplication {
  /// The host provider, when the application delegate is one.
  var conduitBridgeHostProvider: ConduitBridgeHostProvider? {
    delegate as? ConduitBridgeHostProvider
  }
}

/// App group lookup shared by every host and extension.
enum ConduitAppGroup {
  static let infoDictionaryKey = "AppGroupId"

  /// The group named by the bundle's `AppGroupId`, or `group.<bundle id>`.
  static func identifier(in bundle: Bundle = .main) -> String? {
    let appGroupId = bundle.object(
      forInfoDictionaryKey: infoDictionaryKey
    ) as? String
    let defaultGroupId = bundle.bundleIdentifier.map { "group.\($0)" }
    return appGroupId ?? defaultGroupId
  }
}

/// The registration hooks a host calls from its application delegate.
///
/// Flutter-only bridges (the FlutterTextInputView swizzles and the display
/// boost) are not listed here; the Flutter host attaches them itself.
@MainActor
enum ConduitBridgeRegistry {
  /// Call from `application(_:didFinishLaunchingWithOptions:)` before it
  /// returns. BGTaskScheduler only accepts launch handlers registered then.
  static func applicationDidFinishLaunching() {
    BackgroundStreamingHandler.shared.registerBackgroundTasks()
  }

  /// Attaches every host-agnostic bridge to `host`'s messenger.
  static func attachAll(to host: ConduitBridgeHost) {
    PlatformEnvironmentBridge.shared.attach(to: host)
    AppIntentBridge.attach(to: host)
    ConduitCarPlayBridge.shared.attach(to: host)
    NativeSheetBridge.shared.attach(to: host)
    NativeDropdownBridge.shared.attach(to: host)
    NativeImageViewerBridge.shared.attach(to: host)
    NativeSymbolImageBridge.shared.attach(to: host)
    NativeSttBridge.shared.attach(to: host)
    PccBridge.shared.attach(to: host)
    VoiceAudioRouteBridge.shared.attach(to: host)
    NativeIosTtsBridge.shared.attach(to: host)
    BackgroundStreamingHandler.shared.attach(to: host)
    ShareImportBridge.shared.attach(to: host)
    CookieBridge.shared.attach(to: host)
  }
}
