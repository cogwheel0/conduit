import XCTest

@testable import ConduitPushCore

private struct NoDelivery: Error {}

final class PushReceiverTests: XCTestCase {
  private var directory: URL!
  private var storage: MemorySecretStorage!
  private var keys: PushKeyStore!
  private var configStore: PushConfigStore!
  private var ledger: PushLedger!
  private var receiver: PushReceiver!

  override func setUpWithError() throws {
    directory = try temporaryDirectory()
    storage = MemorySecretStorage()
    keys = PushKeyStore(storage: storage)
    configStore = PushConfigStore(directory: directory)
    ledger = PushLedger(directory: directory)
    receiver = PushReceiver(keys: keys, configStore: configStore, ledger: ledger)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Stores the vector's key under its sid and scope, as the app would.
  @discardableResult
  private func subscribe(_ vector: TestVectors.Case) throws -> PushKeyRecord {
    let key = try privateKey(vector.ua_private)
    let record = PushKeyRecord(
      sid: vector.sid, scope: vector.scope, privateKey: key.rawRepresentation,
      publicKey: key.publicKey.x963Representation, authSecret: try b64u(vector.auth),
      createdAtMillis: 0)
    try keys.save(record)
    return record
  }

  private func userInfo(_ vector: TestVectors.Case) -> [AnyHashable: Any] {
    [
      "aps": [
        "alert": ["title-loc-key": "push.fallback.title", "loc-key": "push.fallback.body"],
        "mutable-content": 1, "sound": "default",
      ],
      "cp": ["v": 1, "s": vector.sid, "d": vector.body],
    ]
  }

  private func delivery(_ outcome: PushReceiveOutcome) throws -> PushDelivery {
    guard case .deliver(let delivery) = outcome else {
      XCTFail("expected a delivery, got \(outcome)")
      throw NoDelivery()
    }
    return delivery
  }

  private func repeated(_ outcome: PushReceiveOutcome) throws -> PushDelivery {
    guard case .duplicate(let delivery) = outcome else {
      XCTFail("expected a duplicate, got \(outcome)")
      throw NoDelivery()
    }
    return delivery
  }

  func testDeliversEveryVectorCase() throws {
    for vector in try TestVectors.cp1().cases {
      try subscribe(vector)
      let delivered = try delivery(receiver.receive(userInfo: userInfo(vector)))

      XCTAssertEqual(delivered.sid, vector.sid, vector.name)
      XCTAssertEqual(delivered.scope, vector.scope, vector.name)
      XCTAssertEqual(delivered.payload.json, String(decoding: try b64u(vector.plaintext), as: UTF8.self))
      XCTAssertNil(delivered.replacesLocalNotificationId, vector.name)
      XCTAssertNotNil(ledger.entries()[vector.app_dedup_key], vector.name)
    }
  }

  func testUnknownSubscriptionsAreRejected() throws {
    let vector = try TestVectors.cp1Case("owui_reply")

    XCTAssertEqual(
      receiver.receive(userInfo: userInfo(vector)), .reject(.unknownSubscription, scope: nil))
    XCTAssertTrue(PushRejection.unknownSubscription.mayDrop)
    XCTAssertTrue(ledger.entries().isEmpty)
  }

  func testUnreadableKeychainIsNeverDropped() throws {
    final class LockedStorage: PushSecretStorage {
      func read(account: String) throws -> Data? { throw PushKeyStoreError.keychain(-25308) }
      func write(_ data: Data, account: String) throws {}
      func delete(account: String) throws {}
      func accounts() throws -> [String] { [] }
    }
    let locked = PushReceiver(
      keys: PushKeyStore(storage: LockedStorage()), configStore: configStore, ledger: ledger)

    let outcome = locked.receive(userInfo: userInfo(try TestVectors.cp1Case("owui_reply")))

    XCTAssertEqual(outcome, .reject(.storageUnavailable, scope: nil))
    XCTAssertFalse(PushRejection.storageUnavailable.mayDrop)
  }

  func testForgedOrCorruptBodiesAreRejected() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    let record = try subscribe(vector)
    let other = try TestVectors.cp1Case("owui_reply_failed")

    // Encrypted to another key.
    var forged = userInfo(other)
    forged["cp"] = ["v": 1, "s": record.sid, "d": other.body]
    XCTAssertEqual(receiver.receive(userInfo: forged), .reject(.undecryptable, scope: record.scope))

    XCTAssertEqual(receiver.receive(userInfo: ["aps": [:]]), .reject(.malformedEnvelope, scope: nil))
    XCTAssertEqual(
      receiver.receive(userInfo: ["cp": ["v": 1, "s": record.sid, "d": "not base64!"]]),
      .reject(.malformedEnvelope, scope: nil))
    XCTAssertEqual(
      receiver.receive(userInfo: ["cp": ["v": 2, "s": record.sid, "d": vector.body]]),
      .reject(.unsupportedEnvelope, scope: nil))
    XCTAssertTrue(ledger.entries().isEmpty)
  }

  func testOnlyWhatTheFilteringRequestNamesMayBeDropped() {
    // Undecryptable (nothing to authenticate, no key, or failed
    // authentication) and switched off. Duplicates are their own outcome.
    for reason in [PushRejection.malformedEnvelope, .unknownSubscription, .undecryptable, .switchedOff] {
      XCTAssertTrue(reason.mayDrop, "\(reason)")
    }
    // Possibly genuine, authenticated, or unknown.
    for reason in [PushRejection.unsupportedEnvelope, .invalidPayload, .storageUnavailable] {
      XCTAssertFalse(reason.mayDrop, "\(reason)")
    }
  }

  func testAnAuthenticPushThatIsNotCP1IsRejectedButNotDroppable() throws {
    let record = try keys.create(scope: "owui:acct-1")
    for plaintext in [#"{"v":2,"k":"reply","dk":"d"}"#, #"{"v":1,"k":"poke","dk":"d"}"#, "[]"] {
      let body = try TestWebPush.encrypt(Data(plaintext.utf8), to: record)
      let outcome = receiver.receive(
        userInfo: ["cp": ["v": 1, "s": record.sid, "d": body.base64URLEncodedString()]])

      XCTAssertEqual(outcome, .reject(.invalidPayload, scope: "owui:acct-1"), plaintext)
    }
    XCTAssertFalse(PushRejection.invalidPayload.mayDrop)
    XCTAssertTrue(ledger.entries().isEmpty)
  }

  func testSwitchedOffKindsAndAccountsAreRejected() throws {
    let reply = try TestVectors.cp1Case("owui_reply")
    let channel = try TestVectors.cp1Case("owui_channel_unicode")
    try subscribe(reply)
    try subscribe(channel)
    var config = PushConfig.default
    config.enabledKinds = ["channel", "test"]
    config.disabledScopes = [channel.scope]
    try configStore.save(config)

    XCTAssertEqual(
      receiver.receive(userInfo: userInfo(reply)), .reject(.switchedOff, scope: reply.scope))
    XCTAssertEqual(
      receiver.receive(userInfo: userInfo(channel)), .reject(.switchedOff, scope: channel.scope))

    config = .default
    config.enabled = false
    try configStore.save(config)
    XCTAssertEqual(
      receiver.receive(userInfo: userInfo(reply)), .reject(.switchedOff, scope: reply.scope))
    // A switched-off push does not use up its dedup key.
    XCTAssertTrue(ledger.entries().isEmpty)
  }

  func testARepeatComesBackWithItsContentButSilent() throws {
    let vector = try TestVectors.cp1Case("hermes_reply")
    try subscribe(vector)

    let first = try delivery(receiver.receive(userInfo: userInfo(vector)))
    let again = try repeated(receiver.receive(userInfo: userInfo(vector)))

    // It replaces the first on screen, so it shows the same thing, quietly.
    XCTAssertTrue(first.presentation.playsSound)
    XCTAssertFalse(again.presentation.playsSound)
    XCTAssertEqual(again.presentation.title, first.presentation.title)
    XCTAssertEqual(again.presentation.body, first.presentation.body)
    XCTAssertEqual(again.payload, first.payload)
    XCTAssertEqual(again.scope, vector.scope)
    XCTAssertNil(again.replacesLocalNotificationId)
  }

  func testAPushReplacesTheAppsOwnNotificationSilently() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    try subscribe(vector)
    XCTAssertTrue(try ledger.claim(vector.app_dedup_key, localNotificationId: "1234"))

    let delivered = try delivery(receiver.receive(userInfo: userInfo(vector)))

    XCTAssertEqual(delivered.replacesLocalNotificationId, "1234")
    XCTAssertFalse(delivered.presentation.playsSound)
    XCTAssertNil(try repeated(receiver.receive(userInfo: userInfo(vector))).replacesLocalNotificationId)
    // The app's second claim learns its copy lost.
    XCTAssertEqual(
      try ledger.claimForApp(vector.app_dedup_key, localNotificationId: "1234"),
      .supersededByPush("1234"))
  }

  func testAClaimWithoutALocalNotificationIsADuplicate() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    try subscribe(vector)
    XCTAssertTrue(try ledger.claim(vector.app_dedup_key, localNotificationId: nil))

    XCTAssertFalse(try repeated(receiver.receive(userInfo: userInfo(vector))).presentation.playsSound)
  }

  func testATestPushRecordsItsNonceEvenWhenSwitchedOff() throws {
    let vector = try TestVectors.cp1Case("test")
    try subscribe(vector)
    var config = PushConfig.default
    config.enabled = false
    try configStore.save(config)

    XCTAssertEqual(
      receiver.receive(userInfo: userInfo(vector)), .reject(.switchedOff, scope: vector.scope))
    XCTAssertEqual(try configStore.takeVerifiedNonces(sid: vector.sid), ["Nn3wq0Xk"])
    XCTAssertEqual(try configStore.takeVerifiedNonces(sid: vector.sid), [])

    try configStore.save(.default)
    let delivered = try delivery(receiver.receive(userInfo: userInfo(vector)))
    XCTAssertEqual(delivered.presentation.title, "Push notifications work")
    XCTAssertEqual(try configStore.takeVerifiedNonces(sid: vector.sid), ["Nn3wq0Xk"])
  }

  func testTheConfigMirrorRoundTripsAndToleratesMissingFields() throws {
    let config = PushConfig(
      enabled: false, sound: false, enabledKinds: ["reply"], disabledScopes: ["owui:x"],
      scopeLabels: ["owui:a": "Home"], showScopeLabel: true, strings: ["testTitle": "T"])
    try configStore.save(config)
    XCTAssertEqual(PushConfigStore(directory: directory).load(), config)

    try Data(#"{"sound":false}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
    var expected = PushConfig.default
    expected.sound = false
    XCTAssertEqual(configStore.load(), expected)

    try FileManager.default.removeItem(at: directory.appendingPathComponent("config.json"))
    XCTAssertEqual(configStore.load(), .default)
  }

  func testVerifiedNoncesAreKeptPerSidAndBounded() throws {
    for index in 0..<20 {
      try configStore.recordVerifiedNonce("n\(index)", sid: "a")
    }
    try configStore.recordVerifiedNonce("n19", sid: "a")
    try configStore.recordVerifiedNonce("x", sid: "b")

    XCTAssertEqual(try configStore.takeVerifiedNonces(sid: "a"), (4..<20).map { "n\($0)" })
    XCTAssertEqual(try configStore.takeVerifiedNonces(sid: "b"), ["x"])
  }
}
