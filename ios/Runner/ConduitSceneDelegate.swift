import Flutter
import UIKit

@objc class ConduitSceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    handleShareUrls(connectionOptions.urlContexts)
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    let unhandledContexts = URLContexts.filter { context in
      !NativeShareReceiverBridge.shared.handleOpenUrl(context.url)
    }

    if !unhandledContexts.isEmpty {
      super.scene(scene, openURLContexts: Set(unhandledContexts))
    }
  }

  private func handleShareUrls(_ urlContexts: Set<UIOpenURLContext>) {
    for context in urlContexts {
      _ = NativeShareReceiverBridge.shared.handleOpenUrl(context.url)
    }
  }
}
