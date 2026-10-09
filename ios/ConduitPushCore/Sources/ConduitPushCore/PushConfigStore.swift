import Foundation

/// The app's push preferences, mirrored for the extension. Matches the
/// Pigeon `PlatformPushConfig`.
public struct PushConfig: Equatable {
  public var enabled: Bool
  public var sound: Bool
  /// `cp/1` kinds the user wants shown.
  public var enabledKinds: [String]
  public var disabledScopes: [String]
  /// Account or connection name per scope.
  public var scopeLabels: [String: String]
  public var showScopeLabel: Bool
  /// Localized strings, keyed as in `PushStrings`.
  public var strings: [String: String]

  public init(
    enabled: Bool,
    sound: Bool,
    enabledKinds: [String],
    disabledScopes: [String],
    scopeLabels: [String: String],
    showScopeLabel: Bool,
    strings: [String: String]
  ) {
    self.enabled = enabled
    self.sound = sound
    self.enabledKinds = enabledKinds
    self.disabledScopes = disabledScopes
    self.scopeLabels = scopeLabels
    self.showScopeLabel = showScopeLabel
    self.strings = strings
  }

  /// Used until the app writes a config. A subscription only exists after
  /// the user turned push on, so nothing is switched off yet.
  public static let `default` = PushConfig(
    enabled: true,
    sound: true,
    enabledKinds: PushPayload.Kind.allCases.map(\.rawValue),
    disabledScopes: [],
    scopeLabels: [:],
    showScopeLabel: false,
    strings: [:]
  )

  /// False when the user switched push, this kind, or this account off on
  /// this device.
  public func allows(_ kind: PushPayload.Kind, scope: String) -> Bool {
    enabled && enabledKinds.contains(kind.rawValue) && !disabledScopes.contains(scope)
  }
}

extension PushConfig: Codable {
  private enum CodingKeys: String, CodingKey {
    case enabled, sound, enabledKinds, disabledScopes, scopeLabels, showScopeLabel, strings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = PushConfig.default
    self.init(
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
      sound: try container.decodeIfPresent(Bool.self, forKey: .sound) ?? fallback.sound,
      enabledKinds: try container.decodeIfPresent([String].self, forKey: .enabledKinds)
        ?? fallback.enabledKinds,
      disabledScopes: try container.decodeIfPresent([String].self, forKey: .disabledScopes)
        ?? fallback.disabledScopes,
      scopeLabels: try container.decodeIfPresent([String: String].self, forKey: .scopeLabels)
        ?? fallback.scopeLabels,
      showScopeLabel: try container.decodeIfPresent(Bool.self, forKey: .showScopeLabel)
        ?? fallback.showScopeLabel,
      strings: try container.decodeIfPresent([String: String].self, forKey: .strings)
        ?? fallback.strings
    )
  }
}

/// The push preferences and the test nonces the extension verified, kept as
/// JSON files in the App Group.
public final class PushConfigStore {
  private let configFile: PushLockedJSONFile<PushConfig>
  private let noncesFile: PushLockedJSONFile<[String: [String]]>

  /// Nonces kept per sid until the app takes them.
  static let maximumNoncesPerSid = 16

  public init(directory: URL) {
    configFile = PushLockedJSONFile(
      url: directory.appendingPathComponent("config.json"),
      emptyValue: .default
    )
    noncesFile = PushLockedJSONFile(
      url: directory.appendingPathComponent("verified_nonces.json"),
      emptyValue: [:]
    )
  }

  public func load() -> PushConfig {
    configFile.read()
  }

  public func save(_ config: PushConfig) throws {
    try configFile.replace(with: config)
  }

  /// Called by the extension when a `test` push for `sid` decrypts.
  public func recordVerifiedNonce(_ nonce: String, sid: String) throws {
    try noncesFile.update { nonces in
      var list = nonces[sid] ?? []
      guard !list.contains(nonce) else { return }
      list.append(nonce)
      nonces[sid] = Array(list.suffix(Self.maximumNoncesPerSid))
    }
  }

  /// The nonces verified for `sid` since the last call.
  public func takeVerifiedNonces(sid: String) throws -> [String] {
    try noncesFile.update { nonces in
      nonces.removeValue(forKey: sid) ?? []
    }
  }
}
