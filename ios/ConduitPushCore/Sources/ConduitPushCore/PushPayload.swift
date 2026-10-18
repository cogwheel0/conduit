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
  /// Set on every decrypted notification: `{"scope": …, "payload": cp/1
  /// JSON, "sig": …}`, signed with the install's `PushTapKey`.
  public static let tap = "conduit_tap"
  /// The scope of the subscription a push came to, on every notification
  /// the extension shows for a known sid, the generic ones too.
  public static let scope = "conduit_scope"
  /// `true` on a repeat of a notification already shown, shown again quietly.
  public static let repeated = "conduit_repeat"
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

  /// True for an envelope that names a version other than this one's.
  public static func hasOtherVersion(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let fields = userInfo[PushUserInfoKey.envelope] as? [String: Any],
      let version = fields["v"] as? NSNumber
    else { return false }
    return version.intValue != PushPayload.version
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

  /// The tap in `userInfo`, only if `key` proves the extension wrote it.
  /// Anything else that sets `conduit_tap`, such as a push sent without
  /// `mutable-content` so the extension never ran, is ignored.
  public init?(userInfo: [AnyHashable: Any], key: PushTapKey) {
    guard let fields = userInfo[PushUserInfoKey.tap] as? [String: Any],
      let scope = fields["scope"] as? String,
      let payload = fields["payload"] as? String,
      let encoded = fields["sig"] as? String,
      let signature = Data(base64URLEncoded: encoded),
      key.isValidSignature(signature, scope: scope, payloadJSON: payload)
    else { return nil }
    self.init(scope: scope, payloadJSON: payload)
  }

  public func userInfoValue(signedWith key: PushTapKey) -> [String: String] {
    [
      "scope": scope,
      "payload": payloadJSON,
      "sig": key.signature(scope: scope, payloadJSON: payloadJSON).base64URLEncodedString(),
    ]
  }
}

/// The user info of the notifications the extension shows. It starts from
/// the push's own, so the keys Conduit uses are always set or removed here:
/// a push could carry any of them.
public enum PushNotificationUserInfo {
  /// A notification shown with content. Without `tapKey` (the Keychain could
  /// not be read) it has no tap, so the app does not open it.
  public static func decrypted(
    _ original: [AnyHashable: Any],
    delivery: PushDelivery,
    tapKey: PushTapKey?,
    repeated: Bool
  ) -> [AnyHashable: Any] {
    var userInfo = original
    // The ciphertext is no longer needed; the sid tells the app which
    // subscription the push came from.
    userInfo[PushUserInfoKey.envelope] = ["v": PushPayload.version, "s": delivery.sid]
    userInfo[PushUserInfoKey.scope] = delivery.scope
    if let tapKey {
      userInfo[PushUserInfoKey.tap] = PushTap(
        scope: delivery.scope,
        payloadJSON: delivery.payload.json
      ).userInfoValue(signedWith: tapKey)
    } else {
      userInfo.removeValue(forKey: PushUserInfoKey.tap)
    }
    if repeated {
      userInfo[PushUserInfoKey.repeated] = true
    } else {
      userInfo.removeValue(forKey: PushUserInfoKey.repeated)
    }
    return userInfo
  }

  /// The generic notification. `scope` is the subscription's when the sid
  /// is known, so cancelling the account's notifications finds it too.
  public static func generic(_ original: [AnyHashable: Any], scope: String?) -> [AnyHashable: Any] {
    var userInfo = original
    userInfo.removeValue(forKey: PushUserInfoKey.tap)
    userInfo.removeValue(forKey: PushUserInfoKey.repeated)
    if let scope {
      userInfo[PushUserInfoKey.scope] = scope
    } else {
      userInfo.removeValue(forKey: PushUserInfoKey.scope)
    }
    return userInfo
  }
}
