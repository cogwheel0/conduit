// What the app tells the widget: `widget-snapshot.json` in the app group's
// container, written by the app (desktop/crates/app/src/shell/widget.rs)
// whenever its chat list, its sign-in or its language changes.
//
// Chat titles, ids and times only: never message text, and no chats at all
// while nobody is signed in. The widget only reads it.

import Foundation

struct WidgetSnapshot: Codable, Equatable {
    /// The file's name in the group container.
    static let fileName = "widget-snapshot.json"
    /// The format this widget reads. A newer app may write a higher
    /// version; the widget then shows its actions without chats.
    static let currentVersion = 1
    /// The most rows any family shows (large).
    static let maxChats = 6

    struct Chat: Codable, Equatable, Identifiable {
        var id: String
        /// The title as the app's sidebar shows it ("New Chat" for an
        /// untitled one, in the app's language).
        var title: String
        var updatedAtMs: Int64

        var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMs) / 1000) }
    }

    var version: Int
    /// Signed in (or a Direct-only or Hermes-only setup): the app routes to
    /// its main window.
    var signedIn: Bool
    /// The app's language (`en`, `de`, `zh_Hant`, …).
    var locale: String?
    /// Newest first.
    var chats: [Chat]
}

extension WidgetSnapshot {
    /// The app group the app and the widget share, from the widget's (or
    /// the app's) Info.plist: bundle.sh writes `ConduitAppGroup` from
    /// release.env into both.
    static func appGroup(in bundle: Bundle = .main) -> String? {
        let value = bundle.object(forInfoDictionaryKey: "ConduitAppGroup") as? String
        guard let group = value?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty
        else { return nil }
        return group
    }

    /// Where the app writes the snapshot, or nil without an app group (or
    /// when the system refuses the group to this process).
    static func url(in bundle: Bundle = .main) -> URL? {
        guard let group = appGroup(in: bundle),
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The snapshot at `url`, checked. Nil when there is none yet (the app
    /// hasn't run since the widget was installed), it can't be read, or a
    /// newer app wrote a format this widget doesn't know.
    static func load(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        guard data.count <= 256 * 1024,
            var snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
            snapshot.version == currentVersion
        else { return nil }
        // Signed out means no chats, whatever the file says.
        if !snapshot.signedIn { snapshot.chats = [] }
        snapshot.chats = Array(
            snapshot.chats
                .filter { isValidId($0.id) }
                .map { chat in
                    var chat = chat
                    chat.title = String(chat.title.prefix(200))
                    return chat
                }
                .prefix(maxChats))
        return snapshot
    }

    /// A chat id a link may carry: the app's `deep_link::valid_id`. A row
    /// with any other id is left out rather than linked.
    static func isValidId(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count)
            && id.utf8.allSatisfy { b in
                (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                    || b == 0x3A || b == 0x5F || b == 0x2E || b == 0x2D
            }
    }
}
