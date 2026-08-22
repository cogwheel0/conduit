import Flutter
import Foundation
import ImageIO

#if canImport(FoundationModels)
import FoundationModels
#endif

enum PccSnapshotDeltaError: Error {
    case nonPrefixSnapshot
}

func pccSnapshotDelta(previous: String, snapshot: String) throws -> String {
    guard snapshot.hasPrefix(previous) else {
        throw PccSnapshotDeltaError.nonPrefixSnapshot
    }
    return String(snapshot.dropFirst(previous.count))
}

private let pccMaxImageDimension = 8_192
private let pccMaxDecodedImageBytes = 64 * 1_024 * 1_024

func pccDecodedImageBytes(
    width: Int,
    height: Int,
    currentBytes: Int
) -> Int? {
    guard width > 0,
          height > 0,
          width <= pccMaxImageDimension,
          height <= pccMaxImageDimension,
          height <= (pccMaxDecodedImageBytes - currentBytes) / 4 / width
    else {
        return nil
    }
    return currentBytes + width * height * 4
}

func pccDecodedImageBytes(
    bytesPerRow: Int,
    height: Int,
    currentBytes: Int
) -> Int? {
    guard bytesPerRow > 0,
          height > 0,
          currentBytes >= 0,
          currentBytes <= pccMaxDecodedImageBytes,
          height <= (pccMaxDecodedImageBytes - currentBytes) / bytesPerRow
    else {
        return nil
    }
    return currentBytes + bytesPerRow * height
}

func pccImageMetadataIsSafe(depth: Int, colorModel: String) -> Bool {
    guard depth > 0, depth <= 8 else { return false }
    return colorModel == kCGImagePropertyColorModelRGB as String ||
        colorModel == kCGImagePropertyColorModelGray as String
}

private enum PccBridgeError: LocalizedError {
    case invalidRequest
    case invalidImage
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Apple Foundation Models request is invalid."
        case .invalidImage:
            "Apple Foundation Models received an invalid image."
        case .invalidSchema:
            "Apple Foundation Models received an unsupported response schema."
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
func pccGenerationOptions(
    _ request: PlatformPccCompletionRequest
) throws -> GenerationOptions {
    if let temperature = request.temperature,
       !(0 ... 1).contains(temperature)
    {
        throw PccBridgeError.invalidRequest
    }
    guard request.maximumResponseTokens.map({ $0 > 0 && $0 <= 32_768 }) ?? true,
          request.topP.map({ $0 > 0 && $0 <= 1 }) ?? true,
          request.topK.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
          request.seed.map({ $0 >= 0 }) ?? true
    else {
        throw PccBridgeError.invalidRequest
    }
    let selectedModes = [
        request.greedySampling == true,
        request.topP != nil,
        request.topK != nil,
    ].filter { $0 }.count
    guard selectedModes <= 1 else { throw PccBridgeError.invalidRequest }

    let seed = request.seed.map(UInt64.init)
    let samplingMode: GenerationOptions.SamplingMode?
    if request.greedySampling == true {
        samplingMode = .greedy
    } else if let topP = request.topP {
        samplingMode = .random(probabilityThreshold: topP, seed: seed)
    } else if let topK = request.topK {
        samplingMode = .random(top: Int(topK), seed: seed)
    } else {
        samplingMode = nil
    }
#if CONDUIT_PCC_SDK
    return GenerationOptions(
        samplingMode: samplingMode,
        temperature: request.temperature,
        maximumResponseTokens: request.maximumResponseTokens.map(Int.init)
    )
#else
    return GenerationOptions(
        sampling: samplingMode,
        temperature: request.temperature,
        maximumResponseTokens: request.maximumResponseTokens.map(Int.init)
    )
#endif
}

@available(iOS 26.0, *)
func pccGenerationSchema(json: String, name: String) throws -> GenerationSchema {
    guard json.utf8.count <= 64 * 1024,
          name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#,
                     options: .regularExpression) != nil,
          let rootObject = try JSONSerialization.jsonObject(
              with: Data(json.utf8)
          ) as? [String: Any]
    else {
        throw PccBridgeError.invalidSchema
    }

    var objectIndex = 0
    var propertyCount = 0
    func build(_ raw: [String: Any], depth: Int) throws -> DynamicGenerationSchema {
        guard depth <= 12 else { throw PccBridgeError.invalidSchema }
        let type: String
        if let rawType = raw["type"] {
            guard let declaredType = rawType as? String else {
                throw PccBridgeError.invalidSchema
            }
            type = declaredType
        } else if raw["properties"] is [String: Any] {
            type = "object"
        } else {
            throw PccBridgeError.invalidSchema
        }
        switch type {
        case "object":
            guard let rawProperties = raw["properties"] as? [String: Any],
                  rawProperties.count <= 128
            else {
                throw PccBridgeError.invalidSchema
            }
            propertyCount += rawProperties.count
            guard propertyCount <= 256 else { throw PccBridgeError.invalidSchema }
            let required: Set<String>
            if let rawRequired = raw["required"] {
                guard let names = rawRequired as? [String],
                      Set(names).count == names.count
                else {
                    throw PccBridgeError.invalidSchema
                }
                required = Set(names)
            } else {
                required = []
            }
            guard required.isSubset(of: Set(rawProperties.keys)) else {
                throw PccBridgeError.invalidSchema
            }
            objectIndex += 1
            let objectName = objectIndex == 1 ? name : "\(name)_\(objectIndex)"
            let properties = try rawProperties.keys.sorted().map { propertyName in
                guard propertyName.utf8.count <= 128,
                      let property = rawProperties[propertyName] as? [String: Any]
                else {
                    throw PccBridgeError.invalidSchema
                }
                return DynamicGenerationSchema.Property(
                    name: propertyName,
                    description: property["description"] as? String,
                    schema: try build(property, depth: depth + 1),
                    isOptional: !required.contains(propertyName)
                )
            }
            return DynamicGenerationSchema(
                name: objectName,
                description: raw["description"] as? String,
                properties: properties
            )
        case "array":
            guard let items = raw["items"] as? [String: Any] else {
                throw PccBridgeError.invalidSchema
            }
            return DynamicGenerationSchema(
                arrayOf: try build(items, depth: depth + 1),
                minimumElements: raw["minItems"] as? Int,
                maximumElements: raw["maxItems"] as? Int
            )
        case "string":
            if let rawEnum = raw["enum"] {
                guard let values = rawEnum as? [String], !values.isEmpty else {
                    throw PccBridgeError.invalidSchema
                }
                return DynamicGenerationSchema(
                    type: String.self,
                    guides: [.anyOf(values)]
                )
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            guard raw["minimum"] == nil, raw["maximum"] == nil else {
                throw PccBridgeError.invalidSchema
            }
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            guard raw["minimum"] == nil, raw["maximum"] == nil else {
                throw PccBridgeError.invalidSchema
            }
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "null":
            throw PccBridgeError.invalidSchema
        default:
            throw PccBridgeError.invalidSchema
        }
    }

    return try GenerationSchema(root: build(rootObject, depth: 0), dependencies: [])
}
#endif

private final class PccTaskBox {
    var task: Task<Void, Never>?
    var cancelled = false
}

private final class PccResponseState {
    var emittedContent = false
}

final class PccBridge: PccHostApi {
    static let shared = PccBridge()

    private let lock = NSLock()
    private var tasks: [String: PccTaskBox] = [:]
    private var flutterApi: PccFlutterApi?

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        flutterApi = PccFlutterApi(binaryMessenger: messenger)
        PccHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    }

    func getStatus(
        model: PlatformAppleModel,
        completion: @escaping (Result<PlatformPccStatus, Error>) -> Void
    ) {
        Task {
            if model == .onDevice {
#if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    completion(.success(onDeviceStatus()))
                    return
                }
#endif
                completion(.success(Self.onDeviceUnsupportedStatus))
                return
            }
#if CONDUIT_PCC_SDK
            if #available(iOS 27.0, *) {
                completion(.success(await liveStatus()))
                return
            }
#endif
            completion(.success(Self.pccUnsupportedStatus))
        }
    }

    func showQuotaIncreaseSuggestion(
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        Task {
#if CONDUIT_PCC_SDK
            if #available(iOS 27.0, *) {
                guard let suggestion = PrivateCloudComputeLanguageModel()
                    .quotaUsage.limitIncreaseSuggestion
                else {
                    completion(.success(false))
                    return
                }
                await MainActor.run { suggestion.show() }
                completion(.success(true))
                return
            }
#endif
            completion(.success(false))
        }
    }

    func start(request: PlatformPccCompletionRequest) throws {
        guard !request.runId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.messages.last?.role == "user",
              request.messages.last.map({
                  !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      !$0.images.isEmpty
              }) == true
        else {
            throw PccBridgeError.invalidRequest
        }

        let box = PccTaskBox()
        lock.lock()
        guard tasks[request.runId] == nil else {
            lock.unlock()
            throw PccBridgeError.invalidRequest
        }
        tasks[request.runId] = box
        lock.unlock()

        let task = Task { [weak self, box] in
            guard let self else { return }
            await self.perform(request, box: box)
        }
        lock.lock()
        box.task = task
        let wasCancelled = box.cancelled
        lock.unlock()
        if wasCancelled {
            task.cancel()
        }
    }

    func cancel(runId: String) throws {
        lock.lock()
        let box = tasks[runId]
        box?.cancelled = true
        let task = box?.task
        lock.unlock()
        task?.cancel()
    }

    private func perform(_ request: PlatformPccCompletionRequest, box: PccTaskBox) async {
        defer { removeTask(request.runId, box: box) }
        if request.model == .onDevice {
#if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                await performOnDeviceRequest(request)
                return
            }
#endif
            await emitError(
                runId: request.runId,
                message: "Apple On-Device requires iOS 26 and an Apple Intelligence device."
            )
            return
        }
#if CONDUIT_PCC_SDK
        if #available(iOS 27.0, *) {
            await performAvailableRequest(request)
            return
        }
#endif
        await emitError(
            runId: request.runId,
            message: "Apple Private Cloud Compute requires iOS 27 and an eligible device."
        )
    }

    private func removeTask(_ runId: String, box: PccTaskBox) {
        lock.lock()
        if tasks[runId] === box {
            tasks.removeValue(forKey: runId)
        }
        lock.unlock()
    }

    private func emit(_ event: PlatformPccStreamEvent) async {
        await MainActor.run { [weak self] in
            self?.flutterApi?.onEvent(event: event) { _ in }
        }
    }

    private func emitError(runId: String, message: String) async {
        await emit(PlatformPccStreamEvent(
            runId: runId,
            kind: .error,
            content: message
        ))
    }

    private static let pccUnsupportedStatus = PlatformPccStatus(
        availability: .unsupported,
        quotaStatus: .unknown,
        quotaLimitReached: false,
        canIncreaseQuota: false,
        message: "Apple Private Cloud Compute requires iOS 27 and an eligible device."
    )

    private static let onDeviceUnsupportedStatus = PlatformPccStatus(
        availability: .unsupported,
        quotaStatus: .unknown,
        quotaLimitReached: false,
        canIncreaseQuota: false,
        message: "Apple On-Device requires iOS 26 and an Apple Intelligence device."
    )
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private struct OnDeviceSessionInput {
    let transcript: Transcript
    let prompt: Prompt
    let generationOptions: GenerationOptions
    let responseSchema: GenerationSchema?
}

@available(iOS 26.0, *)
private extension PccBridge {
    func onDeviceStatus() -> PlatformPccStatus {
        let model = SystemLanguageModel.default
        let message: String?
        switch model.availability {
        case .available:
            message = nil
        case .unavailable(.deviceNotEligible):
            message = "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            message = "Turn on Apple Intelligence to use Apple On-Device."
        case .unavailable(.modelNotReady):
            message = "The Apple on-device model is still downloading or not ready."
        @unknown default:
            message = "Apple On-Device is unavailable."
        }
        return PlatformPccStatus(
            availability: model.isAvailable ? .available : .unavailable,
            quotaStatus: .unknown,
            quotaLimitReached: false,
            canIncreaseQuota: false,
            message: message,
            contextSize: Int64(model.contextSize),
            supportsCurrentLocale: model.supportsLocale(Locale.current)
        )
    }

    func performOnDeviceRequest(_ request: PlatformPccCompletionRequest) async {
        do {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                await emitError(
                    runId: request.runId,
                    message: onDeviceStatus().message ?? "Apple On-Device is unavailable."
                )
                return
            }
            let input = try onDeviceSessionInput(request)
            let session = LanguageModelSession(
                model: model,
                tools: [],
                transcript: input.transcript
            )
            try await performOnDevice(
                session: session,
                input: input,
                runId: request.runId
            )
            await emit(PlatformPccStreamEvent(runId: request.runId, kind: .done))
        } catch is CancellationError {
            await emit(PlatformPccStreamEvent(runId: request.runId, kind: .done))
        } catch PccSnapshotDeltaError.nonPrefixSnapshot {
            await emitError(
                runId: request.runId,
                message: "Apple On-Device returned an invalid response stream."
            )
        } catch {
#if CONDUIT_PCC_SDK
            if let error = error as? LanguageModelError {
                await emitError(runId: request.runId, message: onDeviceMessage(for: error))
                return
            }
#else
            if let error = error as? LanguageModelSession.GenerationError {
                await emitError(runId: request.runId, message: onDeviceMessage(for: error))
                return
            }
#endif
            if let error = error as? PccBridgeError {
                await emitError(runId: request.runId, message: error.localizedDescription)
                return
            }
            await emitError(runId: request.runId, message: "Apple On-Device request failed.")
        }
    }

    func performOnDevice(
        session: LanguageModelSession,
        input: OnDeviceSessionInput,
        runId: String
    ) async throws {
        if let schema = input.responseSchema {
            let response = try await session.respond(
                to: input.prompt,
                schema: schema,
                includeSchemaInPrompt: true,
                options: input.generationOptions
            )
            try Task.checkCancellation()
            await emit(PlatformPccStreamEvent(
                runId: runId,
                kind: .content,
                content: response.content.jsonString
            ))
            return
        }

        var previous = ""
        for try await snapshot in session.streamResponse(
            to: input.prompt,
            options: input.generationOptions
        ) {
            try Task.checkCancellation()
            let content = snapshot.content
            let delta = try pccSnapshotDelta(previous: previous, snapshot: content)
            previous = content
            if !delta.isEmpty {
                await emit(PlatformPccStreamEvent(
                    runId: runId,
                    kind: .content,
                    content: delta
                ))
            }
        }
    }

    func onDeviceSessionInput(
        _ request: PlatformPccCompletionRequest
    ) throws -> OnDeviceSessionInput {
        guard request.reasoningLevel == nil,
              request.messages.allSatisfy({ $0.images.isEmpty }),
              let final = request.messages.last,
              final.role == "user",
              !final.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PccBridgeError.invalidRequest
        }

        var instructions: [String] = []
        var entries: [Transcript.Entry] = []
        for message in request.messages.dropLast() {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: content))
            switch message.role {
            case "system":
                instructions.append(content)
            case "user":
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case "assistant":
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [segment]
                )))
            default:
                throw PccBridgeError.invalidRequest
            }
        }
        if !instructions.isEmpty {
            let segment = Transcript.Segment.text(
                Transcript.TextSegment(content: instructions.joined(separator: "\n\n"))
            )
            entries.insert(.instructions(Transcript.Instructions(
                segments: [segment],
                toolDefinitions: []
            )), at: 0)
        }

        let responseSchema: GenerationSchema?
        switch (request.responseSchemaName, request.responseSchemaJson) {
        case (nil, nil):
            responseSchema = nil
        case let (name?, json?):
            responseSchema = try pccGenerationSchema(json: json, name: name)
        default:
            throw PccBridgeError.invalidSchema
        }
        return OnDeviceSessionInput(
            transcript: Transcript(entries: entries),
            prompt: Prompt(final.content),
            generationOptions: try pccGenerationOptions(request),
            responseSchema: responseSchema
        )
    }

#if !CONDUIT_PCC_SDK
    func onDeviceMessage(
        for error: LanguageModelSession.GenerationError
    ) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "This conversation exceeds the Apple On-Device context limit."
        case .assetsUnavailable:
            return "The Apple on-device model is not ready."
        case .guardrailViolation:
            return "Apple On-Device blocked this request for safety reasons."
        case .unsupportedGuide, .unsupportedLanguageOrLocale:
            return "Apple On-Device cannot process this request."
        case .decodingFailure:
            return "Apple On-Device returned an invalid response."
        case .rateLimited, .concurrentRequests:
            return "Apple On-Device is busy. Retry shortly."
        case .refusal:
            return "Apple On-Device declined this request."
        @unknown default:
            return "Apple On-Device request failed."
        }
    }
#endif
}
#endif

#if CONDUIT_PCC_SDK
@available(iOS 27.0, *)
private struct PccSessionInput {
    let transcript: Transcript
    let prompt: Prompt
    let contextOptions: ContextOptions
    let generationOptions: GenerationOptions
    let responseSchema: GenerationSchema?
}

@available(iOS 27.0, *)
private extension PccBridge {
    func liveStatus() async -> PlatformPccStatus {
        let model = PrivateCloudComputeLanguageModel()
        let reset = model.quotaUsage.resetDate.map {
            Int64($0.timeIntervalSince1970 * 1_000)
        }
        let quotaStatus: PlatformPccQuotaStatus = switch model.quotaUsage.status {
        case .belowLimit(let info):
            info.isApproachingLimit ? .approachingLimit : .belowLimit
        case .limitReached:
            .limitReached
        @unknown default:
            .unknown
        }
        let contextSize = try? await model.contextSize
        let supportsCurrentLocale = try? await model.supportsLocale(Locale.current)
        let canIncreaseQuota = model.quotaUsage.limitIncreaseSuggestion != nil
        switch model.availability {
        case .available:
            let limitReached = model.quotaUsage.isLimitReached
            return PlatformPccStatus(
                availability: .available,
                quotaStatus: quotaStatus,
                quotaLimitReached: limitReached,
                canIncreaseQuota: canIncreaseQuota,
                message: limitReached
                    ? "The Apple Private Cloud Compute daily usage limit has been reached."
                    : nil,
                quotaResetAtMilliseconds: reset,
                contextSize: contextSize.map(Int64.init),
                supportsCurrentLocale: supportsCurrentLocale
            )
        case .unavailable(.deviceNotEligible):
            return PlatformPccStatus(
                availability: .unavailable,
                quotaStatus: quotaStatus,
                quotaLimitReached: false,
                canIncreaseQuota: canIncreaseQuota,
                message: "This device is not eligible for Apple Private Cloud Compute."
            )
        case .unavailable(.systemNotReady):
            return PlatformPccStatus(
                availability: .unavailable,
                quotaStatus: quotaStatus,
                quotaLimitReached: false,
                canIncreaseQuota: canIncreaseQuota,
                message: "Apple Private Cloud Compute is not ready on this device."
            )
        @unknown default:
            return PlatformPccStatus(
                availability: .unavailable,
                quotaStatus: quotaStatus,
                quotaLimitReached: false,
                canIncreaseQuota: canIncreaseQuota,
                message: "Apple Private Cloud Compute is unavailable."
            )
        }
    }

    func performAvailableRequest(_ request: PlatformPccCompletionRequest) async {
        let responseState = PccResponseState()
        do {
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                let status = await liveStatus()
                await emitError(
                    runId: request.runId,
                    message: status.message ?? "Apple Private Cloud Compute is unavailable."
                )
                return
            }
            guard !model.quotaUsage.isLimitReached else {
                await emitError(
                    runId: request.runId,
                    message: "The Apple Private Cloud Compute daily usage limit has been reached."
                )
                return
            }

            let input = try sessionInput(request)
            let session = LanguageModelSession(
                model: model,
                tools: [],
                transcript: input.transcript
            )
            try await perform(
                session: session,
                input: input,
                runId: request.runId,
                responseState: responseState
            )
            await emit(PlatformPccStreamEvent(runId: request.runId, kind: .done))
        } catch is CancellationError {
            await emit(PlatformPccStreamEvent(runId: request.runId, kind: .done))
        } catch PccSnapshotDeltaError.nonPrefixSnapshot {
            await emitError(
                runId: request.runId,
                message: "Apple Private Cloud Compute returned an invalid response stream."
            )
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            if case .networkFailure = error,
               !responseState.emittedContent,
               request.allowOnDeviceFallback,
               request.reasoningLevel == nil || request.reasoningLevel == "automatic",
               request.messages.allSatisfy({ $0.images.isEmpty })
            {
                var fallbackRequest = request
                fallbackRequest.reasoningLevel = nil
                await performOnDeviceFallback(fallbackRequest)
            } else {
                await emitError(runId: request.runId, message: message(for: error))
            }
        } catch let error as LanguageModelError {
            await emitError(runId: request.runId, message: message(for: error))
        } catch let error as PccBridgeError {
            await emitError(runId: request.runId, message: error.localizedDescription)
        } catch {
            await emitError(
                runId: request.runId,
                message: "Apple Private Cloud Compute request failed."
            )
        }
    }

    func performOnDeviceFallback(_ request: PlatformPccCompletionRequest) async {
        do {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                await emitError(
                    runId: request.runId,
                    message: "Apple Private Cloud Compute is offline and the on-device model is unavailable."
                )
                return
            }
            let input = try onDeviceSessionInput(request)
            let session = LanguageModelSession(
                model: model,
                tools: [],
                transcript: input.transcript
            )
            await emit(PlatformPccStreamEvent(
                runId: request.runId,
                kind: .fallback,
                content: "on_device"
            ))
            try await performOnDevice(
                session: session,
                input: input,
                runId: request.runId
            )
            await emit(PlatformPccStreamEvent(runId: request.runId, kind: .done))
        } catch is CancellationError {
            await emit(PlatformPccStreamEvent(runId: request.runId, kind: .done))
        } catch let error as LanguageModelError {
            await emitError(runId: request.runId, message: onDeviceMessage(for: error))
        } catch let error as PccBridgeError {
            await emitError(runId: request.runId, message: error.localizedDescription)
        } catch {
            await emitError(
                runId: request.runId,
                message: "Apple Private Cloud Compute is offline and the on-device fallback failed."
            )
        }
    }

    func perform(
        session: LanguageModelSession,
        input: PccSessionInput,
        runId: String,
        responseState: PccResponseState
    ) async throws {
        if let schema = input.responseSchema {
            let response = try await session.respond(
                to: input.prompt,
                schema: schema,
                options: input.generationOptions,
                contextOptions: input.contextOptions
            )
            try Task.checkCancellation()
            responseState.emittedContent = true
            await emit(PlatformPccStreamEvent(
                runId: runId,
                kind: .content,
                content: response.content.jsonString
            ))
            await emitUsage(response.usage, runId: runId)
            return
        }

        var previous = ""
        for try await snapshot in session.streamResponse(
            to: input.prompt,
            options: input.generationOptions,
            contextOptions: input.contextOptions
        ) {
            try Task.checkCancellation()
            let content = snapshot.content
            let delta = try pccSnapshotDelta(previous: previous, snapshot: content)
            previous = content
            if !delta.isEmpty {
                responseState.emittedContent = true
                await emit(PlatformPccStreamEvent(
                    runId: runId,
                    kind: .content,
                    content: delta
                ))
            }
            await emitUsage(snapshot.usage, runId: runId)
        }
    }

    func emitUsage(_ usage: LanguageModelSession.Usage, runId: String) async {
        await emit(PlatformPccStreamEvent(
            runId: runId,
            kind: .usage,
            inputTokenCount: Int64(usage.input.totalTokenCount),
            outputTokenCount: Int64(usage.output.totalTokenCount),
            reasoningTokenCount: Int64(usage.output.reasoningTokenCount),
            totalTokenCount: Int64(usage.totalTokenCount)
        ))
    }

    func sessionInput(
        _ request: PlatformPccCompletionRequest
    ) throws -> PccSessionInput {
        guard let final = request.messages.last,
              final.role == "user",
              (!final.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                  !final.images.isEmpty)
        else {
            throw PccBridgeError.invalidRequest
        }

        var imageCount = 0
        var imageBytes = 0
        var decodedImageBytes = 0
        func decodedImages(_ message: PlatformPccMessage) throws -> [CGImage] {
            imageCount += message.images.count
            imageBytes += message.images.reduce(0) { $0 + $1.bytes.data.count }
            guard imageCount <= 4, imageBytes <= 20 * 1024 * 1024 else {
                throw PccBridgeError.invalidImage
            }
            return try message.images.map { image in
                guard image.mimeType.lowercased().hasPrefix("image/"),
                      !image.bytes.data.isEmpty,
                      let source = CGImageSourceCreateWithData(
                          image.bytes.data as CFData,
                          nil
                      ),
                      let properties = CGImageSourceCopyPropertiesAtIndex(
                          source,
                          0,
                          nil
                      ) as NSDictionary?,
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue,
                      let colorModel = properties[kCGImagePropertyColorModel] as? String,
                      pccImageMetadataIsSafe(depth: depth, colorModel: colorModel),
                      pccDecodedImageBytes(
                          width: width,
                          height: height,
                          currentBytes: decodedImageBytes
                      ) != nil,
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      cgImage.width == width,
                      cgImage.height == height,
                      let nextDecodedBytes = pccDecodedImageBytes(
                          bytesPerRow: cgImage.bytesPerRow,
                          height: cgImage.height,
                          currentBytes: decodedImageBytes
                      )
                else {
                    throw PccBridgeError.invalidImage
                }
                decodedImageBytes = nextDecodedBytes
                return cgImage
            }
        }

        func segments(
            for message: PlatformPccMessage,
            labelPrefix: String
        ) throws -> [Transcript.Segment] {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            var segments: [Transcript.Segment] = []
            if !content.isEmpty {
                segments.append(.text(Transcript.TextSegment(content: content)))
            }
            for (index, image) in try decodedImages(message).enumerated() {
                let attachment = Transcript.AttachmentSegment(
                    content: .image(Transcript.ImageAttachment(image)),
                    label: "\(labelPrefix)-\(index)"
                )
                segments.append(.attachment(attachment))
            }
            return segments
        }

        var instructions: [String] = []
        var entries: [Transcript.Entry] = []
        for (index, message) in request.messages.dropLast().enumerated() {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case "system":
                guard message.images.isEmpty else { throw PccBridgeError.invalidRequest }
                if content.isEmpty { continue }
                instructions.append(content)
            case "user":
                let value = try segments(for: message, labelPrefix: "history-\(index)")
                if !value.isEmpty {
                    entries.append(.prompt(Transcript.Prompt(segments: value)))
                }
            case "assistant":
                guard message.images.isEmpty else { throw PccBridgeError.invalidRequest }
                if content.isEmpty { continue }
                let segment = Transcript.Segment.text(Transcript.TextSegment(content: content))
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [segment]
                )))
            default:
                throw PccBridgeError.invalidRequest
            }
        }
        if !instructions.isEmpty {
            let segment = Transcript.Segment.text(
                Transcript.TextSegment(content: instructions.joined(separator: "\n\n"))
            )
            entries.insert(.instructions(Transcript.Instructions(
                segments: [segment],
                toolDefinitions: []
            )), at: 0)
        }

        let finalImages = try decodedImages(final)
        let finalContent = final.content
        let prompt = Prompt {
            if !finalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalContent
            }
            for (index, image) in finalImages.enumerated() {
                Attachment(image).label("prompt-\(index)")
            }
        }
        let responseSchema: GenerationSchema?
        switch (request.responseSchemaName, request.responseSchemaJson) {
        case (nil, nil):
            responseSchema = nil
        case let (name?, json?):
            responseSchema = try pccGenerationSchema(json: json, name: name)
        default:
            throw PccBridgeError.invalidSchema
        }

        return PccSessionInput(
            transcript: Transcript(entries: entries),
            prompt: prompt,
            contextOptions: try contextOptions(
                request.reasoningLevel,
                includeSchema: responseSchema != nil
            ),
            generationOptions: try pccGenerationOptions(request),
            responseSchema: responseSchema
        )
    }

    func contextOptions(
        _ reasoningLevel: String?,
        includeSchema: Bool
    ) throws -> ContextOptions {
        let reasoning: ContextOptions.ReasoningLevel? = switch reasoningLevel {
        case nil, "automatic": nil
        case "light": .light
        case "moderate": .moderate
        case "deep": .deep
        default: throw PccBridgeError.invalidRequest
        }
        return ContextOptions(
            includeSchemaInPrompt: includeSchema ? true : nil,
            reasoningLevel: reasoning
        )
    }

    func message(for error: PrivateCloudComputeLanguageModel.Error) -> String {
        switch error {
        case .quotaLimitReached:
            return "The Apple Private Cloud Compute daily usage limit has been reached."
        case .networkFailure:
            return "Apple Private Cloud Compute could not be reached. Check your connection and retry."
        case .serviceUnavailable:
            return "Apple Private Cloud Compute is temporarily unavailable."
        @unknown default:
            return "Apple Private Cloud Compute request failed."
        }
    }

    func message(for error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded:
            return "This conversation exceeds the Apple Private Cloud Compute context limit."
        case .rateLimited:
            return "Apple Private Cloud Compute is receiving too many requests. Retry shortly."
        case .refusal:
            return "Apple Private Cloud Compute declined this request."
        case .timeout:
            return "Apple Private Cloud Compute timed out."
        case .guardrailViolation:
            return "Apple Private Cloud Compute blocked this request for safety reasons."
        case .unsupportedCapability, .unsupportedTranscriptContent,
             .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            return "Apple Private Cloud Compute cannot process this request."
        @unknown default:
            return "Apple Private Cloud Compute request failed."
        }
    }

    func onDeviceMessage(for error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded:
            return "This conversation exceeds the Apple On-Device context limit."
        case .rateLimited:
            return "Apple On-Device is busy. Retry shortly."
        case .refusal:
            return "Apple On-Device declined this request."
        case .timeout:
            return "Apple On-Device timed out."
        case .guardrailViolation:
            return "Apple On-Device blocked this request for safety reasons."
        case .unsupportedCapability, .unsupportedTranscriptContent,
             .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            return "Apple On-Device cannot process this request."
        @unknown default:
            return "Apple On-Device request failed."
        }
    }
}
#endif
