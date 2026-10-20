/// The system clipboard.
///
/// Needed by prompt variables, which can substitute `{{CLIPBOARD}}`. Flutter
/// reaches it through a platform channel and the renderer through the async
/// Clipboard API, so even the read is a future on both sides.
abstract interface class ClipboardPort {
  /// Current plain-text contents, or null when empty, unreadable, or denied.
  ///
  /// Null rather than throwing: a browser can refuse clipboard access
  /// outright, and a prompt variable that cannot be filled should render
  /// empty, not fail the send.
  Future<String?> readText();

  Future<void> writeText(String text);
}

/// A clipboard that is always empty and discards writes.
class NullClipboardPort implements ClipboardPort {
  const NullClipboardPort();

  @override
  Future<String?> readText() async => null;

  @override
  Future<void> writeText(String text) async {}
}
