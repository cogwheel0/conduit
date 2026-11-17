import AppIntents
import Foundation

/// Ask Conduit: a question in, the answer back as text, for the next action
/// in a shortcut. The question becomes an ordinary chat (as Quick Ask's
/// do), so the answer is in Conduit too; "Open in Conduit" shows it there.
struct AskConduitIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Conduit"
    static let description = IntentDescription(
        "Asks Conduit a question and gives back the answer as text."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Question",
        requestValueDialog: IntentDialog("What would you like to ask?")
    )
    var prompt: String

    @Parameter(
        title: "Open in Conduit",
        description: "Shows the chat in Conduit once the answer is in.",
        default: false
    )
    var openInConduit: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Conduit \(\.$prompt)") {
            \.$openInConduit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let reply = try await ConduitApp.send(
            .ask(prompt: prompt, openInConduit: openInConduit)
        )
        return .result(value: reply.value ?? "")
    }
}

/// New Chat: Conduit comes forward on a new chat, with the text (if any) in
/// the message box, never sent: the user reads it first, as a
/// `conduit://new?q=` link does.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription(
        "Opens a new chat in Conduit with your text in the message box, ready to send."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Message")
    var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New chat with \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult {
        _ = try await ConduitApp.send(.newChat(prompt: prompt))
        return .result()
    }
}

/// Open Chat: one of the user's chats, chosen in Shortcuts from the list
/// Conduit offers ([ChatEntityQuery]).
struct OpenChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens one of your chats in Conduit.")
    static let openAppWhenRun = true

    @Parameter(title: "Chat", requestValueDialog: IntentDialog("Which chat?"))
    var target: ChatEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        _ = try await ConduitApp.send(.openChat(id: target.id))
        return .result()
    }
}

/// Start Voice Call: a voice call with Conduit in a new chat, as the
/// composer's call button starts one.
struct StartVoiceCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Call"
    static let description = IntentDescription(
        "Starts a voice call with Conduit in a new chat."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        _ = try await ConduitApp.send(.startVoiceCall)
        return .result()
    }
}

/// Show Quick Ask: the Quick Ask panel over whatever app is in front (it
/// floats; Conduit's own windows stay where they are), with the text (if
/// any) in its message box.
struct QuickAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Quick Ask"
    static let description = IntentDescription(
        "Opens Quick Ask over the app you're using, with your text in it if you give some."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Show Quick Ask with \(\.$text)")
    }

    func perform() async throws -> some IntentResult {
        _ = try await ConduitApp.send(.quickAsk(text: text))
        return .result()
    }
}

/// Send to Conduit: a new chat with the text in the message box, never
/// sent, as the phone's Send to Conduit does.
struct SendTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Conduit"
    static let description = IntentDescription(
        "Starts a new Conduit chat with the text you give it."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What should Conduit process?")
    )
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to Conduit")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let reply = try await ConduitApp.send(.sendText(text))
        return .result(value: reply.value ?? "")
    }
}

/// Send Link to Conduit: a new chat about a link, as the phone's: the
/// server reads the page (or a YouTube video's transcript), which is
/// attached as Web Page attaches it, with a request to summarize it in the
/// message box, never sent.
struct SendLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Link to Conduit"
    static let description = IntentDescription(
        "Sends a link into Conduit for a summary or an analysis."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "URL",
        requestValueDialog: IntentDialog("Which link should Conduit analyze?")
    )
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$url) to Conduit")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let reply = try await ConduitApp.send(.sendLink(url.absoluteString))
        return .result(value: reply.value ?? "")
    }
}

/// Send Image to Conduit: a new chat with the image attached, never sent,
/// as the phone's. Images only, up to 20 MB, as on the phone.
struct SendImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Image to Conduit"
    static let description = IntentDescription(
        "Sends an image into Conduit for analysis."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Image",
        requestValueDialog: IntentDialog("Choose an image for Conduit.")
    )
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$image) to Conduit")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let staged = try ImageStaging.stage(image)
        let reply = try await ConduitApp.send(
            .sendImage(
                path: staged.path, filename: staged.filename, isImage: staged.isImage,
                byteCount: staged.byteCount))
        return .result(value: reply.value ?? "")
    }
}
