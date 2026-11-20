// Conduit's App Intents (Shortcuts, Siri, Spotlight) on the Mac.
//
// The intents live in the app's own process: crates/app/build.rs compiles
// this folder into a static library that the Rust binary links, and AppKit
// registers the process with the App Intents runtime at launch. Their work
// happens in the app (crates/app/src/intents.rs), which talks to conduitd:
// each `perform()` sends one JSON request over the C bridge below and waits
// for the one reply. Nothing here reaches the network or the disk.
//
// Shortcuts finds the intents through `Contents/Resources/Metadata.appintents`,
// which packaging/macos/intents.sh extracts from these sources at bundle
// time (Apple's `appintentsmetadataprocessor`), with the strings in each
// `<locale>.lproj/Localizable.strings` made from lib/l10n/desktop.
//
// Every user-visible string here is the English text of a desktop ARB key
// (`desktopIntent*`); intents.sh refuses a bundle whose strings and ARB
// keys disagree.

import AppIntents
import Foundation

/// One request to the app. Encoded as JSON; Rust reads it as
/// `intents::Request` (a tagged enum: `kind` names the case).
struct IntentRequest: Encodable, Sendable {
    var kind: String
    var prompt: String?
    var openInConduit: Bool?
    var id: String?
    var text: String?
    var ids: [String]?
    var query: String?
    var url: String?
    var path: String?
    var filename: String?
    var isImage: Bool?
    var byteCount: Int?

    static func ask(prompt: String, openInConduit: Bool) -> Self {
        Self(kind: "ask", prompt: prompt, openInConduit: openInConduit)
    }

    static func newChat(prompt: String?) -> Self {
        Self(kind: "newChat", prompt: prompt)
    }

    static func openChat(id: String) -> Self {
        Self(kind: "openChat", id: id)
    }

    static let startVoiceCall = Self(kind: "startVoiceCall")

    static func quickAsk(text: String?) -> Self {
        Self(kind: "quickAsk", text: text)
    }

    static func chats(ids: [String]? = nil, query: String? = nil) -> Self {
        Self(kind: "chats", ids: ids, query: query)
    }

    static func sendText(_ text: String?) -> Self {
        Self(kind: "sendText", text: text)
    }

    static func sendLink(_ url: String) -> Self {
        Self(kind: "sendLink", url: url)
    }

    /// `path`: the copy staged for the app ([ImageStaging]), nil when the
    /// file was not staged (not an image, or too large: the app says so).
    static func sendImage(path: String?, filename: String, isImage: Bool, byteCount: Int) -> Self {
        Self(
            kind: "sendImage", path: path, filename: filename, isImage: isImage,
            byteCount: byteCount)
    }
}

/// The app's reply. `error` is already in the user's language.
struct IntentReply: Decodable, Sendable {
    var ok: Bool
    var error: String?
    var value: String?
    var chats: [Chat]?

    struct Chat: Decodable, Sendable {
        var id: String
        var title: String
    }
}

/// What Shortcuts shows when an intent fails.
enum ConduitIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// The app's own words (already localized).
    case app(String)
    /// A reply the bridge could not read: a bug, said plainly.
    case unexpected

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .app(let message): "\(message)"
        case .unexpected: "Conduit couldn't do that. Try again."
        }
    }
}

/// Keeps the continuation alive while the app works; released by the reply.
private final class ReplyBox: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Never>

    init(_ continuation: CheckedContinuation<Data, Never>) {
        self.continuation = continuation
    }
}

private let replyThunk: ConduitIntentsReply = { context, response in
    guard let context else { return }
    let box = Unmanaged<ReplyBox>.fromOpaque(context).takeRetainedValue()
    let data = response.map { Data(bytes: $0, count: strlen($0)) } ?? Data()
    box.continuation.resume(returning: data)
}

enum ConduitApp {
    /// Sends `request` to the app and waits for its reply; a reply that
    /// says it failed throws its message.
    static func send(_ request: IntentRequest) async throws -> IntentReply {
        var json = try JSONEncoder().encode(request)
        json.append(0)
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let context = Unmanaged.passRetained(ReplyBox(continuation)).toOpaque()
            json.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: CChar.self)
                conduit_intents_request(bytes.baseAddress!, context, replyThunk)
            }
        }
        guard let reply = try? JSONDecoder().decode(IntentReply.self, from: data) else {
            throw ConduitIntentError.unexpected
        }
        guard reply.ok else {
            if let message = reply.error, !message.isEmpty {
                throw ConduitIntentError.app(message)
            }
            throw ConduitIntentError.unexpected
        }
        return reply
    }
}
