import Foundation
import UniformTypeIdentifiers

/// File endings that make a shared https address worth downloading as an
/// image instead of sending it as a link.
let nativeShareLinkedImageExtensions: Set<String> = [
  "png", "jpg", "jpeg", "gif", "webp", "heic",
]

/// The most redirects a linked image download follows.
let nativeShareLinkedImageMaximumRedirects = 5

/// The attachment of a share that holds a single web address and nothing
/// else.
///
/// Safari's long-press Share on an image hands over only the image's
/// address, never its bytes. A page share also carries the page title, and
/// stays a link like any share with more to it than one address.
func nativeShareLoneLinkProvider(
  in items: [NSExtensionItem]
) -> NSItemProvider? {
  let providers = items.flatMap { $0.attachments ?? [] }
  guard providers.count == 1, let provider = providers.first else {
    return nil
  }
  let hasText = items.contains { item in
    [item.attributedTitle, item.attributedContentText].contains { text in
      text?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
    }
  }
  let types = provider.registeredTypeIdentifiers
  guard !hasText, !types.isEmpty else { return nil }
  let isWebAddress = types.allSatisfy { identifier in
    guard let type = UTType(identifier) else { return false }
    return type.conforms(to: .url) && !type.conforms(to: .fileURL)
  }
  return isWebAddress ? provider : nil
}

/// Whether a shared address names an image to download in place of the
/// link: https, with a path that ends in an image file type. The query
/// doesn't count, so `photo.jpg?w=800` qualifies.
func nativeShareLinkedImageQualifies(_ url: URL) -> Bool {
  guard url.scheme?.lowercased() == "https",
        url.host?.isEmpty == false
  else {
    return false
  }
  return nativeShareLinkedImageExtensions.contains(
    url.pathExtension.lowercased()
  )
}

/// Whether a linked image download may follow its `redirectCount`th
/// redirect, counting from 1, to `url`. It never leaves https.
func nativeShareLinkedImageRedirectAllowed(
  to url: URL?,
  redirectCount: Int
) -> Bool {
  guard let url,
        url.scheme?.lowercased() == "https",
        url.host?.isEmpty == false
  else {
    return false
  }
  return redirectCount <= nativeShareLinkedImageMaximumRedirects
}

/// Whether `byteCount` bytes of a linked image fit the import allowance.
///
/// A response without a Content-Length reports -1, which fits until the
/// bytes that actually arrive pass the allowance.
func nativeShareLinkedImageFits(
  byteCount: Int64,
  allowedBytes: Int64
) -> Bool {
  byteCount <= allowedBytes
}

/// Whether a response may carry the linked image: a 2xx status and an image
/// content type. The bytes are checked once they have arrived.
func nativeShareLinkedImageResponseAcceptable(
  statusCode: Int,
  mimeType: String?
) -> Bool {
  guard (200..<300).contains(statusCode), let mimeType else { return false }
  return mimeType.lowercased().hasPrefix("image/")
}

/// The image format of a downloaded file, judged by its bytes the same way
/// as an in-memory shared image.
///
/// The bytes decide the format: servers label one image format as another,
/// and a page that ends in `.png` can be HTML.
func nativeShareDownloadedImageType(at url: URL) -> UTType? {
  // Mapped, so only the header ImageIO reads is paged in.
  guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
    return nil
  }
  return nativeShareImageType(of: data)
}

/// Downloads an image a share names only by its https address.
///
/// The session keeps no cookies, cache or credentials, so an image behind a
/// sign-in fails and the share sends the link instead. Bytes stream to a
/// temporary file and nothing is decoded.
final class NativeShareLinkedImageDownload: NSObject, URLSessionDataDelegate {
  typealias Result = (fileURL: URL, type: UTType)

  static func sessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    return configuration
  }

  private let url: URL
  private let allowedBytes: Int64
  private let configuration: URLSessionConfiguration
  private let directoryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  private var session: URLSession?
  private var output: FileHandle?
  private var receivedBytes: Int64 = 0
  private var redirectCount = 0
  private var completion: ((Result?) -> Void)?

  private var fileURL: URL {
    directoryURL.appendingPathComponent("download")
  }

  init(
    url: URL,
    allowedBytes: Int64,
    configuration: URLSessionConfiguration = sessionConfiguration()
  ) {
    self.url = url
    self.allowedBytes = allowedBytes
    self.configuration = configuration
  }

  /// Calls `completion` once, on a background queue, with the downloaded
  /// file and its format, or nil when the address didn't give an image.
  func start(completion: @escaping (Result?) -> Void) {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      output = try FileHandle(forWritingTo: fileURL)
    } catch {
      removeFile()
      completion(nil)
      return
    }
    self.completion = completion
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: queue
    )
    self.session = session
    session.dataTask(with: url).resume()
  }

  /// Deletes the downloaded file once it has been staged.
  func removeFile() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    redirectCount += 1
    guard nativeShareLinkedImageRedirectAllowed(
      to: request.url,
      redirectCount: redirectCount
    ) else {
      completionHandler(nil)
      finish(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse,
          nativeShareLinkedImageResponseAcceptable(
            statusCode: response.statusCode,
            mimeType: response.mimeType
          ),
          nativeShareLinkedImageFits(
            byteCount: response.expectedContentLength,
            allowedBytes: allowedBytes
          )
    else {
      completionHandler(.cancel)
      finish(nil)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard completion != nil else { return }
    receivedBytes += Int64(data.count)
    guard nativeShareLinkedImageFits(
      byteCount: receivedBytes,
      allowedBytes: allowedBytes
    ) else {
      finish(nil)
      return
    }
    do {
      try output?.write(contentsOf: data)
    } catch {
      finish(nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard completion != nil else { return }
    try? output?.close()
    output = nil
    guard error == nil,
          let type = nativeShareDownloadedImageType(at: fileURL)
    else {
      finish(nil)
      return
    }
    finish((fileURL, type))
  }

  private func finish(_ result: Result?) {
    guard let completion else { return }
    self.completion = nil
    try? output?.close()
    output = nil
    // Also cancels the task, and releases this delegate.
    session?.invalidateAndCancel()
    session = nil
    if result == nil {
      removeFile()
    }
    completion(result)
  }
}
