import AppIntents
import Foundation
import UniformTypeIdentifiers

// `--e2e intents` (crates/app/src/e2e/intents.rs) and the smoke pass: the
// intents' own `perform()` and queries, run in this process as the App
// Intents runtime runs them, without Shortcuts (which can't be driven from a
// test). Also checks that every type `Metadata.appintents` names is in this
// binary, which is what the runtime looks them up by.

/// One step of a self-test script.
private struct Step: Decodable {
    var intent: String
    var prompt: String?
    var openInConduit: Bool?
    var id: String?
    var title: String?
    var text: String?
    var ids: [String]?
    var query: String?
    var url: String?
    /// `sendImage`: a file to hand the intent, and how it says what it is
    /// (`inMemory`: as a provider that gives data, not a file, does).
    var path: String?
    var filename: String?
    var type: String?
    var inMemory: Bool?
}

private struct Script: Decodable {
    var steps: [Step]
}

/// What one step did.
private struct Outcome: Encodable {
    var intent: String
    var ok: Bool
    var value: String?
    var error: String?
    var chats: [ChatOut]?
    /// For `types`: how many names the bundle's metadata has, and which of
    /// them this binary lacks.
    var named: Int?
    var missing: [String]?

    struct ChatOut: Encodable {
        var id: String
        var title: String
    }
}

private func message(of error: Error) -> String {
    if let error = error as? ConduitIntentError {
        return String(localized: error.localizedStringResource)
    }
    return String(describing: error)
}

/// The mangled type names the bundle's metadata refers to (actions,
/// entities, queries and the App Shortcuts provider); nil without metadata
/// (a bare binary, `cargo test`).
private func metadataTypeNames() -> [String]? {
    guard
        let url = Bundle.main.url(
            forResource: "extract",
            withExtension: "actionsdata",
            subdirectory: "Metadata.appintents"
        ),
        let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    var names: [String] = []
    for key in ["actions", "entities", "queries"] {
        for case let item as [String: Any] in (json[key] as? [String: Any])?.values ?? [:].values {
            if let name = item["mangledTypeName"] as? String { names.append(name) }
        }
    }
    if let provider = json["autoShortcutProviderMangledName"] as? String {
        names.append(provider)
    }
    return names.sorted()
}

private func run(_ step: Step) async -> Outcome {
    var outcome = Outcome(intent: step.intent, ok: true)
    do {
        switch step.intent {
        case "ask":
            // `@Parameter` values are set through the wrapper, not the struct.
            let intent = AskConduitIntent()
            intent.prompt = step.prompt ?? ""
            intent.openInConduit = step.openInConduit ?? false
            outcome.value = try await intent.perform().value
        case "newChat":
            // `@Parameter` values are set through the wrapper, not the struct.
            let intent = NewChatIntent()
            intent.prompt = step.prompt
            _ = try await intent.perform()
        case "openChat":
            // `@Parameter` values are set through the wrapper, not the struct.
            let intent = OpenChatIntent()
            intent.target = ChatEntity(id: step.id ?? "", title: step.title ?? "")
            _ = try await intent.perform()
        case "startVoiceCall":
            _ = try await StartVoiceCallIntent().perform()
        case "quickAsk":
            // `@Parameter` values are set through the wrapper, not the struct.
            let intent = QuickAskIntent()
            intent.text = step.text
            _ = try await intent.perform()
        case "sendText":
            // `@Parameter` values are set through the wrapper, not the struct.
            let intent = SendTextIntent()
            intent.text = step.text
            outcome.value = try await intent.perform().value
        case "sendLink":
            let intent = SendLinkIntent()
            guard let url = URL(string: step.url ?? "") else {
                outcome.ok = false
                outcome.error = "no URL in the step"
                break
            }
            intent.url = url
            outcome.value = try await intent.perform().value
        case "sendImage":
            let intent = SendImageIntent()
            let fileURL = URL(fileURLWithPath: step.path ?? "")
            let type = step.type.flatMap { UTType($0) }
            if step.inMemory ?? false {
                let data = (try? Data(contentsOf: fileURL)) ?? Data()
                intent.image = IntentFile(
                    data: data, filename: step.filename ?? fileURL.lastPathComponent, type: type)
            } else {
                intent.image = IntentFile(
                    fileURL: fileURL, filename: step.filename ?? fileURL.lastPathComponent,
                    type: type)
            }
            outcome.value = try await intent.perform().value
        case "suggested", "search", "byId":
            let query = ChatEntityQuery()
            let chats: [ChatEntity]
            switch step.intent {
            case "search": chats = try await query.entities(matching: step.query ?? "")
            case "byId": chats = try await query.entities(for: step.ids ?? [])
            default: chats = try await query.suggestedEntities()
            }
            outcome.chats = chats.map { .init(id: $0.id, title: $0.title) }
        case "types":
            guard let names = metadataTypeNames() else {
                outcome.ok = false
                outcome.error = "no Metadata.appintents in this bundle"
                break
            }
            outcome.named = names.count
            outcome.missing = names.filter { _typeByName($0) == nil }
        default:
            outcome.ok = false
            outcome.error = "unknown step \(step.intent)"
        }
    } catch {
        outcome.ok = false
        outcome.error = message(of: error)
    }
    return outcome
}

/// Runs a JSON script (`{"steps": [...]}`) and calls `done` once with a
/// JSON array of outcomes, from another thread. Steps run one at a time.
@_cdecl("conduit_intents_selftest")
public func conduitIntentsSelftest(
    _ script: UnsafePointer<CChar>,
    _ context: UnsafeMutableRawPointer?,
    _ done: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
) {
    let data = Data(bytes: script, count: strlen(script))
    let reply = SelfTestReply(context: context, done: done)
    Task.detached {
        var outcomes: [Outcome] = []
        if let script = try? JSONDecoder().decode(Script.self, from: data) {
            for step in script.steps {
                outcomes.append(await run(step))
            }
        } else {
            outcomes.append(Outcome(intent: "script", ok: false, error: "unreadable script"))
        }
        reply.send((try? JSONEncoder().encode(outcomes)) ?? Data("[]".utf8))
    }
}

/// `done` and its context, carried to the task that calls it once. The app
/// keeps the context alive until then.
private struct SelfTestReply: @unchecked Sendable {
    let context: UnsafeMutableRawPointer?
    let done: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

    func send(_ json: Data) {
        var json = json
        json.append(0)
        json.withUnsafeBytes { raw in
            done(context, raw.bindMemory(to: CChar.self).baseAddress)
        }
    }
}
