import Flutter
import UIKit
import UserNotifications

/// The app side of Conduit's end-to-end-encrypted push notifications.
///
/// Subscription keys live in the Keychain and the preferences, dedup ledger
/// and verified test nonces in App Group files, all shared with the
/// NotificationService extension through the ConduitPushCore sources. The
/// application delegate hands over APNs registration and the notifications
/// the extension decrypted (`conduit_tap` in their user info).
final class PushBridge: NSObject, ConduitBridge, PushHostApi {
  static let shared = PushBridge()

  private static let tokenDefaultsKey = "conduit.push.apnsToken"
  private static let tokenTimeout: TimeInterval = 20

  private let appGroup = ConduitAppGroup.identifier()
  private lazy var keys = PushKeyStore(accessGroup: appGroup)
  private var flutterApi: PushFlutterApi?
  private var launchTap: PlatformPushTap?
  private var tokenWaiters: [(Result<PlatformPushToken?, Error>) -> Void] = []
  private var tokenRequest = 0

  private override init() {
    super.init()
  }

  @MainActor
  func attach(to host: ConduitBridgeHost) {
    flutterApi = PushFlutterApi(binaryMessenger: host.messenger)
    PushHostApiSetup.setUp(binaryMessenger: host.messenger, api: self)
  }

  // MARK: - Application delegate

  /// Call from `application(_:didFinishLaunchingWithOptions:)`.
  func applicationDidFinishLaunching(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    #if DEBUG
      seedDebugSubscription()
    #endif
    if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
      let tap = PushTap(userInfo: userInfo)
    {
      launchTap = Self.platformTap(tap)
    }
    // Apple asks apps to register on every launch so a rotated token is
    // noticed. Only when push is set up: registering alone shows no prompt.
    if !subscriptions().isEmpty {
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  func didRegisterForRemoteNotifications(deviceToken: Data) {
    let token = PlatformPushToken(
      transport: .apns,
      token: deviceToken.map { String(format: "%02x", $0) }.joined(),
      app: Bundle.main.bundleIdentifier ?? "",
      env: Self.apnsEnvironment
    )
    let waiters = takeTokenWaiters()
    waiters.forEach { $0(.success(token)) }

    let defaults = UserDefaults.standard
    let changed = defaults.string(forKey: Self.tokenDefaultsKey) != token.token
    defaults.set(token.token, forKey: Self.tokenDefaultsKey)
    // A caller of currentToken already has it.
    if changed, waiters.isEmpty {
      flutterApi?.onToken(token: token) { _ in }
    }
  }

  func didFailToRegisterForRemoteNotifications(error: Error) {
    let failure = PigeonError(
      code: "apns_registration_failed",
      message: error.localizedDescription,
      details: nil
    )
    takeTokenWaiters().forEach { $0(.failure(failure)) }
  }

  /// True when `notification` is a push the extension decrypted. The app is
  /// in the foreground, so it is not shown here: Dart decides between a
  /// banner and nothing.
  func willPresent(_ notification: UNNotification) -> Bool {
    let userInfo = notification.request.content.userInfo
    guard let tap = PushTap(userInfo: userInfo) else { return false }
    let sid = PushEnvelope.sid(in: userInfo) ?? ""
    let message = PlatformPushMessage(sid: sid, scope: tap.scope, payloadJson: tap.payloadJSON)
    let payload = try? PushPayload.parse(Data(tap.payloadJSON.utf8))
    onMain {
      self.flutterApi?.onForegroundPush(message: message) { _ in }
      if let payload, payload.kind == .test, let nonce = payload.nonce {
        self.flutterApi?.onTestReceived(sid: sid, nonce: nonce) { _ in }
      }
    }
    return true
  }

  /// True when `response` opened a push the extension decrypted.
  func didReceive(_ response: UNNotificationResponse) -> Bool {
    guard let tap = PushTap(userInfo: response.notification.request.content.userInfo) else {
      return false
    }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      onMain { self.deliverTap(Self.platformTap(tap)) }
    }
    return true
  }

  // MARK: - PushHostApi

  func availableTransports() throws -> [PlatformPushTransport] {
    [.apns]
  }

  func requestPermission(completion: @escaping (Result<Bool, Error>) -> Void) {
    // Asking again is harmless: iOS prompts once, and flutter_local_notifications
    // keeps working because the notification center delegate is untouched.
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, error in
      DispatchQueue.main.async {
        if let error {
          completion(
            .failure(
              PigeonError(
                code: "permission_failed", message: error.localizedDescription, details: nil)))
        } else {
          completion(.success(granted))
        }
      }
    }
  }

  func currentToken(
    transport: PlatformPushTransport,
    completion: @escaping (Result<PlatformPushToken?, Error>) -> Void
  ) {
    guard transport == .apns else {
      completion(.success(nil))
      return
    }
    tokenWaiters.append(completion)
    if tokenWaiters.count == 1 {
      let request = tokenRequest
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.tokenTimeout) { [weak self] in
        guard let self, self.tokenRequest == request else { return }
        let timeout = PigeonError(
          code: "apns_timeout",
          message: "APNs did not answer the registration in time",
          details: nil
        )
        self.takeTokenWaiters().forEach { $0(.failure(timeout)) }
      }
    }
    UIApplication.shared.registerForRemoteNotifications()
  }

  func createSubscription(scope: String) throws -> PlatformPushSubscription {
    Self.platformSubscription(try keys.create(scope: scope))
  }

  func listSubscriptions() throws -> [PlatformPushSubscription] {
    try keys.all().filter { !Self.isDebugSubscription($0.sid) }.map(Self.platformSubscription)
  }

  func setEndpoint(sid: String, endpoint: String, transport: PlatformPushTransport) throws {
    try keys.setEndpoint(sid: sid, endpoint: endpoint, transport: Self.transportName(transport))
  }

  func deleteSubscription(sid: String) throws {
    try keys.delete(sid: sid)
    _ = try configStore()?.takeVerifiedNonces(sid: sid)
  }

  func setConfig(config: PlatformPushConfig) throws {
    try requireConfigStore().save(
      PushConfig(
        enabled: config.enabled,
        sound: config.sound,
        enabledKinds: config.enabledKinds,
        disabledScopes: config.disabledScopes,
        scopeLabels: config.scopeLabels,
        showScopeLabel: config.showScopeLabel,
        strings: config.strings
      )
    )
  }

  func claimNotification(dedupKey: String, localNotificationId: String?) throws -> Bool {
    try PushLedger(directory: requireDirectory())
      .claim(dedupKey, localNotificationId: localNotificationId)
  }

  func cancelScope(scope: String) throws {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { notifications in
      let identifiers = notifications
        .filter { Self.notification($0.request.content.userInfo, belongsTo: scope) }
        .map(\.request.identifier)
      guard !identifiers.isEmpty else { return }
      center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
  }

  func takeLaunchTap() throws -> PlatformPushTap? {
    defer { launchTap = nil }
    return launchTap
  }

  func takeVerifiedNonces(sid: String) throws -> [String] {
    try requireConfigStore().takeVerifiedNonces(sid: sid)
  }

  func unifiedPushDistributors() throws -> [String] {
    []
  }

  func registerUnifiedPush(
    sid: String,
    distributor: String,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    completion(.success(nil))
  }

  func unregisterUnifiedPush(sid: String) throws {}

  // MARK: - Helpers

  private func deliverTap(_ tap: PlatformPushTap) {
    // Already waiting for takeLaunchTap, from the launch options.
    guard launchTap != tap else { return }
    guard let flutterApi else {
      launchTap = tap
      return
    }
    flutterApi.onTap(tap: tap) { [weak self] result in
      guard case .failure = result else { return }
      DispatchQueue.main.async { self?.launchTap = tap }
    }
  }

  /// Flutter channels, and this bridge's state, belong to the main thread.
  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func takeTokenWaiters() -> [(Result<PlatformPushToken?, Error>) -> Void] {
    tokenRequest += 1
    defer { tokenWaiters = [] }
    return tokenWaiters
  }

  private func subscriptions() -> [PushKeyRecord] {
    ((try? keys.all()) ?? []).filter { !Self.isDebugSubscription($0.sid) }
  }

  private func directory() -> URL? {
    appGroup.flatMap(PushSharedContainer.directory(appGroup:))
  }

  private func requireDirectory() throws -> URL {
    guard let directory = directory() else {
      throw PigeonError(code: "no_app_group", message: "The App Group is unavailable", details: nil)
    }
    return directory
  }

  private func configStore() -> PushConfigStore? {
    directory().map(PushConfigStore.init(directory:))
  }

  private func requireConfigStore() throws -> PushConfigStore {
    PushConfigStore(directory: try requireDirectory())
  }

  /// `dev` for the APNs sandbox, from the aps-environment the build signs with.
  private static var apnsEnvironment: String {
    let value = Bundle.main.object(forInfoDictionaryKey: PushSharedContainer.apsEnvironmentInfoKey)
    return (value as? String) == "development" ? "dev" : "prod"
  }

  /// A Conduit push for `scope`, or a local notification whose
  /// flutter_local_notifications payload names `scope`.
  private static func notification(_ userInfo: [AnyHashable: Any], belongsTo scope: String) -> Bool {
    if let tap = PushTap(userInfo: userInfo) { return tap.scope == scope }
    guard let payload = userInfo["payload"] as? String,
      let fields = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    else { return false }
    return fields["scope"] as? String == scope
  }

  private static func platformTap(_ tap: PushTap) -> PlatformPushTap {
    PlatformPushTap(scope: tap.scope, payloadJson: tap.payloadJSON)
  }

  private static func platformSubscription(_ record: PushKeyRecord) -> PlatformPushSubscription {
    PlatformPushSubscription(
      sid: record.sid,
      scope: record.scope,
      p256dh: record.publicKey.base64URLEncodedString(),
      auth: record.authSecret.base64URLEncodedString(),
      createdAtMillis: record.createdAtMillis,
      endpoint: record.endpoint,
      transport: record.transport.flatMap(platformTransport)
    )
  }

  private static func transportName(_ transport: PlatformPushTransport) -> String {
    switch transport {
    case .apns: return "apns"
    case .fcm: return "fcm"
    case .unifiedPush: return "unifiedPush"
    }
  }

  private static func platformTransport(_ name: String) -> PlatformPushTransport? {
    PlatformPushTransport.allCases.first { transportName($0) == name }
  }

  #if DEBUG
    /// `debug_subscription` from push/test-vectors/cp1_vectors.json, so
    /// `tool/push/make_apns.py` fixtures sent with `xcrun simctl push`
    /// decrypt. Its key is public: Debug builds only.
    private enum DebugSubscription {
      static let sid = "Y29uZHVpdC1kZWJ1Zy12MQ"
      static let scope = "owui:debug"
      static let privateKey = "jQaEF1R2h2aWPkHD-fyVKtv1gL_66x3eyA6yCm1O_8Y"
      static let publicKey =
        "BLsnOBX-TWxpPtq6p8k4WxmbdMxXvDrDN-HW7Ejc_9J0CZ-Y4XjGwYXshQNZ-Xi5kweXlzK4fKR_oDTe46Iz4HY"
      static let auth = "ts_L89r93mta2NOxht410A"
    }

    private static func isDebugSubscription(_ sid: String) -> Bool {
      sid == DebugSubscription.sid
    }

    private func seedDebugSubscription() {
      guard let privateKey = Data(base64URLEncoded: DebugSubscription.privateKey),
        let publicKey = Data(base64URLEncoded: DebugSubscription.publicKey),
        let auth = Data(base64URLEncoded: DebugSubscription.auth)
      else { return }
      do {
        try keys.save(
          PushKeyRecord(
            sid: DebugSubscription.sid,
            scope: DebugSubscription.scope,
            privateKey: privateKey,
            publicKey: publicKey,
            authSecret: auth,
            createdAtMillis: 0
          )
        )
      } catch {
        print("PushBridge: could not seed the debug subscription: \(error)")
      }
    }
  #else
    private static func isDebugSubscription(_ sid: String) -> Bool { false }
  #endif
}
