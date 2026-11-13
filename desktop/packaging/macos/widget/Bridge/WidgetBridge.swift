// libconduit_widget.dylib: what the app (Rust) calls to tell WidgetKit its
// chats changed. WidgetCenter is Swift-only, so this small library wraps it
// in C functions; the app opens it with dlopen from Contents/Frameworks and
// carries on without it (a dev build, or a bundle without the widget).
//
// WidgetKit honours the call only from the app that contains the widget,
// which is why it runs inside the app's process rather than as a helper.

import Foundation
import WidgetKit

/// Asks WidgetKit to read every Conduit widget's timeline again. Returns 1
/// when the request went to WidgetKit.
@_cdecl("conduit_widget_reload_all")
public func conduitWidgetReloadAll() -> Int32 {
    WidgetCenter.shared.reloadAllTimelines()
    return 1
}

/// The app group's container (created if missing) as a UTF-8 path, copied
/// into `buffer` (NUL-terminated). Returns the path's length, 0 when the
/// system gives this process no container for `group`, or the length
/// needed when `buffer` is too small.
@_cdecl("conduit_widget_group_container")
public func conduitWidgetGroupContainer(
    _ group: UnsafePointer<CChar>?, _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int
) -> Int {
    guard let group, let id = String(validatingCString: group), !id.isEmpty,
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    else { return 0 }
    let path = Array(url.path.utf8CString)
    guard let buffer, capacity >= path.count else { return path.count - 1 }
    path.withUnsafeBufferPointer { src in
        buffer.update(from: src.baseAddress!, count: path.count)
    }
    return path.count - 1
}
