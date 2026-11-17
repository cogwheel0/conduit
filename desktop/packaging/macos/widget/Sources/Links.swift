// The links the widget opens. They go to the app that contains the widget
// (WidgetKit hands a widget's URLs to its own app), which parses them in
// desktop/crates/app/src/shell/deep_link.rs.

import Foundation

enum WidgetLink {
    /// A new chat in the main window, with the caret in the composer.
    static let newChat = URL(string: "conduit://new")!
    /// The Quick Ask panel.
    static let quickAsk = URL(string: "conduit://quick-ask")!
    /// A voice call in a new chat (a new chat when calls can't start).
    static let voiceCall = URL(string: "conduit://call")!
    /// A new chat with what was copied (the phone widget's Clipboard).
    static let clipboard = URL(string: "conduit://clipboard")!

    /// `conduit://chat/<id>`; nil for an id a link can't carry.
    static func chat(_ id: String) -> URL? {
        guard WidgetSnapshot.isValidId(id) else { return nil }
        return URL(string: "conduit://chat/\(id)")
    }
}
