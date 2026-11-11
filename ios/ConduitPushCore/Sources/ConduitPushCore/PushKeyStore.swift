import CryptoKit
import Foundation
import Security

/// One push subscription's secrets: a P-256 key pair and auth secret for one
/// Open WebUI account or Hermes connection (docs/push/PROTOCOL.md section 1).
public struct PushKeyRecord: Equatable {
  /// 16 random bytes, base64url. Names the key pair in every push.
  public let sid: String
  /// `owui:<accountId>` or `hermes:<connectionId>`.
  public let scope: String
  /// Raw 32-byte P-256 scalar.
  public let privateKey: Data
  /// Uncompressed public key (65 bytes), the subscription's `p256dh`.
  public let publicKey: Data
  /// 16 random bytes.
  public let authSecret: Data
  public let createdAtMillis: Int64
  public var endpoint: String?
  /// `apns`, `fcm` or `unifiedPush`.
  public var transport: String?

  public init(
    sid: String,
    scope: String,
    privateKey: Data,
    publicKey: Data,
    authSecret: Data,
    createdAtMillis: Int64,
    endpoint: String? = nil,
    transport: String? = nil
  ) {
    self.sid = sid
    self.scope = scope
    self.privateKey = privateKey
    self.publicKey = publicKey
    self.authSecret = authSecret
    self.createdAtMillis = createdAtMillis
    self.endpoint = endpoint
    self.transport = transport
  }

  /// A fresh key pair, auth secret and sid for `scope`.
  public static func generate(scope: String, now: Date = Date()) -> PushKeyRecord {
    let key = P256.KeyAgreement.PrivateKey()
    return PushKeyRecord(
      sid: randomBytes(16).base64URLEncodedString(),
      scope: scope,
      privateKey: key.rawRepresentation,
      publicKey: key.publicKey.x963Representation,
      authSecret: randomBytes(16),
      createdAtMillis: Int64((now.timeIntervalSince1970 * 1000).rounded())
    )
  }

  public func agreementKey() throws -> P256.KeyAgreement.PrivateKey {
    try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
  }

  static func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }
}

extension PushKeyRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case sid, scope, privateKey, p256dh, auth, createdAt, endpoint, transport
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func bytes(_ key: CodingKeys) throws -> Data {
      let text = try container.decode(String.self, forKey: key)
      guard let data = Data(base64URLEncoded: text) else {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: container, debugDescription: "not base64url")
      }
      return data
    }
    self.init(
      sid: try container.decode(String.self, forKey: .sid),
      scope: try container.decode(String.self, forKey: .scope),
      privateKey: try bytes(.privateKey),
      publicKey: try bytes(.p256dh),
      authSecret: try bytes(.auth),
      createdAtMillis: try container.decode(Int64.self, forKey: .createdAt),
      endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint),
      transport: try container.decodeIfPresent(String.self, forKey: .transport)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sid, forKey: .sid)
    try container.encode(scope, forKey: .scope)
    try container.encode(privateKey.base64URLEncodedString(), forKey: .privateKey)
    try container.encode(publicKey.base64URLEncodedString(), forKey: .p256dh)
    try container.encode(authSecret.base64URLEncodedString(), forKey: .auth)
    try container.encode(createdAtMillis, forKey: .createdAt)
    try container.encodeIfPresent(endpoint, forKey: .endpoint)
    try container.encodeIfPresent(transport, forKey: .transport)
  }
}

/// Where subscription secrets are kept, one item per sid.
public protocol PushSecretStorage {
  func read(account: String) throws -> Data?
  func write(_ data: Data, account: String) throws
  /// Stores `data` unless `account` already has a value. False when it did.
  func add(_ data: Data, account: String) throws -> Bool
  func delete(account: String) throws
  func accounts() throws -> [String]
}

extension PushSecretStorage {
  public func add(_ data: Data, account: String) throws -> Bool {
    guard try read(account: account) == nil else { return false }
    try write(data, account: account)
    return true
  }
}

public enum PushKeyStoreError: Error, Equatable {
  case keychain(OSStatus)
  case unknownSubscription
  case tapKeyUnavailable
}

/// Keychain generic-password items, readable by the app and its
/// Notification Service Extension.
///
/// The access group is the App Group id. iOS lists every app group in an
/// app's keychain access groups after its application identifier, so the
/// group never becomes the default and no `keychain-access-groups`
/// entitlement is needed (which would move flutter_secure_storage's
/// default group).
public struct PushKeychainStorage: PushSecretStorage {
  public static let service = "app.cogwheel.conduit.push"

  public let service: String
  public let accessGroup: String?

  public init(accessGroup: String?, service: String = PushKeychainStorage.service) {
    self.accessGroup = accessGroup
    self.service = service
  }

  private func query(account: String? = nil) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }

  public func read(account: String) throws -> Data? {
    var search = query(account: account)
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw PushKeyStoreError.keychain(status) }
    return result as? Data
  }

  public func write(_ data: Data, account: String) throws {
    var item = query(account: account)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    var status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let changes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      status = SecItemUpdate(query(account: account) as CFDictionary, changes as CFDictionary)
    }
    guard status == errSecSuccess else { throw PushKeyStoreError.keychain(status) }
  }

  /// One `SecItemAdd`, so of two processes adding at once exactly one wins.
  public func add(_ data: Data, account: String) throws -> Bool {
    var item = query(account: account)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecDuplicateItem { return false }
    guard status == errSecSuccess else { throw PushKeyStoreError.keychain(status) }
    return true
  }

  public func delete(account: String) throws {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PushKeyStoreError.keychain(status)
    }
  }

  public func accounts() throws -> [String] {
    var search = query()
    search[kSecReturnAttributes as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw PushKeyStoreError.keychain(status) }
    let items = result as? [[String: Any]] ?? []
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }
}

/// Push subscriptions by sid. The value of each item is the record's JSON.
public final class PushKeyStore {
  private let storage: PushSecretStorage

  public init(storage: PushSecretStorage) {
    self.storage = storage
  }

  public convenience init(accessGroup: String?) {
    self.init(storage: PushKeychainStorage(accessGroup: accessGroup))
  }

  /// Generates and stores a subscription for `scope`.
  public func create(scope: String, now: Date = Date()) throws -> PushKeyRecord {
    let record = PushKeyRecord.generate(scope: scope, now: now)
    try save(record)
    return record
  }

  public func save(_ record: PushKeyRecord) throws {
    try storage.write(JSONEncoder().encode(record), account: record.sid)
  }

  /// The subscription for `sid`, or nil when there is none or it is unreadable.
  public func record(sid: String) throws -> PushKeyRecord? {
    guard let data = try storage.read(account: sid) else { return nil }
    guard let record = try? JSONDecoder().decode(PushKeyRecord.self, from: data),
      record.sid == sid
    else { return nil }
    return record
  }

  /// Every readable subscription, oldest first.
  public func all() throws -> [PushKeyRecord] {
    try storage.accounts()
      .compactMap { try record(sid: $0) }
      .sorted { ($0.createdAtMillis, $0.sid) < ($1.createdAtMillis, $1.sid) }
  }

  public func setEndpoint(sid: String, endpoint: String, transport: String) throws {
    guard var record = try record(sid: sid) else {
      throw PushKeyStoreError.unknownSubscription
    }
    record.endpoint = endpoint
    record.transport = transport
    try save(record)
  }

  public func delete(sid: String) throws {
    try storage.delete(account: sid)
  }
}

/// The per-install secret the extension signs every tap with, so the app
/// opens only notifications the extension decrypted. The iOS counterpart of
/// the token in Android's tap intents.
///
/// A Keychain item in the App Group's access group, readable after the
/// first unlock and never migrated to another device. Whichever of the app
/// and the extension needs it first creates it.
public struct PushTapKey {
  public static let service = "app.cogwheel.conduit.push.tap"
  static let account = "tap"
  static let byteCount = 32
  private static let label = Data("conduit-tap/1".utf8)

  private let key: SymmetricKey

  init(_ bytes: Data) {
    key = SymmetricKey(data: bytes)
  }

  public static func load(accessGroup: String?) throws -> PushTapKey {
    try load(storage: PushKeychainStorage(accessGroup: accessGroup, service: service))
  }

  /// The stored key, or a new one. When both processes create one at once,
  /// the first one stored wins and the other reads it back.
  public static func load(storage: PushSecretStorage) throws -> PushTapKey {
    if let stored = try storage.read(account: account) {
      if stored.count == byteCount { return PushTapKey(stored) }
      // Unusable: nothing it signed can be checked anyway.
      try storage.delete(account: account)
    }
    let fresh = PushKeyRecord.randomBytes(byteCount)
    if try storage.add(fresh, account: account) { return PushTapKey(fresh) }
    guard let stored = try storage.read(account: account), stored.count == byteCount else {
      throw PushKeyStoreError.tapKeyUnavailable
    }
    return PushTapKey(stored)
  }

  /// HMAC-SHA256 over a label, the scope's length and bytes, and the payload.
  func signature(scope: String, payloadJSON: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Self.message(scope: scope, payloadJSON: payloadJSON), using: key))
  }

  func isValidSignature(_ signature: Data, scope: String, payloadJSON: String) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(
      signature,
      authenticating: Self.message(scope: scope, payloadJSON: payloadJSON),
      using: key
    )
  }

  private static func message(scope: String, payloadJSON: String) -> Data {
    let scopeBytes = Data(scope.utf8)
    var length = UInt32(scopeBytes.count).bigEndian
    var message = label
    message.append(0)
    message.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
    message.append(scopeBytes)
    message.append(Data(payloadJSON.utf8))
    return message
  }
}
