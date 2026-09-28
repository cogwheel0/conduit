import 'package:freezed_annotation/freezed_annotation.dart';

part 'system.freezed.dart';
part 'system.g.dart';

/// Reply to `system.ping`.
@freezed
abstract class PongResult with _$PongResult {
  const factory PongResult({
    /// Milliseconds since the daemon finished booting. Shown in diagnostics
    /// and used by the reconnect banner to tell "the core restarted" apart
    /// from "the socket blipped".
    required int uptimeMs,

    /// Daemon wall-clock in UTC milliseconds. A large skew against the
    /// renderer's clock explains otherwise baffling token-expiry bugs.
    required int serverTimeMs,
  }) = _PongResult;

  factory PongResult.fromJson(Map<String, dynamic> json) =>
      _$PongResultFromJson(json);
}

/// Reply to `system.shutdown`.
@freezed
abstract class ShutdownResult with _$ShutdownResult {
  const factory ShutdownResult({
    /// False when the 5 s shutdown budget expired with work still
    /// pending. Electron main still proceeds to SIGTERM, but the next launch
    /// knows to run recovery.
    required bool flushed,

    /// How many outbox entries were still unsent when the daemon gave up.
    @Default(0) int pendingOutboxEntries,
  }) = _ShutdownResult;

  factory ShutdownResult.fromJson(Map<String, dynamic> json) =>
      _$ShutdownResultFromJson(json);
}

/// Reply to `system.exportDiagnostics`.
@freezed
abstract class DiagnosticsExport with _$DiagnosticsExport {
  const factory DiagnosticsExport({
    /// Absolute path to a zip in the staging directory. The shell reveals it
    /// in the file manager; nothing is ever uploaded.
    required String path,
    required int sizeBytes,
  }) = _DiagnosticsExport;

  factory DiagnosticsExport.fromJson(Map<String, dynamic> json) =>
      _$DiagnosticsExportFromJson(json);
}

/// What kind of answer a [UiRequest] is asking for.
enum UiRequestKind {
  /// A tool wants to run and the user must allow or deny it. Bound to
  /// `Cmd/Ctrl+Alt+Enter` / `Backspace`.
  @JsonValue('toolApproval')
  toolApproval,

  /// Open WebUI asked the user a free-text question mid-turn.
  @JsonValue('inputPrompt')
  inputPrompt,

  /// An MCP server is requesting authorization for a capability.
  @JsonValue('mcpApproval')
  mcpApproval,

  /// A Hermes run needs a decision before it continues.
  @JsonValue('hermesDecision')
  hermesDecision,

  /// A plain confirm/cancel.
  @JsonValue('confirm')
  confirm,
}

/// The core asking the user something, delivered as a `ui.request` event.
///
/// This is the reverse direction that makes the [json_rpc] `Peer` (rather than
/// a plain client/server split) the right shape: business logic in the daemon
/// blocks on a human sitting in front of the renderer.
@freezed
abstract class UiRequest with _$UiRequest {
  const factory UiRequest({
    /// Correlates with [UiResponse.requestId].
    required String requestId,
    required UiRequestKind kind,

    /// Localization key for the prompt, resolved by the UI. The daemon has no
    /// locale, so it never sends prose.
    required String messageCode,
    @Default(<String, String>{}) Map<String, String> messageArgs,

    /// Kind-specific detail: the tool name and arguments, the MCP scopes, the
    /// Hermes step. Rendered by the card for that kind.
    @Default(<String, dynamic>{}) Map<String, dynamic> detail,

    /// Milliseconds before the daemon gives up and takes [defaultChoice].
    /// Null means wait forever — correct for tool approvals, wrong for a
    /// prompt that would wedge a background sync.
    int? timeoutMs,

    /// Applied on timeout, and when the window closes with the card open.
    /// Always the conservative option: deny, not allow.
    @Default('deny') String defaultChoice,
  }) = _UiRequest;

  factory UiRequest.fromJson(Map<String, dynamic> json) =>
      _$UiRequestFromJson(json);
}

/// The user's answer, sent back with `ui.respond`.
@freezed
abstract class UiResponse with _$UiResponse {
  const factory UiResponse({
    required String requestId,

    /// `allow`, `deny`, `cancel`, or a kind-specific option id.
    required String choice,

    /// Free-text answer for [UiRequestKind.inputPrompt].
    String? text,

    /// Persist this answer so the same tool or MCP scope is not asked again
    /// ("remembered approvals" in the parity matrix).
    @Default(false) bool remember,
  }) = _UiResponse;

  factory UiResponse.fromJson(Map<String, dynamic> json) =>
      _$UiResponseFromJson(json);
}

/// Params for `system.network`.
@freezed
abstract class NetworkReport with _$NetworkReport {
  const factory NetworkReport({required bool online}) = _NetworkReport;

  factory NetworkReport.fromJson(Map<String, dynamic> json) =>
      _$NetworkReportFromJson(json);
}
