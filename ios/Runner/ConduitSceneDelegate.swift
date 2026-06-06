import Flutter
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
      handleUrlContexts(
        connectionOptions.urlContexts,
        scene: scene,
        forwardsUnhandledToFlutter: false
      )
      return
    }

    guard appDelegate.claimSharedFlutterWindowScene(windowScene) else {
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
    handleUrlContexts(
      connectionOptions.urlContexts,
      scene: scene,
      forwardsUnhandledToFlutter: false
    )
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
    handleUrlContexts(
      URLContexts,
      scene: scene,
      forwardsUnhandledToFlutter: true
    )
  }

  private func handleUrlContexts(
    _ urlContexts: Set<UIOpenURLContext>,
    scene: UIScene,
    forwardsUnhandledToFlutter: Bool
  ) {
    let unhandledContexts = Set(urlContexts.filter { context in
      !NativeShareReceiverBridge.shared.handleOpenUrl(context.url)
    })

    if forwardsUnhandledToFlutter, !unhandledContexts.isEmpty {
      super.scene(scene, openURLContexts: unhandledContexts)
    }
  }
}
