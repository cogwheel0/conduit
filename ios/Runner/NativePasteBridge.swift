import Darwin
import Flutter
import Foundation
import ObjectiveC.runtime
import UIKit
import UniformTypeIdentifiers

final class NativePasteDeliveryCompletion {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    /// Returns true only to the caller that delivered the acknowledgement.
    @discardableResult
    func resolve(_ consumed: Bool) -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()

        guard let callback else { return false }
        callback(consumed)
        return true
    }
}

enum NativePasteDeliveryDecision: Equatable {
    case accepted
    case rejected
    case indeterminate

    var suppressesFallbackPaste: Bool {
        self != .rejected
    }
}

struct NativePasteEditorContext: Equatable {
    let documentText: String
    let selectionStart: Int
    let selectionEnd: Int
}

func nativePasteEditorContext(for responder: UIResponder) ->
    NativePasteEditorContext? {
    guard let textInput = responder as? UITextInput,
          let documentRange = textInput.textRange(
            from: textInput.beginningOfDocument,
            to: textInput.endOfDocument
          ),
          let documentText = textInput.text(in: documentRange),
          let selection = textInput.selectedTextRange else { return nil }
    return NativePasteEditorContext(
        documentText: documentText,
        selectionStart: textInput.offset(
            from: textInput.beginningOfDocument,
            to: selection.start
        ),
        selectionEnd: textInput.offset(
            from: textInput.beginningOfDocument,
            to: selection.end
        )
    )
}

func nativePasteFallbackContextMatches(
    responderIsFirstResponder: Bool,
    expectedPasteboardChangeCount: Int,
    currentPasteboardChangeCount: Int,
    expectedEditorContext: NativePasteEditorContext?,
    currentEditorContext: NativePasteEditorContext?
) -> Bool {
    responderIsFirstResponder &&
        expectedPasteboardChangeCount == currentPasteboardChangeCount &&
        expectedEditorContext == currentEditorContext
}

enum NativePasteDeliveryMarkerState: String, CaseIterable {
    case pending
    case dartOwned = "dart-owned"
    case reclaiming
}

enum NativePasteDeliverySettlement: Equatable {
    case reclaimed
    case dartOwned
    case preservedUnknown
}

/// Reads an item-provider URL under file-coordination ownership. In-place
/// representations can be backed by another process (for example Files or a
/// document provider), so opening the original URL directly can race an
/// eviction or writer while the bytes are copied into app-owned staging.
func withCoordinatedNativePasteRead<T>(
    at sourceURL: URL,
    _ read: (URL) -> T?
) -> T? {
    let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
        if didAccessSecurityScope {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    var coordinationError: NSError?
    var result: T?
    NSFileCoordinator(filePresenter: nil).coordinate(
        readingItemAt: sourceURL,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        result = read(coordinatedURL)
    }
    guard coordinationError == nil else { return nil }
    return result
}

private enum NativePasteNoFollowEntry: Equatable {
    case missing
    case regularFile
    case directory
    case other
    case inaccessible
}

/// Filesystem-backed ownership handshake for native paste deliveries.
///
/// Both sides race to rename the same `.pending` marker. Dart renames it to
/// `.dart-owned` immediately before the synchronous composer mutation; native
/// iOS renames it to `.reclaiming` before deleting the batch. A rename can win
/// only once, so a delayed Pigeon reply can never make native delete files that
/// Dart already owns.
final class NativePasteDeliveryStore {
    static let stagingDirectoryName = "conduit-native-paste"
    static let markerPrefix = ".conduit-native-paste-v2-"
    static let allowedExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpg", "png", "tiff", "webp",
    ]

    let rootURL: URL
    private let fileManager: FileManager
    private let directoryContentsOverride: ((URL) -> [URL]?)?
    private let removeItemOverride: ((URL) -> Bool)?

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(stagingDirectoryName, isDirectory: true),
        fileManager: FileManager = .default,
        directoryContentsForTesting: ((URL) -> [URL]?)? = nil,
        removeItemForTesting: ((URL) -> Bool)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.directoryContentsOverride = directoryContentsForTesting
        self.removeItemOverride = removeItemForTesting
    }

    static func canonicalDeliveryId(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue == rawValue.lowercased(),
              let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.lowercased() == rawValue else { return nil }
        return rawValue
    }

    func createDelivery() -> String? {
        guard ensureRootExists() else { return nil }
        for _ in 0..<3 {
            let deliveryId = UUID().uuidString.lowercased()
            guard let marker = markerURL(
                deliveryId: deliveryId,
                state: .pending
            ) else { continue }
            do {
                try Data().write(to: marker, options: .withoutOverwriting)
                guard isDirectRegularFile(marker) else {
                    _ = removeEntry(marker)
                    continue
                }
                return deliveryId
            } catch {
                continue
            }
        }
        return nil
    }

    func markerURL(
        deliveryId: String,
        state: NativePasteDeliveryMarkerState
    ) -> URL? {
        guard let deliveryId = Self.canonicalDeliveryId(deliveryId) else {
            return nil
        }
        return rootURL.appendingPathComponent(
            "\(Self.markerPrefix)\(deliveryId).\(state.rawValue)",
            isDirectory: false
        )
    }

    func stagingURL(
        deliveryId: String,
        fileExtension: String
    ) -> URL? {
        guard let deliveryId = Self.canonicalDeliveryId(deliveryId),
              Self.allowedExtensions.contains(fileExtension) else { return nil }
        let itemId = UUID().uuidString.lowercased()
        return rootURL.appendingPathComponent(
            "\(deliveryId)-\(itemId)-paste.\(fileExtension)",
            isDirectory: false
        )
    }

    func settle(deliveryId: String) -> NativePasteDeliverySettlement {
        guard let deliveryId = Self.canonicalDeliveryId(deliveryId),
              isDirectDirectory(rootURL),
              let pending = markerURL(deliveryId: deliveryId, state: .pending),
              let dartOwned = markerURL(deliveryId: deliveryId, state: .dartOwned),
              let reclaiming = markerURL(deliveryId: deliveryId, state: .reclaiming)
        else { return .preservedUnknown }

        // Marker types are read separately, so the opposing atomic rename can
        // momentarily produce a mixed observation. Retry a bounded number of
        // times; one source rename permanently stabilizes the state.
        for _ in 0..<3 {
            let pendingState = noFollowEntry(pending)
            let dartOwnedState = noFollowEntry(dartOwned)
            let reclaimingState = noFollowEntry(reclaiming)

            if pendingState == .missing,
               dartOwnedState == .regularFile,
               reclaimingState == .missing {
                _ = removeEntry(dartOwned)
                return .dartOwned
            }
            if pendingState == .missing,
               dartOwnedState == .missing,
               reclaimingState == .regularFile {
                return finishReclaiming(
                    deliveryId: deliveryId,
                    marker: reclaiming
                )
            }
            if pendingState == .regularFile,
               dartOwnedState == .missing,
               reclaimingState == .missing {
                _ = beginReclaiming(deliveryId: deliveryId)
                continue
            }
        }
        return .preservedUnknown
    }

    /// Starts native reclamation without deleting the marker. Staging timeout
    /// uses this durable intermediate state until its non-cancellable provider
    /// callback has drained, so a crash during a late copy remains recoverable.
    func beginReclaiming(deliveryId: String) -> Bool {
        guard let deliveryId = Self.canonicalDeliveryId(deliveryId),
              isDirectDirectory(rootURL),
              let pending = markerURL(deliveryId: deliveryId, state: .pending),
              let dartOwned = markerURL(deliveryId: deliveryId, state: .dartOwned),
              let reclaiming = markerURL(
                deliveryId: deliveryId,
                state: .reclaiming
              ) else { return false }

        if noFollowEntry(pending) == .missing,
           noFollowEntry(dartOwned) == .missing,
           noFollowEntry(reclaiming) == .regularFile {
            return true
        }
        guard noFollowEntry(pending) == .regularFile,
              noFollowEntry(dartOwned) == .missing,
              noFollowEntry(reclaiming) == .missing,
              exclusiveRename(from: pending, to: reclaiming) else {
            return false
        }
        return noFollowEntry(pending) == .missing &&
            noFollowEntry(dartOwned) == .missing &&
            noFollowEntry(reclaiming) == .regularFile
    }

    /// Reconciles only v2 markers. Legacy, unmarked, Dart-owned, malformed,
    /// linked, and nested entries are intentionally invisible to this sweep.
    @discardableResult
    func reconcileStartup() -> Bool {
        if noFollowEntry(rootURL) == .missing { return true }
        guard isDirectDirectory(rootURL),
              let children = directChildren() else { return false }

        var pendingIds = Set<String>()
        var reclaimingIds = Set<String>()
        for child in children where isDirectRegularFile(child) {
            if let id = deliveryId(
                fromMarkerName: child.lastPathComponent,
                state: .pending
            ) {
                pendingIds.insert(id)
            } else if let id = deliveryId(
                fromMarkerName: child.lastPathComponent,
                state: .reclaiming
            ) {
                reclaimingIds.insert(id)
            }
        }

        for deliveryId in reclaimingIds.sorted() {
            guard !hasDartOwnedMarker(deliveryId: deliveryId) else { continue }
            _ = settle(deliveryId: deliveryId)
            if hasNativeOwnedMarker(deliveryId: deliveryId) {
                return false
            }
        }
        for deliveryId in pendingIds.subtracting(reclaimingIds).sorted() {
            guard !hasDartOwnedMarker(deliveryId: deliveryId) else { continue }
            _ = settle(deliveryId: deliveryId)
            if hasNativeOwnedMarker(deliveryId: deliveryId) {
                return false
            }
        }
        return true
    }

    func removeStrictItems(
        deliveryId: String,
        items: [PlatformNativePasteImageItem]
    ) {
        guard let deliveryId = Self.canonicalDeliveryId(deliveryId),
              isDirectDirectory(rootURL) else { return }
        for item in items {
            let itemURL = URL(fileURLWithPath: item.filePath).standardizedFileURL
            guard isStrictItemURL(itemURL, deliveryId: deliveryId),
                  isDirectRegularFile(itemURL) else { continue }
            _ = removeEntry(itemURL)
        }
    }

    func isStrictItemURL(_ itemURL: URL, deliveryId: String) -> Bool {
        guard let deliveryId = Self.canonicalDeliveryId(deliveryId),
              itemURL.standardizedFileURL.deletingLastPathComponent() == rootURL,
              strictItemName(
                itemURL.lastPathComponent,
                deliveryId: deliveryId
              ) else { return false }
        return true
    }

    private func ensureRootExists() -> Bool {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            return isDirectDirectory(rootURL)
        } catch {
            return false
        }
    }

    private func hasDartOwnedMarker(deliveryId: String) -> Bool {
        guard let marker = markerURL(
            deliveryId: deliveryId,
            state: .dartOwned
        ) else { return false }
        return isDirectRegularFile(marker)
    }

    private func hasNativeOwnedMarker(deliveryId: String) -> Bool {
        let nativeStates: [NativePasteDeliveryMarkerState] = [
            .pending,
            .reclaiming,
        ]
        return nativeStates.contains { state in
            guard let marker = markerURL(
                deliveryId: deliveryId,
                state: state
            ) else { return false }
            return isDirectRegularFile(marker)
        }
    }

    private func deliveryId(
        fromMarkerName name: String,
        state: NativePasteDeliveryMarkerState
    ) -> String? {
        let suffix = ".\(state.rawValue)"
        guard name.hasPrefix(Self.markerPrefix), name.hasSuffix(suffix) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: Self.markerPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return Self.canonicalDeliveryId(String(name[start..<end]))
    }

    private func strictItemName(_ name: String, deliveryId: String) -> Bool {
        let prefix = "\(deliveryId)-"
        guard name.hasPrefix(prefix) else { return false }
        let remainder = String(name.dropFirst(prefix.count))
        for fileExtension in Self.allowedExtensions {
            let suffix = "-paste.\(fileExtension)"
            guard remainder.hasSuffix(suffix) else { continue }
            let itemId = String(remainder.dropLast(suffix.count))
            return Self.canonicalDeliveryId(itemId) != nil
        }
        return false
    }

    /// Returns true only once no direct regular item owned by this delivery
    /// remains. A failed deletion retains `.reclaiming` for the next startup
    /// pass instead of turning the item into an unmarked orphan.
    private func reclaimStrictDeliveryFiles(deliveryId: String) -> Bool {
        guard let children = directChildren() else { return false }
        var removedEveryOwnedEntry = true
        for child in children {
            guard isStrictItemURL(child, deliveryId: deliveryId),
                  isDirectRegularFile(child) else { continue }
            if !removeEntry(child) {
                removedEveryOwnedEntry = false
            }
        }
        guard removedEveryOwnedEntry,
              let remaining = directChildren() else { return false }
        return !remaining.contains { child in
            isStrictItemURL(child, deliveryId: deliveryId) &&
                isDirectRegularFile(child)
        }
    }

    private func finishReclaiming(
        deliveryId: String,
        marker: URL
    ) -> NativePasteDeliverySettlement {
        guard reclaimStrictDeliveryFiles(deliveryId: deliveryId),
              removeEntry(marker),
              noFollowEntry(marker) == .missing else {
            return .preservedUnknown
        }
        return .reclaimed
    }

    private func directChildren() -> [URL]? {
        if let directoryContentsOverride {
            return directoryContentsOverride(rootURL)
        }
        return try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
    }

    private func removeEntry(_ url: URL) -> Bool {
        if let removeItemOverride {
            return removeItemOverride(url)
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func isDirectRegularFile(_ url: URL) -> Bool {
        guard url.standardizedFileURL.deletingLastPathComponent() == rootURL
        else { return false }
        return noFollowEntry(url) == .regularFile
    }

    private func isDirectDirectory(_ url: URL) -> Bool {
        guard url.standardizedFileURL == rootURL else { return false }
        return noFollowEntry(url) == .directory
    }

    /// Returns the filesystem type of the path itself. `FileManager`'s
    /// attribute lookup can follow symbolic links, which would let a linked
    /// marker or item impersonate an owned regular file during reconciliation.
    private func noFollowEntry(_ url: URL) -> NativePasteNoFollowEntry {
        var metadata = stat()
        let result = url.path.withCString { path in
            lstat(path, &metadata)
        }
        guard result == 0 else {
            return errno == ENOENT ? .missing : .inaccessible
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

    private func exclusiveRename(from source: URL, to destination: URL) -> Bool {
        source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                ) == 0
            }
        }
    }
}

/// Serial startup gate shared by configuration and user-triggered delivery
/// creation. A failed sweep is never memoized, and no new pending marker is
/// admitted until a later retry proves reconciliation completed.
final class NativePasteStartupGate {
    private var didReconcile = false

    @discardableResult
    func reconcileIfNeeded(store: NativePasteDeliveryStore) -> Bool {
        if didReconcile { return true }
        guard store.reconcileStartup() else { return false }
        didReconcile = true
        return true
    }

    func createDeliveryAfterReconciliation(
        store: NativePasteDeliveryStore
    ) -> String? {
        guard reconcileIfNeeded(store: store) else { return nil }
        return store.createDelivery()
    }
}

/// Separates the UI acknowledgement deadline from marker-backed ownership.
final class NativePasteDeliveryOwnership {
    private let lock = NSLock()
    private let acknowledgement: NativePasteDeliveryCompletion
    private let deliveryId: String
    private let store: NativePasteDeliveryStore
    private let operationQueue: DispatchQueue
    private var ownershipResolved = false

    init(
        deliveryId: String,
        store: NativePasteDeliveryStore,
        operationQueue: DispatchQueue,
        acknowledgement: @escaping (Bool) -> Void
    ) {
        self.deliveryId = deliveryId
        self.store = store
        self.operationQueue = operationQueue
        self.acknowledgement = NativePasteDeliveryCompletion(
            completion: acknowledgement
        )
    }

    func acknowledgementTimedOut() {
        guard reserveOwnershipResolution() else { return }
        settleReservedOwnership(
            decision: .indeterminate,
            resolveAcknowledgement: true
        )
    }

    @discardableResult
    func resolveFromDart(decision: NativePasteDeliveryDecision) -> Bool {
        guard reserveOwnershipResolution() else { return false }
        settleReservedOwnership(
            decision: decision,
            resolveAcknowledgement: true
        )
        return decision == .accepted
    }

    @discardableResult
    private func reserveOwnershipResolution() -> Bool {
        lock.lock()
        let isFirstOwnershipResolution = !ownershipResolved
        if isFirstOwnershipResolution {
            ownershipResolved = true
        }
        lock.unlock()
        return isFirstOwnershipResolution
    }

    private func settleReservedOwnership(
        decision: NativePasteDeliveryDecision,
        resolveAcknowledgement: Bool
    ) {
        operationQueue.async { [acknowledgement, deliveryId, store] in
            let settlement = store.settle(deliveryId: deliveryId)
            let consumed: Bool
            if decision == .accepted {
                consumed = true
            } else {
                // A failed Dart callback after its claim could not roll the
                // marker back. The same filesystem evidence governs an
                // indeterminate timeout: successful reclamation permits the
                // ordinary Flutter paste path, while Dart-owned or unknown
                // marker states remain preservation-only/fail-closed.
                consumed = settlement != .reclaimed
            }
            if resolveAcknowledgement {
                acknowledgement.resolve(consumed)
            }
        }
    }

    @discardableResult
    func resolveFromDart(consumed: Bool) -> Bool {
        resolveFromDart(decision: consumed ? .accepted : .rejected)
    }
}

/// Coordinates the non-cancellable `NSItemProvider` staging callbacks.
///
/// A provider attempt is not an image slot: only a successfully staged item
/// consumes one. `timeout()` closes the coordinator exactly once, removes
/// everything accumulated so far, and makes every late callback remove its own
/// staged file instead of reviving the operation. Timeout ownership remains
/// durable until the one non-cancellable in-flight callback has drained.
final class NativePasteStagingCoordinator {
    typealias Stage = (
        _ providerIndex: Int,
        _ maxBytes: Int64,
        _ completion: @escaping (PlatformNativePasteImageItem?, Int64) -> Void
    ) -> Void

    private let lock = NSLock()
    private let providerCount: Int
    private let maxItemCount: Int
    private let maxItemBytes: Int64
    private let maxAggregateBytes: Int64
    private let removeItems: ([PlatformNativePasteImageItem]) -> Void
    private let onTimeoutStarted: () -> Void
    private let onTimeoutDrained: () -> Void
    private var completion: (([PlatformNativePasteImageItem], Bool) -> Void)?
    private var stage: Stage?
    private var nextProviderIndex = 0
    private var inFlightProviderIndex: Int?
    private var stagedItems: [PlatformNativePasteImageItem] = []
    private var stagedBytes: Int64 = 0
    private var finished = false
    private var timeoutTransitionCompleted = false
    private var timeoutDrainDelivered = false

    init(
        providerCount: Int,
        maxItemCount: Int,
        maxItemBytes: Int64,
        maxAggregateBytes: Int64,
        removeItems: @escaping ([PlatformNativePasteImageItem]) -> Void,
        onTimeoutStarted: @escaping () -> Void = {},
        onTimeoutDrained: @escaping () -> Void = {},
        completion: @escaping ([PlatformNativePasteImageItem], Bool) -> Void
    ) {
        self.providerCount = providerCount
        self.maxItemCount = maxItemCount
        self.maxItemBytes = maxItemBytes
        self.maxAggregateBytes = maxAggregateBytes
        self.removeItems = removeItems
        self.onTimeoutStarted = onTimeoutStarted
        self.onTimeoutDrained = onTimeoutDrained
        self.completion = completion
    }

    func start(stage: @escaping Stage) {
        lock.lock()
        guard !finished, self.stage == nil else {
            lock.unlock()
            return
        }
        self.stage = stage
        lock.unlock()
        advance()
    }

    func timeout() {
        let cleanup: [PlatformNativePasteImageItem]
        let callback: (([PlatformNativePasteImageItem], Bool) -> Void)?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        cleanup = stagedItems
        stagedItems.removeAll(keepingCapacity: false)
        stage = nil
        callback = completion
        completion = nil
        lock.unlock()

        // Persist `.reclaiming` before reporting timeout. If the process exits
        // while the provider later creates or copies its file, startup still
        // has an exact marker with which to reclaim it.
        onTimeoutStarted()
        removeItems(cleanup)
        callback?([], true)

        var shouldDeliverDrain = false
        lock.lock()
        timeoutTransitionCompleted = true
        if inFlightProviderIndex == nil, !timeoutDrainDelivered {
            timeoutDrainDelivered = true
            shouldDeliverDrain = true
        }
        lock.unlock()
        if shouldDeliverDrain { onTimeoutDrained() }
    }

    private func advance() {
        let request: (index: Int, maxBytes: Int64, stage: Stage)?
        let result: [PlatformNativePasteImageItem]?
        let callback: (([PlatformNativePasteImageItem], Bool) -> Void)?

        lock.lock()
        if finished {
            request = nil
            result = nil
            callback = nil
        } else if stagedItems.count >= maxItemCount ||
                    nextProviderIndex >= providerCount ||
                    stagedBytes >= maxAggregateBytes {
            finished = true
            result = stagedItems
            stagedItems.removeAll(keepingCapacity: false)
            request = nil
            callback = completion
            completion = nil
            stage = nil
        } else if let stage {
            let index = nextProviderIndex
            nextProviderIndex += 1
            inFlightProviderIndex = index
            request = (
                index,
                min(maxItemBytes, maxAggregateBytes - stagedBytes),
                stage
            )
            result = nil
            callback = nil
        } else {
            request = nil
            result = nil
            callback = nil
        }
        lock.unlock()

        if let result {
            callback?(result, false)
            return
        }
        guard let request else { return }
        request.stage(request.index, request.maxBytes) { item, byteCount in
            // Retain the coordinator until this non-cancellable provider
            // callback arrives so a post-timeout staged file is still removed.
            self.didStage(
                providerIndex: request.index,
                item: item,
                byteCount: byteCount
            )
        }
    }

    private func didStage(
        providerIndex: Int,
        item: PlatformNativePasteImageItem?,
        byteCount: Int64
    ) {
        var rejectedItems: [PlatformNativePasteImageItem] = []
        var shouldAdvance = false
        var shouldDeliverDrain = false

        lock.lock()
        if finished {
            if let item { rejectedItems.append(item) }
            if inFlightProviderIndex == providerIndex {
                inFlightProviderIndex = nil
            }
            if timeoutTransitionCompleted,
               inFlightProviderIndex == nil,
               !timeoutDrainDelivered {
                timeoutDrainDelivered = true
                shouldDeliverDrain = true
            }
            lock.unlock()
            removeItems(rejectedItems)
            if shouldDeliverDrain { onTimeoutDrained() }
            return
        }
        guard inFlightProviderIndex == providerIndex else {
            if let item { rejectedItems.append(item) }
            lock.unlock()
            removeItems(rejectedItems)
            return
        }
        inFlightProviderIndex = nil
        if let item,
           byteCount > 0,
           byteCount <= maxItemBytes,
           byteCount <= maxAggregateBytes - stagedBytes {
            stagedItems.append(item)
            stagedBytes += byteCount
        } else if let item {
            rejectedItems.append(item)
        }
        shouldAdvance = true
        lock.unlock()

        removeItems(rejectedItems)
        if shouldAdvance { advance() }
    }
}

/// Exposes native iOS paste events from Flutter's text input view to Dart.
final class NativePasteBridge: NativePasteHostApi {
    static let shared = NativePasteBridge()

    private static let maxImageCount = 4
    private static let maxImageBytes: Int64 = 20 * 1024 * 1024
    private static let maxAggregateBytes: Int64 = 60 * 1024 * 1024
    private static let stagingTimeout: TimeInterval = 5
    private static let acknowledgementTimeout: TimeInterval = 5

    private static let supportedTypes: [(
        type: UTType,
        mimeType: String,
        fileExtension: String
    )] = [
        (.gif, "image/gif", "gif"),
        (.png, "image/png", "png"),
        (.jpeg, "image/jpeg", "jpg"),
        (.webP, "image/webp", "webp"),
        (.tiff, "image/tiff", "tiff"),
        (.heic, "image/heic", "heic"),
        (.heif, "image/heif", "heif"),
        (.bmp, "image/bmp", "bmp"),
    ]

    private static var didSwizzle = false

    private let storageQueue = DispatchQueue(
        label: "app.cogwheel.conduit.native-paste-storage",
        qos: .utility
    )
    private let deliveryStore = NativePasteDeliveryStore()
    private let startupGate = NativePasteStartupGate()
    private var flutterApi: NativePasteFlutterApi?

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        flutterApi = NativePasteFlutterApi(binaryMessenger: messenger)
        NativePasteHostApiSetup.setUp(binaryMessenger: messenger, api: self)
        storageQueue.async { [weak self] in
            guard let self else { return }
            _ = startupGate.reconcileIfNeeded(store: deliveryStore)
        }
        Self.installSwizzlesIfNeeded()
    }

    func requestPaste(
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        handlePasteAction { consumed in
            completion(.success(consumed))
        }
    }

    private static func installSwizzlesIfNeeded() {
        guard !didSwizzle else { return }
        didSwizzle = true

        // Only swizzle the base class. FlutterSecureTextInputView inherits
        // from FlutterTextInputView, so the swizzle applies automatically.
        // Swizzling both causes infinite recursion: the subclass swizzle
        // sees the parent's already-swizzled Method, making the exchange
        // a no-op and leaving conduit_canPerformAction pointing at itself.
        guard let targetClass = NSClassFromString("FlutterTextInputView")
        else { return }
        swizzlePaste(for: targetClass)
        swizzleCanPerformAction(for: targetClass)
        swizzlePasteConfiguration(for: targetClass)
    }

    private static func swizzlePaste(for targetClass: AnyClass) {
        let originalSelector = #selector(UIResponder.paste(_:))
        let swizzledSelector = #selector(
            UIResponder.conduit_handlePaste(_:))

        guard
            let originalMethod = class_getInstanceMethod(
                targetClass,
                originalSelector
            ),
            let swizzledMethod = class_getInstanceMethod(
                UIResponder.self,
                swizzledSelector
            )
        else {
            return
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod,
           let newMethod = class_getInstanceMethod(targetClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, newMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    private static func swizzleCanPerformAction(for targetClass: AnyClass) {
        let originalSelector = #selector(
            UIResponder.canPerformAction(_:withSender:))
        let swizzledSelector = #selector(
            UIResponder.conduit_canPerformAction(_:withSender:))

        guard
            let originalMethod = class_getInstanceMethod(
                targetClass,
                originalSelector
            ),
            let swizzledMethod = class_getInstanceMethod(
                UIResponder.self,
                swizzledSelector
            )
        else {
            return
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod,
           let newMethod = class_getInstanceMethod(targetClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, newMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    private static func swizzlePasteConfiguration(for targetClass: AnyClass) {
        let originalSelector = #selector(getter: UIResponder.pasteConfiguration)
        let swizzledSelector = #selector(
            getter: UIResponder.conduit_pasteConfiguration
        )

        guard
            let originalMethod = class_getInstanceMethod(
                targetClass,
                originalSelector
            ),
            let swizzledMethod = class_getInstanceMethod(
                UIResponder.self,
                swizzledSelector
            )
        else {
            return
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod,
           let newMethod = class_getInstanceMethod(targetClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, newMethod)
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    fileprivate func handlePasteAction(
        completion: @escaping (Bool) -> Void
    ) {
        let deliveryCompletion = NativePasteDeliveryCompletion(
            completion: completion
        )
        let providers = UIPasteboard.general.itemProviders.filter { provider in
            Self.supportedTypes.contains { supportedType in
                provider.hasItemConformingToTypeIdentifier(
                    supportedType.type.identifier
                )
            }
        }
        guard !providers.isEmpty else {
            deliveryCompletion.resolve(false)
            return
        }

        storageQueue.async { [weak self] in
            guard let self else {
                deliveryCompletion.resolve(false)
                return
            }
            guard let deliveryId = startupGate
                .createDeliveryAfterReconciliation(store: deliveryStore) else {
                deliveryCompletion.resolve(false)
                return
            }
            let store = deliveryStore
            let operationQueue = storageQueue
            stageImageProviders(
                providers,
                deliveryId: deliveryId
            ) { [weak self] items, timedOut in
                guard !items.isEmpty else {
                    if timedOut {
                        // `.reclaiming` stays durable until the coordinator's
                        // non-cancellable provider callback drains.
                        deliveryCompletion.resolve(false)
                        return
                    }
                    operationQueue.async {
                        _ = store.settle(deliveryId: deliveryId)
                        deliveryCompletion.resolve(false)
                    }
                    return
                }
                let delivery = NativePasteDeliveryOwnership(
                    deliveryId: deliveryId,
                    store: store,
                    operationQueue: operationQueue,
                    acknowledgement: { consumed in
                        deliveryCompletion.resolve(consumed)
                    }
                )
                let payload = PlatformNativePastePayload(
                    kind: .images,
                    items: items,
                    deliveryId: deliveryId
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, let flutterApi = self.flutterApi else {
                        delivery.resolveFromDart(decision: .rejected)
                        return
                    }
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.acknowledgementTimeout
                    ) {
                        delivery.acknowledgementTimedOut()
                    }
                    flutterApi.onPaste(payload: payload) { result in
                        delivery.resolveFromDart(
                            decision: Self.pasteDeliveryDecision(result)
                        )
                    }
                }
            }
        }
    }

    static func pasteDeliveryDecision<Failure: Error>(
        _ result: Result<Bool, Failure>
    ) -> NativePasteDeliveryDecision {
        switch result {
        case .success(true):
            return .accepted
        case .success(false):
            return .rejected
        case .failure:
            return .indeterminate
        }
    }

    @discardableResult
    private func stageImageProviders(
        _ providers: [NSItemProvider],
        deliveryId: String,
        completion: @escaping ([PlatformNativePasteImageItem], Bool) -> Void
    ) -> NativePasteStagingCoordinator {
        let store = deliveryStore
        let operationQueue = storageQueue
        let coordinator = NativePasteStagingCoordinator(
            providerCount: providers.count,
            maxItemCount: Self.maxImageCount,
            maxItemBytes: Self.maxImageBytes,
            maxAggregateBytes: Self.maxAggregateBytes,
            removeItems: { items in
                store.removeStrictItems(
                    deliveryId: deliveryId,
                    items: items
                )
            },
            onTimeoutStarted: {
                operationQueue.sync {
                    _ = store.beginReclaiming(deliveryId: deliveryId)
                }
            },
            onTimeoutDrained: {
                operationQueue.async {
                    _ = store.settle(deliveryId: deliveryId)
                }
            },
            completion: completion
        )
        // `NSItemProvider` has no reliable cancellation primitive. Start this
        // bound before the first provider request; the coordinator owns both
        // accumulated and late files if the deadline wins.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.stagingTimeout
        ) {
            coordinator.timeout()
        }
        coordinator.start { [weak self] index, maxBytes, didStage in
            guard let self else {
                didStage(nil, 0)
                return
            }
            let provider = providers[index]
            guard let supportedType = Self.supportedTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.type.identifier)
            }) else {
                didStage(nil, 0)
                return
            }

            stageProvider(
                provider,
                type: supportedType.type,
                fileExtension: supportedType.fileExtension,
                deliveryId: deliveryId,
                maxBytes: maxBytes
            ) { stagedURL, byteCount in
                if let stagedURL, byteCount > 0 {
                    didStage(PlatformNativePasteImageItem(
                        mimeType: supportedType.mimeType,
                        filePath: stagedURL.path
                    ), byteCount)
                } else {
                    didStage(nil, 0)
                }
            }
        }
        return coordinator
    }

    private func stageProvider(
        _ provider: NSItemProvider,
        type: UTType,
        fileExtension: String,
        deliveryId: String,
        maxBytes: Int64,
        completion: @escaping (URL?, Int64) -> Void
    ) {
        let typeIdentifier = type.identifier
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
            [weak self] sourceURL, _ in
            guard let self else {
                completion(nil, 0)
                return
            }
            if let sourceURL {
                if let result = copyToStaging(
                    sourceURL: sourceURL,
                    fileExtension: fileExtension,
                    deliveryId: deliveryId,
                    maxBytes: maxBytes
                ) {
                    completion(result.url, result.byteCount)
                } else {
                    completion(nil, 0)
                }
                return
            }

            provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { sourceURL, _, _ in
                guard let sourceURL else {
                    completion(nil, 0)
                    return
                }
                let result = withCoordinatedNativePasteRead(
                    at: sourceURL,
                    { coordinatedURL in
                        self.copyToStaging(
                            sourceURL: coordinatedURL,
                            fileExtension: fileExtension,
                            deliveryId: deliveryId,
                            maxBytes: maxBytes
                        )
                    }
                )
                guard let result else {
                    completion(nil, 0)
                    return
                }
                completion(result.url, result.byteCount)
            }
        }
    }

    private func copyToStaging(
        sourceURL: URL,
        fileExtension: String,
        deliveryId: String,
        maxBytes: Int64
    ) -> (url: URL, byteCount: Int64)? {
        guard maxBytes > 0,
              let destination = deliveryStore.stagingURL(
                deliveryId: deliveryId,
                fileExtension: fileExtension
              ) else { return nil }
        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: Int64 = 0
            while true {
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                copied += Int64(chunk.count)
                guard copied <= maxBytes else {
                    try? FileManager.default.removeItem(at: destination)
                    return nil
                }
                try output.write(contentsOf: chunk)
            }
            guard copied > 0 else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            return (destination, copied)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

}

extension UIResponder {
    @objc func conduit_handlePaste(_ sender: Any?) {
        let pasteboardChangeCount = UIPasteboard.general.changeCount
        let editorContext = nativePasteEditorContext(for: self)
        NativePasteBridge.shared.handlePasteAction { [weak self] consumed in
            guard !consumed, let self else { return }
            let forwardToFlutter: () -> Void = { [weak self] in
                guard let self else { return }
                guard nativePasteFallbackContextMatches(
                    responderIsFirstResponder: self.isFirstResponder,
                    expectedPasteboardChangeCount: pasteboardChangeCount,
                    currentPasteboardChangeCount: UIPasteboard.general.changeCount,
                    expectedEditorContext: editorContext,
                    currentEditorContext: nativePasteEditorContext(for: self)
                ) else { return }
                self.conduit_handlePaste(sender)
            }
            if Thread.isMainThread {
                forwardToFlutter()
            } else {
                DispatchQueue.main.async(execute: forwardToFlutter)
            }
        }
    }

    @objc func conduit_canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        if action == #selector(UIResponder.paste(_:)), isFirstResponder {
            return true
        }

        return conduit_canPerformAction(action, withSender: sender)
    }

    @objc var conduit_pasteConfiguration: UIPasteConfiguration? {
        get {
            UIPasteConfiguration(acceptableTypeIdentifiers: [
                UTType.image.identifier,
                UTType.png.identifier,
                UTType.jpeg.identifier,
                UTType.gif.identifier,
                UTType.webP.identifier,
                UTType.tiff.identifier,
                UTType.heic.identifier,
                UTType.heif.identifier,
                UTType.bmp.identifier,
                UTType.text.identifier,
                UTType.plainText.identifier,
            ])
        }
        set {
            // Ignore setter; the swizzled getter defines accepted types.
        }
    }
}
