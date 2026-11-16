// The hand-off between the Share extension and Conduit.
//
// The extension is sandboxed (every app extension is) and Conduit is not,
// so they meet in one folder the extension's entitlements open to it:
//
//   ~/Library/Caches/<app bundle id>.share-inbox/<uuid>/
//     manifest.json        what was shared (ShareManifest)
//     files/<n>/<name>     a copy of each shared file, under its own name
//
// A share is written into `<uuid>.part` and renamed to `<uuid>` once its
// manifest is complete, so Conduit never reads half a share. The extension
// then opens `conduit://share/<uuid>` with its own containing app (never
// whichever app owns the scheme), and Conduit starts a new chat from the
// folder: the text in the message field, the files attached, nothing sent.
// Conduit marks a share it took and clears old ones; the extension clears
// a share that was cancelled.
//
// Plain Foundation, so tests/InboxTests.swift can run it without a host.

import Foundation

/// What one share holds. The JSON keys are read by Conduit
/// (desktop/crates/app/src/shell/share_inbox.rs); change both together.
struct ShareManifest: Codable, Equatable {
  var version = ShareManifest.currentVersion
  /// What the user typed in the sheet.
  var message: String?
  /// Text items (a selection, a note), in the order shared.
  var texts: [String] = []
  /// Web links, in the order shared.
  var urls: [String] = []
  /// Files copied into the share, in the order shared.
  var files: [ShareFile] = []
  /// Names of files over the size limit (not copied).
  var tooLarge: [String] = []
  /// Files past the count limit (not copied).
  var tooMany = 0

  static let currentVersion = 1

  var isEmpty: Bool {
    (message ?? "").isEmpty && texts.isEmpty && urls.isEmpty && files.isEmpty
  }
}

struct ShareFile: Codable, Equatable {
  /// The name the attachment gets.
  var name: String
  /// Where the copy is, relative to the share's folder.
  var path: String
}

/// The limits Conduit's "Open with" applies too (shell/open_files.rs).
enum ShareLimits {
  static let maxFiles = 10
  static let maxFileBytes: Int64 = 256 * 1024 * 1024
  /// The longest text item kept, in characters.
  static let maxTextCharacters = 100_000
}

enum ShareInboxError: Error {
  case notAFile
  case published
}

/// What happened to one item handed to a draft.
enum ShareAddResult: Equatable {
  case added
  case duplicate
  case empty
  case tooLarge
  case tooMany
  case notAFile
  /// The share was published or discarded: nothing more goes in.
  case closed
}

/// One item provider's answer, taken only while the share waits for it.
/// The wait ends at its timeout or at the answer; an answer that comes
/// after that is refused (`deliver` returns false), so a slow provider
/// can never put into the share an item its sheet never showed.
final class ShareWait<Value> {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var value: Value?
  private var closed = false

  /// Hands over the answer; false when the wait is over, and the caller
  /// cleans up what it made for it.
  func deliver(_ answer: Value?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return false }
    value = answer
    closed = true
    done.signal()
    return true
  }

  /// Waits for the answer until `deadline`, then takes no more.
  func wait(until deadline: DispatchTime) -> Value? {
    _ = done.wait(timeout: deadline)
    lock.lock()
    defer { lock.unlock() }
    closed = true
    return value
  }
}

enum ShareInbox {
  /// The folder name under ~/Library/Caches for `appBundleID`.
  static func folderName(appBundleID: String) -> String {
    "\(appBundleID).share-inbox"
  }

  /// The inbox for `appBundleID` under `home` (the user's real home: a
  /// sandboxed process's NSHomeDirectory() is its container).
  static func root(appBundleID: String, home: URL) -> URL {
    home.appendingPathComponent("Library/Caches", isDirectory: true)
      .appendingPathComponent(folderName(appBundleID: appBundleID), isDirectory: true)
  }

  /// The user's home folder, from the password database (outside the
  /// container).
  static func realHome() -> URL {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// A new, empty share under `root`.
  static func begin(root: URL, fileManager: FileManager = .default) throws -> ShareDraft {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let dir = root.appendingPathComponent("\(id).part", isDirectory: true)
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
    return ShareDraft(id: id, root: root, dir: dir, fileManager: fileManager)
  }

  /// The link that hands share `id` to Conduit.
  static func link(id: String) -> URL? {
    URL(string: "conduit://share/\(id)")
  }
}

/// One share being put together. Not thread-safe: the extension calls it
/// from one serial queue.
final class ShareDraft {
  let id: String
  let root: URL
  private(set) var dir: URL
  private(set) var manifest = ShareManifest()
  private let fileManager: FileManager
  private var seenTexts = Set<String>()
  private var published = false
  private var discarded = false

  init(id: String, root: URL, dir: URL, fileManager: FileManager) {
    self.id = id
    self.root = root
    self.dir = dir
    self.fileManager = fileManager
  }

  /// A text item: trimmed, cut to the limit, kept once.
  @discardableResult
  func addText(_ raw: String) -> ShareAddResult {
    if published || discarded { return .closed }
    let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(ShareLimits.maxTextCharacters))
    if text.isEmpty { return .empty }
    guard seenTexts.insert(text).inserted else { return .duplicate }
    manifest.texts.append(text)
    return .added
  }

  /// A web link, kept once (and never also as text).
  @discardableResult
  func addURL(_ url: URL) -> ShareAddResult {
    if published || discarded { return .closed }
    let text = url.absoluteString
    if text.isEmpty { return .empty }
    guard seenTexts.insert(text).inserted else { return .duplicate }
    manifest.urls.append(text)
    return .added
  }

  /// Copies the file at `source` into the share (a clone on APFS).
  @discardableResult
  func addFile(copying source: URL, name: String? = nil) throws -> ShareAddResult {
    if published || discarded { return .closed }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { return .notAFile }
    let fileName = ShareDraft.safeName(name ?? source.lastPathComponent)
    if let check = admit(name: fileName, bytes: Int64(values.fileSize ?? 0)) { return check }
    let (destination, relative) = try slot(for: fileName)
    try fileManager.copyItem(at: source, to: destination)
    manifest.files.append(ShareFile(name: fileName, path: relative))
    return .added
  }

  /// Writes `data` into the share as a file named `name`.
  @discardableResult
  func addData(_ data: Data, name: String) throws -> ShareAddResult {
    if published || discarded { return .closed }
    let fileName = ShareDraft.safeName(name)
    if let check = admit(name: fileName, bytes: Int64(data.count)) { return check }
    let (destination, relative) = try slot(for: fileName)
    try data.write(to: destination, options: .withoutOverwriting)
    manifest.files.append(ShareFile(name: fileName, path: relative))
    return .added
  }

  /// Finishes the share: the manifest, then the folder under its final
  /// name. Returns the id the link carries.
  func publish(message: String?) throws -> String {
    guard !published, !discarded else { throw ShareInboxError.published }
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    manifest.message = trimmed.isEmpty
      ? nil : String(trimmed.prefix(ShareLimits.maxTextCharacters))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: dir.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    let final = root.appendingPathComponent(id, isDirectory: true)
    try fileManager.moveItem(at: dir, to: final)
    dir = final
    published = true
    return id
  }

  /// Removes an unpublished share (Cancel, or a failure before the hand-off).
  func discard() {
    guard !published else { return }
    discarded = true
    try? fileManager.removeItem(at: dir)
  }

  /// Takes a published share back when Conduit could not be opened, so it
  /// does not wait in the inbox until it is cleared.
  func withdraw() {
    guard published else { return }
    try? fileManager.removeItem(at: dir)
  }

  // MARK: - Private

  private func admit(name: String, bytes: Int64) -> ShareAddResult? {
    if bytes > ShareLimits.maxFileBytes {
      manifest.tooLarge.append(name)
      return .tooLarge
    }
    if manifest.files.count >= ShareLimits.maxFiles {
      manifest.tooMany += 1
      return .tooMany
    }
    return nil
  }

  /// `files/<n>/<name>`: one folder per file, so two files may share a
  /// name. Returns the file's URL and its path relative to the share.
  private func slot(for name: String) throws -> (URL, String) {
    let index = String(manifest.files.count)
    let folder = dir.appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(index, isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder.appendingPathComponent(name, isDirectory: false), "files/\(index)/\(name)")
  }

  /// A file name that stays one path component: no slashes, no leading
  /// dots, no control characters, at most 200 characters.
  static func safeName(_ raw: String) -> String {
    var name = raw.unicodeScalars.map { scalar -> Character in
      if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
        return "-"
      }
      return Character(scalar)
    }.reduce(into: "") { $0.append($1) }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while name.hasPrefix(".") { name.removeFirst() }
    if name.count > 200 {
      let ext = (name as NSString).pathExtension
      let keep = 200 - (ext.isEmpty ? 0 : ext.count + 1)
      let stem = String((name as NSString).deletingPathExtension.prefix(max(keep, 1)))
      name = ext.isEmpty ? stem : "\(stem).\(ext)"
    }
    return name.isEmpty ? "File" : name
  }
}
