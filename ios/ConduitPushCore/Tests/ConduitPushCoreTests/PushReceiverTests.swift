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

    XCTAssertEqual(receiver.receive(userInfo: userInfo(vector)), .reject(.unknownSubscription))
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

    XCTAssertEqual(outcome, .reject(.storageUnavailable))
    XCTAssertFalse(PushRejection.storageUnavailable.mayDrop)
  }

  func testForgedOrCorruptBodiesAreRejected() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    let record = try subscribe(vector)
    let other = try TestVectors.cp1Case("owui_reply_failed")

    // Encrypted to another key.
    var forged = userInfo(other)
    forged["cp"] = ["v": 1, "s": record.sid, "d": other.body]
    XCTAssertEqual(receiver.receive(userInfo: forged), .reject(.undecryptable))

    XCTAssertEqual(receiver.receive(userInfo: ["aps": [:]]), .reject(.malformedEnvelope))
    XCTAssertEqual(
      receiver.receive(userInfo: ["cp": ["v": 2, "s": record.sid, "d": vector.body]]),
      .reject(.malformedEnvelope))
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

    XCTAssertEqual(receiver.receive(userInfo: userInfo(reply)), .reject(.switchedOff))
    XCTAssertEqual(receiver.receive(userInfo: userInfo(channel)), .reject(.switchedOff))

    config = .default
    config.enabled = false
    try configStore.save(config)
    XCTAssertEqual(receiver.receive(userInfo: userInfo(reply)), .reject(.switchedOff))
    // A switched-off push does not use up its dedup key.
    XCTAssertTrue(ledger.entries().isEmpty)
  }

  func testDuplicatesAreRejected() throws {
    let vector = try TestVectors.cp1Case("hermes_reply")
    try subscribe(vector)

    _ = try delivery(receiver.receive(userInfo: userInfo(vector)))
    XCTAssertEqual(receiver.receive(userInfo: userInfo(vector)), .reject(.duplicate))
  }

  func testAPushReplacesTheAppsOwnNotificationSilently() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    try subscribe(vector)
    XCTAssertTrue(try ledger.claim(vector.app_dedup_key, localNotificationId: "1234"))

    let delivered = try delivery(receiver.receive(userInfo: userInfo(vector)))

    XCTAssertEqual(delivered.replacesLocalNotificationId, "1234")
    XCTAssertFalse(delivered.presentation.playsSound)
    XCTAssertEqual(receiver.receive(userInfo: userInfo(vector)), .reject(.duplicate))
  }

  func testAClaimWithoutALocalNotificationIsADuplicate() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    try subscribe(vector)
    XCTAssertTrue(try ledger.claim(vector.app_dedup_key, localNotificationId: nil))

    XCTAssertEqual(receiver.receive(userInfo: userInfo(vector)), .reject(.duplicate))
  }

  func testATestPushRecordsItsNonceEvenWhenSwitchedOff() throws {
    let vector = try TestVectors.cp1Case("test")
    try subscribe(vector)
    var config = PushConfig.default
    config.enabled = false
    try configStore.save(config)

    XCTAssertEqual(receiver.receive(userInfo: userInfo(vector)), .reject(.switchedOff))
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
