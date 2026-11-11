import Foundation

/// The outcome of claiming a dedup key for a push.
public enum PushClaim: Equatable {
  /// Nobody showed this notification yet.
  case claimed
  /// The app claimed it for a notification it posts itself under this id.
  /// The push takes over: remove the local copy and show this one silently.
  case replacesLocal(String)
  /// Already shown, or already taken over by a push.
  case duplicate
}

/// The outcome of the app claiming a dedup key for its own notification.
public enum PushLocalClaim: Equatable {
  /// Nobody showed this notification yet: post it.
  case claimed
  /// A push or another notification already has it.
  case taken
  /// A push took the key over after the app claimed it under this id,
  /// possibly before the app posted its copy, so there was nothing to remove
  /// then. Remove the app's copy now.
  case supersededByPush(String)
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
    /// A push for this key was shown after the app claimed it under
    /// `localNotificationId`, so the app's copy must go.
    public var pushDelivered: Bool

    public init(claimedAt: Double, localNotificationId: String?, pushDelivered: Bool = false) {
      self.claimedAt = claimedAt
      self.localNotificationId = localNotificationId
      self.pushDelivered = pushDelivered
    }

    private enum CodingKeys: String, CodingKey {
      case claimedAt, localNotificationId, pushDelivered
    }

    /// Ledgers written before `pushDelivered` existed still read.
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        claimedAt: try container.decode(Double.self, forKey: .claimedAt),
        localNotificationId: try container.decodeIfPresent(String.self, forKey: .localNotificationId),
        pushDelivered: try container.decodeIfPresent(Bool.self, forKey: .pushDelivered) ?? false
      )
    }
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
  /// already claimed it.
  public func claim(_ key: String, localNotificationId: String?) throws -> Bool {
    try claimForApp(key, localNotificationId: localNotificationId) == .claimed
  }

  /// Claims `key` for a notification the app posts itself under
  /// `localNotificationId`.
  ///
  /// The app claims once before it posts and once more, with the same id,
  /// right after: a push that took the key over in between is reported then
  /// as `.supersededByPush`.
  public func claimForApp(_ key: String, localNotificationId: String?) throws -> PushLocalClaim {
    try mutate { entries, timestamp in
      guard let existing = entries[key] else {
        entries[key] = Entry(claimedAt: timestamp, localNotificationId: localNotificationId)
        return .claimed
      }
      if let localNotificationId, existing.pushDelivered,
        existing.localNotificationId == localNotificationId
      {
        return .supersededByPush(localNotificationId)
      }
      return .taken
    }
  }

  /// Claims `key` for a push. A push may replace a notification the app
  /// posted itself, once.
  public func claimForPush(_ key: String) throws -> PushClaim {
    try mutate { entries, timestamp in
      guard var existing = entries[key] else {
        entries[key] = Entry(claimedAt: timestamp, localNotificationId: nil)
        return .claimed
      }
      guard let localId = existing.localNotificationId, !existing.pushDelivered else {
        return .duplicate
      }
      // The id stays, so the app's second claim can find out its copy lost.
      existing.pushDelivered = true
      entries[key] = existing
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
