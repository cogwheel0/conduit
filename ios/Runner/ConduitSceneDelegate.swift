import Flutter
import flutter_sharing_intent
import UIKit

@objc class ConduitSceneDelegate: FlutterSceneDelegate {
  private weak var registeredFlutterEngine: FlutterEngine?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard
      let windowScene = scene as? UIWindowScene,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate,
      let flutterEngine = appDelegate.ensureSharedFlutterEngine()
    else {
      super.scene(scene, willConnectTo: session, options: connectionOptions)
      handleInitialShareUrlContexts(connectionOptions.urlContexts)
      return
    }

    guard appDelegate.claimSharedFlutterWindowScene(windowScene) else {
      handleInitialShareUrlContexts(connectionOptions.urlContexts)
      UIApplication.shared.requestSceneSessionDestruction(
        session,
        options: nil
      ) { error in
        print("ConduitSceneDelegate: failed to discard extra app scene: \(error)")
      }
      return
    }

    let flutterViewController = FlutterViewController(
      engine: flutterEngine,
      nibName: nil,
      bundle: nil
    )
    _ = flutterViewController.loadDefaultSplashScreenView()
    _ = registerSceneLifeCycle(with: flutterEngine)
    registeredFlutterEngine = flutterEngine

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterViewController
    self.window = window
    window.makeKeyAndVisible()

    super.scene(scene, willConnectTo: session, options: connectionOptions)
    handleInitialShareUrlContexts(connectionOptions.urlContexts)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    super.sceneDidDisconnect(scene)

    if let flutterEngine = registeredFlutterEngine {
      _ = unregisterSceneLifeCycle(with: flutterEngine)
      registeredFlutterEngine = nil
    }

    if let windowScene = scene as? UIWindowScene {
      (UIApplication.shared.delegate as? AppDelegate)?
        .releaseSharedFlutterWindowScene(windowScene)
    }
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    let unhandledContexts = Set(URLContexts.filter { context in
      !handleShareUrl(context.url, setInitialData: false)
    })

    if !unhandledContexts.isEmpty {
      super.scene(scene, openURLContexts: unhandledContexts)
    }
  }

  private func handleInitialShareUrlContexts(
    _ urlContexts: Set<UIOpenURLContext>
  ) {
    for context in urlContexts where handleShareUrl(
      context.url,
      setInitialData: true
    ) {
      return
    }
  }

  private func handleShareUrl(_ url: URL, setInitialData: Bool) -> Bool {
    let plugin = SwiftFlutterSharingIntentPlugin.instance
    guard plugin.hasSameSchemePrefix(url: url) else { return false }
    defer {
      (UIApplication.shared.delegate as? AppDelegate)?.notifyShareImportEvent()
    }

    if setInitialData {
      let launchOptions: [AnyHashable: Any] = [
        UIApplication.LaunchOptionsKey.url: url,
      ]
      return plugin.application(
        UIApplication.shared,
        didFinishLaunchingWithOptions: launchOptions
      )
    }

    return plugin.application(
      UIApplication.shared,
      open: url,
      options: [:]
    )
  }
}
