import AVFoundation
import MobileCoreServices
import UniformTypeIdentifiers
import UIKit

private let shareSchemePrefix = "SharingMedia"
private let shareAppGroupIdKey = "AppGroupId"
private let maxSharedFileCount = nativeShareMaximumFileCount
private let maxSharedItemCount = nativeShareMaximumItemCount
private let maxSharedImageBytes: Int64 = 20 * 1024 * 1024
private let maxSharedVideoBytes: Int64 = 250 * 1024 * 1024
private let maxSharedGenericFileBytes: Int64 = 100 * 1024 * 1024
private let maxSharedAggregateBytes: Int64 = 300 * 1024 * 1024
private let maxSharedTextBytes = nativeShareMaximumTextBytes
private let maxSharedUrlBytes = nativeShareMaximumURLBytes
final class ShareLoadDeadline {
  private let lock = NSLock()
  private var active = true

  var isActive: Bool {
    lock.lock()
    let value = active
    lock.unlock()
    return value
  }

  @discardableResult
  func performIfActive(_ action: () -> Void) -> Bool {
    lock.lock()
    guard active else {
      lock.unlock()
      return false
    }
    action()
    lock.unlock()
    return true
  }

  @discardableResult
  func finish() -> Bool {
    lock.lock()
    guard active else {
      lock.unlock()
      return false
    }
    active = false
    lock.unlock()
    return true
  }
}

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

private struct ShareLoadTask {
  let provider: NSItemProvider
  let supportedType: SupportedShareType
  let ordinal: Int
}

final class ShareViewController: UIViewController {
  private var hostAppBundleIdentifier = ""
  private var appGroupId = ""
  private var didBeginLoading = false
  private var didOpenHostApp = false
  private var didFinishShare = false
  private let shareImportId = UUID().uuidString.lowercased()
  private var expectedImportFileCount = 0
  private var importErrors: [String] = []
  private var sharedMedia: [(ordinal: Int, media: SharedMediaFile)] = []
  private let sharedMediaLock = NSLock()
  private var stagedByteCount: Int64 = 0
  private let loadDeadline = ShareLoadDeadline()
  private var loadWatchdog: DispatchWorkItem?
  private var envelopeStore: NativeShareEnvelopeStore?
  private var ownsImportSlot = false
  private let envelopeQueue = DispatchQueue(
    label: "app.cogwheel.conduit.share-extension-envelope",
    qos: .utility
  )

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
      self?.completeShareLoading()
    }
  }

  deinit {
    loadWatchdog?.cancel()
  }

  private func startLoadWatchdog(interval: TimeInterval) {
    guard loadWatchdog == nil else { return }
    let watchdog = DispatchWorkItem { [weak self] in
      guard let self, loadDeadline.isActive else { return }
      recordImportError("Share import timed out before every attachment finished loading.")
      completeShareLoading()
    }
    loadWatchdog = watchdog
    DispatchQueue.main.asyncAfter(
      deadline: .now() + interval,
      execute: watchdog
    )
  }

  private func completeShareLoading() {
    guard loadDeadline.finish() else { return }
    loadWatchdog?.cancel()
    loadWatchdog = nil
    let finish: () -> Void = { [weak self] in
      self?.saveAndRedirect()
    }
    if Thread.isMainThread {
      finish()
    } else {
      DispatchQueue.main.async(execute: finish)
    }
  }

  private func loadSharedItems(completion: @escaping () -> Void) {
    let inputItems = extensionContext?.inputItems.compactMap {
      $0 as? NSExtensionItem
    } ?? []
    var ordinal = 0
    var fileBackedCount = 0
    var discoveredFileBackedCount = 0
    var skippedForItemLimit = false
    var loadTasks: [ShareLoadTask] = []

    for item in inputItems {
      for attachment in item.attachments ?? [] {
        guard let supportedType = supportedType(for: attachment) else { continue }
        guard loadTasks.count < maxSharedItemCount else {
          skippedForItemLimit = true
          continue
        }
        let type = supportedType.mediaType
        if type.isFileBacked {
          discoveredFileBackedCount += 1
          guard fileBackedCount < maxSharedFileCount else { continue }
        }
        if type.isFileBacked { fileBackedCount += 1 }

        let currentOrdinal = ordinal
        ordinal += 1
        loadTasks.append(ShareLoadTask(
          provider: attachment,
          supportedType: supportedType,
          ordinal: currentOrdinal
        ))
      }
    }
    expectedImportFileCount = fileBackedCount
    if discoveredFileBackedCount > fileBackedCount {
      recordImportError("Only the first \(maxSharedFileCount) shared attachments were imported.")
    }
    if skippedForItemLimit {
      recordImportError("Only the first \(maxSharedItemCount) shared items were processed.")
    }
    startLoadWatchdog(
      interval: nativeShareLoadWatchdogInterval(
        totalItemCount: loadTasks.count,
        fileBackedItemCount: fileBackedCount
      )
    )
    guard let statusJSON = shareImportStatusJSON(isInProgress: true) else {
      recordImportError("Unable to reserve durable storage for this share.")
      DispatchQueue.main.async(execute: completion)
      return
    }

    // Claim the cross-process status slot before any provider starts. POSIX
    // lock admission and legacy migration can block behind the host process,
    // so keep them off the extension's main queue.
    envelopeQueue.async { [self] in
      let reserved = reserveShareImport(statusJSON: statusJSON)
      guard loadDeadline.isActive else {
        if reserved {
          _ = try? envelopeStore?.clearStatus(id: shareImportId)
        }
        return
      }
      DispatchQueue.main.async { [self] in
        guard loadDeadline.isActive else {
          if reserved {
            envelopeQueue.async { [self] in
              _ = try? envelopeStore?.clearStatus(id: shareImportId)
            }
          }
          return
        }
        guard reserved else {
          recordImportError("Unable to reserve durable storage for this share.")
          completion()
          return
        }
        ownsImportSlot = true
        if expectedImportFileCount > 0 {
          openHostApp()
        }

        // Process providers serially. Share extensions have a tight memory
        // budget; concurrent providers can materialize multiple full files.
        loadTask(loadTasks, at: 0, completion: completion)
      }
    }
  }

  private func loadTask(
    _ tasks: [ShareLoadTask],
    at index: Int,
    completion: @escaping () -> Void
  ) {
    guard loadDeadline.isActive else { return }
    guard index < tasks.count else {
      DispatchQueue.main.async(execute: completion)
      return
    }
    let task = tasks[index]
    let done: () -> Void = { [weak self] in
      guard let self else { return }
      self.loadTask(tasks, at: index + 1, completion: completion)
    }

    if task.supportedType.mediaType.isFileBacked {
      task.provider.loadFileRepresentation(
        forTypeIdentifier: task.supportedType.itemTypeIdentifier
      ) { [weak self] url, error in
        guard let self else { return }
        guard loadDeadline.isActive else { return }
        if let url {
          stageFile(
            at: url,
            type: task.supportedType.mediaType,
            ordinal: task.ordinal
          )
          done()
          return
        }
        loadInPlaceFileFallback(
          task,
          precedingError: error,
          completion: done
        )
      }
      return
    }

    loadItemFallback(task, completion: done)
  }

  private func loadInPlaceFileFallback(
    _ task: ShareLoadTask,
    precedingError: Error?,
    completion: @escaping () -> Void
  ) {
    task.provider.loadInPlaceFileRepresentation(
      forTypeIdentifier: task.supportedType.itemTypeIdentifier
    ) { [weak self] url, _, error in
      guard let self else {
        completion()
        return
      }
      guard loadDeadline.isActive else { return }
      if let url {
        stageFile(
          at: url,
          type: task.supportedType.mediaType,
          ordinal: task.ordinal
        )
        completion()
        return
      }
      recordFileBackedLoadError(error ?? precedingError)
      completion()
    }
  }

  private func recordFileBackedLoadError(_ error: Error?) {
    if let error {
      recordImportError(
        "Could not import shared attachment: \(error.localizedDescription)"
      )
    } else {
      recordImportError("Could not import shared file attachment.")
    }
  }

  private func loadItemFallback(
    _ task: ShareLoadTask,
    completion: @escaping () -> Void
  ) {
    task.provider.loadItem(
      forTypeIdentifier: task.supportedType.itemTypeIdentifier
    ) { [weak self] data, error in
      defer { completion() }
      guard let self else { return }
      guard loadDeadline.isActive else { return }
      if let error {
        recordImportError("Could not import shared attachment: \(error.localizedDescription)")
        return
      }
      handleLoadedItem(
        data,
        type: task.supportedType.mediaType,
        ordinal: task.ordinal
      )
    }
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
    guard loadDeadline.isActive else { return }
    switch type {
    case .text:
      if let text = data as? String {
        guard text.utf8.count <= maxSharedTextBytes else {
          recordImportError("Shared text is too large to import.")
          return
        }
        appendMedia(
          SharedMediaFile(value: text, mimeType: "text/plain", type: type),
          ordinal: ordinal
        )
      } else if let textData = data as? Data {
        guard textData.count <= maxSharedTextBytes else {
          recordImportError("Shared text is too large to import.")
          return
        }
        guard let text = String(data: textData, encoding: .utf8) else {
          recordImportError("Shared text could not be decoded.")
          return
        }
        appendMedia(
          SharedMediaFile(value: text, mimeType: "text/plain", type: type),
          ordinal: ordinal
        )
      }
    case .url:
      if let url = data as? URL {
        guard url.absoluteString.utf8.count <= maxSharedUrlBytes else {
          recordImportError("Shared URL is too large to import.")
          return
        }
        appendMedia(SharedMediaFile(value: url.absoluteString, type: type), ordinal: ordinal)
      } else if let text = data as? String {
        guard text.utf8.count <= maxSharedUrlBytes else {
          recordImportError("Shared URL is too large to import.")
          return
        }
        appendMedia(SharedMediaFile(value: text, type: type), ordinal: ordinal)
      }
    case .image, .video, .file:
      // File-backed providers are handled before this generic item path. Do
      // not materialize their payloads as Data or decoded images here.
      recordFileBackedLoadError(nil)
    }
  }

  private func stageFile(at sourceURL: URL, type: SharedMediaType, ordinal: Int) {
    guard loadDeadline.isActive else { return }
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let maxBytes = maxSharedBytes(for: type, url: sourceURL)
    let remaining = remainingAggregateBytes()
    let allowedBytes = min(maxBytes, remaining)
    guard allowedBytes > 0 else {
      recordImportError("The shared attachments exceed the total import size limit.")
      return
    }
    if let size = fileSize(sourceURL), size > allowedBytes {
      recordImportError("\(sourceURL.lastPathComponent) exceeds the share import size limit.")
      return
    }
    guard let destinationURL = destinationURL(
      originalName: sourceURL.lastPathComponent,
      fallbackExtension: fallbackExtension(for: type),
      ordinal: ordinal
    ) else { return }
    guard let copiedBytes = copyFile(
      at: sourceURL,
      to: destinationURL,
      maxBytes: allowedBytes,
      isCancelled: { [weak self] in
        self?.loadDeadline.isActive != true
      }
    ) else {
      guard loadDeadline.isActive else { return }
      recordImportError("Could not import \(sourceURL.lastPathComponent).")
      return
    }

    // Preserve URL encoding. Decoding `%23`, `%3F`, or `%25` here can turn a
    // valid filename into a fragment/query delimiter or a different path.
    let stagedURL = destinationURL.absoluteString
    let media: SharedMediaFile
    if type == .video {
      media = SharedMediaFile(
        value: stagedURL,
        mimeType: destinationURL.mimeType(),
        duration: videoDuration(from: sourceURL),
        type: type
      )
    } else {
      media = SharedMediaFile(
        value: stagedURL,
        mimeType: destinationURL.mimeType(),
        type: type
      )
    }

    guard appendStagedMedia(media, ordinal: ordinal, byteCount: copiedBytes) else {
      try? FileManager.default.removeItem(at: destinationURL)
      return
    }
  }

  @discardableResult
  private func appendMedia(_ media: SharedMediaFile, ordinal: Int) -> Bool {
    loadDeadline.performIfActive {
      sharedMediaLock.lock()
      sharedMedia.append((ordinal: ordinal, media: media))
      sharedMediaLock.unlock()
    }
  }

  private func appendStagedMedia(
    _ media: SharedMediaFile,
    ordinal: Int,
    byteCount: Int64
  ) -> Bool {
    loadDeadline.performIfActive {
      sharedMediaLock.lock()
      stagedByteCount += max(0, byteCount)
      sharedMedia.append((ordinal: ordinal, media: media))
      sharedMediaLock.unlock()
    }
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
    if envelopeStore == nil,
       let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
       ) {
      envelopeStore = NativeShareEnvelopeStore(
        containerURL: container,
        legacyDefaults: UserDefaults(suiteName: appGroupId)
      )
    }
  }

  private func saveAndRedirect(message: String? = nil) {
    guard !didFinishShare else { return }
    didFinishShare = true

    guard ownsImportSlot, let envelopeStore else {
      // The watchdog can expire while beginImport is still waiting on the
      // cross-process lock. Serialize completion behind that reservation and
      // remove only this import's status before the extension may terminate.
      let pendingStore = self.envelopeStore
      envelopeQueue.async { [self] in
        _ = try? pendingStore?.clearStatus(id: shareImportId)
        completeExtensionRequest()
      }
      return
    }

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
      let statusJSON = shareImportStatusJSON(isInProgress: false)
      envelopeQueue.async { [self] in
        if let statusJSON {
          do {
            _ = try envelopeStore.finishWithoutPayload(
              id: shareImportId,
              statusJSON: statusJSON
            )
          } catch {
            _ = try? envelopeStore.clearStatus(id: shareImportId)
          }
        } else {
          _ = try? envelopeStore.clearStatus(id: shareImportId)
        }
        completeExtensionRequest()
      }
      return
    }

    let itemsJSON = toData(data: media)
    guard !itemsJSON.isEmpty,
          let statusJSON = shareImportStatusJSON(isInProgress: false) else {
      envelopeQueue.async { [self] in
        try? envelopeStore.cleanUnpublishedOwnedFiles(
          id: shareImportId,
          itemsJSON: itemsJSON
        )
        _ = try? envelopeStore.clearStatus(id: shareImportId)
        completeExtensionRequest()
      }
      return
    }
    envelopeQueue.async { [self] in
      do {
        let published = try envelopeStore.publish(
          id: shareImportId,
          itemsJSON: itemsJSON,
          message: messageToStore?.isEmpty == false ? messageToStore : nil,
          statusJSON: statusJSON
        )
        if published {
          DispatchQueue.main.async { [self] in
            redirectToHostApp()
          }
        } else {
          // A newer import owns the mutable status pointer. Never clear it
          // using this superseded extension's identifier.
          completeExtensionRequest()
        }
      } catch {
        try? envelopeStore.cleanUnpublishedOwnedFiles(
          id: shareImportId,
          itemsJSON: itemsJSON
        )
        // Publication failed before ownership crossed to Dart. Clear only
        // this exact status ID so the host cannot remain wedged on an
        // in-progress record. `clearStatus` is intentionally best effort.
        _ = try? envelopeStore.clearStatus(id: shareImportId)
        completeExtensionRequest()
      }
    }
  }

  private func completeExtensionRequest() {
    let complete: () -> Void = { [self] in
      extensionContext?.completeRequest(
        returningItems: [],
        completionHandler: nil
      )
    }
    if Thread.isMainThread {
      complete()
    } else {
      DispatchQueue.main.async(execute: complete)
    }
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
    loadDeadline.performIfActive {
      sharedMediaLock.lock()
      if !importErrors.contains(message) {
        importErrors.append(message)
      }
      sharedMediaLock.unlock()
    }
  }

  private func shareImportStatusJSON(isInProgress: Bool) -> Data? {
    sharedMediaLock.lock()
    let errors = importErrors
    sharedMediaLock.unlock()
    let payload: [String: Any] = [
      "id": shareImportId,
      "expectedFileCount": expectedImportFileCount,
      "isInProgress": isInProgress,
      "errors": errors,
    ]
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload)
    else {
      return nil
    }
    return data
  }

  private func reserveShareImport(statusJSON: Data) -> Bool {
    guard let envelopeStore else {
      return false
    }
    do {
      try envelopeStore.beginImport(
        id: shareImportId,
        statusJSON: statusJSON
      )
      return true
    } catch {
      return false
    }
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
      nativeShareStagingDirectoryName,
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

    let itemId = UUID().uuidString.lowercased()
    guard let filename = nativeShareStagedFileName(
      importId: shareImportId,
      itemId: itemId,
      ordinal: ordinal,
      originalName: originalName,
      fallbackExtension: fallbackExtension
    ) else { return nil }
    return directoryURL.appendingPathComponent(filename)
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

  private func copyFile(
    at srcURL: URL,
    to dstURL: URL,
    maxBytes: Int64,
    isCancelled: () -> Bool
  ) -> Int64? {
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
        guard !isCancelled() else {
          try? FileManager.default.removeItem(at: dstURL)
          return nil
        }
        let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty { break }
        copiedBytes += Int64(chunk.count)
        if copiedBytes > maxBytes {
          try? FileManager.default.removeItem(at: dstURL)
          return nil
        }
        try output.write(contentsOf: chunk)
      }
      guard !isCancelled() else {
        try? FileManager.default.removeItem(at: dstURL)
        return nil
      }
      return copiedBytes
    } catch {
      try? FileManager.default.removeItem(at: dstURL)
      return nil
    }
  }

  private func videoDuration(from url: URL) -> Double? {
    let asset = AVAsset(url: url)
    let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
    return duration.isFinite ? duration : nil
  }

  private func maxSharedBytes(for type: SharedMediaType, url: URL? = nil) -> Int64 {
    if type == .image {
      return maxSharedImageBytes
    }
    if type == .file,
       let url,
       UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
      return maxSharedImageBytes
    }
    switch type {
    case .video:
      return maxSharedVideoBytes
    case .file:
      return maxSharedGenericFileBytes
    case .image:
      return maxSharedImageBytes
    case .text, .url:
      return 0
    }
  }

  private func remainingAggregateBytes() -> Int64 {
    sharedMediaLock.lock()
    let remaining = max(0, maxSharedAggregateBytes - stagedByteCount)
    sharedMediaLock.unlock()
    return remaining
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

private extension UIImage {
  func preparingThumbnailSide(_ maxSide: CGFloat) -> UIImage? {
    // UIImage.size follows its display orientation; multiplying by scale
    // recovers oriented pixel dimensions without distorting rotated photos.
    let pixelWidth = size.width * scale
    let pixelHeight = size.height * scale
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    let resizeScale = min(maxSide / pixelWidth, maxSide / pixelHeight, 1)
    if resizeScale >= 1 { return self }
    let target = CGSize(
      width: max(1, floor(pixelWidth * resizeScale)),
      height: max(1, floor(pixelHeight * resizeScale))
    )
    let format = UIGraphicsImageRendererFormat()
    // `target` is expressed in output pixels. A screen-derived default scale
    // of 2x/3x would silently produce an 8192/12288-pixel PNG from a 4096
    // target and defeat the extension's decode/memory bound.
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
  }
}
