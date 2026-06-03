import Intents
import UniformTypeIdentifiers
import UIKit

private let maxSharedFileCount = 6
private let maxSharedFileBytes: Int64 = 20 * 1024 * 1024
private let maxSharedPayloadBytes = Int64(maxSharedFileCount) * maxSharedFileBytes

final class ShareViewController: UIViewController {
  private let payloadKey = "ConduitSharePayload"
  private let shareHost = "share"

  private var sharedText: [String] = []
  private var sharedFilePaths: [String] = []
  private var stagedSharedFileBytes: Int64 = 0
  private var fileNameCounts: [String: Int] = [:]

  override func viewDidLoad() {
    super.viewDidLoad()

    Task {
      await handleShare()
    }
  }

  private func handleShare() async {
    guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
      finish()
      return
    }

    for item in inputItems {
      guard let attachments = item.attachments else { continue }
      for attachment in attachments {
        await handle(attachment)
      }
    }

    persistPayload()
    openHostApp()
    finish()
  }

  private func handle(_ attachment: NSItemProvider) async {
    do {
      if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        try await handleFileBackedItem(attachment, type: .image, fallbackExtension: "png")
      } else if attachment.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        try await handleFileBackedItem(attachment, type: .movie, fallbackExtension: "mp4")
      } else if attachment.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
        try await handleFileBackedItem(attachment, type: .audio, fallbackExtension: "m4a")
      } else if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        try await handleFileBackedItem(attachment, type: .fileURL, fallbackExtension: "dat")
      } else if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        try await handleUrl(attachment)
      } else if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
        try await handleText(attachment)
      } else if attachment.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
        try await handleFileBackedItem(attachment, type: .data, fallbackExtension: "dat")
      }
    } catch {
      print("Conduit ShareExtension: failed to load attachment: \(error)")
    }
  }

  private func handleText(_ attachment: NSItemProvider) async throws {
    let item = try await attachment.loadItem(
      forTypeIdentifier: UTType.text.identifier,
      options: nil
    )

    if let text = item as? String {
      sharedText.append(text)
    } else if let data = item as? Data,
              let text = String(data: data, encoding: .utf8) {
      sharedText.append(text)
    }
  }

  private func handleUrl(_ attachment: NSItemProvider) async throws {
    let item = try await attachment.loadItem(
      forTypeIdentifier: UTType.url.identifier,
      options: nil
    )

    if let url = item as? URL {
      sharedText.append(url.absoluteString)
    } else if let text = item as? String {
      sharedText.append(text)
    }
  }

  private func handleFileBackedItem(
    _ attachment: NSItemProvider,
    type: UTType,
    fallbackExtension: String
  ) async throws {
    let item = try await attachment.loadItem(
      forTypeIdentifier: type.identifier,
      options: nil
    )

    if let url = item as? URL {
      try await copySharedFile(from: url, fallbackExtension: fallbackExtension)
    } else if let data = item as? Data {
      try await writeSharedData(
        data,
        originalName: nil,
        fallbackExtension: fallbackExtension
      )
    } else if let image = item as? UIImage,
              let data = image.pngData() {
      try await writeSharedData(data, originalName: nil, fallbackExtension: "png")
    }
  }

  private func copySharedFile(
    from sourceUrl: URL,
    fallbackExtension: String
  ) async throws {
    try validateCanStageSharedFile()
    if let sourceSize = try? sourceUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize {
      try validateCanStageSharedFile(byteCount: Int64(sourceSize))
    }

    let destinationUrl = try destinationUrl(
      originalName: sourceUrl.lastPathComponent,
      fallbackExtension: fallbackExtension
    )

    let copiedBytes = try await Self.copyFileOffMain(
      from: sourceUrl,
      to: destinationUrl,
      maxPayloadRemainingBytes: maxSharedPayloadBytes - stagedSharedFileBytes
    )
    try validateCanStageSharedFile(byteCount: copiedBytes)
    stagedSharedFileBytes += copiedBytes
    sharedFilePaths.append(destinationUrl.path)
  }

  private func writeSharedData(
    _ data: Data,
    originalName: String?,
    fallbackExtension: String
  ) async throws {
    let byteCount = Int64(data.count)
    try validateCanStageSharedFile(byteCount: byteCount)

    let destinationUrl = try destinationUrl(
      originalName: originalName,
      fallbackExtension: fallbackExtension
    )

    try await Self.writeDataOffMain(data, to: destinationUrl)
    stagedSharedFileBytes += byteCount
    sharedFilePaths.append(destinationUrl.path)
  }

  private nonisolated static func copyFileOffMain(
    from sourceUrl: URL,
    to destinationUrl: URL,
    maxPayloadRemainingBytes: Int64
  ) async throws -> Int64 {
    try await Task.detached(priority: .utility) {
      let didAccessSecurityScopedResource = sourceUrl.startAccessingSecurityScopedResource()
      defer {
        if didAccessSecurityScopedResource {
          sourceUrl.stopAccessingSecurityScopedResource()
        }
      }

      let fileManager = FileManager.default
      if let sourceSize = try? sourceUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize,
         Int64(sourceSize) > maxSharedFileBytes {
        throw ShareExtensionError.sharedFileTooLarge(Int64(sourceSize))
      }
      if let sourceSize = try? sourceUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize,
         Int64(sourceSize) > maxPayloadRemainingBytes {
        throw ShareExtensionError.sharedPayloadTooLarge(Int64(sourceSize))
      }

      try fileManager.createDirectory(
        at: destinationUrl.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: destinationUrl.path) {
        try fileManager.removeItem(at: destinationUrl)
      }

      do {
        let sourceHandle = try FileHandle(forReadingFrom: sourceUrl)
        _ = fileManager.createFile(atPath: destinationUrl.path, contents: nil)
        let destinationHandle = try FileHandle(forWritingTo: destinationUrl)
        defer {
          try? sourceHandle.close()
          try? destinationHandle.close()
        }

        var copiedBytes: Int64 = 0
        while true {
          let chunk = try sourceHandle.read(upToCount: 64 * 1024) ?? Data()
          if chunk.isEmpty { break }

          copiedBytes += Int64(chunk.count)
          if copiedBytes > maxSharedFileBytes {
            throw ShareExtensionError.sharedFileTooLarge(copiedBytes)
          }
          if copiedBytes > maxPayloadRemainingBytes {
            throw ShareExtensionError.sharedPayloadTooLarge(copiedBytes)
          }

          destinationHandle.write(chunk)
        }
        return copiedBytes
      } catch {
        try? fileManager.removeItem(at: destinationUrl)
        throw error
      }
    }.value
  }

  private func validateCanStageSharedFile(byteCount: Int64? = nil) throws {
    guard sharedFilePaths.count < maxSharedFileCount else {
      throw ShareExtensionError.sharedFileCountExceeded(maxSharedFileCount)
    }

    guard let byteCount else { return }

    guard byteCount <= maxSharedFileBytes else {
      throw ShareExtensionError.sharedFileTooLarge(byteCount)
    }
    guard stagedSharedFileBytes + byteCount <= maxSharedPayloadBytes else {
      throw ShareExtensionError.sharedPayloadTooLarge(stagedSharedFileBytes + byteCount)
    }
  }

  private nonisolated static func writeDataOffMain(
    _ data: Data,
    to destinationUrl: URL
  ) async throws {
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(
        at: destinationUrl.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destinationUrl, options: .atomic)
    }.value
  }

  private func destinationUrl(
    originalName: String?,
    fallbackExtension: String
  ) throws -> URL {
    guard let containerUrl = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      throw ShareExtensionError.missingAppGroupContainer
    }

    let directoryUrl = containerUrl.appendingPathComponent(
      "shared-incoming",
      isDirectory: true
    )

    let fileName = uniqueFileName(
      originalName: originalName,
      fallbackExtension: fallbackExtension
    )
    return directoryUrl.appendingPathComponent(fileName)
  }

  private func uniqueFileName(
    originalName: String?,
    fallbackExtension: String
  ) -> String {
    let cleanedName = sanitizeFileName(originalName)
    let baseName = cleanedName?.isEmpty == false
      ? cleanedName!
      : "shared-\(UUID().uuidString).\(fallbackExtension)"

    let name = (baseName as NSString).deletingPathExtension
    let ext = (baseName as NSString).pathExtension.isEmpty
      ? fallbackExtension
      : (baseName as NSString).pathExtension
    let normalized = "\(name).\(ext)"

    let count = (fileNameCounts[normalized] ?? 0) + 1
    fileNameCounts[normalized] = count

    if count == 1 {
      return "\(UUID().uuidString)-\(normalized)"
    }
    return "\(UUID().uuidString)-\(name)-\(count).\(ext)"
  }

  private func sanitizeFileName(_ name: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
      .union(.newlines)
      .union(.controlCharacters)
    return name
      .components(separatedBy: invalidCharacters)
      .joined(separator: "-")
  }

  private func persistPayload() {
    let text = sharedText
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    guard !text.isEmpty || !sharedFilePaths.isEmpty else { return }

    let payload: [String: Any] = [
      "id": UUID().uuidString,
      "text": text,
      "filePaths": sharedFilePaths,
    ]

    guard let defaults = UserDefaults(suiteName: appGroupId) else {
      print("Conduit ShareExtension: failed to open shared defaults")
      return
    }

    defaults.set(payload, forKey: payloadKey)
    defaults.synchronize()
  }

  private func openHostApp() {
    guard let url = URL(
      string: "\(appUrlScheme)://\(shareHost)?source=shareExtension&nonce=\(UUID().uuidString)"
    ) else {
      return
    }

    extensionContext?.open(url, completionHandler: nil)
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
  }

  private var appGroupId: String {
    (Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String)
      ?? "group.\(hostAppBundleIdentifier)"
  }

  private var appUrlScheme: String {
    (Bundle.main.object(forInfoDictionaryKey: "AppURLScheme") as? String)
      ?? "conduit"
  }

  private var hostAppBundleIdentifier: String {
    let extensionBundleId = Bundle.main.bundleIdentifier ?? ""
    guard let lastDot = extensionBundleId.lastIndex(of: ".") else {
      return extensionBundleId
    }
    return String(extensionBundleId[..<lastDot])
  }
}

private enum ShareExtensionError: Error {
  case missingAppGroupContainer
  case sharedFileTooLarge(Int64)
  case sharedPayloadTooLarge(Int64)
  case sharedFileCountExceeded(Int)
}
