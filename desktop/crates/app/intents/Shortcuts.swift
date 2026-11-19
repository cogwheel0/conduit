import AppIntents

/// The App Shortcuts: in Shortcuts, Spotlight and Siri with no setup. Each
/// phrase names the app once (`.applicationName`, the bundle's display
/// name); the phrases' translations are in each locale's
/// AppShortcuts.strings (packaging/macos/intents.sh).
struct ConduitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskConduitIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask Conduit",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat",
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open a chat in \(.applicationName)",
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: StartVoiceCallIntent(),
            phrases: [
                "Start a voice call in \(.applicationName)",
                "Call \(.applicationName)",
            ],
            shortTitle: "Start Voice Call",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SendTextIntent(),
            phrases: [
                "Send text to \(.applicationName)",
                "Summarize this in \(.applicationName)",
            ],
            shortTitle: "Send Text",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: SendLinkIntent(),
            phrases: [
                "Send a link to \(.applicationName)",
                "Summarize a link in \(.applicationName)",
            ],
            shortTitle: "Send Link",
            systemImageName: "link"
        )
        AppShortcut(
            intent: SendImageIntent(),
            phrases: [
                "Send an image to \(.applicationName)",
                "Analyze an image with \(.applicationName)",
            ],
            shortTitle: "Send Image",
            systemImageName: "photo"
        )
        AppShortcut(
            intent: QuickAskIntent(),
            phrases: [
                "Show Quick Ask in \(.applicationName)",
            ],
            shortTitle: "Quick Ask",
            systemImageName: "text.bubble"
        )
    }
}
