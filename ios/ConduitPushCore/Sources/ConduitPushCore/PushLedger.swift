import Foundation

/// The outcome of claiming a dedup key for a push.
public enum PushClaim: Equatable {
  /// Nobody showed this notification yet.
  case claimed
  /// The app already posted it locally under this notification id. The push
  /// takes over: remove the local copy and show this one silently.
  case replacesLocal(String)
  /// Already shown, or already taken over by a push.
  case duplicate
}

/// Which notifications were shown, shared by the app and the extension so a
/// reply never notifies twice (docs/push/PROTOCOL.md section 7).
///
/// Keys are app-wide dedup keys (`<scope>|<dk>`). Entries expire after three
/// days, longer than any push TTL.
public final class PushLedger {
  public struct Entry: Codable, Equatable {
    /// Unix seconds.
    public var claimedAt: Double
    /// The id of the notification the app posted itself, if it did.
    public var localNotificationId: String?
  }

  public static let retention: TimeInterval = 3 * 24 * 60 * 60

  private let file: PushLockedJSONFile<[String: Entry]>
  private let now: () -> Date

  public init(directory: URL, now: @escaping () -> Date = Date.init) {
    file = PushLockedJSONFile(
      url: directory.appendingPathComponent("ledger.json"),
      emptyValue: [:]
    )
    self.now = now
  }

  /// Records `key` as shown. False when a push or a local notification
  /// already claimed it. Used by the app before it posts a notification.
  public func claim(_ key: String, localNotificationId: String?) throws -> Bool {
    try mutate { entries, timestamp in
      guard entries[key] == nil else { return false }
      entries[key] = Entry(claimedAt: timestamp, localNotificationId: localNotificationId)
      return true
    }
  }

  /// Claims `key` for a push. A push may replace a notification the app
  /// posted itself, once.
  public func claimForPush(_ key: String) throws -> PushClaim {
    try mutate { entries, timestamp in
      guard let existing = entries[key] else {
        entries[key] = Entry(claimedAt: timestamp, localNotificationId: nil)
        return .claimed
      }
      guard let localId = existing.localNotificationId else { return .duplicate }
      entries[key] = Entry(claimedAt: existing.claimedAt, localNotificationId: nil)
      return .replacesLocal(localId)
    }
  }

  /// A snapshot of the ledger, for diagnostics and tests.
  public func entries() -> [String: Entry] {
    file.read()
  }

  private func mutate<Result>(
    _ body: (inout [String: Entry], Double) -> Result
  ) throws -> Result {
    let timestamp = now().timeIntervalSince1970
    return try file.update { entries in
      let cutoff = timestamp - Self.retention
      entries = entries.filter { $0.value.claimedAt >= cutoff }
      return body(&entries, timestamp)
    }
  }
}
