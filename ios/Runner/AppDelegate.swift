import Flutter
import UIKit
import UserNotifications

// FLUTTER HOST ONLY. The Flutter app's composition root: it owns the Flutter
// engines and attaches the native feature bridges to them through
// `FlutterConduitBridgeHost`. The bridges themselves live in their own files
// and depend only on `ConduitBridgeHost`.

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  ConduitBridgeHostProvider {
  private var sharedFlutterEngine: FlutterEngine?
  private weak var sharedFlutterWindowScene: UIWindowScene?
  private var didConfigureSharedFlutterEngine = false
  private var bridgeHost: FlutterConduitBridgeHost?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ConduitBridgeRegistry.applicationDidFinishLaunching(launchOptions: launchOptions)
    // FlutterAppDelegate forwards notification callbacks to plugins only while
    // it is the notification center's delegate. Without this, a tap on a
    // Conduit notification never reached flutter_local_notifications. Set it
    // before launch finishes so a tap that cold-starts the app is delivered.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushBridge.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    PushBridge.shared.didFailToRegisterForRemoteNotifications(error: error)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // Conduit pushes the NotificationService extension decrypted go to the push
  // bridge; everything else, flutter_local_notifications' own notifications
  // included, still reaches the plugins through FlutterAppDelegate.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if PushBridge.shared.willPresent(notification) {
      completionHandler([])
      return
    }
    super.userNotificationCenter(
      center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if PushBridge.shared.didReceive(response) {
      completionHandler()
      return
    }
    super.userNotificationCenter(
      center, didReceive: response, withCompletionHandler: completionHandler)
  }

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    guard sharedFlutterEngine == nil else { return }

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    attachBridges(messenger: engineBridge.applicationRegistrar.messenger())
  }

  func ensureBridgeHost() -> ConduitBridgeHost? {
    guard ensureSharedFlutterEngine() != nil else { return nil }
    return bridgeHost
  }

  @discardableResult
  func ensureSharedFlutterEngine() -> FlutterEngine? {
    if let engine = sharedFlutterEngine {
      configureSharedFlutterEngineIfNeeded(engine)
      return engine
    }

    let engine = FlutterEngine(
      name: "conduit.shared",
      project: nil,
      allowHeadlessExecution: true
    )
    guard engine.run() else {
      print("AppDelegate: failed to start shared Flutter engine")
      return nil
    }

    sharedFlutterEngine = engine
    configureSharedFlutterEngineIfNeeded(engine)
    return engine
  }

  func claimSharedFlutterWindowScene(_ windowScene: UIWindowScene) -> Bool {
    if let currentScene = sharedFlutterWindowScene, currentScene !== windowScene {
      return false
    }

    sharedFlutterWindowScene = windowScene
    return true
  }

  func releaseSharedFlutterWindowScene(_ windowScene: UIWindowScene) {
    if sharedFlutterWindowScene === windowScene {
      sharedFlutterWindowScene = nil
    }
  }

  private func configureSharedFlutterEngineIfNeeded(_ engine: FlutterEngine) {
    guard !didConfigureSharedFlutterEngine else { return }

    GeneratedPluginRegistrant.register(with: engine)
    attachBridges(messenger: engine.binaryMessenger)
    didConfigureSharedFlutterEngine = true
  }

  private func attachBridges(messenger: FlutterBinaryMessenger) {
    let host = FlutterConduitBridgeHost(messenger: messenger)
    bridgeHost = host
    ConduitBridgeRegistry.attachAll(to: host)

    // Flutter-only bridges: two swizzle Flutter's text input view and one
    // compensates for the Flutter engine's frame pacing, so none of them is
    // part of the host-agnostic registry.
    NativePasteBridge.shared.configure(messenger: messenger)
    NativeKeyboardAttachmentBridge.shared.configure(messenger: messenger)
    DisplayBoostBridge.shared.configure(messenger: messenger)
  }
}

extension AppDelegate: NativeSttCallKitAppDelegate {}
