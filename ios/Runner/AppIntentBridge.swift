import CryptoKit
import Flutter
import Foundation

func appLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}

/// Manages the method channel for App Intent invocations to Flutter.
/// Native Swift intents call this to invoke Flutter-side business logic.
final class AppIntentReadiness {
    private let lock = NSLock()
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func update(_ value: Bool) {
        lock.lock()
        ready = value
        let readyWaiters: [CheckedContinuation<Bool, Never>]
        if value {
            readyWaiters = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
        } else {
            readyWaiters = []
        }
        lock.unlock()
        readyWaiters.forEach { $0.resume(returning: true) }
    }

    func currentValue() -> Bool {
        lock.lock()
        let value = ready
        lock.unlock()
        return value
    }

    func waitUntilReady(timeoutNanoseconds: UInt64) async -> Bool {
        if Task.isCancelled { return false }
        if currentValue() { return true }
        guard timeoutNanoseconds > 0 else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                return await self.waitForReadySignal()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return false
                }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func waitForReadySignal() async -> Bool {
        if Task.isCancelled { return false }
        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if ready {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                waiters[waiterId] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.resolveWaiter(waiterId, value: false)
        }
    }

    private func resolveWaiter(_ waiterId: UUID, value: Bool) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterId)
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

struct AppIntentStagedImage: Equatable {
    let filePath: String
    let contentDigest: String
}

final class AppIntentBridge: AppIntentHostApi, @unchecked Sendable {
    private static let sharedLock = NSLock()
    private static var storedShared: AppIntentBridge?
    private static let sharedReadiness = AppIntentReadiness()

    static var shared: AppIntentBridge? {
        get {
            sharedLock.lock()
            let bridge = storedShared
            sharedLock.unlock()
            return bridge
        }
        set {
            sharedLock.lock()
            storedShared = newValue
            let ready = newValue?.readiness.currentValue() ?? false
            sharedReadiness.update(ready)
            sharedLock.unlock()
        }
    }

    private static let imageByteLimit = 20 * 1024 * 1024
    private static let imageStagingDirectoryName = "conduit-app-intents"
    private static let invocationTimeout: TimeInterval = 10

    private let api: AppIntentFlutterApi
    private let readiness = AppIntentReadiness()

    init(messenger: FlutterBinaryMessenger) {
        api = AppIntentFlutterApi(binaryMessenger: messenger)
        AppIntentHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    }

    /// Replaces the shared bridge with one bound to `host`'s messenger.
    static func attach(to host: ConduitBridgeHost) {
        shared = AppIntentBridge(messenger: host.messenger)
    }

    func setReady(ready: Bool) throws {
        // Pigeon acknowledges this synchronous host call as soon as the
        // method returns. Apply readiness before returning so Dart never sees
        // a successful setReady(true) while native intents still see false.
        Self.sharedLock.lock()
        readiness.update(ready)
        if Self.storedShared === self {
            Self.sharedReadiness.update(ready)
        }
        Self.sharedLock.unlock()
    }

    /// Waits for both the Flutter engine and the Dart handler to be ready.
    /// App Intents can be asked to run while a cold launch is still between
    /// native plugin registration and the deferred Dart coordinator startup.
    static func readyBridge() async -> AppIntentBridge? {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            guard !Task.isCancelled else { return nil }
            if let bridge = readySharedBridge() {
                return bridge
            }
            let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingSeconds > 0 else { return nil }
            let remainingNanoseconds = UInt64(
                min(remainingSeconds * 1_000_000_000, Double(UInt64.max))
            )
            guard await sharedReadiness.waitUntilReady(
                timeoutNanoseconds: remainingNanoseconds
            ) else { return nil }
        }
    }

    private static func readySharedBridge() -> AppIntentBridge? {
        sharedLock.lock()
        let bridge = storedShared
        let ready = bridge?.readiness.currentValue() ?? false
        sharedLock.unlock()
        return ready ? bridge : nil
    }

    static func stageImage(data: Data, filename: String) async throws -> String {
        try await stageImageArtifact(data: data, filename: filename).filePath
    }

    static func stageImageArtifact(
        data: Data,
        filename: String
    ) async throws -> AppIntentStagedImage {
        guard !data.isEmpty, data.count <= imageByteLimit else {
            throw AppIntentError.executionFailed(
                appLocalized("appIntent.imageTooLarge", "Image is too large (20 MB maximum).")
            )
        }
        let stagingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let directory = try imageStagingDirectory()
            let fileExtension = safeImageFileExtension(filename)
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString)-intent.\(fileExtension)"
            )
            var completed = false
            defer {
                if !completed {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try data.write(to: destination, options: [.atomic])
            try Task.checkCancellation()
            completed = true
            return AppIntentStagedImage(
                filePath: destination.path,
                contentDigest: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        }
        return try await withTaskCancellationHandler {
            try await stagingTask.value
        } onCancel: {
            stagingTask.cancel()
        }
    }

    static func stageImage(fileURL: URL, filename: String) async throws -> String {
        try await stageImageArtifact(
            fileURL: fileURL,
            filename: filename
        ).filePath
    }

    static func stageImageArtifact(
        fileURL: URL,
        filename: String
    ) async throws -> AppIntentStagedImage {
        let stagingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let didAccessSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let values = try fileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            if let fileSize = values.fileSize,
               fileSize <= 0 || fileSize > imageByteLimit {
                throw AppIntentError.executionFailed(
                    appLocalized(
                        "appIntent.imageTooLarge",
                        "Image is too large (20 MB maximum)."
                    )
                )
            }

            let directory = try imageStagingDirectory()
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString)-intent.\(safeImageFileExtension(filename))"
            )
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            var completed = false
            defer {
                if !completed {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            let input = try FileHandle(forReadingFrom: fileURL)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            var totalBytes = 0
            var digest = SHA256()
            while let chunk = try input.read(upToCount: 64 * 1024),
                  !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= imageByteLimit - totalBytes else {
                    throw AppIntentError.executionFailed(
                        appLocalized(
                            "appIntent.imageTooLarge",
                            "Image is too large (20 MB maximum)."
                        )
                    )
                }
                try output.write(contentsOf: chunk)
                digest.update(data: chunk)
                totalBytes += chunk.count
            }
            try Task.checkCancellation()
            guard totalBytes > 0 else {
                throw AppIntentError.executionFailed(
                    appLocalized(
                        "appIntent.imageTooLarge",
                        "Image is too large (20 MB maximum)."
                    )
                )
            }
            completed = true
            return AppIntentStagedImage(
                filePath: destination.path,
                contentDigest: digest.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        }
        return try await withTaskCancellationHandler {
            try await stagingTask.value
        } onCancel: {
            stagingTask.cancel()
        }
    }

    static func removeStagedImageIfOwned(atPath filePath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(imageStagingDirectoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = URL(fileURLWithPath: filePath).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path,
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private static func imageStagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(imageStagingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directory.standardizedFileURL
    }

    private static func safeImageFileExtension(_ filename: String) -> String {
        let rawExtension = (filename as NSString).pathExtension.lowercased()
        let allowed = rawExtension.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed)).prefix(10)
        return sanitized.isEmpty ? "img" : String(sanitized)
    }

    /// Invokes a Flutter handler for the given intent identifier.
    func invokeIntent(
        identifier: String,
        parameters: [String: Any],
        canonicalParameters: [String: String]
    ) async -> [String: Any] {
        let invocationLease = AppIntentInvocationStore.shared.lease(
            identifier: identifier,
            canonicalParameters: canonicalParameters
        )
        let result: [String: Any]
        switch identifier {
        case "app.cogwheel.conduit.ask_chat":
            result = await invoke { bridge, completion in
                bridge.api.askChat(
                    invocationId: invocationLease.invocationId,
                    prompt: parameters["prompt"] as? String,
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.start_voice_call":
            result = await invoke { bridge, completion in
                bridge.api.startVoiceCall(
                    invocationId: invocationLease.invocationId,
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_text":
            result = await invoke { bridge, completion in
                bridge.api.sendText(
                    invocationId: invocationLease.invocationId,
                    text: parameters["text"] as? String ?? "",
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_url":
            result = await invoke { bridge, completion in
                bridge.api.sendUrl(
                    invocationId: invocationLease.invocationId,
                    url: parameters["url"] as? String ?? "",
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_image":
            guard let filePath = parameters["filePath"] as? String,
                  !filePath.isEmpty else {
                result = [
                    "success": false,
                    "error": "No staged image provided."
                ]
                break
            }
            let payload = PlatformAppIntentImagePayload(
                filename: parameters["filename"] as? String ?? "shared_image.jpg",
                filePath: filePath
            )
            result = await invoke { bridge, completion in
                bridge.api.sendImage(
                    invocationId: invocationLease.invocationId,
                    payload: payload,
                    completion: completion
                )
            }
        default:
            result = [
                "success": false,
                "error": "Unknown intent: \(identifier)"
            ]
        }
        AppIntentInvocationStore.shared.resolve(
            invocationLease,
            dispatchState: result[appIntentNativeDispatchStateKey] as? String
        )
        return result
    }

    private func invoke(
        _ call: @escaping (
            AppIntentBridge,
            @escaping (Result<PlatformAppIntentResponse, PigeonError>) -> Void
        ) -> Void
    ) async -> [String: Any] {
        let completion = AppIntentInvocationCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                guard !completion.isResolved else { return }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + Self.invocationTimeout
                ) {
                    completion.resolveInterrupted(
                        "App Intent timed out waiting for Conduit."
                    )
                }

                DispatchQueue.main.async {
                    // Reacquire at the dispatch boundary. The bridge returned
                    // by readyBridge() can be replaced (or deallocated)
                    // before this block reaches the main queue; the current
                    // ready bridge receives the same durable invocation.
                    guard let targetBridge = Self.readySharedBridge() else {
                        completion.resolveNotDispatched(
                            "App Intent bridge was replaced."
                        )
                        return
                    }
                    guard completion.beginDispatch() else { return }
                    call(targetBridge) { result in
                        switch result {
                        case .success(let response):
                            var payload: [String: Any] = [
                                "success": response.success,
                            ]
                            payload["value"] = response.value
                            payload["error"] = response.error
                            payload[appIntentNativeOwnedFilePathKey] =
                                response.ownedFilePath
                            completion.resolveCompleted(payload)
                        case .failure(let error):
                            // The message crossed the engine boundary, but a
                            // transport failure cannot prove whether Dart took
                            // ownership before its response was lost.
                            completion.resolveTransportFailure(
                                error.message ?? error.localizedDescription
                            )
                        }
                    }
                }
            }
        } onCancel: {
            completion.resolveInterrupted("App Intent was cancelled.")
        }
    }
}
