import Darwin
import Flutter
import Foundation

private let conduitShareChannelName = "conduit/share_receiver_text"
private let conduitShareAppGroupIdKey = "AppGroupId"

func nativeSharedPayloadTypeIsText(_ type: Any?) -> Bool {
  if let type = type as? String {
    return type == "text" || type == "url"
  }
  if let type = type as? NSNumber {
    // JSON booleans bridge through NSNumber, where false.intValue is 0 and
    // true.intValue is 1. They are not valid share-media type codes.
    guard CFGetTypeID(type) != CFBooleanGetTypeID() else { return false }
    let value = type.intValue
    return value == 0 || value == 1 || value == 5
  }
  if let type = type as? Int {
    return type == 0 || type == 1 || type == 5
  }
  return false
}

/// Builds the acknowledgement-bearing payload only from a complete native
/// record. Returning content without its durable status identifier would make
/// the record impossible for Dart to acknowledge and permanently wedge the
/// pending-share signal.
func nativeValidatedShareImportPayload(
  rawItems: [[String: Any]],
  message: String?,
  status: [String: Any]?,
  shareStagingDirectoryPath: String?
) -> [String: Any]? {
  guard let id = (status?["id"] as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines),
    !id.isEmpty else {
    return nil
  }

  var textParts: [String] = []
  var seenText = Set<String>()
  var filePaths: [String] = []
  var seenFilePaths = Set<String>()

  func addText(_ value: String?) {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty,
          seenText.insert(trimmed).inserted else { return }
    textParts.append(trimmed)
  }

  func addFilePath(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !value.isEmpty else { return false }

    let path: String
    if value.lowercased().hasPrefix("file:") {
      guard let url = URL(string: value), url.isFileURL,
            url.host == nil || url.host?.isEmpty == true ||
              url.host?.lowercased() == "localhost" else {
        return false
      }
      path = url.standardizedFileURL.path
    } else {
      guard value.hasPrefix("/") else { return false }
      path = URL(fileURLWithPath: value).standardizedFileURL.path
    }
    guard !path.isEmpty, path.hasPrefix("/"),
          let rawRoot = shareStagingDirectoryPath,
          rawRoot.hasPrefix("/") else { return false }
    let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    let canonicalCandidate = candidate.resolvingSymlinksInPath()
      .standardizedFileURL
    guard canonicalCandidate.deletingLastPathComponent().path == root.path else {
      return false
    }
    var rootMetadata = stat()
    var candidateMetadata = stat()
    guard root.path.withCString({ lstat($0, &rootMetadata) }) == 0,
          rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          candidate.path.withCString({ lstat($0, &candidateMetadata) }) == 0,
          candidateMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      return false
    }
    if seenFilePaths.insert(canonicalCandidate.path).inserted {
      filePaths.append(canonicalCandidate.path)
    }
    return true
  }

  addText(message)
  for item in rawItems {
    // Every encoded media entry must carry both its type and content. Treat a
    // partially decoded map as corruption instead of silently returning an
    // unacknowledgeable or truncated handoff.
    guard item["type"] != nil,
          let value = item["path"] as? String ?? item["value"] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    if nativeSharedPayloadTypeIsText(item["type"]) {
      addText(value)
    } else {
      guard addFilePath(value) else { return nil }
    }
  }

  guard !textParts.isEmpty || !filePaths.isEmpty else { return nil }
  var payload: [String: Any] = [
    "id": id,
    "filePaths": filePaths,
  ]
  if !textParts.isEmpty {
    payload["text"] = textParts.joined(separator: "\n")
  }
  return payload
}
