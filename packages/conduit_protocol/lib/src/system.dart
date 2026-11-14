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
    /// False when the outbox could not be emptied within the shutdown
    /// budget (or its count could not be read). The daemon stops anyway; the
    /// changes stay on disk and are sent on the next launch.
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

  /// A Hermes run needs a decision before it continues. `messageCode`
  /// says which: `hermes.approval` (run a command or write a file:
  /// `messageArgs.summary`, `detail.choices` from `once`, `session`,
  /// `always` and `deny`, and a paid tool's `detail.cost` `{price,
  /// approximate, note, spent, limit, server, overLimit}`), answered with
  /// `ui.respond`; or `hermes.mcpSetup` (set up an MCP server:
  /// `messageArgs.server`, `messageArgs.action`), answered with
  /// `hermes.decisions.answer` (`approve` or `decline`).
  @JsonValue('hermesDecision')
  hermesDecision,

  /// A plain confirm/cancel.
  @JsonValue('confirm')
  confirm,

  /// An MCP App in a chat wants to call one of its server's tools:
  /// `messageArgs` has `serverName` and `toolName`, `detail.arguments` the
  /// arguments as pretty-printed JSON. `allow` runs it; anything else
  /// refuses.
  @JsonValue('mcpAppToolCall')
  mcpAppToolCall,

  /// An MCP App in a chat asks to open a web page: `messageArgs.url`.
  /// `allow` opens it in the browser (the window does, on `openUrl`).
  @JsonValue('mcpAppOpenLink')
  mcpAppOpenLink,

  /// A Hermes agent asks one or more questions as a form: `detail.chatId`,
  /// `detail.questions` (each `{id, text, choices: [{value, label,
  /// recommended}], multiSelect, locked, lockedAnswer}`; up to five) and
  /// `messageArgs.prompt`. Answered with `hermes.decisions.answer`
  /// (`answers`, one per open question, null to skip); `deny` only closes
  /// the card here.
  @JsonValue('hermesClarify')
  hermesClarify,

  /// A Hermes agent needs the sudo password to run a command:
  /// `messageArgs.prompt`, `detail.chatId`. Answered with
  /// `hermes.decisions.answer` (`value`), which is never logged or kept.
  @JsonValue('hermesSudo')
  hermesSudo,

  /// A Hermes agent needs a secret (an API key, a token):
  /// `messageArgs.prompt`, `detail.chatId`. Answered with
  /// `hermes.decisions.answer` (`value`), which is never logged or kept.
  @JsonValue('hermesSecret')
  hermesSecret,

  /// A LibreChat agent paused its run to ask the user something.
  /// `detail` has `question`, an optional `description`, `options` (a list
  /// of `{label, description?}`) and `multiSelect`; `messageArgs.chatId`
  /// names the chat. The answer goes back as [UiResponse.text] (an
  /// option's label, several joined with ", ", or the user's own words)
  /// with choice `answer` (or `allow`, as the window's question card says
  /// it); `cancel` stops the reply.
  ///
  /// A LibreChat tool call waiting for approval is a [toolApproval] with
  /// `detail.backend` `libreChat`.
  @JsonValue('libreChatQuestion')
  libreChatQuestion,

  /// Hermes holds a switch to another model (a pricier, data-sharing or
  /// smaller-context one) until the user confirms it: `messageArgs.model`
  /// (the model's name) and, when Hermes gave one, `messageArgs.reason`.
  /// `allow` switches the chat and sends the waiting message; `deny` keeps
  /// the current model, sends nothing and gives the words back to the
  /// composer (`composer.insertText`). Unanswered (no window, the
  /// timeout), the switch is refused as before.
  @JsonValue('hermesModelSwitch')
  hermesModelSwitch,
}

/// How an [UiRequestKind.inputPrompt] wants its value entered.
@JsonEnum(fieldRename: FieldRename.none)
enum UiInputType {
  /// One line of plain text. What a request without [UiRequest.inputType]
  /// asks for.
  text,

  /// Masked text: the card must not echo it or keep it in history.
  password,

  /// One of [UiRequest.options], answered with its `value` in
  /// [UiResponse.text].
  select,
}

/// One choice of a [UiInputType.select] prompt.
@freezed
abstract class UiInputOption with _$UiInputOption {
  const factory UiInputOption({
    /// What goes back in [UiResponse.text] when this is picked.
    required String value,

    /// What the card shows. Server-written prose, not a localization key.
    required String label,
  }) = _UiInputOption;

  factory UiInputOption.fromJson(Map<String, dynamic> json) =>
      _$UiInputOptionFromJson(json);
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

    /// For [UiRequestKind.inputPrompt]: how the value is entered. Omitted
    /// for plain text, so older cards keep working for the common case.
    UiInputType? inputType,

    /// For [UiInputType.select]: the choices, in the server's order.
    /// Omitted otherwise.
    List<UiInputOption>? options,
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

/// Reply to the methods whose only answer is that they ran:
/// `system.network`, the `channels.*` actions, `terminal.fileAction`,
/// `workspace.delete` and `workspace.promptDeleteVersion`.
@freezed
abstract class OkResult with _$OkResult {
  const factory OkResult({required bool ok}) = _OkResult;

  factory OkResult.fromJson(Map<String, dynamic> json) =>
      _$OkResultFromJson(json);
}

/// Reply to `ui.respond`.
@freezed
abstract class AcceptedResult with _$AcceptedResult {
  const factory AcceptedResult({
    /// False when the request had already been answered, by another window
    /// or by its timeout. Not an error: the answer simply no longer counts.
    required bool accepted,
  }) = _AcceptedResult;

  factory AcceptedResult.fromJson(Map<String, dynamic> json) =>
      _$AcceptedResultFromJson(json);
}

/// Payload of `ui.settled`: a `ui.request` was answered or ran out of time.
@freezed
abstract class UiSettled with _$UiSettled {
  const factory UiSettled({
    /// The [UiRequest.requestId] that no longer needs an answer.
    required String requestId,
  }) = _UiSettled;

  factory UiSettled.fromJson(Map<String, dynamic> json) =>
      _$UiSettledFromJson(json);
}

/// How a [Notice] should look.
@JsonEnum(fieldRename: FieldRename.none)
enum NoticeLevel { info, success, warning, error }

/// Payload of `notify.show`: something the core wants the user to see,
/// shown by the window as a toast.
@freezed
abstract class Notice with _$Notice {
  const factory Notice({
    required NoticeLevel level,

    /// Prose the core or the server wrote, not a localization key.
    required String message,
  }) = _Notice;

  factory Notice.fromJson(Map<String, dynamic> json) => _$NoticeFromJson(json);
}
