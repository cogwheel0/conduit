import Darwin
import Foundation

/// Where Conduit push state lives, and the Info.plist keys that configure it.
public enum PushSharedContainer {
  /// The App Group id, from the bundle's `AppGroupId` like every other
  /// Conduit target.
  public static let appGroupInfoKey = "AppGroupId"
  /// `YES` once Apple grants com.apple.developer.usernotifications.filtering
  /// and the extension may drop pushes instead of showing them passively.
  public static let filteringInfoKey = "ConduitPushFilteringEnabled"
  /// `development` or `production`, mirroring the aps-environment entitlement.
  public static let apsEnvironmentInfoKey = "ConduitApsEnvironment"

  public static func appGroupIdentifier(in bundle: Bundle = .main) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
      !value.isEmpty, !value.hasPrefix("$(")
    else { return nil }
    return value
  }

  public static func isFilteringEnabled(in bundle: Bundle = .main) -> Bool {
    switch bundle.object(forInfoDictionaryKey: filteringInfoKey) {
    case let flag as Bool: return flag
    case let text as String: return ["YES", "TRUE", "1"].contains(text.uppercased())
    default: return false
    }
  }

  /// `<App Group container>/ConduitPush`.
  public static func directory(appGroup: String) -> URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("ConduitPush", isDirectory: true)
  }
}

/// A small JSON file in the App Group that the app and the extension both
/// change. Every read-modify-write holds an exclusive `flock` on a sibling
/// lock file, so updates from the two processes never interleave.
final class PushLockedJSONFile<Value: Codable> {
  let url: URL
  private let emptyValue: Value

  init(url: URL, emptyValue: Value) {
    self.url = url
    self.emptyValue = emptyValue
  }

  /// The current value, without taking the lock. Writes replace the file
  /// atomically, so a reader never sees half a file.
  func read() -> Value {
    guard let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(Value.self, from: data)
    else { return emptyValue }
    return value
  }

  /// Runs `body` on the current value under the lock and writes the result.
  func update<Result>(_ body: (inout Value) throws -> Result) throws -> Result {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockPath = url.path + ".lock"
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    defer { flock(descriptor, LOCK_UN) }

    var value = read()
    let result = try body(&value)
    try write(value)
    return result
  }

  /// Replaces the value under the lock.
  func replace(with value: Value) throws {
    try update { $0 = value }
  }

  private func write(_ value: Value) throws {
    let data = try JSONEncoder().encode(value)
    #if os(iOS)
      // Readable by the extension after the first unlock, like the keys.
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
}
