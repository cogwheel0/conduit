/// How prominent a transient notice is.
enum UiNoticeLevel { info, success, warning, error }

/// Asks the user something, from inside the core.
///
/// Open WebUI can interrupt a stream to ask for a confirmation or a value,
/// and a tool call can need approval before it runs. The logic deciding
/// *when* to ask belongs to the streaming pipeline; rendering a dialog does
/// not — on desktop the question travels to whichever window is in front as
/// a `ui.request` notification and comes back as `ui.respond`.
///
/// Every method has a defined answer when there is nobody to ask, because
/// the stream must not hang: a confirmation with no UI is a decline, and a
/// prompt with no UI is a cancellation.
abstract interface class UiRequestPort {
  /// Returns false when the user declines *or* when no surface is available.
  Future<bool> confirm({
    required String title,
    String message,
    String? confirmLabel,
    String? cancelLabel,
  });

  /// Returns the trimmed text, or null when cancelled, left empty, or
  /// unanswerable.
  Future<String?> promptForText({
    required String title,
    String message,
    String? placeholder,
    String? initialValue,
    String? confirmLabel,
    String? cancelLabel,
  });

  /// Fire-and-forget notice. Never blocks the stream.
  void notify(UiNoticeLevel level, String message);
}

/// Declines everything and drops notices.
///
/// The correct behaviour with no attached UI — a headless daemon, a test.
/// Declining rather than approving matters: this is the path a tool-approval
/// request takes when nobody is watching.
class NullUiRequestPort implements UiRequestPort {
  const NullUiRequestPort();

  @override
  Future<bool> confirm({
    required String title,
    String message = '',
    String? confirmLabel,
    String? cancelLabel,
  }) async => false;

  @override
  Future<String?> promptForText({
    required String title,
    String message = '',
    String? placeholder,
    String? initialValue,
    String? confirmLabel,
    String? cancelLabel,
  }) async => null;

  @override
  void notify(UiNoticeLevel level, String message) {}
}
