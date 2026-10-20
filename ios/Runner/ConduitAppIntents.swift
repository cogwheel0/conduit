import AppIntents
import Foundation
import UniformTypeIdentifiers

@available(iOS 16.0, *)
enum AppIntentError: Error {
    case executionFailed(String)
}

@available(iOS 16.0, *)
struct AskConduitIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Conduit"
    static var description = IntentDescription(
        "Start a Conduit chat with an optional prompt."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Prompt",
        requestValueDialog: IntentDialog("What should Conduit answer?")
    )
    var prompt: String?

    init() {}

    init(prompt: String?) {
        self.prompt = prompt
    }

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let parameters: [String: Any] = prompt?.isEmpty == false
            ? ["prompt": prompt ?? ""]
            : [:]
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.ask_chat",
            parameters: parameters,
            canonicalParameters: ["prompt": prompt ?? ""]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.openingChat", "Opening chat")
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? appLocalized("appIntent.unableOpenChat", "Unable to open Conduit chat")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct StartVoiceCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Call"
    static var description = IntentDescription(
        "Start a live voice call with Conduit."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.start_voice_call",
            parameters: [:],
            canonicalParameters: [:]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.startingVoiceCall", "Starting voice call")
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? appLocalized("appIntent.unableStartVoiceCall", "Unable to start voice call")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct ConduitSendTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Conduit"
    static var description = IntentDescription(
        "Start a Conduit chat with provided text."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What should Conduit process?")
    )
    var text: String?

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_text",
            parameters: ["text": trimmed ?? ""],
            canonicalParameters: ["text": trimmed ?? ""]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.sentToConduit", "Sent to Conduit")
            return .result(value: value)
        }

        let message = result["error"] as? String ?? appLocalized("appIntent.unableSendText", "Unable to send text")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct ConduitSendUrlIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Link to Conduit"
    static var description = IntentDescription(
        "Send a URL into Conduit for summary or analysis."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "URL",
        requestValueDialog: IntentDialog("Which link should Conduit analyze?")
    )
    var url: URL

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_url",
            parameters: ["url": url.absoluteString],
            canonicalParameters: ["url": url.absoluteString]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.sentLinkToConduit", "Sent link to Conduit")
            return .result(value: value)
        }

        let message = result["error"] as? String ?? appLocalized("appIntent.unableSendLink", "Unable to send link")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct ConduitSendImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Image to Conduit"
    static var description = IntentDescription(
        "Send an image into Conduit for analysis."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Image",
        requestValueDialog: IntentDialog("Choose an image for Conduit.")
    )
    var image: IntentFile

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        // Some providers omit the declared type, so fall back to the file
        // extension. Anything that still does not resolve to an image is
        // rejected rather than staged and sent as an attachment.
        let type = image.type
            ?? UTType(filenameExtension: (image.filename as NSString).pathExtension)
        guard let type, type.conforms(to: .image) else {
            throw AppIntentError.executionFailed(
                appLocalized("appIntent.onlyImagesSupported", "Only image files are supported.")
            )
        }

        let name = image.filename
        let stagedImage: AppIntentStagedImage
        if let fileURL = image.fileURL {
            stagedImage = try await AppIntentBridge.stageImageArtifact(
                fileURL: fileURL,
                filename: name
            )
        } else {
            // Some providers expose only in-memory data. Keep this fallback,
            // but prefer file-backed streaming so the 20 MB limit is enforced
            // before materializing the full image in the app process.
            stagedImage = try await AppIntentBridge.stageImageArtifact(
                data: image.data,
                filename: name
            )
        }
        let filePath = stagedImage.filePath
        var dartMayOwnStagedImage = false
        defer {
            if !dartMayOwnStagedImage {
                AppIntentBridge.removeStagedImageIfOwned(atPath: filePath)
            }
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_image",
            parameters: [
                "filename": name,
                "filePath": filePath,
            ],
            canonicalParameters: [
                "filename": name,
                "contentDigest": stagedImage.contentDigest,
            ]
        )

        if let success = result["success"] as? Bool, success {
            // A retry stages a fresh copy but reuses the invocation ID. Dart
            // may return the cached result for the original path; transfer
            // only the exact path Dart reports owning so the duplicate copy
            // is reclaimed by this defer.
            dartMayOwnStagedImage =
                result[appIntentNativeOwnedFilePathKey] as? String == filePath
            let value = result["value"] as? String ?? appLocalized("appIntent.sentImageToConduit", "Sent image to Conduit")
            return .result(value: value)
        }

        // A timeout, cancellation, or transport failure after dispatch is an
        // indeterminate ownership boundary. Dart may already have persisted a
        // queue row for this exact path, so native cleanup must fail safe.
        if result[appIntentNativeDispatchStateKey] as? String ==
            appIntentNativeDispatchIndeterminate {
            dartMayOwnStagedImage = true
        }

        let message = result["error"] as? String ?? appLocalized("appIntent.unableSendImage", "Unable to send image")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: AskConduitIntent(),
                phrases: [
                    "Ask with \(.applicationName)",
                    "Start chat in \(.applicationName)",
                    "Open composer in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: StartVoiceCallIntent(),
                phrases: [
                    "Start voice call in \(.applicationName)",
                    "Call with \(.applicationName)",
                    "Begin voice chat in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: ConduitSendTextIntent(),
                phrases: [
                    "Send text to \(.applicationName)",
                    "Share text with \(.applicationName)",
                    "Summarize this in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: ConduitSendUrlIntent(),
                phrases: [
                    "Summarize link in \(.applicationName)",
                    "Analyze link with \(.applicationName)",
                    "Send URL to \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: ConduitSendImageIntent(),
                phrases: [
                    "Send image to \(.applicationName)",
                    "Analyze image with \(.applicationName)",
                    "Share photo to \(.applicationName)",
                ]
            ),
        ]
    }
}
