import UserNotifications
import os

// Shows Conduit's end-to-end-encrypted pushes (docs/push/PROTOCOL.md
// section 7). The relay sends an APNs alert with the localized "New
// notification" text, `mutable-content`, and the encrypted payload in `cp`;
// this extension decrypts it and replaces the alert.
//
// The ConduitPushCore sources are compiled into this target directly.
//
// What Conduit told Apple when it asked for the notification filtering
// entitlement (com.apple.developer.usernotifications.filtering), and what
// this extension must keep doing:
//   - It makes no network requests.
//   - It uses only the Keychain, App Group files and CryptoKit.
//   - It drops only pushes that fail authenticated decryption, duplicates
//     of a notification already shown, and pushes for a kind or account the
//     user turned off on this device.
// Until the entitlement is granted (ConduitPushFilteringEnabled is NO), those
// pushes are shown as passive, silent generic notifications instead.

final class NotificationService: UNNotificationServiceExtension {
  private static let log = Logger(
    subsystem: "app.cogwheel.conduit.NotificationService",
    category: "push"
  )

  private let lock = NSLock()
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let original = request.content
    lock.withLock {
      self.contentHandler = contentHandler
      bestAttempt = Self.passive(original, config: .default)
    }

    guard let appGroup = PushSharedContainer.appGroupIdentifier(),
      let directory = PushSharedContainer.directory(appGroup: appGroup)
    else {
      Self.log.error("No App Group container; showing the generic notification")
      finish(with: Self.passive(original, config: .default))
      return
    }

    let receiver = PushReceiver(
      keys: PushKeyStore(accessGroup: appGroup),
      configStore: PushConfigStore(directory: directory),
      ledger: PushLedger(directory: directory)
    )
    let passive = Self.passive(original, config: receiver.currentConfig())
    lock.withLock { bestAttempt = passive }

    switch receiver.receive(userInfo: original.userInfo) {
    case .deliver(let delivery):
      if let localId = delivery.replacesLocalNotificationId {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [localId])
      }
      finish(with: Self.decrypted(original, delivery: delivery, tapKey: Self.tapKey(appGroup)))
    case .reject(let reason):
      let drop = reason.mayDrop && PushSharedContainer.isFilteringEnabled()
      Self.log.notice(
        "Not showing push content: \(String(describing: reason), privacy: .public), drop: \(drop, privacy: .public)"
      )
      finish(with: drop ? UNNotificationContent() : passive)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    let attempt = lock.withLock { bestAttempt }
    if let attempt { finish(with: attempt) }
  }

  /// Hands `content` to the system once; later calls are ignored.
  private func finish(with content: UNNotificationContent) {
    let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
      defer { contentHandler = nil }
      return contentHandler
    }
    handler?(content)
  }

  /// The key taps are signed with. Without it the notification has no tap.
  private static func tapKey(_ appGroup: String) -> PushTapKey? {
    do {
      return try PushTapKey.load(accessGroup: appGroup)
    } catch {
      log.error("No tap key; the notification will not open its item")
      return nil
    }
  }

  /// The decrypted notification, with the tap payload the app reads.
  private static func decrypted(
    _ original: UNNotificationContent,
    delivery: PushDelivery,
    tapKey: PushTapKey?
  ) -> UNNotificationContent {
    let content = mutableCopy(of: original)
    let shown = delivery.presentation
    content.title = shown.title
    content.subtitle = shown.subtitle
    content.body = shown.body
    content.threadIdentifier = shown.threadIdentifier
    content.sound = shown.playsSound ? .default : nil
    content.interruptionLevel = .active
    var userInfo = original.userInfo
    // The ciphertext is no longer needed; the sid tells the app which
    // subscription the push came from.
    userInfo[PushUserInfoKey.envelope] = ["v": PushPayload.version, "s": delivery.sid]
    // Without the key there is no tap, so the app does not open it.
    if let tapKey {
      userInfo[PushUserInfoKey.tap] = PushTap(
        scope: delivery.scope,
        payloadJSON: delivery.payload.json
      ).userInfoValue(signedWith: tapKey)
    } else {
      userInfo.removeValue(forKey: PushUserInfoKey.tap)
    }
    content.userInfo = userInfo
    return content
  }

  /// The generic alert, quiet: no sound and no banner over other work.
  private static func passive(
    _ original: UNNotificationContent,
    config: PushConfig
  ) -> UNNotificationContent {
    let content = mutableCopy(of: original)
    let fallback = PushPresentation.fallback(config: config)
    // iOS already localized the relay's loc-keys from the app's
    // Localizable.strings; prefer the app's mirrored strings when it sent
    // them, since the app may run in another language than the device.
    content.title = localized(
      config.strings[PushStrings.fallbackTitle], system: original.title,
      key: "push.fallback.title", english: fallback.title)
    content.body = localized(
      config.strings[PushStrings.fallbackBody], system: original.body,
      key: "push.fallback.body", english: fallback.body)
    content.subtitle = ""
    content.sound = nil
    content.interruptionLevel = .passive
    content.relevanceScore = 0
    var userInfo = original.userInfo
    userInfo.removeValue(forKey: PushUserInfoKey.tap)
    content.userInfo = userInfo
    return content
  }

  private static func localized(
    _ mirrored: String?,
    system: String,
    key: String,
    english: String
  ) -> String {
    if let mirrored, !mirrored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return mirrored
    }
    if !system.isEmpty, system != key { return system }
    return english
  }

  private static func mutableCopy(of content: UNNotificationContent) -> UNMutableNotificationContent {
    (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
  }
}
