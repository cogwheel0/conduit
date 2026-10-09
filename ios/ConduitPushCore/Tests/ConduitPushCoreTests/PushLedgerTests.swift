import XCTest

@testable import ConduitPushCore

final class PushLedgerTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = try temporaryDirectory()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testTheFirstClaimWinsAndLaterClaimsLose() throws {
    let ledger = PushLedger(directory: directory)

    XCTAssertTrue(try ledger.claim("owui:a|chat:1:1", localNotificationId: "7"))
    XCTAssertFalse(try ledger.claim("owui:a|chat:1:1", localNotificationId: "8"))
    XCTAssertFalse(try ledger.claim("owui:a|chat:1:1", localNotificationId: nil))
    XCTAssertTrue(try ledger.claim("owui:b|chat:1:1", localNotificationId: nil))
    XCTAssertEqual(ledger.entries()["owui:a|chat:1:1"]?.localNotificationId, "7")
  }

  func testAPushClaimsAFreshKey() throws {
    let ledger = PushLedger(directory: directory)

    XCTAssertEqual(try ledger.claimForPush("k"), .claimed)
    XCTAssertEqual(try ledger.claimForPush("k"), .duplicate)
    XCTAssertFalse(try ledger.claim("k", localNotificationId: "1"))
  }

  func testAPushReplacesALocalNotificationOnce() throws {
    let ledger = PushLedger(directory: directory)
    XCTAssertTrue(try ledger.claim("k", localNotificationId: "42"))

    XCTAssertEqual(try ledger.claimForPush("k"), .replacesLocal("42"))
    XCTAssertEqual(try ledger.claimForPush("k"), .duplicate)
    XCTAssertNil(ledger.entries()["k"]?.localNotificationId)
  }

  func testAPushDoesNotReplaceAClaimWithoutALocalNotification() throws {
    let ledger = PushLedger(directory: directory)
    XCTAssertTrue(try ledger.claim("k", localNotificationId: nil))

    XCTAssertEqual(try ledger.claimForPush("k"), .duplicate)
  }

  func testClaimsPersistAcrossInstances() throws {
    XCTAssertTrue(try PushLedger(directory: directory).claim("k", localNotificationId: "1"))

    XCTAssertEqual(try PushLedger(directory: directory).claimForPush("k"), .replacesLocal("1"))
  }

  func testEntriesExpireAfterThreeDays() throws {
    var now = Date(timeIntervalSince1970: 1_760_000_000)
    let ledger = PushLedger(directory: directory, now: { now })
    XCTAssertTrue(try ledger.claim("old", localNotificationId: nil))

    now.addTimeInterval(PushLedger.retention - 1)
    XCTAssertTrue(try ledger.claim("newer", localNotificationId: nil))
    XCTAssertEqual(try ledger.claimForPush("old"), .duplicate)

    now.addTimeInterval(2)
    XCTAssertEqual(try ledger.claimForPush("old"), .claimed)
    XCTAssertEqual(Set(ledger.entries().keys), ["newer", "old"])
  }

  func testAnUnreadableLedgerStartsEmpty() throws {
    try Data("not json".utf8).write(to: directory.appendingPathComponent("ledger.json"))

    XCTAssertEqual(try PushLedger(directory: directory).claimForPush("k"), .claimed)
  }

  func testConcurrentClaimsFromSeparateHandlesHaveOneWinner() throws {
    // Each ledger opens its own lock descriptor, as the app and the
    // extension do, so this exercises the flock rather than a mutex.
    let attempts = 64
    for round in 0..<5 {
      let key = "race-\(round)"
      let results = ConcurrentResults()
      DispatchQueue.concurrentPerform(iterations: attempts) { index in
        let ledger = PushLedger(directory: directory)
        let won: Bool
        if index.isMultiple(of: 2) {
          won = (try? ledger.claimForPush(key)) == .claimed
        } else {
          won = (try? ledger.claim(key, localNotificationId: nil)) == true
        }
        results.append(won)
      }
      XCTAssertEqual(results.values.count, attempts)
      XCTAssertEqual(results.values.filter { $0 }.count, 1, key)
    }
    XCTAssertEqual(PushLedger(directory: directory).entries().count, 5)
  }
}

private final class ConcurrentResults {
  private let lock = NSLock()
  private var storage: [Bool] = []

  func append(_ value: Bool) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
