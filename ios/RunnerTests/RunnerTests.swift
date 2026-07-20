import AVFoundation
import Darwin
import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testHermesFlutterAssetCanBeLoadedAsAnImage() {
    let image = loadFlutterAssetImage("assets/icons/hermes_agent.png")
    XCTAssertNotNil(image)
  }

  func testHermesAvatarCanUseTemplateRenderingInDarkMode() throws {
    let image = try XCTUnwrap(loadFlutterAssetImage("assets/icons/hermes_agent.png"))

    XCTAssertEqual(
      nativeAvatarImage(image, isTemplate: true).renderingMode,
      .alwaysTemplate
    )
    XCTAssertNotEqual(
      nativeAvatarImage(image, isTemplate: false).renderingMode,
      .alwaysTemplate
    )
  }

  func testTemplateAvatarHidesFallbackInitials() throws {
    let image = try XCTUnwrap(loadFlutterAssetImage("assets/icons/hermes_agent.png"))
    let imageView = UIImageView()
    let initialsLabel = UILabel()
    imageView.isHidden = true
    initialsLabel.isHidden = false

    applyNativeAvatarImage(
      image,
      isTemplate: true,
      to: imageView,
      initialsLabel: initialsLabel
    )

    XCTAssertFalse(imageView.isHidden)
    XCTAssertTrue(initialsLabel.isHidden)
    XCTAssertEqual(imageView.image?.renderingMode, .alwaysTemplate)
    XCTAssertEqual(imageView.contentMode, .scaleAspectFit)
  }

  func testNativeSheetImageCacheKeyScopesAuthenticatedImagesByHeaders() {
    let rawUrl = "https://example.test/avatar.png"
    let accountA = nativeSheetImageCacheKey(
      rawUrl: rawUrl,
      headers: ["Authorization": "Bearer account-a", "Accept": "image/png"]
    )
    let accountAReordered = nativeSheetImageCacheKey(
      rawUrl: rawUrl,
      headers: ["accept": "image/png", "authorization": "Bearer account-a"]
    )
    let accountB = nativeSheetImageCacheKey(
      rawUrl: rawUrl,
      headers: ["Authorization": "Bearer account-b", "Accept": "image/png"]
    )

    XCTAssertEqual(accountA, accountAReordered)
    XCTAssertNotEqual(accountA, accountB)
    XCTAssertFalse(String(accountA).contains("account-a"))
    XCTAssertEqual(
      nativeSheetImageCacheKey(rawUrl: rawUrl, headers: [:]),
      NSString(string: rawUrl)
    )
  }

  func testNativeSheetImageSessionIsBoundedAndDoesNotPersistCredentials() {
    let configuration = nativeSheetImageSessionConfiguration()

    XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 4)
    XCTAssertEqual(
      configuration.requestCachePolicy,
      .reloadIgnoringLocalCacheData
    )
    XCTAssertNil(configuration.urlCache)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.urlCredentialStorage)
  }

  func testNativeProfilePhotoFileIsDownsampledToBoundedPixels() throws {
    let sourceImage = UIGraphicsImageRenderer(
      size: CGSize(width: 2048, height: 1536)
    ).image { context in
      UIColor.systemBlue.setFill()
      context.cgContext.fill(
        CGRect(x: 0, y: 0, width: 2048, height: 1536)
      )
    }
    let sourceData = try XCTUnwrap(
      sourceImage.jpegData(compressionQuality: 0.9)
    )
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString)-profile-photo.jpg"
    )
    try sourceData.write(to: sourceURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let thumbnail = try XCTUnwrap(
      nativeDownsampleImageFile(at: sourceURL, maxPixelSize: 1024)
    )
    let cgImage = try XCTUnwrap(thumbnail.cgImage)

    XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 1024)
    XCTAssertGreaterThan(cgImage.width, 0)
    XCTAssertGreaterThan(cgImage.height, 0)
  }

  func testNativeSheetAvatarDataCacheKeyTracksCurrentBytes() {
    let first = nativeSheetAvatarDataCacheKey(
      cacheIdentifier: "presentation:model",
      data: Data([1, 2, 3]),
      targetPixelSize: 96
    )
    let firstAgain = nativeSheetAvatarDataCacheKey(
      cacheIdentifier: "presentation:model",
      data: Data([1, 2, 3]),
      targetPixelSize: 96
    )
    let changed = nativeSheetAvatarDataCacheKey(
      cacheIdentifier: "presentation:model",
      data: Data([1, 2, 4]),
      targetPixelSize: 96
    )

    XCTAssertEqual(first, firstAgain)
    XCTAssertNotEqual(first, changed)
    XCTAssertFalse(String(first).contains("\u{1}\u{2}\u{3}"))
  }

  func testNativeSheetRedirectsStayOnExactOrigin() throws {
    let original = try XCTUnwrap(URL(string: "https://example.test/avatar"))

    XCTAssertTrue(nativeSheetRedirectStaysWithinOrigin(
      originalURL: original,
      redirectURL: try XCTUnwrap(URL(string: "https://example.test:443/final"))
    ))
    XCTAssertFalse(nativeSheetRedirectStaysWithinOrigin(
      originalURL: original,
      redirectURL: try XCTUnwrap(URL(string: "https://cdn.example.test/final"))
    ))
    XCTAssertFalse(nativeSheetRedirectStaysWithinOrigin(
      originalURL: original,
      redirectURL: try XCTUnwrap(URL(string: "https://example.test:444/final"))
    ))
    XCTAssertFalse(nativeSheetRedirectStaysWithinOrigin(
      originalURL: original,
      redirectURL: try XCTUnwrap(URL(string: "http://example.test/final"))
    ))
  }

  func testNativeSheetImageHeadersRequireExplicitTrustedOrigin() throws {
    let trusted = try XCTUnwrap(URL(string: "https://server.example:443/api"))
    let headers = ["Authorization": "Bearer secret", "X-Tenant": "one"]

    let sameOrigin = try XCTUnwrap(nativeSheetImageRequest(
      rawUrl: "https://server.example/avatar.png",
      headers: headers,
      trustedServerOriginURL: trusted
    ))
    XCTAssertEqual(
      sameOrigin.value(forHTTPHeaderField: "Authorization"),
      "Bearer secret"
    )
    XCTAssertEqual(sameOrigin.value(forHTTPHeaderField: "X-Tenant"), "one")

    // Production avatar views pass the avatar URL itself as the trust anchor
    // because Dart only attaches headers built for that URL's server origin.
    let selfTrusted = try XCTUnwrap(nativeSheetImageRequest(
      rawUrl: "https://server.example/avatar.png",
      headers: headers,
      trustedServerOriginURL: URL(string: "https://server.example/avatar.png")
    ))
    XCTAssertEqual(
      selfTrusted.value(forHTTPHeaderField: "Authorization"),
      "Bearer secret"
    )

    let offOrigin = try XCTUnwrap(nativeSheetImageRequest(
      rawUrl: "https://cdn.example/avatar.png",
      headers: headers,
      trustedServerOriginURL: trusted
    ))
    XCTAssertNil(offOrigin.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(offOrigin.value(forHTTPHeaderField: "X-Tenant"))

    let noTrustAnchor = try XCTUnwrap(nativeSheetImageRequest(
      rawUrl: "https://server.example/avatar.png",
      headers: headers,
      trustedServerOriginURL: nil
    ))
    XCTAssertTrue(noTrustAnchor.allHTTPHeaderFields?.isEmpty ?? true)

    XCTAssertNotNil(nativeSheetImageRequest(
      rawUrl: "https://cdn.example/public.png",
      headers: [:],
      trustedServerOriginURL: nil
    ))
    XCTAssertNil(nativeSheetImageRequest(
      rawUrl: "file:///tmp/avatar.png",
      headers: [:],
      trustedServerOriginURL: nil
    ))
  }

  func testNativeSheetRequestAdmissionIsGloballyBounded() {
    let admission = NativeSheetRequestAdmission(limit: 2)

    XCTAssertTrue(admission.acquire())
    XCTAssertTrue(admission.acquire())
    XCTAssertFalse(admission.acquire())
    XCTAssertEqual(admission.count, 2)
    admission.release()
    XCTAssertTrue(admission.acquire())
    XCTAssertEqual(admission.count, 2)
  }

  func testNativeSheetAvatarHashingRunsOffMain() {
    let observed = expectation(description: "avatar hash observed")
    var didRunOnMain: Bool?
    NativeSheetImageLoader.setAvatarHashExecutionObserverForTesting { isMain in
      didRunOnMain = isMain
      observed.fulfill()
    }
    defer {
      NativeSheetImageLoader.setAvatarHashExecutionObserverForTesting(nil)
    }

    _ = NativeSheetImageLoader.load(
      data: Data([0, 1, 2, 3]),
      cacheIdentifier: UUID().uuidString,
      targetPixelSize: 16,
      completion: { _ in }
    )

    wait(for: [observed], timeout: 1)
    XCTAssertEqual(didRunOnMain, false)
  }

  func testNativeSheetImageLoadCancellationIsExactlyOnce() {
    let token = NativeSheetImageLoadToken()
    var cancellations = 0
    token.installCancellationHandler { cancellations += 1 }

    token.cancel()
    token.cancel()

    XCTAssertTrue(token.isCancelled)
    XCTAssertEqual(cancellations, 1)
  }

  func testNativeSheetStaleImageCompletionCannotFinishReusedCacheKey() throws {
    let cacheKey = NSString(string: "image-race-\(UUID().uuidString)")
    var staleCompletions = 0
    var replacementCompletions = 0

    let stale = NativeSheetImageLoader.beginInFlightRequestForTesting(
      cacheKey: cacheKey
    ) { _ in
      staleCompletions += 1
    }
    let staleRequestId = try XCTUnwrap(stale.requestId)
    stale.token.cancel()

    let replacementDelivered = expectation(
      description: "replacement image delivered"
    )
    let replacement = NativeSheetImageLoader.beginInFlightRequestForTesting(
      cacheKey: cacheKey
    ) { _ in
      replacementCompletions += 1
      replacementDelivered.fulfill()
    }
    let replacementRequestId = try XCTUnwrap(replacement.requestId)
    XCTAssertNotEqual(staleRequestId, replacementRequestId)

    let staleNetworkToken = NativeSheetImageLoadToken()
    NativeSheetImageLoader.installNetworkTokenForTesting(
      staleNetworkToken,
      cacheKey: cacheKey,
      requestId: staleRequestId
    )
    XCTAssertTrue(staleNetworkToken.isCancelled)

    let image = UIGraphicsImageRenderer(
      size: CGSize(width: 1, height: 1)
    ).image { context in
      UIColor.black.setFill()
      context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    NativeSheetImageLoader.finishInFlightRequestForTesting(
      cacheKey: cacheKey,
      requestId: staleRequestId,
      image: image
    )
    XCTAssertEqual(staleCompletions, 0)
    XCTAssertEqual(replacementCompletions, 0)

    NativeSheetImageLoader.finishInFlightRequestForTesting(
      cacheKey: cacheKey,
      requestId: replacementRequestId,
      image: image
    )
    wait(for: [replacementDelivered], timeout: 1)
    XCTAssertEqual(staleCompletions, 0)
    XCTAssertEqual(replacementCompletions, 1)
  }

  func testNativeSheetModelUpdateIsAppliedOnMainBeforeOffMainCallReturns() {
    let applied = expectation(description: "model update applied")

    DispatchQueue.global(qos: .userInitiated).async {
      var didApply = false
      applyNativeSheetModelUpdateSynchronouslyOnMain(
        presentationId: "current-presentation",
        activePresentationId: { "current-presentation" },
        update: {
          XCTAssertTrue(Thread.isMainThread)
          didApply = true
        }
      )
      XCTAssertTrue(didApply)
      applied.fulfill()
    }

    wait(for: [applied], timeout: 1)
  }

  func testNativeSheetModelUpdateRejectsStalePresentation() {
    var didApply = false

    applyNativeSheetModelUpdateSynchronouslyOnMain(
      presentationId: "stale-presentation",
      activePresentationId: { "current-presentation" },
      update: { didApply = true }
    )

    XCTAssertFalse(didApply)
  }

  func testAppIntentReadinessIsAppliedBeforeUpdateReturns() {
    let readiness = AppIntentReadiness()

    XCTAssertFalse(readiness.currentValue())
    readiness.update(true)
    XCTAssertTrue(readiness.currentValue())
    readiness.update(false)
    XCTAssertFalse(readiness.currentValue())
  }

  func testAppIntentReadinessWaiterResumesOnReadyTransition() async {
    let readiness = AppIntentReadiness()
    let waiter = Task {
      await readiness.waitUntilReady(timeoutNanoseconds: 1_000_000_000)
    }

    try? await Task.sleep(nanoseconds: 10_000_000)
    readiness.update(true)

    let becameReady = await waiter.value
    XCTAssertTrue(becameReady)
  }

  func testAppIntentReadinessWaiterUsesSingleTimeout() async {
    let readiness = AppIntentReadiness()
    let startedAt = ProcessInfo.processInfo.systemUptime

    let becameReady = await readiness.waitUntilReady(
      timeoutNanoseconds: 10_000_000
    )

    XCTAssertFalse(becameReady)
    XCTAssertLessThan(
      ProcessInfo.processInfo.systemUptime - startedAt,
      0.5
    )
  }

  func testCancelledAppIntentReadinessWaitReturnsPromptly() async {
    let previousBridge = AppIntentBridge.shared
    AppIntentBridge.shared = nil
    defer { AppIntentBridge.shared = previousBridge }
    let startedAt = ProcessInfo.processInfo.systemUptime
    let task = Task { await AppIntentBridge.readyBridge() }
    task.cancel()

    let bridge = await task.value

    XCTAssertNil(bridge)
    XCTAssertLessThan(
      ProcessInfo.processInfo.systemUptime - startedAt,
      0.5
    )
  }

  private func nativePasteTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "conduit-native-paste-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
  }

  private func createNativePasteDelivery(
    in store: NativePasteDeliveryStore,
    bytes: Data = Data([1, 2, 3])
  ) throws -> (id: String, item: URL) {
    let deliveryId = try XCTUnwrap(store.createDelivery())
    let item = try XCTUnwrap(store.stagingURL(
      deliveryId: deliveryId,
      fileExtension: "png"
    ))
    try bytes.write(to: item)
    return (deliveryId, item)
  }

  private func nativePasteMarker(
    _ store: NativePasteDeliveryStore,
    deliveryId: String,
    state: NativePasteDeliveryMarkerState
  ) throws -> URL {
    try XCTUnwrap(store.markerURL(
      deliveryId: deliveryId,
      state: state
    ))
  }

  private func moveNativePasteMarker(
    _ store: NativePasteDeliveryStore,
    deliveryId: String,
    from sourceState: NativePasteDeliveryMarkerState,
    to destinationState: NativePasteDeliveryMarkerState
  ) throws {
    try FileManager.default.moveItem(
      at: nativePasteMarker(
        store,
        deliveryId: deliveryId,
        state: sourceState
      ),
      to: nativePasteMarker(
        store,
        deliveryId: deliveryId,
        state: destinationState
      )
    )
  }

  private func nativePasteEntryExistsNoFollow(_ url: URL) -> Bool {
    var metadata = stat()
    return url.path.withCString { lstat($0, &metadata) == 0 }
  }

  private func nativePasteHasAnyMarker(
    _ store: NativePasteDeliveryStore,
    deliveryId: String
  ) -> Bool {
    NativePasteDeliveryMarkerState.allCases.contains { state in
      guard let marker = store.markerURL(
        deliveryId: deliveryId,
        state: state
      ) else { return false }
      return nativePasteEntryExistsNoFollow(marker)
    }
  }

  func testNativePasteInPlaceReadIsFileCoordinated() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-paste-coordinated-\(UUID().uuidString).png"
    )
    let expected = Data([0x89, 0x50, 0x4e, 0x47])
    try expected.write(to: source, options: .atomic)
    defer { try? FileManager.default.removeItem(at: source) }

    var coordinatedURL: URL?
    let actual = withCoordinatedNativePasteRead(at: source) { url in
      coordinatedURL = url
      return try? Data(contentsOf: url)
    }

    XCTAssertEqual(actual, expected)
    XCTAssertNotNil(coordinatedURL)
  }

  func testNativePasteCreatesPendingMarkerBeforeAnyStagedItem() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)

    let deliveryId = try XCTUnwrap(store.createDelivery())
    let pending = try nativePasteMarker(
      store,
      deliveryId: deliveryId,
      state: .pending
    )
    let initialEntries = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )

    XCTAssertEqual(deliveryId, deliveryId.lowercased())
    XCTAssertEqual(initialEntries, [pending])
    XCTAssertTrue(nativePasteEntryExistsNoFollow(pending))

    let staged = try XCTUnwrap(store.stagingURL(
      deliveryId: deliveryId,
      fileExtension: "png"
    ))
    XCTAssertTrue(staged.lastPathComponent.hasPrefix("\(deliveryId)-"))
    XCTAssertTrue(staged.lastPathComponent.hasSuffix("-paste.png"))
    XCTAssertNil(store.stagingURL(
      deliveryId: deliveryId.uppercased(),
      fileExtension: "png"
    ))
  }

  func testRejectedNativePasteReclaimsOnlyStrictDeliveryItems() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let delivery = try createNativePasteDelivery(in: store)
    let omitted = try XCTUnwrap(store.stagingURL(
      deliveryId: delivery.id,
      fileExtension: "png"
    ))
    try Data([4, 5, 6]).write(to: omitted)
    let unrelated = root.appendingPathComponent("unrelated.png")
    try Data([9]).write(to: unrelated)
    let queue = DispatchQueue(label: "native-paste-test-rejection")
    var acknowledgements: [Bool] = []
    let ownership = NativePasteDeliveryOwnership(
      deliveryId: delivery.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    XCTAssertFalse(ownership.resolveFromDart(decision: .rejected))
    queue.sync {}

    XCTAssertEqual(acknowledgements, [false])
    XCTAssertFalse(nativePasteEntryExistsNoFollow(delivery.item))
    XCTAssertFalse(nativePasteEntryExistsNoFollow(omitted))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(unrelated))
    XCTAssertFalse(nativePasteHasAnyMarker(store, deliveryId: delivery.id))
  }

  func testAcceptedNativePasteFinalizesDartMarkerAndPreservesItems() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let delivery = try createNativePasteDelivery(in: store)
    try moveNativePasteMarker(
      store,
      deliveryId: delivery.id,
      from: .pending,
      to: .dartOwned
    )
    let queue = DispatchQueue(label: "native-paste-test-accepted")
    var acknowledgements: [Bool] = []
    let ownership = NativePasteDeliveryOwnership(
      deliveryId: delivery.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    XCTAssertTrue(ownership.resolveFromDart(decision: .accepted))
    queue.sync {}

    XCTAssertEqual(acknowledgements, [true])
    XCTAssertTrue(nativePasteEntryExistsNoFollow(delivery.item))
    XCTAssertFalse(nativePasteHasAnyMarker(store, deliveryId: delivery.id))
  }

  func testNativePasteFallbackRequiresUnchangedResponderAndPasteboard() {
    let original = NativePasteEditorContext(
      documentText: "draft",
      selectionStart: 5,
      selectionEnd: 5
    )
    XCTAssertTrue(nativePasteFallbackContextMatches(
      responderIsFirstResponder: true,
      expectedPasteboardChangeCount: 7,
      currentPasteboardChangeCount: 7,
      expectedEditorContext: original,
      currentEditorContext: original
    ))
    XCTAssertFalse(nativePasteFallbackContextMatches(
      responderIsFirstResponder: false,
      expectedPasteboardChangeCount: 7,
      currentPasteboardChangeCount: 7,
      expectedEditorContext: original,
      currentEditorContext: original
    ))
    XCTAssertFalse(nativePasteFallbackContextMatches(
      responderIsFirstResponder: true,
      expectedPasteboardChangeCount: 7,
      currentPasteboardChangeCount: 8,
      expectedEditorContext: original,
      currentEditorContext: original
    ))
    XCTAssertFalse(nativePasteFallbackContextMatches(
      responderIsFirstResponder: true,
      expectedPasteboardChangeCount: 7,
      currentPasteboardChangeCount: 7,
      expectedEditorContext: original,
      currentEditorContext: NativePasteEditorContext(
        documentText: "draft changed",
        selectionStart: 13,
        selectionEnd: 13
      )
    ))
  }

  func testIndeterminateNativePasteDecisionSuppressesFallback() {
    let result: Result<Bool, NSError> = .failure(
      NSError(domain: "test", code: 1)
    )

    XCTAssertEqual(
      NativePasteBridge.pasteDeliveryDecision(result),
      .indeterminate
    )
    XCTAssertTrue(NativePasteBridge.pasteDeliveryDecision(result)
      .suppressesFallbackPaste)
  }

  func testNativePasteDeliveryCompletionAcknowledgesExactlyOnce() {
    var acknowledgements: [Bool] = []
    let completion = NativePasteDeliveryCompletion {
      acknowledgements.append($0)
    }

    XCTAssertTrue(completion.resolve(false))
    XCTAssertFalse(completion.resolve(true))
    XCTAssertEqual(acknowledgements, [false])
  }

  func testNativePasteAcknowledgementTimeoutReclaimsPendingDelivery() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let staged = try createNativePasteDelivery(in: store)
    let queue = DispatchQueue(label: "native-paste-test-timeout")
    var acknowledgements: [Bool] = []
    let delivery = NativePasteDeliveryOwnership(
      deliveryId: staged.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    delivery.acknowledgementTimedOut()
    queue.sync {}

    XCTAssertEqual(acknowledgements, [false])
    XCTAssertFalse(nativePasteEntryExistsNoFollow(staged.item))
    XCTAssertFalse(nativePasteHasAnyMarker(store, deliveryId: staged.id))

    XCTAssertFalse(delivery.resolveFromDart(decision: .accepted))
    XCTAssertFalse(delivery.resolveFromDart(consumed: false))
    XCTAssertEqual(acknowledgements, [false])
    XCTAssertFalse(nativePasteEntryExistsNoFollow(staged.item))
  }

  func testNativePasteTimeoutAcknowledgesAfterOwnershipSettlement() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let staged = try createNativePasteDelivery(in: store)
    let queue = DispatchQueue(label: "native-paste-test-timeout-ordering")
    let blockerStarted = expectation(description: "operation queue blocked")
    let unblock = DispatchSemaphore(value: 0)
    defer { unblock.signal() }
    queue.async {
      blockerStarted.fulfill()
      unblock.wait()
    }
    wait(for: [blockerStarted], timeout: 1)

    var acknowledgements: [Bool] = []
    let delivery = NativePasteDeliveryOwnership(
      deliveryId: staged.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    delivery.acknowledgementTimedOut()
    XCTAssertTrue(acknowledgements.isEmpty)
    XCTAssertTrue(nativePasteEntryExistsNoFollow(staged.item))

    unblock.signal()
    queue.sync {}
    XCTAssertEqual(acknowledgements, [false])
    XCTAssertFalse(nativePasteEntryExistsNoFollow(staged.item))
  }

  func testNativePasteTimeoutCannotOverrideReservedDartRejection() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let staged = try createNativePasteDelivery(in: store)
    let queue = DispatchQueue(label: "native-paste-test-reserved-rejection")
    let blockerStarted = expectation(description: "operation queue blocked")
    let unblock = DispatchSemaphore(value: 0)
    defer { unblock.signal() }
    queue.async {
      blockerStarted.fulfill()
      unblock.wait()
    }
    wait(for: [blockerStarted], timeout: 1)

    var acknowledgements: [Bool] = []
    let delivery = NativePasteDeliveryOwnership(
      deliveryId: staged.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    XCTAssertFalse(delivery.resolveFromDart(decision: .rejected))
    delivery.acknowledgementTimedOut()
    XCTAssertTrue(acknowledgements.isEmpty)

    unblock.signal()
    queue.sync {}
    XCTAssertEqual(acknowledgements, [false])
    XCTAssertFalse(nativePasteEntryExistsNoFollow(staged.item))
  }

  func testNativePasteTimeoutSeeingDartOwnershipPreservesItems() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let staged = try createNativePasteDelivery(in: store)
    try moveNativePasteMarker(
      store,
      deliveryId: staged.id,
      from: .pending,
      to: .dartOwned
    )
    let queue = DispatchQueue(label: "native-paste-test-owned-timeout")
    var acknowledgements: [Bool] = []
    let delivery = NativePasteDeliveryOwnership(
      deliveryId: staged.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    delivery.acknowledgementTimedOut()
    queue.sync {}

    XCTAssertEqual(acknowledgements, [true])
    XCTAssertTrue(nativePasteEntryExistsNoFollow(staged.item))
    XCTAssertFalse(nativePasteHasAnyMarker(store, deliveryId: staged.id))
  }

  func testRejectedClaimWithFailedRollbackPreservesDartOwnedItems() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let staged = try createNativePasteDelivery(in: store)
    try moveNativePasteMarker(
      store,
      deliveryId: staged.id,
      from: .pending,
      to: .dartOwned
    )
    let queue = DispatchQueue(label: "native-paste-test-failed-rollback")
    var acknowledgements: [Bool] = []
    let delivery = NativePasteDeliveryOwnership(
      deliveryId: staged.id,
      store: store,
      operationQueue: queue,
      acknowledgement: { acknowledgements.append($0) }
    )

    XCTAssertFalse(delivery.resolveFromDart(decision: .rejected))
    queue.sync {}

    XCTAssertEqual(acknowledgements, [true])
    XCTAssertTrue(nativePasteEntryExistsNoFollow(staged.item))
    XCTAssertFalse(nativePasteHasAnyMarker(store, deliveryId: staged.id))
  }

  func testNativeAndDartMarkerRenamesHaveExactlyOneWinner() throws {
    for iteration in 0..<40 {
      let root = nativePasteTestRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = NativePasteDeliveryStore(rootURL: root)
      let staged = try createNativePasteDelivery(in: store)
      let pending = try nativePasteMarker(
        store,
        deliveryId: staged.id,
        state: .pending
      )
      let dartOwned = try nativePasteMarker(
        store,
        deliveryId: staged.id,
        state: .dartOwned
      )
      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      let lock = NSLock()
      var dartWon = false
      var settlement: NativePasteDeliverySettlement?

      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        start.wait()
        let result = store.settle(deliveryId: staged.id)
        lock.lock()
        settlement = result
        lock.unlock()
        group.leave()
      }
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        start.wait()
        do {
          try FileManager.default.moveItem(at: pending, to: dartOwned)
          lock.lock()
          dartWon = true
          lock.unlock()
        } catch {}
        group.leave()
      }
      start.signal()
      start.signal()
      XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

      lock.lock()
      let observedDartWin = dartWon
      let observedSettlement = settlement
      lock.unlock()
      XCTAssertEqual(
        observedSettlement,
        observedDartWin ? .dartOwned : .reclaimed,
        "iteration \(iteration)"
      )
      XCTAssertEqual(
        nativePasteEntryExistsNoFollow(staged.item),
        observedDartWin,
        "iteration \(iteration)"
      )
      XCTAssertFalse(nativePasteHasAnyMarker(
        store,
        deliveryId: staged.id
      ))
    }
  }

  func testNativePasteStartupReconciliationIsStrictAndNoFollow() throws {
    let root = nativePasteTestRoot()
    let outsideTarget = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString.lowercased())-outside.png")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outsideTarget)
    }
    try Data([7, 8, 9]).write(to: outsideTarget)
    let store = NativePasteDeliveryStore(rootURL: root)

    let pending = try createNativePasteDelivery(in: store)
    let reclaiming = try createNativePasteDelivery(in: store)
    try moveNativePasteMarker(
      store,
      deliveryId: reclaiming.id,
      from: .pending,
      to: .reclaiming
    )
    let dartOwned = try createNativePasteDelivery(in: store)
    try moveNativePasteMarker(
      store,
      deliveryId: dartOwned.id,
      from: .pending,
      to: .dartOwned
    )

    let unmarkedId = UUID().uuidString.lowercased()
    let unmarked = try XCTUnwrap(store.stagingURL(
      deliveryId: unmarkedId,
      fileExtension: "png"
    ))
    try Data([1]).write(to: unmarked)
    let legacy = root.appendingPathComponent(
      "\(UUID().uuidString.lowercased())-native-paste.png"
    )
    try Data([2]).write(to: legacy)
    let malformedMarker = root.appendingPathComponent(
      ".conduit-native-paste-v2-not-a-uuid.pending"
    )
    try Data().write(to: malformedMarker)

    let linkedMarkerId = UUID().uuidString.lowercased()
    let linkedMarker = try nativePasteMarker(
      store,
      deliveryId: linkedMarkerId,
      state: .pending
    )
    try FileManager.default.createSymbolicLink(
      at: linkedMarker,
      withDestinationURL: outsideTarget
    )
    let linkedMarkerItem = try XCTUnwrap(store.stagingURL(
      deliveryId: linkedMarkerId,
      fileExtension: "png"
    ))
    try Data([3]).write(to: linkedMarkerItem)

    let linkedItemDelivery = try XCTUnwrap(store.createDelivery())
    let linkedItem = try XCTUnwrap(store.stagingURL(
      deliveryId: linkedItemDelivery,
      fileExtension: "png"
    ))
    try FileManager.default.createSymbolicLink(
      at: linkedItem,
      withDestinationURL: outsideTarget
    )

    let wrongPrefix = root.appendingPathComponent(
      "\(pending.id)-not-a-uuid-paste.png"
    )
    try Data([4]).write(to: wrongPrefix)

    store.reconcileStartup()

    XCTAssertFalse(nativePasteEntryExistsNoFollow(pending.item))
    XCTAssertFalse(nativePasteHasAnyMarker(store, deliveryId: pending.id))
    XCTAssertFalse(nativePasteEntryExistsNoFollow(reclaiming.item))
    XCTAssertFalse(nativePasteHasAnyMarker(
      store,
      deliveryId: reclaiming.id
    ))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(dartOwned.item))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(try nativePasteMarker(
      store,
      deliveryId: dartOwned.id,
      state: .dartOwned
    )))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(unmarked))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(legacy))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(malformedMarker))
    XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
      atPath: linkedMarker.path
    ))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(linkedMarkerItem))
    XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
      atPath: linkedItem.path
    ))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(outsideTarget))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(wrongPrefix))
  }

  func testNativePasteStartupGateRetriesFailedEnumerationBeforeAdmission() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let initialStore = NativePasteDeliveryStore(rootURL: root)
    let stale = try createNativePasteDelivery(in: initialStore)
    var failEnumeration = true
    let retryingStore = NativePasteDeliveryStore(
      rootURL: root,
      directoryContentsForTesting: { url in
        if failEnumeration { return nil }
        return try? FileManager.default.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: nil,
          options: [.skipsSubdirectoryDescendants]
        )
      }
    )
    let gate = NativePasteStartupGate()

    XCTAssertNil(gate.createDeliveryAfterReconciliation(store: retryingStore))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(stale.item))
    XCTAssertTrue(nativePasteHasAnyMarker(
      retryingStore,
      deliveryId: stale.id
    ))

    failEnumeration = false
    let admittedId = try XCTUnwrap(
      gate.createDeliveryAfterReconciliation(store: retryingStore)
    )

    XCTAssertFalse(nativePasteEntryExistsNoFollow(stale.item))
    XCTAssertFalse(nativePasteHasAnyMarker(
      retryingStore,
      deliveryId: stale.id
    ))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(try nativePasteMarker(
      retryingStore,
      deliveryId: admittedId,
      state: .pending
    )))
  }

  func testNativePasteFailedUnlinkKeepsReclaimMarkerForStartupRetry() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let initialStore = NativePasteDeliveryStore(rootURL: root)
    let staged = try createNativePasteDelivery(in: initialStore)
    var failItemDeletion = true
    let retryingStore = NativePasteDeliveryStore(
      rootURL: root,
      removeItemForTesting: { url in
        if failItemDeletion, url.standardizedFileURL == staged.item {
          return false
        }
        do {
          try FileManager.default.removeItem(at: url)
          return true
        } catch {
          return false
        }
      }
    )

    XCTAssertEqual(
      retryingStore.settle(deliveryId: staged.id),
      .preservedUnknown
    )
    XCTAssertTrue(nativePasteEntryExistsNoFollow(staged.item))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(try nativePasteMarker(
      retryingStore,
      deliveryId: staged.id,
      state: .reclaiming
    )))

    failItemDeletion = false
    XCTAssertTrue(retryingStore.reconcileStartup())
    XCTAssertFalse(nativePasteEntryExistsNoFollow(staged.item))
    XCTAssertFalse(nativePasteHasAnyMarker(
      retryingStore,
      deliveryId: staged.id
    ))
  }

  func testNativePasteTimeoutMarkerSurvivesForLateCopyReconciliation() throws {
    let root = nativePasteTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativePasteDeliveryStore(rootURL: root)
    let deliveryId = try XCTUnwrap(store.createDelivery())
    var providerCompletion: ((PlatformNativePasteImageItem?, Int64) -> Void)?
    var completions = 0
    var timeoutDrained = 0
    let coordinator = NativePasteStagingCoordinator(
      providerCount: 1,
      maxItemCount: 1,
      maxItemBytes: 10,
      maxAggregateBytes: 10,
      removeItems: { items in
        store.removeStrictItems(deliveryId: deliveryId, items: items)
      },
      onTimeoutStarted: {
        XCTAssertTrue(store.beginReclaiming(deliveryId: deliveryId))
      },
      onTimeoutDrained: {
        timeoutDrained += 1
        _ = store.settle(deliveryId: deliveryId)
      },
      completion: { items, timedOut in
        XCTAssertTrue(timedOut)
        XCTAssertTrue(items.isEmpty)
        completions += 1
      }
    )
    coordinator.start { _, _, completion in
      providerCompletion = completion
    }

    coordinator.timeout()
    let latePartial = try XCTUnwrap(store.stagingURL(
      deliveryId: deliveryId,
      fileExtension: "png"
    ))
    try Data([1, 2, 3]).write(to: latePartial)

    XCTAssertEqual(completions, 1)
    XCTAssertEqual(timeoutDrained, 0)
    XCTAssertTrue(nativePasteEntryExistsNoFollow(latePartial))
    XCTAssertTrue(nativePasteEntryExistsNoFollow(try nativePasteMarker(
      store,
      deliveryId: deliveryId,
      state: .reclaiming
    )))

    // Simulate process death before the non-cancellable provider callback.
    let restartedStore = NativePasteDeliveryStore(rootURL: root)
    XCTAssertTrue(restartedStore.reconcileStartup())
    XCTAssertFalse(nativePasteEntryExistsNoFollow(latePartial))
    XCTAssertFalse(nativePasteHasAnyMarker(
      restartedStore,
      deliveryId: deliveryId
    ))

    // A late callback still cannot redeliver or complete the paste twice.
    providerCompletion?(PlatformNativePasteImageItem(
      mimeType: "image/png",
      filePath: latePartial.path
    ), 3)
    coordinator.timeout()
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(timeoutDrained, 1)
  }

  func testNativePasteStagesAcrossFailuresUntilSuccessfulLimit() {
    let oversize = PlatformNativePasteImageItem(
      mimeType: "image/png",
      filePath: "oversize"
    )
    let first = PlatformNativePasteImageItem(
      mimeType: "image/png",
      filePath: "first"
    )
    let second = PlatformNativePasteImageItem(
      mimeType: "image/png",
      filePath: "second"
    )
    var attempts: [Int] = []
    var removed: [String] = []
    var delivered: [PlatformNativePasteImageItem] = []
    let coordinator = NativePasteStagingCoordinator(
      providerCount: 6,
      maxItemCount: 2,
      maxItemBytes: 10,
      maxAggregateBytes: 20,
      removeItems: { removed.append(contentsOf: $0.map(\.filePath)) },
      completion: { items, timedOut in
        XCTAssertFalse(timedOut)
        delivered = items
      }
    )

    coordinator.start { index, _, completion in
      attempts.append(index)
      switch index {
      case 0:
        completion(nil, 0)
      case 1:
        completion(oversize, 11)
      case 2:
        completion(first, 6)
      case 3:
        completion(nil, 0)
      case 4:
        completion(second, 6)
      default:
        XCTFail("staging continued after two successful images")
        completion(nil, 0)
      }
    }

    XCTAssertEqual(attempts, [0, 1, 2, 3, 4])
    XCTAssertEqual(delivered.map(\.filePath), ["first", "second"])
    XCTAssertEqual(removed, ["oversize"])
  }

  func testNativePasteTimeoutOwnsAccumulatedAndLateStagedFiles() {
    let accumulated = PlatformNativePasteImageItem(
      mimeType: "image/png",
      filePath: "accumulated"
    )
    let late = PlatformNativePasteImageItem(
      mimeType: "image/png",
      filePath: "late"
    )
    var secondProviderCompletion: ((PlatformNativePasteImageItem?, Int64) -> Void)?
    var removed: [String] = []
    var deliveries: [[PlatformNativePasteImageItem]] = []
    var timeoutFlags: [Bool] = []
    var timeoutStarted = 0
    var timeoutDrained = 0
    let coordinator = NativePasteStagingCoordinator(
      providerCount: 2,
      maxItemCount: 2,
      maxItemBytes: 10,
      maxAggregateBytes: 20,
      removeItems: { removed.append(contentsOf: $0.map(\.filePath)) },
      onTimeoutStarted: { timeoutStarted += 1 },
      onTimeoutDrained: { timeoutDrained += 1 },
      completion: { items, timedOut in
        deliveries.append(items)
        timeoutFlags.append(timedOut)
      }
    )

    coordinator.start { index, _, completion in
      if index == 0 {
        completion(accumulated, 4)
      } else {
        secondProviderCompletion = completion
      }
    }
    coordinator.timeout()
    XCTAssertEqual(timeoutStarted, 1)
    XCTAssertEqual(timeoutDrained, 0)
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(timeoutFlags, [true])
    secondProviderCompletion?(late, 4)
    coordinator.timeout()

    XCTAssertEqual(deliveries.count, 1)
    XCTAssertTrue(deliveries[0].isEmpty)
    XCTAssertEqual(removed, ["accumulated", "late"])
    XCTAssertEqual(timeoutStarted, 1)
    XCTAssertEqual(timeoutDrained, 1)
  }

  func testAppIntentStagedImageCleanupIsRestrictedToOwnedRoot() throws {
    let ownedDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("conduit-app-intents", isDirectory: true)
    try FileManager.default.createDirectory(
      at: ownedDirectory,
      withIntermediateDirectories: true
    )
    let ownedFile = ownedDirectory.appendingPathComponent(
      "\(UUID().uuidString)-intent.png"
    )
    let outsideFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)-outside.png")
    defer {
      try? FileManager.default.removeItem(at: ownedFile)
      try? FileManager.default.removeItem(at: outsideFile)
    }
    try Data([1]).write(to: ownedFile)
    try Data([2]).write(to: outsideFile)

    AppIntentBridge.removeStagedImageIfOwned(atPath: ownedFile.path)
    AppIntentBridge.removeStagedImageIfOwned(atPath: outsideFile.path)

    XCTAssertFalse(FileManager.default.fileExists(atPath: ownedFile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
  }

  func testAppIntentFileBackedImageIsStreamedIntoOwnedStaging() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString)-source.png"
    )
    let bytes = Data(repeating: 0x5a, count: 512 * 1024)
    try bytes.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let first = try await AppIntentBridge.stageImageArtifact(
      fileURL: source,
      filename: "source.png"
    )
    let retry = try await AppIntentBridge.stageImageArtifact(
      fileURL: source,
      filename: "source.png"
    )
    defer {
      AppIntentBridge.removeStagedImageIfOwned(atPath: first.filePath)
      AppIntentBridge.removeStagedImageIfOwned(atPath: retry.filePath)
    }

    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: first.filePath)),
      bytes
    )
    XCTAssertNotEqual(first.filePath, retry.filePath)
    XCTAssertEqual(first.contentDigest, retry.contentDigest)
  }

  func testAppIntentFileBackedImageRejectsOversizeBeforeStaging() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString)-oversize.png"
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(20 * 1024 * 1024 + 1))
    try handle.close()
    defer { try? FileManager.default.removeItem(at: source) }

    do {
      _ = try await AppIntentBridge.stageImage(
        fileURL: source,
        filename: "oversize.png"
      )
      XCTFail("oversize file was staged")
    } catch {
      XCTAssertTrue(error is AppIntentError)
    }
  }

  private func nativeShareStatusJSON(
    id: String,
    isInProgress: Bool
  ) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "id": id,
      "expectedFileCount": 1,
      "isInProgress": isInProgress,
      "errors": [],
    ])
  }

  private func nativeShareItemsJSON(_ items: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: items)
  }

  func testShareStagedFilenameFitsFilesystemByteLimitAndPreservesExtension() throws {
    let importId = UUID().uuidString.lowercased()
    let itemId = UUID().uuidString.lowercased()
    let originalName = String(repeating: "界", count: 300) + ".jpeg"

    let filename = try XCTUnwrap(nativeShareStagedFileName(
      importId: importId,
      itemId: itemId,
      ordinal: 11,
      originalName: originalName,
      fallbackExtension: "bin"
    ))

    XCTAssertLessThanOrEqual(
      filename.utf8.count,
      nativeShareMaximumFilenameBytes
    )
    XCTAssertTrue(filename.hasPrefix("\(importId)-\(itemId)-11-"))
    XCTAssertTrue(filename.hasSuffix(".jpeg"))
  }

  func testShareLoadWatchdogScalesWithAdmittedSerialWorkloadAndStaysBounded() {
    let empty = nativeShareLoadWatchdogInterval(
      totalItemCount: 0,
      fileBackedItemCount: 0
    )
    let oneFile = nativeShareLoadWatchdogInterval(
      totalItemCount: 1,
      fileBackedItemCount: 1
    )
    let maximumWorkload = nativeShareLoadWatchdogInterval(
      totalItemCount: nativeShareMaximumItemCount,
      fileBackedItemCount: 6
    )
    let untrustedCounts = nativeShareLoadWatchdogInterval(
      totalItemCount: .max,
      fileBackedItemCount: .max
    )

    XCTAssertEqual(empty, 20)
    XCTAssertGreaterThan(oneFile, empty)
    XCTAssertGreaterThan(maximumWorkload, oneFile)
    XCTAssertLessThanOrEqual(maximumWorkload, 120)
    XCTAssertEqual(untrustedCounts, maximumWorkload)
  }

  func testShareEnvelopeRejectsAStagedFileFromAnotherImportId() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-cross-import-file-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let currentId = UUID().uuidString.lowercased()
    let otherId = UUID().uuidString.lowercased()
    let otherFile = staging.appendingPathComponent(
      "\(otherId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    try Data([1, 2, 3]).write(to: otherFile)
    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: currentId,
      statusJSON: nativeShareStatusJSON(id: currentId, isInProgress: true)
    )

    XCTAssertThrowsError(try store.publish(
      id: currentId,
      itemsJSON: nativeShareItemsJSON([
        ["type": 2, "value": otherFile.absoluteString],
      ]),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: currentId, isInProgress: false)
    ))
    XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path))
    XCTAssertNil(try store.takeCurrent())
  }

  func testShareEnvelopeNewImportRecoversMalformedStatusPointerOnly() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-malformed-status-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let storage = container.appendingPathComponent(
      "conduit-share-envelopes-v1",
      isDirectory: true
    )
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: storage,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let orphanId = UUID().uuidString.lowercased()
    let orphan = staging.appendingPathComponent(
      "\(orphanId)-\(UUID().uuidString.lowercased())-0-orphan.png"
    )
    try Data([9]).write(to: orphan)
    let statusURL = storage.appendingPathComponent("current-status.json")
    let malformedStatuses = [
      Data("not-json".utf8),
      Data(repeating: 0x61, count: 256 * 1024 + 1),
      try JSONSerialization.data(withJSONObject: [
        "id": "not-a-uuid",
        "isInProgress": true,
      ]),
      try JSONSerialization.data(withJSONObject: [
        "id": UUID().uuidString.lowercased(),
        "isInProgress": "yes",
      ]),
    ]
    let store = NativeShareEnvelopeStore(containerURL: container)

    for malformed in malformedStatuses {
      try malformed.write(to: statusURL, options: .atomic)
      let replacementId = UUID().uuidString.lowercased()
      try store.beginImport(
        id: replacementId,
        statusJSON: nativeShareStatusJSON(
          id: replacementId,
          isInProgress: true
        )
      )
      let current = try XCTUnwrap(store.currentStatusJSON())
      let value = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: current) as? [String: Any]
      )
      XCTAssertEqual(value["id"] as? String, replacementId)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
  }

  func testShareEnvelopeAcceptsMaximumAggregateTextPayload() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-maximum-text-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let importId = UUID().uuidString.lowercased()
    let value = String(
      repeating: "a",
      count: nativeShareMaximumTextBytes
    )
    let items = try nativeShareItemsJSON((0..<nativeShareMaximumItemCount).map {
      _ in ["type": 0, "value": value]
    })
    XCTAssertGreaterThan(items.count, 2 * 1024 * 1024)
    XCTAssertGreaterThan(
      items.count,
      nativeShareMaximumAggregateTextBytes
    )

    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: importId,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: importId,
      itemsJSON: items,
      message: nil,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: false)
    ))
    XCTAssertEqual(try store.takeCurrent()?.envelope.itemsJSON, items)
  }

  func testShareEnvelopeRejectsTextBeyondAggregateLimit() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-over-aggregate-text-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let importId = UUID().uuidString.lowercased()
    let value = String(
      repeating: "a",
      count: nativeShareMaximumTextBytes
    )
    var payload = (0..<nativeShareMaximumItemCount).map {
      _ in ["type": 0 as Any, "value": value as Any]
    }
    payload[0]["message"] = "x"

    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: importId,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: true)
    )
    XCTAssertThrowsError(try store.publish(
      id: importId,
      itemsJSON: nativeShareItemsJSON(payload),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: false)
    ))
  }

  func testShareEnvelopeTakeAndAcknowledgementAreExactIdAndIdempotent() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-envelope-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    try FileManager.default.createDirectory(
      at: container,
      withIntermediateDirectories: true
    )
    let store = NativeShareEnvelopeStore(containerURL: container)
    let firstId = UUID().uuidString.lowercased()
    let secondId = UUID().uuidString.lowercased()
    let firstItems = try nativeShareItemsJSON([
      ["type": 0, "value": "first"],
    ])

    try store.beginImport(
      id: firstId,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: firstId,
      itemsJSON: firstItems,
      message: nil,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: false)
    ))
    XCTAssertEqual(try store.takeCurrent()?.envelope.id, firstId)
    XCTAssertTrue(try store.acknowledge(id: firstId))
    XCTAssertTrue(try store.acknowledge(id: firstId))

    try store.beginImport(
      id: secondId,
      statusJSON: nativeShareStatusJSON(id: secondId, isInProgress: true)
    )
    XCTAssertFalse(try store.acknowledge(id: firstId))
    XCTAssertNil(try store.takeCurrent())
    let currentStatus = try XCTUnwrap(store.currentStatusJSON())
    let currentMap = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: currentStatus) as? [String: Any]
    )
    XCTAssertEqual(currentMap["id"] as? String, secondId)
  }

  func testShareEnvelopeSupersedeCleansOnlyPriorOwnedStagingFiles() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-cleanup-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let firstId = UUID().uuidString.lowercased()
    let secondId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(firstId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    let unrelated = staging.appendingPathComponent(
      "\(UUID().uuidString.lowercased())-0-unrelated.png"
    )
    try Data([1, 2, 3]).write(to: owned)
    try Data([9]).write(to: unrelated)
    let store = NativeShareEnvelopeStore(containerURL: container)

    try store.beginImport(
      id: firstId,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: firstId,
      itemsJSON: nativeShareItemsJSON([
        ["type": 2, "value": owned.absoluteString],
      ]),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: false)
    ))

    try store.beginImport(
      id: secondId,
      statusJSON: nativeShareStatusJSON(id: secondId, isInProgress: true)
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertFalse(try store.acknowledge(id: firstId))
  }

  func testShareEnvelopeAcknowledgementTransfersStagedFileOwnership() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-transfer-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let firstId = UUID().uuidString.lowercased()
    let secondId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(firstId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    try Data([1]).write(to: owned)
    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: firstId,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: firstId,
      itemsJSON: nativeShareItemsJSON([
        ["type": 2, "value": owned.absoluteString],
      ]),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: false)
    ))
    XCTAssertTrue(try store.acknowledge(id: firstId))

    try store.beginImport(
      id: secondId,
      statusJSON: nativeShareStatusJSON(id: secondId, isInProgress: true)
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
  }

  func testShareEnvelopeFailedSupersedeRetainsDartOwnershipMarker() throws {
    enum InjectedFailure: Error { case statusWrite }

    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-failed-supersede-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let firstId = UUID().uuidString.lowercased()
    let secondId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(firstId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    try Data([1, 2, 3]).write(to: owned)
    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: firstId,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: firstId,
      itemsJSON: nativeShareItemsJSON([
        ["type": 2, "value": owned.absoluteString],
      ]),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: firstId, isInProgress: false)
    ))
    XCTAssertTrue(try store.acknowledge(id: firstId))

    let failingStore = NativeShareEnvelopeStore(
      containerURL: container,
      statusWriteOverrideForTesting: { _, _ in
        throw InjectedFailure.statusWrite
      }
    )
    XCTAssertThrowsError(try failingStore.beginImport(
      id: secondId,
      statusJSON: nativeShareStatusJSON(id: secondId, isInProgress: true)
    ))

    XCTAssertTrue(try store.acknowledge(id: firstId))
    XCTAssertNil(try store.takeCurrent())
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))

    try store.beginImport(
      id: secondId,
      statusJSON: nativeShareStatusJSON(id: secondId, isInProgress: true)
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertFalse(try store.acknowledge(id: firstId))
  }

  func testShareEnvelopePublishFailureRemovesCrashLeftEnvelopeBeforeCleanup() throws {
    enum InjectedFailure: Error { case statusWrite }

    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-failed-publish-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let importId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(importId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    try Data([4, 5, 6]).write(to: owned)
    let itemsJSON = try nativeShareItemsJSON([
      ["type": 2, "value": owned.absoluteString],
    ])
    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: importId,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: true)
    )

    // Model a process exit after the immutable envelope rename but before the
    // terminal status rename.
    let storage = container.appendingPathComponent(
      "conduit-share-envelopes-v1",
      isDirectory: true
    )
    let envelopeURL = storage.appendingPathComponent(
      "payload-\(importId).plist"
    )
    let crashLeftEnvelope = NativeSharePayloadEnvelope(
      id: importId,
      itemsJSON: itemsJSON,
      message: nil
    )
    try PropertyListEncoder().encode(crashLeftEnvelope).write(to: envelopeURL)

    let failingStore = NativeShareEnvelopeStore(
      containerURL: container,
      statusWriteOverrideForTesting: { _, _ in
        throw InjectedFailure.statusWrite
      }
    )
    XCTAssertThrowsError(try failingStore.publish(
      id: importId,
      itemsJSON: itemsJSON,
      message: nil,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: false)
    ))

    XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertNil(try store.takeCurrent())
  }

  func testShareEnvelopeAcknowledgedClearRequiresExactIdAndPreservesFiles() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-acknowledged-clear-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let importId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(importId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    try Data([7]).write(to: owned)
    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: importId,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: importId,
      itemsJSON: nativeShareItemsJSON([
        ["type": 2, "value": owned.absoluteString],
      ]),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: false)
    ))
    XCTAssertTrue(try store.acknowledge(id: importId))

    XCTAssertFalse(try store.clearStatus(id: nil))
    XCTAssertNotNil(try store.currentStatusJSON())
    XCTAssertTrue(try store.clearStatus(id: importId))
    XCTAssertNil(try store.currentStatusJSON())
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertFalse(try store.acknowledge(id: importId))
  }

  func testShareEnvelopeClearReclaimsOnlyUnacknowledgedNativeFiles() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-clear-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let importId = UUID().uuidString.lowercased()
    let otherId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(importId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    try Data([1]).write(to: owned)
    let store = NativeShareEnvelopeStore(containerURL: container)
    try store.beginImport(
      id: importId,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: true)
    )
    XCTAssertTrue(try store.publish(
      id: importId,
      itemsJSON: nativeShareItemsJSON([
        ["type": 2, "value": owned.absoluteString],
      ]),
      message: nil,
      statusJSON: nativeShareStatusJSON(id: importId, isInProgress: false)
    ))

    XCTAssertFalse(try store.clearStatus(id: otherId))
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertTrue(try store.clearStatus(id: importId))
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertNil(try store.currentStatusJSON())
    XCTAssertFalse(try store.acknowledge(id: importId))
  }

  func testCorruptLegacyShareRecordIsDiscardedWithoutDeletingUntrustedPaths() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-corrupt-legacy-\(UUID().uuidString)",
      isDirectory: true
    )
    let staging = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    let suiteName = "RunnerTests.NativeShare.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: container)
    }
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: true
    )
    let importId = UUID().uuidString.lowercased()
    let owned = staging.appendingPathComponent(
      "\(importId)-\(UUID().uuidString.lowercased())-0-image.png"
    )
    let outside = container.appendingPathComponent("outside.png")
    try Data([1]).write(to: owned)
    try Data([2]).write(to: outside)
    defaults.set(
      try nativeShareItemsJSON([
        ["type": 2, "value": owned.absoluteString],
        ["type": 2, "value": outside.absoluteString],
        ["value": "corrupt-entry-without-type"],
      ]),
      forKey: nativeShareLegacyPayloadDefaultsKey
    )
    defaults.set(
      try nativeShareStatusJSON(id: importId, isInProgress: false),
      forKey: nativeShareLegacyStatusDefaultsKey
    )
    defaults.set("legacy", forKey: nativeShareLegacyMessageDefaultsKey)
    defaults.synchronize()

    let store = NativeShareEnvelopeStore(
      containerURL: container,
      legacyDefaults: defaults
    )

    XCTAssertNil(try store.currentStatusJSON())
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    XCTAssertNil(defaults.object(forKey: nativeShareLegacyPayloadDefaultsKey))
    XCTAssertNil(defaults.object(forKey: nativeShareLegacyStatusDefaultsKey))
    XCTAssertNil(defaults.object(forKey: nativeShareLegacyMessageDefaultsKey))
  }

  func testSharePayloadValidationRequiresDurableIdAndOwnedRegularFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-validation-\(UUID().uuidString)",
      isDirectory: true
    )
    let owned = root.appendingPathComponent("shared.png")
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-share-outside-\(UUID().uuidString).png"
    )
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    try Data([1]).write(to: owned)
    try Data([2]).write(to: outside)

    let valid = nativeValidatedShareImportPayload(
      rawItems: [
        ["type": 0, "value": " shared text "],
        ["type": 2, "value": owned.absoluteString],
      ],
      message: nil,
      status: ["id": " current "],
      shareStagingDirectoryPath: root.path
    )

    XCTAssertEqual(valid?["id"] as? String, "current")
    XCTAssertEqual(valid?["text"] as? String, "shared text")
    XCTAssertEqual(
      valid?["filePaths"] as? [String],
      [owned.resolvingSymlinksInPath().path]
    )
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [["type": 0, "value": "text"]],
      message: nil,
      status: [:],
      shareStagingDirectoryPath: root.path
    ))
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [["type": 2]],
      message: nil,
      status: ["id": "current"],
      shareStagingDirectoryPath: root.path
    ))
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [["type": 2, "value": "file://%"]],
      message: nil,
      status: ["id": "current"],
      shareStagingDirectoryPath: root.path
    ))
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [["type": 2, "value": "relative.png"]],
      message: nil,
      status: ["id": "current"],
      shareStagingDirectoryPath: root.path
    ))
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [["type": 2, "value": outside.absoluteString]],
      message: nil,
      status: ["id": "current"],
      shareStagingDirectoryPath: root.path
    ))
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [],
      message: "  ",
      status: ["id": "current"],
      shareStagingDirectoryPath: root.path
    ))

    let symlink = root.appendingPathComponent("linked.png")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    XCTAssertNil(nativeValidatedShareImportPayload(
      rawItems: [["type": 2, "value": symlink.absoluteString]],
      message: nil,
      status: ["id": "current"],
      shareStagingDirectoryPath: root.path
    ))
  }

  func testSharedPayloadBooleanTypesAreNotNumericTextCodes() {
    XCTAssertFalse(nativeSharedPayloadTypeIsText(false))
    XCTAssertFalse(nativeSharedPayloadTypeIsText(true))
    XCTAssertTrue(nativeSharedPayloadTypeIsText(NSNumber(value: 0)))
    XCTAssertTrue(nativeSharedPayloadTypeIsText(NSNumber(value: 1)))
  }

  func testConcurrentSttShutdownWaitersShareCompletion() async {
    let completion = NativeSttShutdownCompletion()
    let state = AsyncTestFlag()
    let waiter = Task {
      await completion.wait()
      await state.set()
    }

    try? await Task.sleep(nanoseconds: 10_000_000)
    let completedBeforeSignal = await state.current()
    XCTAssertFalse(completedBeforeSignal)

    completion.complete()
    await waiter.value
    let completedAfterSignal = await state.current()
    XCTAssertTrue(completedAfterSignal)

    let startedAt = ProcessInfo.processInfo.systemUptime
    await completion.wait()
    XCTAssertLessThan(
      ProcessInfo.processInfo.systemUptime - startedAt,
      0.1
    )
  }

  func testNativeSttLifecycleSerializesReplacementAfterFullShutdown() async {
    let lifecycle = NativeSttLifecycleState()
    let firstTransition = lifecycle.beginStart()
    await firstTransition.shutdownTask.value
    let first = TestNativeSttSession()
    XCTAssertTrue(
      lifecycle.install(first, generation: firstTransition.generation)
    )

    let replacementTransition = lifecycle.beginStart()
    let firstStopStarted = await first.stopStarted.wait(
      timeoutNanoseconds: 500_000_000
    )
    XCTAssertTrue(firstStopStarted)
    let stale = TestNativeSttSession()
    XCTAssertFalse(
      lifecycle.install(stale, generation: firstTransition.generation)
    )
    let joinedRetirement = lifecycle.retireIfCurrent(
      first,
      generation: firstTransition.generation
    )

    first.allowStop.complete()
    await joinedRetirement.value
    await replacementTransition.shutdownTask.value
    let replacement = TestNativeSttSession()
    XCTAssertTrue(
      lifecycle.install(
        replacement,
        generation: replacementTransition.generation
      )
    )

    let stopTransition = lifecycle.beginStop()
    let replacementStopStarted = await replacement.stopStarted.wait(
      timeoutNanoseconds: 500_000_000
    )
    XCTAssertTrue(replacementStopStarted)
    replacement.allowStop.complete()
    await stopTransition.shutdownTask.value
    XCTAssertEqual(first.stopCount, 1)
    XCTAssertEqual(replacement.stopCount, 1)
  }

  func testNativeSttCommandTransitionsHonorReceiptOrderBeforeAwaiting() async {
    let lifecycle = NativeSttLifecycleState()
    let start = lifecycle.beginStart()
    let stop = lifecycle.beginStop()
    let restart = lifecycle.beginStart()

    XCTAssertFalse(lifecycle.isCurrent(start.generation))
    XCTAssertFalse(lifecycle.isCurrent(stop.generation))
    XCTAssertTrue(lifecycle.isCurrent(restart.generation))

    await restart.shutdownTask.value
  }

  func testStaleSttFinishCannotRetireReplacementSession() async {
    let lifecycle = NativeSttLifecycleState()
    let firstTransition = lifecycle.beginStart()
    await firstTransition.shutdownTask.value
    let first = TestNativeSttSession()
    XCTAssertTrue(lifecycle.install(first, generation: firstTransition.generation))

    let replacementTransition = lifecycle.beginStart()
    first.allowStop.complete()
    await replacementTransition.shutdownTask.value
    let replacement = TestNativeSttSession()
    XCTAssertTrue(lifecycle.install(
      replacement,
      generation: replacementTransition.generation
    ))

    await lifecycle.finishIfCurrent(
      first,
      generation: firstTransition.generation
    ).value
    XCTAssertEqual(replacement.stopCount, 0)
    XCTAssertTrue(lifecycle.isInstalled(
      replacement,
      generation: replacementTransition.generation
    ))

    let stop = lifecycle.beginStop()
    replacement.allowStop.complete()
    await stop.shutdownTask.value
  }

  func testCurrentSttFinishInvalidatesGenerationBeforeShutdown() async {
    let lifecycle = NativeSttLifecycleState()
    let transition = lifecycle.beginStart()
    await transition.shutdownTask.value
    let session = TestNativeSttSession()
    XCTAssertTrue(lifecycle.install(
      session,
      generation: transition.generation
    ))

    let shutdown = lifecycle.finishIfCurrent(
      session,
      generation: transition.generation
    )

    XCTAssertFalse(lifecycle.isCurrent(transition.generation))
    XCTAssertFalse(lifecycle.isInstalled(
      session,
      generation: transition.generation
    ))
    session.allowStop.complete()
    await shutdown.value
  }

  func testSttEventGateRejectsStaleStartAndSubscriptionEvents() {
    let gate = NativeSttEventDeliveryGate()
    var firstSubscriptionEvents: [String] = []
    gate.listen { value in
      if let payload = value as? [String: Any],
         let value = payload["value"] as? String {
        firstSubscriptionEvents.append(value)
      }
    }

    let first = gate.activate(lifecycleGeneration: 1)
    let replacement = gate.activate(lifecycleGeneration: 2)
    XCTAssertFalse(gate.deliver(["value": "stale"], token: first))
    XCTAssertTrue(gate.deliver(["value": "replacement"], token: replacement))
    XCTAssertEqual(firstSubscriptionEvents, ["replacement"])

    var secondSubscriptionEvents: [String] = []
    gate.listen { value in
      if let payload = value as? [String: Any],
         let value = payload["value"] as? String {
        secondSubscriptionEvents.append(value)
      }
    }
    XCTAssertFalse(gate.deliver(["value": "old-subscription"], token: replacement))
    let current = gate.activate(lifecycleGeneration: 2)
    XCTAssertTrue(gate.deliver(["value": "current"], token: current))
    gate.cancelSubscription()
    XCTAssertFalse(gate.deliver(["value": "cancelled"], token: current))
    XCTAssertEqual(secondSubscriptionEvents, ["current"])
  }

  func testSttEventGateOnlyOwnerCanDeactivateReplacement() {
    let gate = NativeSttEventDeliveryGate()
    var values: [String] = []
    gate.listen { value in
      if let payload = value as? [String: Any],
         let value = payload["value"] as? String {
        values.append(value)
      }
    }

    let retiring = gate.activate(lifecycleGeneration: 1)
    let replacement = gate.activate(lifecycleGeneration: 2)

    XCTAssertFalse(gate.deactivate(retiring))
    XCTAssertTrue(gate.deliver(["value": "replacement"], token: replacement))
    XCTAssertTrue(gate.deactivate(replacement))
    XCTAssertFalse(gate.deliver(["value": "late"], token: replacement))
    XCTAssertEqual(values, ["replacement"])
  }

  func testSttTerminalReservationOrdersDoneAndRejectsLaterResults() {
    let gate = NativeSttEventDeliveryGate()
    var eventTypes: [String] = []
    let doneDelivered = expectation(description: "done delivered")
    gate.listen { value in
      guard let payload = value as? [String: Any],
            let type = payload["type"] as? String else { return }
      eventTypes.append(type)
      if type == "done" { doneDelivered.fulfill() }
    }
    let token = gate.activate(lifecycleGeneration: 1)

    XCTAssertTrue(gate.enqueue(
      ["type": "result", "text": "before"],
      token: token,
      isTerminal: false
    ))
    XCTAssertTrue(gate.enqueue(
      ["type": "done"],
      token: token,
      isTerminal: true
    ))
    XCTAssertFalse(gate.enqueue(
      ["type": "result", "text": "after"],
      token: token,
      isTerminal: false
    ))

    wait(for: [doneDelivered], timeout: 1)
    XCTAssertEqual(eventTypes, ["result", "done"])
    XCTAssertFalse(gate.deliver(["type": "result"], token: token))
  }

  func testNativeSttStopAcknowledgementTimeoutDoesNotCancelDeferredCleanup() async {
    let cleanupCanFinish = NativeSttShutdownCompletion()
    let cleanup = Task {
      await cleanupCanFinish.wait()
    }
    let startedAt = ProcessInfo.processInfo.systemUptime

    let completed = await waitForNativeSttTask(
      cleanup,
      timeoutNanoseconds: 10_000_000
    )

    XCTAssertFalse(completed)
    XCTAssertLessThan(
      ProcessInfo.processInfo.systemUptime - startedAt,
      0.5
    )
    cleanupCanFinish.complete()
    await cleanup.value
  }

  func testNativeSttResourceMutationGateClosesAndDrainsWithoutBlockingMutation() async {
    let gate = NativeSttResourceMutationGate()
    XCTAssertTrue(gate.begin())
    gate.close()
    XCTAssertFalse(gate.begin())
    let drained = NativeSttShutdownCompletion()
    let waiter = Task {
      await gate.waitUntilDrained()
      drained.complete()
    }

    let drainedEarly = await drained.wait(timeoutNanoseconds: 10_000_000)
    XCTAssertFalse(drainedEarly)
    gate.end()
    let drainedAfterEnd = await drained.wait(
      timeoutNanoseconds: 500_000_000
    )
    XCTAssertTrue(drainedAfterEnd)
    await waiter.value
  }

  func testAppIntentInvocationInterruptionIsExactlyOnceAndMarksDispatchedOwnershipIndeterminate() async {
    let completion = AppIntentInvocationCompletion()
    let responseTask = Task { () -> [String: Any] in
      await withCheckedContinuation { continuation in
        completion.install(continuation)
      }
    }

    XCTAssertTrue(completion.beginDispatch())
    XCTAssertFalse(completion.beginDispatch())
    XCTAssertTrue(completion.resolveInterrupted("timed out"))
    XCTAssertFalse(completion.resolveCompleted(["success": true]))

    let response = await responseTask.value
    XCTAssertEqual(response["success"] as? Bool, false)
    XCTAssertEqual(
      response[appIntentNativeDispatchStateKey] as? String,
      appIntentNativeDispatchIndeterminate
    )
  }

  func testAppIntentInvocationLeaseSeparatesOverlappingDispatches() throws {
    let suiteName = "RunnerTests.AppIntentInvocation.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var now: Int64 = 1_000
    let store = AppIntentInvocationStore(
      defaults: defaults,
      nowMilliseconds: { now }
    )
    let parameters = ["text": "private input"]

    let first = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    let overlap = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertNotEqual(overlap.invocationId, first.invocationId)

    store.resolve(
      first,
      dispatchState: appIntentNativeDispatchIndeterminate
    )
    let retry = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertEqual(retry.invocationId, first.invocationId)
    XCTAssertFalse(
      AppIntentInvocationStore.fingerprint(
        identifier: "app.cogwheel.conduit.send_text",
        canonicalParameters: parameters
      ).contains("private input")
    )

    store.resolve(overlap, dispatchState: appIntentNativeDispatchCompleted)
    store.resolve(retry, dispatchState: appIntentNativeDispatchCompleted)
    let next = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertNotEqual(next.invocationId, first.invocationId)

    now += 6 * 60 * 1_000
    let expired = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertNotEqual(expired.invocationId, next.invocationId)
  }

  func testAppIntentInvocationRetryRenewsAndPersistsNearExpiryLease() throws {
    let suiteName = "RunnerTests.AppIntentInvocationExpiry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var now: Int64 = 1_000
    let parameters = ["text": "retry input"]
    let store = AppIntentInvocationStore(
      defaults: defaults,
      nowMilliseconds: { now }
    )
    let first = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    store.resolve(
      first,
      dispatchState: appIntentNativeDispatchIndeterminate
    )

    now += 5 * 60 * 1_000 - 1
    let nearExpiryRetry = store.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertEqual(nearExpiryRetry.invocationId, first.invocationId)
    store.resolve(
      nearExpiryRetry,
      dispatchState: appIntentNativeDispatchIndeterminate
    )

    // Advance past the original lease deadline, then recreate the store to
    // prove that retry renewal was flushed to UserDefaults.
    now += 2
    let reloadedStore = AppIntentInvocationStore(
      defaults: defaults,
      nowMilliseconds: { now }
    )
    let persistedRetry = reloadedStore.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertEqual(persistedRetry.invocationId, first.invocationId)
  }

  func testAppIntentInvocationBecomesRetryableAfterStoreRecreation() throws {
    let suiteName = "RunnerTests.AppIntentInvocationRestart.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let parameters = ["text": "interrupted input"]
    let firstStore = AppIntentInvocationStore(defaults: defaults)
    let interrupted = firstStore.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )

    // Store recreation models process termination before resolve() could run.
    let restartedStore = AppIntentInvocationStore(defaults: defaults)
    let retry = restartedStore.lease(
      identifier: "app.cogwheel.conduit.send_text",
      canonicalParameters: parameters
    )
    XCTAssertEqual(retry.invocationId, interrupted.invocationId)
  }

  func testNativeSttPcmCopyPreservesInterleavedChannelStride() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 2,
        interleaved: true
      )
    )
    let source = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)
    )
    source.frameLength = 3
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
      source.mutableAudioBufferList
    )
    let sourceSamples = try XCTUnwrap(sourceBuffers[0].mData)
      .bindMemory(to: Int16.self, capacity: 6)
    let expected: [Int16] = [1, 11, 2, 22, 3, 33]
    for (index, value) in expected.enumerated() {
      sourceSamples[index] = value
    }

    let copied = try XCTUnwrap(copyNativeSttPCMBuffer(source))
    let copiedBuffers = UnsafeMutableAudioBufferListPointer(
      copied.mutableAudioBufferList
    )
    let copiedSamples = try XCTUnwrap(copiedBuffers[0].mData)
      .bindMemory(to: Int16.self, capacity: 6)

    XCTAssertEqual(copied.frameLength, 3)
    XCTAssertEqual(
      (0..<expected.count).map { copiedSamples[$0] },
      expected
    )
  }

  func testNativeSttPcmCopyRejectsUninitializedSamples() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    )
    let source = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)
    )

    XCTAssertNil(copyNativeSttPCMBuffer(source))
  }

  func testNativeSttPcmBufferPoolIsFixedCapacityAndReusable() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      )
    )
    let source = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
    )
    source.frameLength = 4
    let samples = try XCTUnwrap(source.int16ChannelData?[0])
    for index in 0..<4 { samples[index] = Int16(index + 1) }
    let pool = try XCTUnwrap(
      NativeSttPCMBufferPool(format: format, frameCapacity: 4, count: 2)
    )

    let first = try XCTUnwrap(pool.copyFromTap(source))
    let second = try XCTUnwrap(pool.copyFromTap(source))
    XCTAssertNil(pool.copyFromTap(source))
    XCTAssertEqual(pool.availableCount, 0)
    XCTAssertEqual(first.buffer.frameLength, 4)
    XCTAssertEqual(first.buffer.int16ChannelData?[0][3], 4)

    first.release()
    XCTAssertEqual(pool.availableCount, 1)
    let reused = try XCTUnwrap(pool.copyFromTap(source))
    XCTAssertEqual(pool.availableCount, 0)
    second.release()
    reused.release()
    XCTAssertEqual(pool.availableCount, 2)
  }

  func testNativeSttPcmBufferPoolCopiesOversizedTapBuffersOffPool() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      )
    )
    // iOS treats the requested tap bufferSize as a hint; a delivered buffer
    // larger than a pool slot must still reach the analyzer.
    let source = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)
    )
    source.frameLength = 8
    let samples = try XCTUnwrap(source.int16ChannelData?[0])
    for index in 0..<8 { samples[index] = Int16(index + 1) }
    let pool = try XCTUnwrap(
      NativeSttPCMBufferPool(format: format, frameCapacity: 4, count: 2)
    )

    let oversized = try XCTUnwrap(pool.copyFromTap(source))
    XCTAssertEqual(pool.availableCount, 2)
    XCTAssertEqual(oversized.buffer.frameLength, 8)
    XCTAssertEqual(oversized.buffer.int16ChannelData?[0][7], 8)

    // Releasing a one-off lease must not mint a phantom pool slot.
    oversized.release()
    XCTAssertEqual(pool.availableCount, 2)

    source.frameLength = 4
    let pooledFirst = try XCTUnwrap(pool.copyFromTap(source))
    let pooledSecond = try XCTUnwrap(pool.copyFromTap(source))
    XCTAssertNil(pool.copyFromTap(source))
    pooledFirst.release()
    pooledSecond.release()
    XCTAssertEqual(pool.availableCount, 2)
  }

  func testAvatarSelectionGenerationInvalidatesStaleCompression() {
    let generation = NativeAvatarSelectionGeneration()
    let firstPhoto = generation.begin()
    let secondPhoto = generation.begin()

    XCTAssertFalse(generation.isCurrent(firstPhoto))
    XCTAssertTrue(generation.isCurrent(secondPhoto))

    generation.invalidate()
    XCTAssertFalse(generation.isCurrent(secondPhoto))
  }

  func testAvatarPreviewMutationInvalidatesInitialImageLoad() {
    let generation = NativeAvatarSelectionGeneration()
    let initialImageLoad = generation.begin()

    generation.invalidate()

    XCTAssertFalse(generation.isCurrent(initialImageLoad))
  }

  func testHostOnlyCookieDoesNotMatchSubdomain() throws {
    let hostOnly = try testCookie(domain: "example.test", path: "/")
    let domain = try testCookie(domain: ".example.test", path: "/")
    let subdomainUrl = try XCTUnwrap(URL(string: "https://sub.example.test/"))

    XCTAssertFalse(cookieMatchesUrl(cookie: hostOnly, url: subdomainUrl))
    XCTAssertTrue(cookieMatchesUrl(cookie: domain, url: subdomainUrl))
  }

  func testSecureCookieDoesNotMatchHttpUrl() throws {
    let secureCookie = try testCookie(
      domain: "example.test",
      path: "/",
      secure: true
    )

    XCTAssertFalse(
      cookieMatchesUrl(
        cookie: secureCookie,
        url: try XCTUnwrap(URL(string: "http://example.test/"))
      )
    )
    XCTAssertTrue(
      cookieMatchesUrl(
        cookie: secureCookie,
        url: try XCTUnwrap(URL(string: "https://example.test/"))
      )
    )
  }

  func testCookiePathRequiresRfcBoundary() throws {
    let cookie = try testCookie(domain: "example.test", path: "/foo")

    XCTAssertTrue(
      cookieMatchesUrl(
        cookie: cookie,
        url: try XCTUnwrap(URL(string: "https://example.test/foo/bar"))
      )
    )
    XCTAssertFalse(
      cookieMatchesUrl(
        cookie: cookie,
        url: try XCTUnwrap(URL(string: "https://example.test/foobar"))
      )
    )
  }

  func testCookiePathDoesNotTreatEncodedSlashAsBoundary() throws {
    let cookie = try testCookie(domain: "example.test", path: "/admin")

    XCTAssertFalse(
      cookieMatchesUrl(
        cookie: cookie,
        url: try XCTUnwrap(
          URL(string: "https://example.test/admin%2Fpublic")
        )
      )
    )
    XCTAssertTrue(
      cookieMatchesUrl(
        cookie: cookie,
        url: try XCTUnwrap(
          URL(string: "https://example.test/admin/%2Fpublic")
        )
      )
    )
  }

  func testDuplicateCookieNamesPreferLongestMatchingPathDeterministically() throws {
    let root = try testCookie(
      name: "session",
      value: "root",
      domain: "example.test",
      path: "/"
    )
    let scoped = try testCookie(
      name: "session",
      value: "scoped",
      domain: "example.test",
      path: "/foo"
    )
    let url = try XCTUnwrap(URL(string: "https://example.test/foo/bar"))

    XCTAssertEqual(
      cookieValuesForUrl(cookies: [root, scoped], url: url)["session"],
      "scoped"
    )
    XCTAssertEqual(
      cookieValuesForUrl(cookies: [scoped, root], url: url)["session"],
      "scoped"
    )
  }

}

private func testCookie(
  name: String = "session",
  value: String = "value",
  domain: String,
  path: String,
  secure: Bool = false
) throws -> HTTPCookie {
  var properties: [HTTPCookiePropertyKey: Any] = [
    .name: name,
    .value: value,
    .domain: domain,
    .path: path,
  ]
  if secure {
    properties[.secure] = "TRUE"
  }
  return try XCTUnwrap(HTTPCookie(properties: properties))
}

private actor AsyncTestFlag {
  private var value = false

  func set() {
    value = true
  }

  func current() -> Bool {
    value
  }
}

private final class TestNativeSttSession: NativeSttSession {
  let stopStarted = NativeSttShutdownCompletion()
  let allowStop = NativeSttShutdownCompletion()
  private let lock = NSLock()
  private var storedStopCount = 0

  var stopCount: Int {
    lock.lock()
    let value = storedStopCount
    lock.unlock()
    return value
  }

  func stop() async {
    recordStop()
    stopStarted.complete()
    await allowStop.wait()
  }

  private func recordStop() {
    lock.lock()
    storedStopCount += 1
    lock.unlock()
  }
}
