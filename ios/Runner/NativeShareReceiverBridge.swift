import Flutter
import UIKit

final class NativeShareReceiverBridge {
  static let shared = NativeShareReceiverBridge()

  private let channelName = "conduit/share_receiver"
  private let payloadKey = "ConduitSharePayload"
  private let shareHost = "share"

  private var channel: FlutterMethodChannel?
  private var pendingPayload: [String: Any]?

  private init() {}

  func configure(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  func captureLaunchOptions(
    _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) {
    guard
      let url = launchOptions?[.url] as? URL,
      isShareUrl(url)
    else {
      return
    }

    pendingPayload = readStoredPayload()
  }

  func handleOpenUrl(_ url: URL) -> Bool {
    guard isShareUrl(url) else { return false }

    guard let payload = readStoredPayload() ?? pendingPayload else {
      return true
    }

    deliver(payload)
    return true
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getInitialSharedPayload":
      if let payload = pendingPayload {
        result(payload)
        return
      }

      result(readStoredPayload())

    case "ackSharedPayload":
      let payload = normalize(call.arguments as? [String: Any])
      acknowledge(payload)
      result(nil)

    case "resetInitialSharedPayload":
      pendingPayload = nil
      removeStoredPayload()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func deliver(_ payload: [String: Any]) {
    pendingPayload = payload

    guard let channel = channel else {
      return
    }

    channel.invokeMethod("sharedPayload", arguments: payload) { [weak self] response in
      if response != nil {
        self?.pendingPayload = payload
      }
    }
  }

  private func isShareUrl(_ url: URL) -> Bool {
    url.host == shareHost
  }

  private func readStoredPayload() -> [String: Any]? {
    guard let defaults = sharedDefaults() else { return nil }

    if let payload = defaults.dictionary(forKey: payloadKey) {
      return normalize(payload)
    }

    guard let data = defaults.data(forKey: payloadKey),
          let object = try? JSONSerialization.jsonObject(with: data),
          let payload = object as? [String: Any] else {
      return nil
    }

    return normalize(payload)
  }

  private func acknowledge(_ payload: [String: Any]?) {
    guard let payload else { return }

    if payloadsMatch(pendingPayload, payload) {
      pendingPayload = nil
    }

    if payloadsMatch(readStoredPayload(), payload) {
      removeStoredPayload()
    }
  }

  private func removeStoredPayload() {
    guard let defaults = sharedDefaults() else { return }
    defaults.removeObject(forKey: payloadKey)
    defaults.synchronize()
  }

  private func sharedDefaults() -> UserDefaults? {
    guard let appGroupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String else {
      return nil
    }
    return UserDefaults(suiteName: appGroupId)
  }

  private func normalize(_ payload: [String: Any]?) -> [String: Any]? {
    guard let payload else { return nil }

    let id = payload["id"] as? String
    let text = payload["text"] as? String
    let filePaths = (payload["filePaths"] as? [String])?
      .filter { !$0.isEmpty } ?? []

    if (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      && filePaths.isEmpty {
      return nil
    }

    var normalized: [String: Any] = ["filePaths": filePaths]
    if let id, !id.isEmpty {
      normalized["id"] = id
    }
    if let text {
      normalized["text"] = text
    }
    return normalized
  }

  private func payloadsMatch(_ lhs: [String: Any]?, _ rhs: [String: Any]) -> Bool {
    guard let lhs = normalize(lhs),
          let rhs = normalize(rhs) else {
      return false
    }

    return lhs["id"] as? String == rhs["id"] as? String
      && lhs["text"] as? String == rhs["text"] as? String
      && (lhs["filePaths"] as? [String] ?? []) == (rhs["filePaths"] as? [String] ?? [])
  }
}
