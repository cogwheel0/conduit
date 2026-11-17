// Apple's on-device Foundation Models for Conduit on the Mac: the window's
// half of `apple.*`.
//
// The chat runs in conduitd (the core's Direct engine and its Apple
// adapter); Foundation Models is a Swift API, so the model runs here, in the
// app. The daemon's `apple.command`s arrive as JSON through
// `conduit_apple_command` and every answer and event goes back as an
// `apple.report` JSON through the sink Rust installed
// (`src/shell/apple_models.rs`). This is the on-device half of the phone's
// `ios/Runner/PccBridge.swift`, with the same rules and limits.
//
// Private Cloud Compute is NOT here, by design: FoundationModels traps (a
// fatal error, not a throw) on the first request of a binary without the
// `com.apple.developer.private-cloud-compute` entitlement, and this build
// has none. Nothing in this file names `PrivateCloudComputeLanguageModel`.
//
// FoundationModels exists from macOS 26; the app runs from 14, so the
// framework is weak-linked (build.rs) and every use is behind
// `#available(macOS 26.0, *)`.
//
// Two SDKs build this file. macOS 27's SDK (Xcode 27; FoundationModels
// module version 2) adds what macOS 27 does: token usage on stream
// snapshots and macOS 27's error types, both also behind
// `#available(macOS 27.0, *)` at run time, and GenerationOptions'
// `samplingMode:` label (26's `sampling:` is deprecated there). The
// compiler must know a symbol even inside `#available`, so every use is
// also behind `#if canImport(FoundationModels, _version: 2.0)`. Built with
// macOS 26's SDK (Xcode 26), a reply reports no token usage and macOS 27's
// failures read as the generic one; packaging/macos/apple_models.sh says
// so at build time (`sdk-gaps`, which tests the same condition).

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The wire (conduit_protocol's AppleCommand and AppleReport)

private struct WireMessage: Decodable {
    let role: String
    let content: String?
}

private struct WireTool: Decodable {
    let name: String
    let description: String?
    let inputSchemaJson: String?
}

private struct WireGeneration: Decodable {
    let runId: String
    let model: String
    let messages: [WireMessage]?
    let tools: [WireTool]?
    let temperature: Double?
    let maximumResponseTokens: Int?
    let topP: Double?
    let topK: Int?
    let seed: Int?
    let greedySampling: Bool?
    let responseSchemaName: String?
    let responseSchemaJson: String?
}

private struct WireCommand: Decodable {
    let id: Int
    let kind: String
    let model: String?
    let request: WireGeneration?
    let runId: String?
    let callId: String?
    let toolContent: String?
    let toolCancelled: Bool?
}

private struct WireStatus: Encodable {
    var availability: String
    var reason: String?
    var contextSize: Int?
    var supportsCurrentLocale: Bool?
}

private struct WireReport: Encodable {
    var id: Int?
    var ok: Bool = true
    var error: String?
    var kind: String?
    var supported: Bool?
    var status: WireStatus?
    var runId: String?
    var content: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?
    var callId: String?
    var toolName: String?
    var argumentsJson: String?
    var failure: String?
    var reason: String?
}

/// Why a request was refused before it ran (`AppleFailure` on the wire).
private enum EngineError: Error {
    case invalidRequest
    case invalidSchema
    case invalidToolSchema
    case invalidStream

    var failure: String {
        switch self {
        case .invalidRequest: "invalidRequest"
        case .invalidSchema: "invalidSchema"
        case .invalidToolSchema: "invalidToolSchema"
        case .invalidStream: "invalidStream"
        }
    }
}

/// The text a snapshot added to the one before. A model that goes back on
/// what it wrote is refused, as on the phone.
func conduitAppleSnapshotDelta(previous: String, snapshot: String) -> String? {
    guard snapshot.hasPrefix(previous) else { return nil }
    return String(snapshot.dropFirst(previous.count))
}

// MARK: - The engine

public typealias ConduitAppleSink = @convention(c) (UnsafePointer<CChar>) -> Void

/// One run's task, and whether it was cancelled before it had one.
private final class RunBox: @unchecked Sendable {
    var task: Task<Void, Never>?
    var cancelled = false
}

/// The answer to one tool call, awaited by the model's tool.
private struct ToolAnswer: Sendable {
    let content: String
    let cancelled: Bool
}

private final class Engine: @unchecked Sendable {
    static let shared = Engine()

    private let lock = NSLock()
    private var sink: ConduitAppleSink?
    private var fake = false
    private var runs: [String: RunBox] = [:]
    private var tools: [String: CheckedContinuation<ToolAnswer, Never>] = [:]
    private var nextCall = 0

    func install(sink: ConduitAppleSink, fake: Bool) {
        lock.lock()
        self.sink = sink
        self.fake = fake
        lock.unlock()
    }

    var isFake: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fake
    }

    func send(_ report: WireReport) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink,
              let data = try? JSONEncoder().encode(report),
              let json = String(data: data, encoding: .utf8)
        else { return }
        json.withCString { sink($0) }
    }

    /// Whether this macOS has Apple's models at all.
    var supported: Bool {
        if isFake { return true }
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return true }
#endif
        return false
    }

    func handle(_ json: String) {
        guard let command = try? JSONDecoder().decode(
            WireCommand.self,
            from: Data(json.utf8)
        ) else {
            return
        }
        switch command.kind {
        case "status":
            guard command.model == nil || command.model == "onDevice" else {
                // Private Cloud Compute is never asked of this engine.
                send(WireReport(
                    id: command.id,
                    status: WireStatus(availability: "unsupported", reason: "notOffered")
                ))
                return
            }
            send(WireReport(id: command.id, status: status()))
        case "start":
            guard let request = command.request,
                  request.model == "onDevice",
                  !request.runId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  request.messages?.last?.role == "user",
                  !(request.messages?.last?.content ?? "")
                      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                send(WireReport(id: command.id, ok: false, error: "invalid request"))
                return
            }
            let box = RunBox()
            lock.lock()
            if runs[request.runId] != nil {
                lock.unlock()
                send(WireReport(id: command.id, ok: false, error: "run already running"))
                return
            }
            runs[request.runId] = box
            lock.unlock()
            send(WireReport(id: command.id))
            let task = Task.detached { [self] in
                await self.perform(request)
                self.finished(request.runId, box: box)
            }
            lock.lock()
            box.task = task
            let cancelled = box.cancelled
            lock.unlock()
            if cancelled { task.cancel() }
        case "cancel":
            lock.lock()
            let box = command.runId.flatMap { runs[$0] }
            box?.cancelled = true
            let task = box?.task
            lock.unlock()
            task?.cancel()
            send(WireReport(id: command.id))
        case "toolResult":
            let key = "\(command.runId ?? "")\u{1F}\(command.callId ?? "")"
            lock.lock()
            let waiting = tools.removeValue(forKey: key)
            lock.unlock()
            waiting?.resume(returning: ToolAnswer(
                content: command.toolContent ?? "",
                cancelled: command.toolCancelled ?? false
            ))
            send(WireReport(id: command.id))
        default:
            send(WireReport(id: command.id, ok: false, error: "unknown command"))
        }
    }

    private func finished(_ runId: String, box: RunBox) {
        lock.lock()
        if runs[runId] === box { runs.removeValue(forKey: runId) }
        lock.unlock()
    }

    /// Asks the daemon (the core's tool runtime) to run a tool, and waits for
    /// its answer. A cancelled run, or a cancelled answer, ends the loop.
    func callTool(runId: String, name: String, argumentsJson: String) async throws -> String {
        try Task.checkCancellation()
        let callId = lock.withLock {
            nextCall += 1
            return "call-\(nextCall)"
        }
        let key = "\(runId)\u{1F}\(callId)"
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ToolAnswer, Never>) in
                lock.withLock { tools[key] = continuation }
                // Cancelled before the continuation was there to resume.
                if Task.isCancelled {
                    let waiting = lock.withLock { tools.removeValue(forKey: key) }
                    waiting?.resume(returning: ToolAnswer(content: "", cancelled: true))
                    return
                }
                send(WireReport(
                    kind: "toolCall",
                    runId: runId,
                    callId: callId,
                    toolName: name,
                    argumentsJson: argumentsJson
                ))
            }
        } onCancel: {
            let waiting = lock.withLock { tools.removeValue(forKey: key) }
            waiting?.resume(returning: ToolAnswer(content: "", cancelled: true))
        }
        if answer.cancelled { throw CancellationError() }
        try Task.checkCancellation()
        return answer.content
    }

    // MARK: Status

    func status() -> WireStatus {
        if isFake {
            return WireStatus(
                availability: "available",
                contextSize: 4_096,
                supportsCurrentLocale: true
            )
        }
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            let reason: String?
            switch model.availability {
            case .available:
                reason = nil
            case .unavailable(.deviceNotEligible):
                reason = "deviceNotEligible"
            case .unavailable(.appleIntelligenceNotEnabled):
                reason = "appleIntelligenceNotEnabled"
            case .unavailable(.modelNotReady):
                reason = "modelNotReady"
            @unknown default:
                reason = "other"
            }
            return WireStatus(
                availability: model.isAvailable ? "available" : "unavailable",
                reason: reason,
                contextSize: Self.contextSize(of: model),
                supportsCurrentLocale: model.supportsLocale(Locale.current)
            )
        }
#endif
        return WireStatus(availability: "unsupported", reason: "systemTooOld")
    }

    /// The model's context window, or nil when unknown. `contextSize`
    /// first appears in the macOS 26.4 SDK (back-deployed to 26.0), so
    /// Xcode 26.0-26.3 (Swift 6.2, an SDK without the symbol) builds this
    /// as unknown: the compiler must know a symbol even inside
    /// `#available`, and Xcode 26.4 is the first with Swift 6.3.
#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func contextSize(of model: SystemLanguageModel) -> Int? {
#if compiler(>=6.3)
        let size = model.contextSize
        return size > 0 ? size : nil
#else
        return nil
#endif
    }
#endif

    // MARK: Runs

    private func perform(_ request: WireGeneration) async {
        let runId = request.runId
        if isFake {
            await performFake(request)
            return
        }
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            await performOnDevice(request)
            return
        }
#endif
        send(WireReport(kind: "failed", runId: runId, failure: "unavailable", reason: "systemTooOld"))
    }

    /// The scripted model of the dev-only E2E (`CONDUIT_APPLE_ENGINE=fake`):
    /// it answers word by word, so Stop has something to stop; "context
    /// limit" in the prompt fails as a full context does.
    private func performFake(_ request: WireGeneration) async {
        let runId = request.runId
        let prompt = request.messages?.last?.content ?? ""
        if prompt.localizedCaseInsensitiveContains("context limit") {
            send(WireReport(kind: "failed", runId: runId, failure: "contextExceeded"))
            return
        }
        var words = ["On", "this", "Mac,", "the", "answer", "is", "ready."]
        if prompt.localizedCaseInsensitiveContains("long") {
            words = Array(repeating: ["The", "tide", "turns", "slowly."], count: 60).flatMap { $0 }
        }
        let delay: UInt64 = prompt.localizedCaseInsensitiveContains("long") ? 120_000_000 : 40_000_000
        var written = 0
        do {
            for (index, word) in words.enumerated() {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                send(WireReport(
                    kind: "content",
                    runId: runId,
                    content: index == 0 ? word : " " + word
                ))
                written += 1
            }
            let input = prompt.split(separator: " ").count
            send(WireReport(
                kind: "usage",
                runId: runId,
                inputTokens: input,
                outputTokens: written,
                totalTokens: input + written
            ))
            send(WireReport(kind: "done", runId: runId))
        } catch {
            send(WireReport(kind: "done", runId: runId))
        }
    }
}

// MARK: - Apple's on-device model

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private struct OnDeviceInput {
    let transcript: Transcript
    let prompt: Prompt
    let options: GenerationOptions
    let schema: GenerationSchema?
}

@available(macOS 26.0, *)
private final class ConduitTool: Tool, @unchecked Sendable {
    init(name: String, description: String, parameters: GenerationSchema, runId: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.runId = runId
    }

    let name: String
    let description: String
    let parameters: GenerationSchema
    private let runId: String

    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        try await Engine.shared.callTool(
            runId: runId,
            name: name,
            argumentsJson: arguments.jsonString
        )
    }
}

@available(macOS 26.0, *)
private extension Engine {
    func performOnDevice(_ request: WireGeneration) async {
        let runId = request.runId
        do {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                send(WireReport(
                    kind: "failed",
                    runId: runId,
                    failure: "unavailable",
                    reason: status().reason ?? "other"
                ))
                return
            }
            let input = try onDeviceInput(request)
            let session = LanguageModelSession(
                model: model,
                tools: try nativeTools(request),
                transcript: input.transcript
            )
            if let schema = input.schema {
                let response = try await session.respond(
                    to: input.prompt,
                    schema: schema,
                    includeSchemaInPrompt: true,
                    options: input.options
                )
                try Task.checkCancellation()
                send(WireReport(kind: "content", runId: runId, content: response.content.jsonString))
            } else {
                var previous = ""
                var lastSnapshotUsage: WireReport?
                for try await snapshot in session.streamResponse(
                    to: input.prompt,
                    options: input.options
                ) {
                    try Task.checkCancellation()
                    let content = snapshot.content
                    guard let delta = conduitAppleSnapshotDelta(previous: previous, snapshot: content) else {
                        throw EngineError.invalidStream
                    }
                    previous = content
                    if !delta.isEmpty {
                        send(WireReport(kind: "content", runId: runId, content: delta))
                    }
                    if let usage = Self.usage(of: snapshot, runId: runId) {
                        lastSnapshotUsage = usage
                    }
                }
                if let usage = lastSnapshotUsage { send(usage) }
            }
            send(WireReport(kind: "done", runId: runId))
        } catch is CancellationError {
            send(WireReport(kind: "done", runId: runId))
        } catch let error as EngineError {
            send(WireReport(kind: "failed", runId: runId, failure: error.failure))
        } catch let error as LanguageModelSession.ToolCallError
            where error.underlyingError is CancellationError
        {
            // The core ended the tool loop (or the run): the run ends there.
            send(WireReport(kind: "done", runId: runId))
        } catch {
            send(WireReport(kind: "failed", runId: runId, failure: Self.failure(of: error)))
        }
    }

    /// The run's token usage so far, which macOS 27 reports on every
    /// snapshot. Nil on macOS 26, and in a build with macOS 26's SDK.
    static func usage(
        of snapshot: LanguageModelSession.ResponseStream<String>.Snapshot,
        runId: String
    ) -> WireReport? {
#if canImport(FoundationModels, _version: 2.0)
        if #available(macOS 27.0, *) {
            let usage = snapshot.usage
            return WireReport(
                kind: "usage",
                runId: runId,
                inputTokens: usage.input.totalTokenCount,
                outputTokens: usage.output.totalTokenCount,
                reasoningTokens: usage.output.reasoningTokenCount,
                totalTokens: usage.input.totalTokenCount + usage.output.totalTokenCount
            )
        }
#endif
        return nil
    }

    /// The failure Apple's error means, for macOS 27's errors and 26's.
    /// Built with macOS 26's SDK, only 26's are known; the rest read as the
    /// generic failure.
    static func failure(of error: Error) -> String {
#if canImport(FoundationModels, _version: 2.0)
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return "contextExceeded"
                case .rateLimited: return "busy"
                case .refusal: return "refusal"
                case .timeout: return "timedOut"
                case .guardrailViolation: return "guardrail"
                case .unsupportedCapability, .unsupportedTranscriptContent,
                     .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
                    return "unsupported"
                @unknown default: return "failed"
                }
            }
            if error is SystemLanguageModel.Error { return "notReady" }
            if error is LanguageModelSession.Error { return "busy" }
            if error is GeneratedContent.ParsingError { return "decoding" }
        }
#endif
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return "contextExceeded"
            case .assetsUnavailable: return "notReady"
            case .guardrailViolation: return "guardrail"
            case .unsupportedGuide, .unsupportedLanguageOrLocale: return "unsupported"
            case .decodingFailure: return "decoding"
            case .rateLimited, .concurrentRequests: return "busy"
            case .refusal: return "refusal"
            @unknown default: return "failed"
            }
        }
        return "failed"
    }

    func onDeviceInput(_ request: WireGeneration) throws -> OnDeviceInput {
        let messages = request.messages ?? []
        guard let final = messages.last,
              final.role == "user",
              let finalText = final.content,
              !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EngineError.invalidRequest
        }
        var instructions: [String] = []
        var entries: [Transcript.Entry] = []
        for message in messages.dropLast() {
            let content = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: content))
            switch message.role {
            case "system":
                instructions.append(content)
            case "user":
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case "assistant":
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            default:
                throw EngineError.invalidRequest
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
        let schema: GenerationSchema?
        switch (request.responseSchemaName, request.responseSchemaJson) {
        case (nil, nil):
            schema = nil
        case let (name?, json?):
            schema = try conduitAppleGenerationSchema(json: json, name: name)
        default:
            throw EngineError.invalidSchema
        }
        return OnDeviceInput(
            transcript: Transcript(entries: entries),
            prompt: Prompt(finalText),
            options: try generationOptions(request),
            schema: schema
        )
    }

    func generationOptions(_ request: WireGeneration) throws -> GenerationOptions {
        if let temperature = request.temperature, !(0 ... 1).contains(temperature) {
            throw EngineError.invalidRequest
        }
        guard request.maximumResponseTokens.map({ $0 > 0 && $0 <= 32_768 }) ?? true,
              request.topP.map({ $0 > 0 && $0 <= 1 }) ?? true,
              request.topK.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
              request.seed.map({ $0 >= 0 }) ?? true
        else {
            throw EngineError.invalidRequest
        }
        let modes = [request.greedySampling == true, request.topP != nil, request.topK != nil]
            .filter { $0 }.count
        guard modes <= 1 else { throw EngineError.invalidRequest }
        let seed = request.seed.map(UInt64.init)
        let sampling: GenerationOptions.SamplingMode?
        if request.greedySampling == true {
            sampling = .greedy
        } else if let topP = request.topP {
            sampling = .random(probabilityThreshold: topP, seed: seed)
        } else if let topK = request.topK {
            sampling = .random(top: topK, seed: seed)
        } else {
            sampling = nil
        }
        // The same initializer under its two names: macOS 27's SDK renamed
        // the label (and back-deploys the new name to macOS 26).
#if canImport(FoundationModels, _version: 2.0)
        return GenerationOptions(
            samplingMode: sampling,
            temperature: request.temperature,
            maximumResponseTokens: request.maximumResponseTokens
        )
#else
        return GenerationOptions(
            sampling: sampling,
            temperature: request.temperature,
            maximumResponseTokens: request.maximumResponseTokens
        )
#endif
    }

    func nativeTools(_ request: WireGeneration) throws -> [any Tool] {
        let definitions = request.tools ?? []
        guard definitions.count <= 128 else { throw EngineError.invalidToolSchema }
        var names: Set<String> = []
        var totalBytes = 0
        return try definitions.enumerated().compactMap { index, definition in
            let schemaJson = definition.inputSchemaJson ?? "{}"
            let description = definition.description ?? ""
            let schemaObject = try? JSONSerialization.jsonObject(
                with: Data(schemaJson.utf8)
            ) as? [String: Any]
            let isObjectSchema = schemaObject?["type"] as? String == "object" ||
                (schemaObject?["type"] == nil && schemaObject?["properties"] is [String: Any])
            totalBytes += definition.name.utf8.count + description.utf8.count + schemaJson.utf8.count
            guard definition.name.range(
                of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#,
                options: .regularExpression
            ) != nil,
                names.insert(definition.name).inserted,
                description.utf8.count <= 4_096,
                schemaJson.utf8.count <= 64 * 1_024,
                totalBytes <= 512 * 1_024
            else {
                throw EngineError.invalidToolSchema
            }
            // A tool the model cannot describe is left out, as on the phone.
            guard isObjectSchema,
                  let parameters = try? conduitAppleGenerationSchema(
                      json: schemaJson,
                      name: "McpToolArguments_\(index + 1)"
                  )
            else {
                return nil
            }
            return ConduitTool(
                name: definition.name,
                description: description,
                parameters: parameters,
                runId: request.runId
            )
        }
    }
}

/// A JSON Schema as Foundation Models' dynamic schema: the phone's subset
/// (objects, arrays, strings with enums, integers and numbers with bounds,
/// booleans), with its limits.
@available(macOS 26.0, *)
func conduitAppleGenerationSchema(json: String, name: String) throws -> GenerationSchema {
    guard json.utf8.count <= 64 * 1024,
          name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
          let rootObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else {
        throw EngineError.invalidSchema
    }

    var objectIndex = 0
    var propertyCount = 0
    func build(_ raw: [String: Any], depth: Int) throws -> DynamicGenerationSchema {
        guard depth <= 12 else { throw EngineError.invalidSchema }
        let type: String
        if let rawType = raw["type"] {
            guard let declared = rawType as? String else { throw EngineError.invalidSchema }
            type = declared
        } else if raw["properties"] is [String: Any] {
            type = "object"
        } else {
            throw EngineError.invalidSchema
        }
        func numericBounds() throws -> (minimum: NSNumber?, maximum: NSNumber?) {
            func number(_ key: String) throws -> NSNumber? {
                guard let value = raw[key] else { return nil }
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite
                else {
                    throw EngineError.invalidSchema
                }
                return number
            }
            let minimum = try number("minimum")
            let maximum = try number("maximum")
            if let minimum, let maximum, minimum.compare(maximum) == .orderedDescending {
                throw EngineError.invalidSchema
            }
            return (minimum, maximum)
        }
        switch type {
        case "object":
            guard let rawProperties = raw["properties"] as? [String: Any],
                  rawProperties.count <= 128
            else {
                throw EngineError.invalidSchema
            }
            propertyCount += rawProperties.count
            guard propertyCount <= 256 else { throw EngineError.invalidSchema }
            let required: Set<String>
            if let rawRequired = raw["required"] {
                guard let names = rawRequired as? [String], Set(names).count == names.count else {
                    throw EngineError.invalidSchema
                }
                required = Set(names)
            } else {
                required = []
            }
            guard required.isSubset(of: Set(rawProperties.keys)) else {
                throw EngineError.invalidSchema
            }
            objectIndex += 1
            let objectName = objectIndex == 1 ? name : "\(name)_\(objectIndex)"
            let properties = try rawProperties.keys.sorted().map { propertyName in
                guard propertyName.utf8.count <= 128,
                      let property = rawProperties[propertyName] as? [String: Any]
                else {
                    throw EngineError.invalidSchema
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
            guard let items = raw["items"] as? [String: Any] else { throw EngineError.invalidSchema }
            func count(_ key: String) throws -> Int? {
                guard let value = raw[key] else { return nil }
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let integer = value as? Int,
                      integer >= 0
                else {
                    throw EngineError.invalidSchema
                }
                return integer
            }
            let minimum = try count("minItems")
            let maximum = try count("maxItems")
            if let minimum, let maximum, maximum < minimum { throw EngineError.invalidSchema }
            return DynamicGenerationSchema(
                arrayOf: try build(items, depth: depth + 1),
                minimumElements: minimum,
                maximumElements: maximum
            )
        case "string":
            if let rawEnum = raw["enum"] {
                guard let values = rawEnum as? [String], !values.isEmpty else {
                    throw EngineError.invalidSchema
                }
                return DynamicGenerationSchema(type: String.self, guides: [.anyOf(values)])
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            let bounds = try numericBounds()
            var guides: [GenerationGuide<Int>] = []
            if let minimum = bounds.minimum {
                guard let value = minimum as? Int else { throw EngineError.invalidSchema }
                guides.append(.minimum(value))
            }
            if let maximum = bounds.maximum {
                guard let value = maximum as? Int else { throw EngineError.invalidSchema }
                guides.append(.maximum(value))
            }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case "number":
            let bounds = try numericBounds()
            var guides: [GenerationGuide<Double>] = []
            if let minimum = bounds.minimum { guides.append(.minimum(minimum.doubleValue)) }
            if let maximum = bounds.maximum { guides.append(.maximum(maximum.doubleValue)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            throw EngineError.invalidSchema
        }
    }

    return try GenerationSchema(root: build(rootObject, depth: 0), dependencies: [])
}
#endif

// MARK: - The C interface (src/shell/apple_models.rs)

/// Installs where reports go (a C function taking one JSON string), and
/// whether the scripted dev model stands in for Apple's.
@_cdecl("conduit_apple_install")
public func conduit_apple_install(_ sink: ConduitAppleSink, _ fake: Bool) {
    Engine.shared.install(sink: sink, fake: fake)
}

/// Whether this macOS has Apple's models (26 or later), or the fake stands
/// in.
@_cdecl("conduit_apple_supported")
public func conduit_apple_supported() -> Bool {
    Engine.shared.supported
}

/// Runs one `apple.command` (its JSON). Answers and events come back
/// through the installed sink, from any thread.
@_cdecl("conduit_apple_command")
public func conduit_apple_command(_ json: UnsafePointer<CChar>) {
    Engine.shared.handle(String(cString: json))
}
