import Darwin
import Foundation

let nativeShareLegacyPayloadDefaultsKey = "SharingKey"
let nativeShareLegacyMessageDefaultsKey = "SharingMessageKey"
let nativeShareLegacyStatusDefaultsKey = "ShareImportStatusKey"
let nativeShareStagingDirectoryName = "conduit-shared-intents"
let nativeShareMaximumFileCount = 6
let nativeShareMaximumItemCount = 12
let nativeShareMaximumTextBytes = 256 * 1024
let nativeShareMaximumURLBytes = 16 * 1024
let nativeShareMaximumAggregateTextBytes =
  nativeShareMaximumItemCount * nativeShareMaximumTextBytes
let nativeShareMaximumFilenameBytes = 255

private let nativeShareLoadWatchdogBaseInterval: TimeInterval = 20
private let nativeShareLoadWatchdogPerFileInterval: TimeInterval = 15
private let nativeShareLoadWatchdogPerValueInterval: TimeInterval = 2
private let nativeShareLoadWatchdogMaximumInterval: TimeInterval = 120

/// Keeps the watchdog bounded while giving the serial, memory-safe loader a
/// realistic budget for every admitted provider.
func nativeShareLoadWatchdogInterval(
  totalItemCount: Int,
  fileBackedItemCount: Int
) -> TimeInterval {
  let admittedTotal = min(max(0, totalItemCount), nativeShareMaximumItemCount)
  let admittedFiles = min(
    min(max(0, fileBackedItemCount), nativeShareMaximumFileCount),
    admittedTotal
  )
  let valueCount = admittedTotal - admittedFiles
  return min(
    nativeShareLoadWatchdogMaximumInterval,
    nativeShareLoadWatchdogBaseInterval
      + TimeInterval(admittedFiles) * nativeShareLoadWatchdogPerFileInterval
      + TimeInterval(valueCount) * nativeShareLoadWatchdogPerValueInterval
  )
}

private func nativeShareSanitizedFileName(_ name: String) -> String {
  let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
    .union(.newlines)
    .union(.controlCharacters)
  return name.components(separatedBy: invalid).joined(separator: "-")
}

private func nativeShareUTF8Prefix(_ value: String, maximumBytes: Int) -> String {
  guard maximumBytes > 0 else { return "" }
  var result = String.UnicodeScalarView()
  var byteCount = 0
  for scalar in value.unicodeScalars {
    let scalarBytes = String(scalar).utf8.count
    guard byteCount + scalarBytes <= maximumBytes else { break }
    result.append(scalar)
    byteCount += scalarBytes
  }
  return String(result)
}

/// Builds an APFS-safe staged filename while retaining the original extension.
/// The import/item prefixes are part of the same 255-byte filesystem limit.
func nativeShareStagedFileName(
  importId: String,
  itemId: String,
  ordinal: Int,
  originalName: String?,
  fallbackExtension: String
) -> String? {
  let prefix = "\(importId)-\(itemId)-\(ordinal)-"
  let availableBytes = nativeShareMaximumFilenameBytes - prefix.utf8.count
  guard availableBytes >= 5 else { return nil }

  let fallback = nativeShareSanitizedFileName(fallbackExtension)
    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
  let rawName = originalName?.isEmpty == false
    ? originalName!
    : "file.\(fallback)"
  let sanitized = nativeShareSanitizedFileName(rawName)
  let path = sanitized as NSString
  var fileExtension = path.pathExtension
  var stem = path.deletingPathExtension
  if fileExtension.isEmpty {
    fileExtension = fallback
    stem = sanitized
  }

  // Reserve at least one byte for a stem. Pathological extensions are
  // shortened only when preserving them in full is impossible.
  fileExtension = nativeShareUTF8Prefix(
    fileExtension,
    maximumBytes: max(0, availableBytes - 2)
  )
  var suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
  if suffix.utf8.count >= availableBytes {
    fileExtension = nativeShareUTF8Prefix(
      fileExtension,
      maximumBytes: max(0, availableBytes - 2)
    )
    suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
  }

  let stemBudget = availableBytes - suffix.utf8.count
  let candidateStem = stem.isEmpty ? "file" : stem
  var boundedStem = nativeShareUTF8Prefix(
    candidateStem,
    maximumBytes: stemBudget
  )
  if boundedStem.isEmpty {
    boundedStem = nativeShareUTF8Prefix("file", maximumBytes: stemBudget)
  }
  guard !boundedStem.isEmpty else { return nil }

  let result = "\(prefix)\(boundedStem)\(suffix)"
  guard result.utf8.count <= nativeShareMaximumFilenameBytes else {
    return nil
  }
  return result
}

struct NativeSharePayloadEnvelope: Codable, Equatable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: String
  let itemsJSON: Data
  let message: String?

  init(id: String, itemsJSON: Data, message: String?) {
    schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.itemsJSON = itemsJSON
    self.message = message
  }
}

struct NativeShareEnvelopeSnapshot: Equatable {
  let envelope: NativeSharePayloadEnvelope
  let statusJSON: Data
}

enum NativeShareEnvelopeStoreError: Error {
  case invalidIdentifier
  case invalidStatus
  case invalidEnvelope
  case invalidStorage
  case unsafeStagedFile
  case coordinationFailed(Int32)
}

/// Cross-process durable storage shared by the app and Share Extension.
///
/// Payloads are immutable files keyed by their canonical UUID. A mutable
/// status file points at the current import, while exact-ID acknowledgement
/// removes only that payload file. A POSIX advisory lock serializes every
/// status/envelope transition across the two processes; the static lock also
/// covers multiple store instances inside RunnerTests and one app process.
final class NativeShareEnvelopeStore {
  private static let storageDirectoryName = "conduit-share-envelopes-v1"
  private static let statusFileName = "current-status.json"
  private static let lockFileName = ".coordination.lock"
  private static let envelopePrefix = "payload-"
  private static let envelopeSuffix = ".plist"
  private static let maximumStatusBytes = 256 * 1024
  // JSON may escape one input byte as six ASCII bytes (for example, U+0001).
  // Keep enough room for all 12 admitted 256-KiB text items, bounded metadata,
  // a separate message, and the binary-plist container itself.
  private static let maximumItemsJSONBytes =
    nativeShareMaximumAggregateTextBytes * 6 + 512 * 1024
  private static let maximumEnvelopeBytes =
    maximumItemsJSONBytes + nativeShareMaximumTextBytes * 2 + 512 * 1024
  private static let localLock = NSLock()

  private let fileManager: FileManager
  private let legacyDefaults: UserDefaults?
  private let storageDirectoryURL: URL
  private let stagingDirectoryURL: URL
  private let statusWriteOverrideForTesting: ((Data, URL) throws -> Void)?

  init(
    containerURL: URL,
    legacyDefaults: UserDefaults? = nil,
    fileManager: FileManager = .default,
    statusWriteOverrideForTesting: ((Data, URL) throws -> Void)? = nil
  ) {
    self.fileManager = fileManager
    self.legacyDefaults = legacyDefaults
    self.statusWriteOverrideForTesting = statusWriteOverrideForTesting
    storageDirectoryURL = containerURL.appendingPathComponent(
      Self.storageDirectoryName,
      isDirectory: true
    )
    stagingDirectoryURL = containerURL.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
  }

  func beginImport(id: String, statusJSON: Data) throws {
    let canonicalId = try validatedIdentifier(id)
    guard try statusIdentifier(from: statusJSON) == canonicalId else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      var supersededId: String?
      var transferredMarkerURL: URL?
      if let currentId = try recoverableCurrentStatusIdentifierLocked() {
        if try hasDartOwnershipMarkerLocked(id: currentId) {
          guard try noFollowType(at: envelopeURL(id: currentId)) == .missing else {
            throw NativeShareEnvelopeStoreError.invalidEnvelope
          }
          // Keep the ownership marker until the replacement pointer is
          // durable. If status replacement fails or this process exits, the
          // old staged files must remain recognizably Dart-owned.
          transferredMarkerURL = try dartOwnedURL(id: currentId)
        } else {
          supersededId = currentId
        }
      }
      discardLegacyRecordLocked()
      try writeMutableFile(statusJSON, to: statusURL)

      // The new in-progress pointer now fences readers from the superseded
      // import. Post-commit cleanup is preservation-first: a crash may leak a
      // native-owned file, but cannot expose a partially deleted payload or
      // cause a later import to reclaim Dart-owned files.
      if let transferredMarkerURL {
        try? fileManager.removeItem(at: transferredMarkerURL)
      } else if let supersededId {
        try? discardEnvelopeLocked(id: supersededId, cleanOwnedFiles: true)
        try? cleanInProgressFilesLocked(id: supersededId)
      }
    }
  }

  /// Publishes only if this import still owns the current status slot. An
  /// older extension instance finishing after a newer share cannot overwrite
  /// the newer record; its own staged files are cleaned instead.
  @discardableResult
  func publish(
    id: String,
    itemsJSON: Data,
    message: String?,
    statusJSON: Data
  ) throws -> Bool {
    let canonicalId = try validatedIdentifier(id)
    guard try statusIdentifier(from: statusJSON) == canonicalId else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    let envelope = NativeSharePayloadEnvelope(
      id: canonicalId,
      itemsJSON: itemsJSON,
      message: message
    )
    _ = try ownedStagedFileURLs(
      from: itemsJSON,
      message: message,
      expectedImportId: canonicalId
    )

    return try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      guard let currentStatus = try readRegularFileIfPresent(
        at: statusURL,
        maximumBytes: Self.maximumStatusBytes
      ), try statusIdentifier(from: currentStatus) == canonicalId else {
        try cleanOwnedStagedFilesLocked(
          id: canonicalId,
          itemsJSON: itemsJSON
        )
        return false
      }

      let envelopeURL = try self.envelopeURL(id: canonicalId)
      let encoded = try PropertyListEncoder().encode(envelope)
      if !statusIsInProgress(currentStatus) {
        guard currentStatus == statusJSON,
              try readRegularFileIfPresent(
                at: envelopeURL,
                maximumBytes: Self.maximumEnvelopeBytes
              ) == encoded else {
          throw NativeShareEnvelopeStoreError.invalidEnvelope
        }
        return true
      }

      _ = try writeImmutableFile(encoded, to: envelopeURL)
      do {
        try writeMutableFile(statusJSON, to: statusURL)
      } catch let statusWriteError {
        // An envelope is not committed until its terminal status pointer is
        // durable. Remove even an identical envelope left by an earlier crash
        // before reclaiming its paths, or a retry could publish deleted files.
        if try noFollowType(at: envelopeURL) != .missing {
          try fileManager.removeItem(at: envelopeURL)
        }
        guard try noFollowType(at: envelopeURL) == .missing else {
          throw NativeShareEnvelopeStoreError.invalidStorage
        }
        try cleanOwnedStagedFilesLocked(
          id: canonicalId,
          itemsJSON: itemsJSON
        )
        throw statusWriteError
      }
      return true
    }
  }

  @discardableResult
  func finishWithoutPayload(id: String, statusJSON: Data) throws -> Bool {
    let canonicalId = try validatedIdentifier(id)
    guard try statusIdentifier(from: statusJSON) == canonicalId else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    return try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      guard try currentStatusIdentifierLocked() == canonicalId else {
        return false
      }
      try writeMutableFile(statusJSON, to: statusURL)
      return true
    }
  }

  func currentStatusJSON() throws -> Data? {
    try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      guard try recoverableCurrentStatusIdentifierLocked() != nil else {
        return nil
      }
      return try readRegularFileIfPresent(
        at: statusURL,
        maximumBytes: Self.maximumStatusBytes
      )
    }
  }

  /// Returns an exact status/envelope snapshot without mutating it. Repeated
  /// takes remain retryable until the same ID is acknowledged.
  func takeCurrent() throws -> NativeShareEnvelopeSnapshot? {
    try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      guard let id = try recoverableCurrentStatusIdentifierLocked(),
            let statusJSON = try readRegularFileIfPresent(
        at: statusURL,
        maximumBytes: Self.maximumStatusBytes
      ), !statusIsInProgress(statusJSON) else {
        return nil
      }
      guard let envelope = try readEnvelopeLocked(id: id) else { return nil }
      guard envelope.id == id,
            envelope.schemaVersion == NativeSharePayloadEnvelope.currentSchemaVersion else {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }
      return NativeShareEnvelopeSnapshot(
        envelope: envelope,
        statusJSON: statusJSON
      )
    }
  }

  /// Deletes only the immutable envelope named by `id`. It never consults or
  /// clears a possibly newer status pointer and never deletes staged files.
  /// The atomic rename is also an idempotent ownership tombstone: if the
  /// platform reply is lost, retrying the same acknowledgement still succeeds.
  @discardableResult
  func acknowledge(id: String) throws -> Bool {
    let canonicalId = try validatedIdentifier(id)
    return try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      let ownedURL = try dartOwnedURL(id: canonicalId)
      if try noFollowType(at: ownedURL) == .regularFile {
        return true
      }
      let url = try envelopeURL(id: canonicalId)
      guard let envelope = try readEnvelopeLocked(id: canonicalId),
            envelope.id == canonicalId else {
        return false
      }
      let result = url.path.withCString { source in
        ownedURL.path.withCString { destination in
          renameatx_np(
            AT_FDCWD,
            source,
            AT_FDCWD,
            destination,
            UInt32(RENAME_EXCL)
          )
        }
      }
      guard result == 0 else {
        if errno == EEXIST,
           try noFollowType(at: ownedURL) == .regularFile {
          return true
        }
        throw NativeShareEnvelopeStoreError.coordinationFailed(errno)
      }
      return true
    }
  }

  func cleanUnpublishedOwnedFiles(id: String, itemsJSON: Data) throws {
    let canonicalId = try validatedIdentifier(id)
    try withExclusiveAccess {
      try cleanOwnedStagedFilesLocked(
        id: canonicalId,
        itemsJSON: itemsJSON
      )
    }
  }

  @discardableResult
  func clearStatus(id: String?) throws -> Bool {
    guard let id else { return false }
    let requestedId = try validatedIdentifier(id)
    return try withExclusiveAccess {
      try migrateLegacyRecordIfNeededLocked()
      guard let currentId = try recoverableCurrentStatusIdentifierLocked(),
            requestedId == currentId else {
        return false
      }
      if try hasDartOwnershipMarkerLocked(id: currentId) {
        // Remove the pointer first. If the process dies before the marker is
        // removed, a later import can only preserve these Dart-owned files;
        // it can never misclassify them as native-owned and delete them.
        try fileManager.removeItem(at: statusURL)
        try fileManager.removeItem(at: try dartOwnedURL(id: currentId))
      } else {
        // A terminal status can also be cleared without ever yielding a valid
        // payload (provider failure, timeout, or corrupt media). Reclaim its
        // still-native envelope and any files staged before publication before
        // dropping the only durable pointer to their import ID.
        try discardEnvelopeLocked(id: currentId, cleanOwnedFiles: true)
        try cleanInProgressFilesLocked(id: currentId)
        try fileManager.removeItem(at: statusURL)
      }
      return true
    }
  }

  private var statusURL: URL {
    storageDirectoryURL.appendingPathComponent(Self.statusFileName)
  }

  private var lockURL: URL {
    storageDirectoryURL.appendingPathComponent(Self.lockFileName)
  }

  private func envelopeURL(id: String) throws -> URL {
    let canonicalId = try validatedIdentifier(id)
    return storageDirectoryURL.appendingPathComponent(
      "\(Self.envelopePrefix)\(canonicalId)\(Self.envelopeSuffix)"
    )
  }

  private func dartOwnedURL(id: String) throws -> URL {
    let canonicalId = try validatedIdentifier(id)
    return storageDirectoryURL.appendingPathComponent(
      "dart-owned-\(canonicalId).marker"
    )
  }

  private func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
    Self.localLock.lock()
    defer { Self.localLock.unlock() }
    try ensureStorageDirectory()

    let descriptor = lockURL.path.withCString {
      open(
        $0,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR)
      )
    }
    guard descriptor >= 0 else {
      throw NativeShareEnvelopeStoreError.coordinationFailed(errno)
    }
    defer { close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          lockDescriptor(descriptor) == 0 else {
      throw NativeShareEnvelopeStoreError.coordinationFailed(errno)
    }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    return try operation()
  }

  private func lockDescriptor(_ descriptor: Int32) -> Int32 {
    var result: Int32
    repeat {
      result = Darwin.lockf(descriptor, F_LOCK, 0)
    } while result != 0 && errno == EINTR
    return result
  }

  private func ensureStorageDirectory() throws {
    try fileManager.createDirectory(
      at: storageDirectoryURL,
      withIntermediateDirectories: true
    )
    guard try noFollowType(at: storageDirectoryURL) == .directory else {
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
  }

  private func currentStatusIdentifierLocked() throws -> String? {
    guard let data = try readRegularFileIfPresent(
      at: statusURL,
      maximumBytes: Self.maximumStatusBytes
    ) else { return nil }
    return try statusIdentifier(from: data)
  }

  /// A malformed regular status file is app-owned metadata, but none of the
  /// payload or staging paths behind it can be trusted. Remove only that
  /// pointer so a new import can claim the slot; orphan reclamation remains
  /// deliberately preservation-first.
  private func recoverableCurrentStatusIdentifierLocked() throws -> String? {
    do {
      return try currentStatusIdentifierLocked()
    } catch NativeShareEnvelopeStoreError.invalidStatus {
      try removeMalformedStatusLocked()
      return nil
    } catch NativeShareEnvelopeStoreError.invalidIdentifier {
      try removeMalformedStatusLocked()
      return nil
    } catch NativeShareEnvelopeStoreError.invalidEnvelope {
      try removeMalformedStatusLocked()
      return nil
    }
  }

  private func removeMalformedStatusLocked() throws {
    guard try noFollowType(at: statusURL) == .regularFile else {
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
    try fileManager.removeItem(at: statusURL)
    guard try noFollowType(at: statusURL) == .missing else {
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
  }

  private func statusIdentifier(from data: Data) throws -> String {
    guard data.count <= Self.maximumStatusBytes,
          let decoded = try? JSONSerialization.jsonObject(with: data),
          let value = decoded as? [String: Any],
          let rawId = value["id"] as? String,
          let rawProgress = value["isInProgress"] as? NSNumber,
          CFGetTypeID(rawProgress) == CFBooleanGetTypeID() else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    return try validatedIdentifier(rawId)
  }

  private func statusIsInProgress(_ data: Data) -> Bool {
    guard let value = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      let rawProgress = value["isInProgress"] as? NSNumber,
      CFGetTypeID(rawProgress) == CFBooleanGetTypeID() else { return true }
    return rawProgress.boolValue
  }

  private func validatedIdentifier(_ id: String) throws -> String {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let canonical = UUID(uuidString: trimmed)?.uuidString.lowercased(),
          canonical == trimmed.lowercased() else {
      throw NativeShareEnvelopeStoreError.invalidIdentifier
    }
    return canonical
  }

  private func readEnvelopeLocked(id: String) throws -> NativeSharePayloadEnvelope? {
    let canonicalId = try validatedIdentifier(id)
    let data = try readRegularFileIfPresent(
      at: try envelopeURL(id: canonicalId),
      maximumBytes: Self.maximumEnvelopeBytes
    )
    guard let data else { return nil }
    guard let envelope = try? PropertyListDecoder().decode(
      NativeSharePayloadEnvelope.self,
      from: data
    ), envelope.id == canonicalId else {
      throw NativeShareEnvelopeStoreError.invalidEnvelope
    }
    _ = try ownedStagedFileURLs(
      from: envelope.itemsJSON,
      message: envelope.message,
      expectedImportId: envelope.id
    )
    return envelope
  }

  private func discardEnvelopeLocked(
    id: String,
    cleanOwnedFiles: Bool
  ) throws {
    let url = try envelopeURL(id: id)
    guard let envelope = try readEnvelopeLocked(id: id) else { return }
    if cleanOwnedFiles {
      try cleanOwnedStagedFilesLocked(
        id: id,
        itemsJSON: envelope.itemsJSON
      )
    }
    try fileManager.removeItem(at: url)
  }

  private func hasDartOwnershipMarkerLocked(id: String) throws -> Bool {
    switch try noFollowType(at: try dartOwnedURL(id: id)) {
    case .missing:
      return false
    case .regularFile:
      return true
    case .directory, .other:
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
  }

  private func cleanInProgressFilesLocked(id: String) throws {
    switch try noFollowType(at: stagingDirectoryURL) {
    case .missing:
      return
    case .directory:
      break
    case .regularFile, .other:
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
    let prefix = "\(try validatedIdentifier(id))-"
    let entries = try fileManager.contentsOfDirectory(
      at: stagingDirectoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    )
    for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
      guard entry.deletingLastPathComponent().standardizedFileURL.path ==
        stagingDirectoryURL.standardizedFileURL.path else {
        throw NativeShareEnvelopeStoreError.unsafeStagedFile
      }
      switch try noFollowType(at: entry) {
      case .missing:
        continue
      case .regularFile:
        try fileManager.removeItem(at: entry)
      case .directory, .other:
        throw NativeShareEnvelopeStoreError.unsafeStagedFile
      }
    }
  }

  private func migrateLegacyRecordIfNeededLocked() throws {
    guard let defaults = legacyDefaults else { return }
    defaults.synchronize()
    let legacyPayload = defaults.data(forKey: nativeShareLegacyPayloadDefaultsKey)
    let legacyMessage = defaults.string(forKey: nativeShareLegacyMessageDefaultsKey)
    let legacyStatus = defaults.data(forKey: nativeShareLegacyStatusDefaultsKey)
    guard legacyPayload != nil || legacyMessage != nil || legacyStatus != nil else {
      return
    }

    if try noFollowType(at: statusURL) != .missing {
      discardLegacyRecordLocked()
      return
    }

    if let legacyStatus,
       let legacyId = try? statusIdentifier(from: legacyStatus) {
      let normalizedStatus = try normalizedStatusJSON(
        legacyStatus,
        id: legacyId
      )
      if let legacyPayload {
        guard (try? ownedStagedFileURLs(
          from: legacyPayload,
          message: legacyMessage,
          expectedImportId: legacyId
        )) != nil else {
          // A corrupt legacy payload must not wedge every future read. Reclaim
          // only paths that independently pass the owned-root/no-follow
          // checks, then forget the untrusted defaults record.
          discardLegacyRecordLocked(expectedImportId: legacyId)
          return
        }
        let envelope = NativeSharePayloadEnvelope(
          id: legacyId,
          itemsJSON: legacyPayload,
          message: legacyMessage
        )
        let encoded = try PropertyListEncoder().encode(envelope)
        _ = try writeImmutableFile(
          encoded,
          to: try envelopeURL(id: legacyId)
        )
      }
      try writeMutableFile(normalizedStatus, to: statusURL)
      clearLegacyDefaultsLocked()
      return
    }

    discardLegacyRecordLocked()
  }

  private func discardLegacyRecordLocked(expectedImportId: String? = nil) {
    guard let defaults = legacyDefaults else { return }
    defaults.synchronize()
    defer { clearLegacyDefaultsLocked() }
    if let expectedImportId,
       let payload = defaults.data(forKey: nativeShareLegacyPayloadDefaultsKey) {
      for url in bestEffortOwnedStagedFileURLs(
        from: payload,
        expectedImportId: expectedImportId
      ) {
        guard (try? noFollowType(at: url)) == .regularFile else { continue }
        try? fileManager.removeItem(at: url)
      }
    }
  }

  /// Returns only paths that are individually proven to be direct regular
  /// files in the app-owned staging root. Malformed entries and paths outside
  /// that root are preserved; legacy cleanup must never turn corrupt metadata
  /// into an arbitrary-file deletion primitive.
  private func bestEffortOwnedStagedFileURLs(
    from itemsJSON: Data,
    expectedImportId: String
  ) -> Set<URL> {
    guard let items = try? JSONSerialization.jsonObject(with: itemsJSON)
      as? [[String: Any]] else { return [] }
    var urls = Set<URL>()
    for item in items {
      let rawType = (item["type"] as? NSNumber)?.intValue
      if let rawType, [2, 3, 4].contains(rawType),
         let value = item["value"] as? String ?? item["path"] as? String {
        do {
          if let url = try ownedStagedFileURL(
            from: value,
            expectedImportId: expectedImportId
          ) { urls.insert(url) }
        } catch {}
      }
      if let thumbnail = item["thumbnail"] as? String {
        do {
          if let url = try ownedStagedFileURL(
            from: thumbnail,
            expectedImportId: expectedImportId
          ) { urls.insert(url) }
        } catch {}
      }
    }
    return urls
  }

  private func clearLegacyDefaultsLocked() {
    guard let defaults = legacyDefaults else { return }
    defaults.removeObject(forKey: nativeShareLegacyPayloadDefaultsKey)
    defaults.removeObject(forKey: nativeShareLegacyMessageDefaultsKey)
    defaults.removeObject(forKey: nativeShareLegacyStatusDefaultsKey)
    defaults.synchronize()
  }

  private func normalizedStatusJSON(_ data: Data, id: String) throws -> Data {
    guard var value = try JSONSerialization.jsonObject(with: data)
      as? [String: Any] else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    value["id"] = id
    guard JSONSerialization.isValidJSONObject(value) else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    return try JSONSerialization.data(withJSONObject: value)
  }

  private func cleanOwnedStagedFilesLocked(
    id: String,
    itemsJSON: Data
  ) throws {
    for url in try ownedStagedFileURLs(
      from: itemsJSON,
      expectedImportId: id
    ) {
      switch try noFollowType(at: url) {
      case .missing:
        continue
      case .regularFile:
        try fileManager.removeItem(at: url)
        guard try noFollowType(at: url) == .missing else {
          throw NativeShareEnvelopeStoreError.unsafeStagedFile
        }
      case .directory, .other:
        throw NativeShareEnvelopeStoreError.unsafeStagedFile
      }
    }
  }

  private func ownedStagedFileURLs(
    from itemsJSON: Data,
    message: String? = nil,
    expectedImportId: String
  ) throws -> Set<URL> {
    let canonicalId = try validatedIdentifier(expectedImportId)
    guard itemsJSON.count <= Self.maximumItemsJSONBytes,
          let items = try JSONSerialization.jsonObject(with: itemsJSON)
            as? [[String: Any]],
          !items.isEmpty,
          items.count <= nativeShareMaximumItemCount else {
      throw NativeShareEnvelopeStoreError.invalidEnvelope
    }
    if let message,
       message.utf8.count > nativeShareMaximumTextBytes {
      throw NativeShareEnvelopeStoreError.invalidEnvelope
    }

    var urls = Set<URL>()
    var aggregateTextBytes = 0
    for item in items {
      guard let rawType = item["type"] as? NSNumber,
            CFGetTypeID(rawType) != CFBooleanGetTypeID(),
            rawType.doubleValue == Double(rawType.intValue),
            (0...4).contains(rawType.intValue),
            let value = item["value"] as? String ?? item["path"] as? String else {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }

      switch rawType.intValue {
      case 0:
        guard value.utf8.count <= nativeShareMaximumTextBytes else {
          throw NativeShareEnvelopeStoreError.invalidEnvelope
        }
        aggregateTextBytes += value.utf8.count
      case 1:
        guard value.utf8.count <= nativeShareMaximumURLBytes else {
          throw NativeShareEnvelopeStoreError.invalidEnvelope
        }
        aggregateTextBytes += value.utf8.count
      case 2, 3, 4:
        guard let url = try ownedStagedFileURL(
          from: value,
          expectedImportId: canonicalId
        ) else {
          throw NativeShareEnvelopeStoreError.invalidEnvelope
        }
        urls.insert(url)
      default:
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }

      if let itemMessage = item["message"] as? String {
        guard itemMessage.utf8.count <= nativeShareMaximumTextBytes else {
          throw NativeShareEnvelopeStoreError.invalidEnvelope
        }
        aggregateTextBytes += itemMessage.utf8.count
      }
      if let mimeType = item["mimeType"] as? String,
         mimeType.utf8.count > 1_024 {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }
      if let thumbnail = item["thumbnail"] as? String,
         let url = try ownedStagedFileURL(
          from: thumbnail,
          expectedImportId: canonicalId
         ) {
        urls.insert(url)
      }
      guard aggregateTextBytes <= nativeShareMaximumAggregateTextBytes else {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }
    }
    return urls
  }

  private func ownedStagedFileURL(
    from rawValue: String,
    expectedImportId: String
  ) throws -> URL? {
    let candidate: URL
    if rawValue.lowercased().hasPrefix("file:") {
      guard let parsed = URL(string: rawValue), parsed.isFileURL else {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }
      candidate = parsed.standardizedFileURL
    } else if rawValue.hasPrefix("/") {
      candidate = URL(fileURLWithPath: rawValue).standardizedFileURL
    } else {
      return nil
    }

    let root = stagingDirectoryURL.standardizedFileURL
    guard candidate.deletingLastPathComponent().path == root.path,
          hasOwnedStagingName(
            candidate.lastPathComponent,
            expectedImportId: expectedImportId
          ) else {
      return nil
    }
    switch try noFollowType(at: root) {
    case .missing:
      return candidate
    case .directory:
      break
    case .regularFile, .other:
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
    switch try noFollowType(at: candidate) {
    case .missing, .regularFile:
      return candidate
    case .directory, .other:
      throw NativeShareEnvelopeStoreError.unsafeStagedFile
    }
  }

  private func hasOwnedStagingName(
    _ name: String,
    expectedImportId: String
  ) -> Bool {
    let prefix = "\(expectedImportId)-"
    return name.count > prefix.count && name.hasPrefix(prefix)
  }

  @discardableResult
  private func writeImmutableFile(_ data: Data, to url: URL) throws -> Bool {
    guard data.count <= Self.maximumEnvelopeBytes else {
      throw NativeShareEnvelopeStoreError.invalidEnvelope
    }
    if let existing = try readRegularFileIfPresent(
      at: url,
      maximumBytes: Self.maximumEnvelopeBytes
    ) {
      guard existing == data else {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }
      return false
    }
    let temporaryURL = storageDirectoryURL.appendingPathComponent(
      ".tmp-\(UUID().uuidString.lowercased())"
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }
    try data.write(to: temporaryURL, options: .withoutOverwriting)
    let result = temporaryURL.path.withCString { source in
      url.path.withCString { destination in
        renameatx_np(
          AT_FDCWD,
          source,
          AT_FDCWD,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard result == 0 else {
      if errno == EEXIST,
         let existing = try readRegularFileIfPresent(
          at: url,
          maximumBytes: Self.maximumEnvelopeBytes
         ), existing == data {
        return false
      }
      throw NativeShareEnvelopeStoreError.coordinationFailed(errno)
    }
    return true
  }

  private func writeMutableFile(_ data: Data, to url: URL) throws {
    guard data.count <= Self.maximumStatusBytes else {
      throw NativeShareEnvelopeStoreError.invalidStatus
    }
    if url.standardizedFileURL == statusURL.standardizedFileURL,
       let statusWriteOverrideForTesting {
      try statusWriteOverrideForTesting(data, url)
      return
    }
    let temporaryURL = storageDirectoryURL.appendingPathComponent(
      ".tmp-\(UUID().uuidString.lowercased())"
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }
    try data.write(to: temporaryURL, options: .withoutOverwriting)
    let result = temporaryURL.path.withCString { source in
      url.path.withCString { destination in rename(source, destination) }
    }
    guard result == 0 else {
      throw NativeShareEnvelopeStoreError.coordinationFailed(errno)
    }
  }

  private func readRegularFileIfPresent(
    at url: URL,
    maximumBytes: Int
  ) throws -> Data? {
    switch try noFollowType(at: url) {
    case .missing:
      return nil
    case .regularFile:
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count <= maximumBytes else {
        throw NativeShareEnvelopeStoreError.invalidEnvelope
      }
      return data
    case .directory, .other:
      throw NativeShareEnvelopeStoreError.invalidStorage
    }
  }

  private enum NoFollowType: Equatable {
    case missing
    case regularFile
    case directory
    case other
  }

  private func noFollowType(at url: URL) throws -> NoFollowType {
    var metadata = stat()
    let result = url.path.withCString { lstat($0, &metadata) }
    if result != 0 {
      if errno == ENOENT { return .missing }
      throw NativeShareEnvelopeStoreError.coordinationFailed(errno)
    }
    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG):
      return .regularFile
    case mode_t(S_IFDIR):
      return .directory
    default:
      return .other
    }
  }
}
