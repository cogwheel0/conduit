import CryptoKit
import XCTest

@testable import ConduitPushCore

final class PushKeyStoreTests: XCTestCase {
  func testGeneratedSubscriptionsHaveProtocolSizes() throws {
    let record = PushKeyRecord.generate(scope: "owui:a", now: Date(timeIntervalSince1970: 1_760_000_000))

    XCTAssertEqual(Data(base64URLEncoded: record.sid)?.count, 16)
    XCTAssertEqual(record.sid.count, 22)
    XCTAssertEqual(record.privateKey.count, 32)
    XCTAssertEqual(record.publicKey.count, 65)
    XCTAssertEqual(record.publicKey.first, 0x04)
    XCTAssertEqual(record.authSecret.count, 16)
    XCTAssertEqual(record.createdAtMillis, 1_760_000_000_000)
    XCTAssertEqual(try record.agreementKey().publicKey.x963Representation, record.publicKey)
    XCTAssertNotEqual(PushKeyRecord.generate(scope: "owui:a").sid, record.sid)
  }

  func testRecordsAreStoredAsJSON() throws {
    let record = PushKeyRecord(
      sid: "Y29uZHVpdC1kZWJ1Zy12MQ", scope: "owui:debug",
      privateKey: Data(repeating: 1, count: 32), publicKey: Data(repeating: 4, count: 65),
      authSecret: Data(repeating: 2, count: 16), createdAtMillis: 5,
      endpoint: "https://relay.example/v1/push/x", transport: "apns")

    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])

    XCTAssertEqual(
      Set(json.keys),
      ["sid", "scope", "privateKey", "p256dh", "auth", "createdAt", "endpoint", "transport"])
    XCTAssertEqual(json["auth"] as? String, Data(repeating: 2, count: 16).base64URLEncodedString())
    XCTAssertEqual(json["createdAt"] as? Int, 5)
    XCTAssertEqual(try JSONDecoder().decode(PushKeyRecord.self, from: JSONEncoder().encode(record)), record)
  }

  func testCreatesListsUpdatesAndDeletesSubscriptions() throws {
    let storage = MemorySecretStorage()
    let store = PushKeyStore(storage: storage)
    let first = try store.create(scope: "owui:a", now: Date(timeIntervalSince1970: 1))
    let second = try store.create(scope: "hermes:b", now: Date(timeIntervalSince1970: 2))

    XCTAssertEqual(try store.all().map(\.sid), [first.sid, second.sid])
    XCTAssertEqual(try store.record(sid: first.sid), first)

    try store.setEndpoint(sid: first.sid, endpoint: "https://relay/x", transport: "apns")
    let updated = try XCTUnwrap(store.record(sid: first.sid))
    XCTAssertEqual(updated.endpoint, "https://relay/x")
    XCTAssertEqual(updated.transport, "apns")
    XCTAssertEqual(updated.privateKey, first.privateKey)

    try store.delete(sid: first.sid)
    XCTAssertNil(try store.record(sid: first.sid))
    XCTAssertEqual(try store.all().map(\.sid), [second.sid])
    XCTAssertThrowsError(try store.setEndpoint(sid: first.sid, endpoint: "e", transport: "apns")) {
      XCTAssertEqual($0 as? PushKeyStoreError, .unknownSubscription)
    }
  }

  func testUnreadableItemsAreSkipped() throws {
    let storage = MemorySecretStorage()
    storage.items["broken"] = Data("{".utf8)
    let store = PushKeyStore(storage: storage)
    let record = try store.create(scope: "owui:a")
    // An item whose JSON names another sid is not trusted either.
    storage.items["mismatch"] = storage.items[record.sid]

    XCTAssertNil(try store.record(sid: "broken"))
    XCTAssertNil(try store.record(sid: "mismatch"))
    XCTAssertEqual(try store.all().map(\.sid), [record.sid])
  }

  func testTheTapKeyIsCreatedOnceAndThenReused() throws {
    let storage = MemorySecretStorage()
    let tap = PushTap(scope: "owui:a", payloadJSON: "{}")

    let first = try PushTapKey.load(storage: storage)
    XCTAssertEqual(storage.items[PushTapKey.account]?.count, 32)
    let second = try PushTapKey.load(storage: storage)

    XCTAssertNotNil(PushTap(userInfo: [PushUserInfoKey.tap: tap.userInfoValue(signedWith: first)], key: second))
  }

  func testTheTapKeyAnotherProcessStoredFirstWins() throws {
    /// Another process adds its key between this one's read and add.
    final class RacingStorage: PushSecretStorage {
      let theirs = Data(repeating: 9, count: 32)
      var items: [String: Data] = [:]
      func read(account: String) throws -> Data? { items[account] }
      func write(_ data: Data, account: String) throws { items[account] = data }
      func add(_ data: Data, account: String) throws -> Bool {
        items[account] = theirs
        return false
      }
      func delete(account: String) throws { items.removeValue(forKey: account) }
      func accounts() throws -> [String] { Array(items.keys) }
    }
    let storage = RacingStorage()
    let tap = PushTap(scope: "owui:a", payloadJSON: "{}")

    let mine = try PushTapKey.load(storage: storage)

    let theirs = PushTapKey(storage.theirs)
    XCTAssertNotNil(PushTap(userInfo: [PushUserInfoKey.tap: tap.userInfoValue(signedWith: theirs)], key: mine))
  }

  func testAnUnusableTapKeyIsReplaced() throws {
    let storage = MemorySecretStorage()
    storage.items[PushTapKey.account] = Data(repeating: 1, count: 3)

    _ = try PushTapKey.load(storage: storage)

    XCTAssertEqual(storage.items[PushTapKey.account]?.count, 32)
  }
}
