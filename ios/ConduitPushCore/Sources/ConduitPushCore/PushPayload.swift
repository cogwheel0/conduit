import Foundation

/// Why a decrypted plaintext is not a `cp/1` payload.
public enum PushPayloadError: Error, Equatable {
  case notJSON
  case notAnObject
  case unsupportedVersion
  case unknownKind
  case missingDedupKey
}

/// A decrypted `cp/1` notification (docs/push/PROTOCOL.md section 2).
///
/// Unknown keys are ignored. Optional strings that are missing or of the
/// wrong type read as absent rather than failing the whole payload.
public struct PushPayload: Equatable {
  public enum Kind: String, CaseIterable {
    case reply
    case replyFailed = "reply_failed"
    case channel
    case cron
    case test
  }

  public static let version = 1

  public let kind: Kind
  /// `owui` or `hermes`.
  public let source: String?
  public let ids: [String: String]
  public let title: String
  public let body: String
  public let author: String?
  public let timestamp: Int?
  /// The server's dedup key; the app prefixes it with the scope.
  public let dedupKey: String
  public let group: String?
  /// Test nonce, only for `test`.
  public let nonce: String?
  /// The plaintext exactly as decrypted, for Dart.
  public let json: String

  public static func parse(_ plaintext: Data) throws -> PushPayload {
    guard let json = String(data: plaintext, encoding: .utf8),
      let object = try? JSONSerialization.jsonObject(with: plaintext, options: [.fragmentsAllowed])
    else {
      throw PushPayloadError.notJSON
    }
    guard let fields = object as? [String: Any] else {
      throw PushPayloadError.notAnObject
    }
    guard let version = strictInt(fields["v"]), version == Self.version else {
      throw PushPayloadError.unsupportedVersion
    }
    guard let rawKind = fields["k"] as? String, let kind = Kind(rawValue: rawKind) else {
      throw PushPayloadError.unknownKind
    }
    guard let dedupKey = fields["dk"] as? String, !dedupKey.isEmpty else {
      throw PushPayloadError.missingDedupKey
    }
    var ids: [String: String] = [:]
    for (key, value) in fields["ids"] as? [String: Any] ?? [:] {
      if let value = value as? String { ids[key] = value }
    }
    return PushPayload(
      kind: kind,
      source: fields["src"] as? String,
      ids: ids,
      title: fields["t"] as? String ?? "",
      body: fields["b"] as? String ?? "",
      author: nonEmpty(fields["a"]),
      timestamp: strictInt(fields["ts"]),
      dedupKey: dedupKey,
      group: nonEmpty(fields["g"]),
      nonce: nonEmpty(fields["n"]),
      json: json
    )
  }

  /// The app-wide dedup key shared with socket-driven notifications.
  public func appDedupKey(scope: String) -> String {
    "\(scope)|\(dedupKey)"
  }

  private static func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
  }

  /// An integer JSON number. `true` bridges to 1 through NSNumber, so
  /// booleans are refused explicitly.
  private static func strictInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let double = number.doubleValue
    guard double == double.rounded(), let int = Int(exactly: double) else { return nil }
    return int
  }
}

/// Keys Conduit puts in a notification's `userInfo`.
public enum PushUserInfoKey {
  /// The relay's envelope: `{"v": 1, "s": sid, "d": base64url body}`.
  public static let envelope = "cp"
  /// Set on every decrypted notification: `{"scope": …, "payload": cp/1 JSON}`.
  public static let tap = "conduit_tap"
}

/// The relay's APNs envelope, before decryption.
public struct PushEnvelope: Equatable {
  public let sid: String
  public let body: Data

  public init?(userInfo: [AnyHashable: Any]) {
    guard let fields = userInfo[PushUserInfoKey.envelope] as? [String: Any],
      (fields["v"] as? NSNumber)?.intValue == PushPayload.version,
      let sid = fields["s"] as? String, !sid.isEmpty,
      let encoded = fields["d"] as? String,
      let body = Data(base64URLEncoded: encoded)
    else { return nil }
    self.sid = sid
    self.body = body
  }

  /// Just the sid, for notifications whose body was already decrypted.
  public static func sid(in userInfo: [AnyHashable: Any]) -> String? {
    (userInfo[PushUserInfoKey.envelope] as? [String: Any])?["s"] as? String
  }
}

/// What a tap on a decrypted push carries back to the app.
public struct PushTap: Equatable {
  public let scope: String
  public let payloadJSON: String

  public init(scope: String, payloadJSON: String) {
    self.scope = scope
    self.payloadJSON = payloadJSON
  }

  public init?(userInfo: [AnyHashable: Any]) {
    guard let fields = userInfo[PushUserInfoKey.tap] as? [String: Any],
      let scope = fields["scope"] as? String,
      let payload = fields["payload"] as? String
    else { return nil }
    self.init(scope: scope, payloadJSON: payload)
  }

  public var userInfoValue: [String: String] {
    ["scope": scope, "payload": payloadJSON]
  }
}
