import AVFoundation
import MobileCoreServices
import UniformTypeIdentifiers
import UIKit

private let shareSchemePrefix = "SharingMedia"
private let shareUserDefaultsKey = "SharingKey"
private let shareUserDefaultsMessageKey = "SharingMessageKey"
private let shareImportStatusKey = "ShareImportStatusKey"
private let shareAppGroupIdKey = "AppGroupId"
private let shareStagingDirectoryName = "conduit-shared-intents"
private let maxSharedFileCount = 6
private let maxSharedImageBytes: Int64 = 20 * 1024 * 1024

private struct SharedMediaFile: Codable {
  let value: String
  let mimeType: String?
  let thumbnail: String?
  let duration: Double?
  let message: String?
  let type: SharedMediaType

  init(
    value: String,
    mimeType: String? = nil,
    thumbnail: String? = nil,
    duration: Double? = nil,
    message: String? = nil,
    type: SharedMediaType
  ) {
    self.value = value
    self.mimeType = mimeType
    self.thumbnail = thumbnail
    self.duration = duration
    self.message = message
    self.type = type
  }
}

private enum SharedMediaType: Int, Codable, CaseIterable {
  case image = 2
  case video = 3
  case text = 0
  case file = 4
  case url = 1

  var toUTTypeIdentifier: String {
    switch self {
    case .image:
      return UTType.image.identifier
    case .video:
      return UTType.movie.identifier
    case .text:
      return UTType.text.identifier
    case .file:
      return UTType.fileURL.identifier
    case .url:
      return UTType.url.identifier
    }
  }

  var isFileBacked: Bool {
    switch self {
    case .image, .video, .file:
      return true
    case .text, .url:
      return false
    }
  }
}

private struct SupportedShareType {
  let mediaType: SharedMediaType
  let itemTypeIdentifier: String
}

final class ShareViewController: UIViewController {
  private var hostAppBundleIdentifier = ""
  private var appGroupId = ""
  private var didBeginLoading = false
  private var didOpenHostApp = false
  private var didFinishShare = false
  private let shareImportId = UUID().uuidString
  private var expectedImportFileCount = 0
  private var importErrors: [String] = []
  private var sharedMedia: [(ordinal: Int, media: SharedMediaFile)] = []
  private let sharedMediaLock = NSLock()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.isHidden = true
    loadIds()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    guard !didBeginLoading else { return }
    didBeginLoading = true
    loadSharedItems { [weak self] in
      guard let self else { return }
      saveAndRedirect()
    }
  }

  private func loadSharedItems(completion: @escaping () -> Void) {
    let inputItems = extensionContext?.inputItems.compactMap {
      $0 as? NSExtensionItem
    } ?? []
    var expectedFileBackedCount = 0
    for item in inputItems {
      for attachment in item.attachments ?? [] {
        guard let supportedType = supportedType(for: attachment),
              supportedType.mediaType.isFileBacked else {
          continue
        }
        expectedFileBackedCount += 1
      }
    }
    expectedImportFileCount = min(expectedFileBackedCount, maxSharedFileCount)
    if expectedFileBackedCount > maxSharedFileCount {
      recordImportError("Only the first \(maxSharedFileCount) shared attachments were imported.")
    }
    if expectedImportFileCount > 0 {
      storeShareImportStatus(isInProgress: true)
      openHostApp()
    }

    let group = DispatchGroup()
    var ordinal = 0
    var fileBackedCount = 0

    for item in inputItems {
      for attachment in item.attachments ?? [] {
        guard let supportedType = supportedType(for: attachment) else { continue }
        let type = supportedType.mediaType
        if type.isFileBacked {
          guard fileBackedCount < maxSharedFileCount else { continue }
          fileBackedCount += 1
        }

        let currentOrdinal = ordinal
        ordinal += 1
        group.enter()
        attachment.loadItem(forTypeIdentifier: supportedType.itemTypeIdentifier) {
          [weak self] data, error in
          defer { group.leave() }
          guard let self else { return }
          if let error {
            recordImportError("Could not import shared attachment: \(error.localizedDescription)")
            return
          }
          handleLoadedItem(data, type: type, ordinal: currentOrdinal)
        }
      }
    }

    group.notify(queue: .main, execute: completion)
  }

  private func supportedType(for attachment: NSItemProvider) -> SupportedShareType? {
    for type in SharedMediaType.allCases {
      let identifier = type.toUTTypeIdentifier
      if attachment.hasItemConformingToTypeIdentifier(identifier) {
        return SupportedShareType(
          mediaType: type,
          itemTypeIdentifier: identifier
        )
      }
    }

    let dataIdentifier = UTType.data.identifier
    if attachment.hasItemConformingToTypeIdentifier(dataIdentifier) {
      return SupportedShareType(
        mediaType: .file,
        itemTypeIdentifier: dataIdentifier
      )
    }

    return nil
  }

  private func handleLoadedItem(
    _ data: NSSecureCoding?,
    type: SharedMediaType,
    ordinal: Int
  ) {
    switch type {
    case .text:
      if let text = data as? String {
        appendMedia(
          SharedMediaFile(value: text, mimeType: "text/plain", type: type),
          ordinal: ordinal
        )
      } else if let textData = data as? Data,
                let text = String(data: textData, encoding: .utf8) {
        appendMedia(
          SharedMediaFile(value: text, mimeType: "text/plain", type: type),
          ordinal: ordinal
        )
      }
    case .url:
      if let url = data as? URL {
        appendMedia(SharedMediaFile(value: url.absoluteString, type: type), ordinal: ordinal)
      } else if let text = data as? String {
        appendMedia(SharedMediaFile(value: text, type: type), ordinal: ordinal)
      }
    case .image:
      if let url = data as? URL {
        stageFile(at: url, type: type, ordinal: ordinal)
      } else if let image = data as? UIImage {
        stageImage(image, ordinal: ordinal)
      } else if let imageData = data as? Data {
        stageData(imageData, type: type, ordinal: ordinal, fallbackExtension: "png")
      }
    case .video:
      if let url = data as? URL {
        stageFile(at: url, type: type, ordinal: ordinal)
      } else if let videoData = data as? Data {
        stageData(videoData, type: type, ordinal: ordinal, fallbackExtension: "mp4")
      }
    case .file:
      if let url = data as? URL {
        stageFile(at: url, type: type, ordinal: ordinal)
      } else if let fileData = data as? Data {
        stageData(fileData, type: type, ordinal: ordinal, fallbackExtension: "dat")
      }
    }
  }

  private func stageFile(at sourceURL: URL, type: SharedMediaType, ordinal: Int) {
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let maxBytes = maxSharedBytes(for: type, url: sourceURL)
    if let maxBytes,
       let size = fileSize(sourceURL),
       size > maxBytes {
      recordImportError("\(sourceURL.lastPathComponent) is larger than the 20 MB image limit.")
      return
    }
    guard let destinationURL = destinationURL(
      originalName: sourceURL.lastPathComponent,
      fallbackExtension: fallbackExtension(for: type),
      ordinal: ordinal
    ) else { return }
    guard copyFile(at: sourceURL, to: destinationURL, maxBytes: maxBytes) else {
      recordImportError("Could not import \(sourceURL.lastPathComponent).")
      return
    }

    let decodedPath = destinationURL.absoluteString.removingPercentEncoding
      ?? destinationURL.absoluteString
    if type == .video {
      appendMedia(
        SharedMediaFile(
          value: decodedPath,
          mimeType: destinationURL.mimeType(),
          duration: videoDuration(from: sourceURL),
          type: type
        ),
        ordinal: ordinal
      )
      return
    }

    appendMedia(
      SharedMediaFile(
        value: decodedPath,
        mimeType: destinationURL.mimeType(),
        type: type
      ),
      ordinal: ordinal
    )
  }

  private func stageImage(_ image: UIImage, ordinal: Int) {
    guard let data = image.pngData() else { return }
    stageData(data, type: .image, ordinal: ordinal, fallbackExtension: "png")
  }

  private func stageData(
    _ data: Data,
    type: SharedMediaType,
    ordinal: Int,
    fallbackExtension: String
  ) {
    if let maxBytes = maxSharedBytes(for: type),
       Int64(data.count) > maxBytes {
      recordImportError("Shared image is larger than the 20 MB image limit.")
      return
    }
    guard let destinationURL = destinationURL(
      originalName: nil,
      fallbackExtension: fallbackExtension,
      ordinal: ordinal
    ) else { return }

    do {
      try data.write(to: destinationURL, options: .atomic)
    } catch {
      recordImportError("Could not import shared attachment: \(error.localizedDescription)")
      return
    }

    appendMedia(
      SharedMediaFile(
        value: destinationURL.absoluteString.removingPercentEncoding ?? destinationURL.absoluteString,
        mimeType: destinationURL.mimeType(),
        type: type
      ),
      ordinal: ordinal
    )
  }

  private func appendMedia(_ media: SharedMediaFile, ordinal: Int) {
    sharedMediaLock.lock()
    sharedMedia.append((ordinal: ordinal, media: media))
    sharedMediaLock.unlock()
  }

  private func loadIds() {
    guard
      let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier,
      let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".")
    else {
      return
    }

    hostAppBundleIdentifier = String(
      shareExtensionAppBundleIdentifier[..<lastIndexOfPoint]
    )
    let defaultAppGroupId = "group.\(hostAppBundleIdentifier)"
    appGroupId = (Bundle.main.object(forInfoDictionaryKey: shareAppGroupIdKey) as? String)
      ?? defaultAppGroupId
  }

  private func saveAndRedirect(message: String? = nil) {
    guard !didFinishShare else { return }
    didFinishShare = true

    let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    var media = sortedMedia()
    var messageToStore = trimmedMessage
    if media.isEmpty, let trimmedMessage, !trimmedMessage.isEmpty {
      media = [
        SharedMediaFile(
          value: trimmedMessage,
          mimeType: "text/plain",
          type: .text
        ),
      ]
      messageToStore = nil
    }

    guard !media.isEmpty else {
      storeShareImportStatus(isInProgress: false)
      extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      return
    }

    let userDefaults = UserDefaults(suiteName: appGroupId)
    userDefaults?.set(toData(data: media), forKey: shareUserDefaultsKey)
    if let messageToStore, !messageToStore.isEmpty {
      userDefaults?.set(messageToStore, forKey: shareUserDefaultsMessageKey)
    } else {
      userDefaults?.removeObject(forKey: shareUserDefaultsMessageKey)
    }
    storeShareImportStatus(isInProgress: false, userDefaults: userDefaults)
    userDefaults?.synchronize()
    redirectToHostApp()
  }

  private func sortedMedia() -> [SharedMediaFile] {
    sharedMediaLock.lock()
    let media = sharedMedia.sorted { $0.ordinal < $1.ordinal }.map(\.media)
    sharedMediaLock.unlock()
    return media
  }

  private func openHostApp() {
    guard !didOpenHostApp else { return }
    didOpenHostApp = true

    loadIds()
    guard let url = URL(string: "\(shareSchemePrefix)-\(hostAppBundleIdentifier):share") else {
      return
    }
    var responder = self as UIResponder?

    if #available(iOS 18.0, *) {
      while responder != nil {
        if let application = responder as? UIApplication {
          application.open(url, options: [:], completionHandler: nil)
        }
        responder = responder?.next
      }
    } else {
      let selectorOpenURL = sel_registerName("openURL:")

      while responder != nil {
        if responder?.responds(to: selectorOpenURL) == true {
          _ = responder?.perform(selectorOpenURL, with: url)
        }
        responder = responder?.next
      }
    }
  }

  private func redirectToHostApp() {
    openHostApp()
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
  }

  private func recordImportError(_ message: String) {
    sharedMediaLock.lock()
    if !importErrors.contains(message) {
      importErrors.append(message)
    }
    sharedMediaLock.unlock()
  }

  private func storeShareImportStatus(
    isInProgress: Bool,
    userDefaults: UserDefaults? = nil
  ) {
    guard expectedImportFileCount > 0 || !importErrors.isEmpty else { return }

    let defaults = userDefaults ?? UserDefaults(suiteName: appGroupId)
    let payload: [String: Any] = [
      "id": shareImportId,
      "expectedFileCount": expectedImportFileCount,
      "isInProgress": isInProgress,
      "errors": importErrors,
    ]
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload)
    else {
      return
    }

    defaults?.set(data, forKey: shareImportStatusKey)
    defaults?.synchronize()
  }

  private func destinationURL(
    originalName: String?,
    fallbackExtension: String,
    ordinal: Int
  ) -> URL? {
    guard let containerURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
      return nil
    }
    let directoryURL = containerURL.appendingPathComponent(
      shareStagingDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      return nil
    }

    let rawName = originalName?.isEmpty == false
      ? originalName!
      : "\(UUID().uuidString).\(fallbackExtension)"
    return directoryURL
      .appendingPathComponent("\(UUID().uuidString)-\(ordinal)-\(sanitizedFileName(rawName))")
  }

  private func sanitizedFileName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
      .union(.newlines)
      .union(.controlCharacters)
    return name.components(separatedBy: invalid).joined(separator: "-")
  }

  private func fileSize(_ url: URL) -> Int64? {
    if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
       let fileSize = values.fileSize {
      return Int64(fileSize)
    }

    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber else {
      return nil
    }
    return size.int64Value
  }

  private func copyFile(at srcURL: URL, to dstURL: URL, maxBytes: Int64?) -> Bool {
    do {
      if FileManager.default.fileExists(atPath: dstURL.path) {
        try FileManager.default.removeItem(at: dstURL)
      }
      FileManager.default.createFile(atPath: dstURL.path, contents: nil)
      let input = try FileHandle(forReadingFrom: srcURL)
      let output = try FileHandle(forWritingTo: dstURL)
      defer {
        try? input.close()
        try? output.close()
      }

      var copiedBytes: Int64 = 0
      while true {
        let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty { break }
        copiedBytes += Int64(chunk.count)
        if let maxBytes, copiedBytes > maxBytes {
          try? FileManager.default.removeItem(at: dstURL)
          return false
        }
        output.write(chunk)
      }
      return true
    } catch {
      try? FileManager.default.removeItem(at: dstURL)
      return false
    }
  }

  private func videoDuration(from url: URL) -> Double? {
    let asset = AVAsset(url: url)
    let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
    return duration.isFinite ? duration : nil
  }

  private func maxSharedBytes(for type: SharedMediaType, url: URL? = nil) -> Int64? {
    if type == .image {
      return maxSharedImageBytes
    }
    if type == .file,
       let url,
       UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
      return maxSharedImageBytes
    }
    return nil
  }

  private func fallbackExtension(for type: SharedMediaType) -> String {
    switch type {
    case .image:
      return "png"
    case .video:
      return "mp4"
    case .text:
      return "txt"
    case .file:
      return "dat"
    case .url:
      return "url"
    }
  }

  private func toData(data: [SharedMediaFile]) -> Data {
    (try? JSONEncoder().encode(data)) ?? Data()
  }
}

private extension URL {
  func mimeType() -> String {
    UTType(filenameExtension: pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
  }
}
