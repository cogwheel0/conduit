import Flutter
import UIKit
import UserNotifications
import WebKit

private let platformEnvironmentChannelName = "app.cogwheel.conduit/platform_environment"

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundStreamingHandler: BackgroundStreamingHandler?
  private var sharedFlutterEngine: FlutterEngine?
  private weak var sharedFlutterWindowScene: UIWindowScene?
  private var didConfigureSharedFlutterEngine = false
  private var cookieChannel: FlutterMethodChannel?
  private var shareImportChannel: FlutterMethodChannel?

  private func shareAppGroupId() -> String? {
    let appGroupId = Bundle.main.object(
      forInfoDictionaryKey: conduitShareAppGroupIdKey
    ) as? String
    let defaultGroupId = Bundle.main.bundleIdentifier.map { "group.\($0)" }
    return appGroupId ?? defaultGroupId
  }

  private func shareUserDefaults() -> UserDefaults? {
    guard let groupId = shareAppGroupId() else { return nil }
    return UserDefaults(suiteName: groupId)
  }

  private lazy var shareEnvelopeStore: NativeShareEnvelopeStore? = {
    guard let groupId = shareAppGroupId(),
          let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId
          ) else { return nil }
    return NativeShareEnvelopeStore(
      containerURL: container,
      legacyDefaults: shareUserDefaults()
    )
  }()

  private func shareStagingDirectoryPath() -> String? {
    guard let groupId = shareAppGroupId(),
          let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId
          ) else { return nil }
    let directory = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let values = try directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        return nil
      }
      return directory.resolvingSymlinksInPath().standardizedFileURL.path
    } catch {
      return nil
    }
  }

  private func pendingShareImportStatus() -> [String: Any]? {
    guard let store = shareEnvelopeStore,
          let data = try? store.currentStatusJSON() else {
      return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func clearShareImportStatus(id: String?) {
    guard let store = shareEnvelopeStore else { return }
    _ = try? store.clearStatus(id: id)
  }

  private func takePendingShareImportPayload() -> [String: Any]? {
    guard let store = shareEnvelopeStore,
          let snapshot = try? store.takeCurrent(),
          let rawItems = (try? JSONSerialization.jsonObject(
            with: snapshot.envelope.itemsJSON
          ))
      as? [[String: Any]],
      let status = (try? JSONSerialization.jsonObject(
        with: snapshot.statusJSON
      )) as? [String: Any],
      let payload = nativeValidatedShareImportPayload(
        rawItems: rawItems,
        message: snapshot.envelope.message,
        status: status,
        shareStagingDirectoryPath: shareStagingDirectoryPath()
      ) else {
      return nil
    }
    return payload
  }

  private func acknowledgePendingShareImportPayload(id: String?) -> Bool {
    guard let id, let store = shareEnvelopeStore else { return false }
    return (try? store.acknowledge(id: id)) == true
  }

  func notifyShareImportEvent() {
    shareImportChannel?.invokeMethod("stagedSharePayloadReady", arguments: nil)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    backgroundStreamingHandler = BackgroundStreamingHandler()
    backgroundStreamingHandler?.registerBackgroundTasks()
    // FlutterAppDelegate forwards notification callbacks to plugins only while
    // it is the notification center's delegate. Without this, a tap on a
    // Conduit notification never reached flutter_local_notifications. Set it
    // before launch finishes so a tap that cold-starts the app is delivered.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    guard sharedFlutterEngine == nil else { return }

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    configureApplicationFlutterChannels(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }

  @discardableResult
  func ensureCarPlayFlutterEngine() -> Bool {
    return ensureSharedFlutterEngine() != nil
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
    configureApplicationFlutterChannels(messenger: engine.binaryMessenger)
    didConfigureSharedFlutterEngine = true
  }

  private func configureApplicationFlutterChannels(
    messenger: FlutterBinaryMessenger
  ) {
    let platformEnvironmentChannel = FlutterMethodChannel(
      name: platformEnvironmentChannelName,
      binaryMessenger: messenger
    )
    platformEnvironmentChannel.setMethodCallHandler { call, result in
      guard call.method == "isIOSAppOnMac" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(ProcessInfo.processInfo.isiOSAppOnMac)
    }

    AppIntentBridge.shared = AppIntentBridge(messenger: messenger)
    ConduitCarPlayBridge.shared.configure(messenger: messenger)
    NativePasteBridge.shared.configure(messenger: messenger)
    NativeKeyboardAttachmentBridge.shared.configure(messenger: messenger)
    NativeSheetBridge.shared.configure(messenger: messenger)
    NativeDropdownBridge.shared.configure(messenger: messenger)
    NativeImageViewerBridge.shared.configure(messenger: messenger)
    NativeSymbolImageBridge.shared.configure(messenger: messenger)
    NativeSttBridge.shared.configure(messenger: messenger)
    DisplayBoostBridge.shared.configure(messenger: messenger)
    PccBridge.shared.configure(messenger: messenger)
    VoiceAudioRouteBridge.shared.configure(messenger: messenger)
    NativeIosTtsBridge.shared.configure(messenger: messenger)
    backgroundStreamingHandler?.setup(messenger: messenger)

    let shareImportChannel = FlutterMethodChannel(
      name: conduitShareChannelName,
      binaryMessenger: messenger
    )
    self.shareImportChannel = shareImportChannel
    shareImportChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }

      switch call.method {
      case "pendingShareImportStatus":
        result(self.pendingShareImportStatus())
      case "takePendingShareImportPayload":
        result(self.takePendingShareImportPayload())
      case "ackPendingShareImportPayload":
        let arguments = call.arguments as? [String: Any]
        result(self.acknowledgePendingShareImportPayload(
          id: arguments?["id"] as? String
        ))
      case "shareStagingDirectoryPath":
        result(self.shareStagingDirectoryPath())
      case "clearShareImportStatus":
        let arguments = call.arguments as? [String: Any]
        self.clearShareImportStatus(id: arguments?["id"] as? String)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let cookieChannel = FlutterMethodChannel(
      name: "com.conduit.app/cookies",
      binaryMessenger: messenger
    )
    self.cookieChannel = cookieChannel

    cookieChannel.setMethodCallHandler { (call, result) in
      if call.method == "getCookies" {
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid URL", details: nil))
          return
        }

        // Get cookies from WKWebView's cookie store
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          result(cookieValuesForUrl(cookies: cookies, url: url))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
