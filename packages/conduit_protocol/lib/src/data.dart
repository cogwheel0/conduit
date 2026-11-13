import 'package:freezed_annotation/freezed_annotation.dart';

part 'data.freezed.dart';
part 'data.g.dart';

/// Reply to `data.summary`: what Chat Data Controls' server-wide actions
/// would reach, as core's `ServerChatBulkScope` counts it, for the signed-in
/// Open WebUI account.
@freezed
abstract class ChatDataSummary with _$ChatDataSummary {
  const factory ChatDataSummary({
    /// Chat Data Controls apply: an Open WebUI account is signed in.
    @Default(false) bool available,

    /// Stored chats an action reaches (the account's server chats).
    @Default(0) int serverChats,

    /// Chats that exist only on this computer; no action reaches them, and
    /// a library export leaves them out.
    @Default(0) int localOnly,

    /// Reached chats with an edit or a reply the server does not have yet.
    @Default(0) int unsent,

    /// Of those, replies being sent or written now.
    @Default(0) int running,

    /// The account may export, import and delete its chats (an admin, or
    /// the server's `chat` permissions allow it).
    @Default(false) bool canExport,
    @Default(false) bool canImport,
    @Default(false) bool canDelete,
  }) = _ChatDataSummary;

  factory ChatDataSummary.fromJson(Map<String, dynamic> json) =>
      _$ChatDataSummaryFromJson(json);
}

/// Params for `data.export`: the file the whole library is written to (an
/// Open WebUI-compatible JSON array). Written only once every chat arrived;
/// a failed or cut-off export leaves no file.
@freezed
abstract class DataExportRequest with _$DataExportRequest {
  const factory DataExportRequest({required String path}) = _DataExportRequest;

  factory DataExportRequest.fromJson(Map<String, dynamic> json) =>
      _$DataExportRequestFromJson(json);
}

/// Params for `data.import`: a backup file to send to the server.
@freezed
abstract class DataImportRequest with _$DataImportRequest {
  const factory DataImportRequest({required String path}) = _DataImportRequest;

  factory DataImportRequest.fromJson(Map<String, dynamic> json) =>
      _$DataImportRequestFromJson(json);
}

/// Params for `data.deleteAll`.
@freezed
abstract class DataDeleteAll with _$DataDeleteAll {
  const factory DataDeleteAll({
    /// Discard edits and replies the server does not have yet; without it
    /// their presence refuses the action (failure `pendingWork`).
    @Default(false) bool discardUnsent,
  }) = _DataDeleteAll;

  factory DataDeleteAll.fromJson(Map<String, dynamic> json) =>
      _$DataDeleteAllFromJson(json);
}

/// Reply to the `data.*` actions. [failure] is null when the action did what
/// it says, else core's reason, by name: for a backup or restore one of
/// `ChatBackupFailure` (`malformedExport`, `notJson`, `notAList`,
/// `emptyImport`, `fileTooLarge`, `unrecognizedChat`, `invalidField`,
/// `cancelled`, `ownerChanged`), for the rest one of
/// `ChatDataControlsFailure` (`forbidden`, `pendingWork`, `responseRunning`,
/// `localWorkChanged`, `serverRefused`, `outcomeUnknown`, `ownerChanged`,
/// `accountUnknown`), or `failed` for anything else.
@freezed
abstract class DataActionResult with _$DataActionResult {
  const factory DataActionResult({
    String? failure,

    /// Chats exported, imported, or changed on this computer.
    @Default(0) int count,

    /// For an import: of [count], those stored here already (the rest come
    /// with the next sync).
    @Default(0) int stored,

    /// For an import's preview: the messages in the file's chats.
    @Default(0) int messages,

    /// The 0-based position of the chat a restore refused, when it names one.
    int? index,
  }) = _DataActionResult;

  factory DataActionResult.fromJson(Map<String, dynamic> json) =>
      _$DataActionResultFromJson(json);
}

/// Reply to `data.connection`: the server's realtime socket, as core's
/// `SocketHealth` reports it. `socket.health` says when it changed.
@freezed
abstract class ConnectionHealth with _$ConnectionHealth {
  const factory ConnectionHealth({
    /// An Open WebUI server's socket applies (none for Direct or Hermes).
    @Default(false) bool available,
    @Default(false) bool connected,

    /// `websocket`, `polling` or `unknown`.
    @Default('unknown') String transport,

    /// The last heartbeat's round trip, or null before one.
    int? latencyMs,

    /// `excellent`, `good`, `fair`, `poor` or `unknown`.
    @Default('unknown') String quality,

    /// When the last heartbeat answered, in ms since the epoch.
    int? lastHeartbeatMs,
    @Default(0) int reconnects,

    /// The transports the server allows; Settings offers a choice only when
    /// it allows both.
    @Default(true) bool allowPolling,
    @Default(true) bool allowWebsocket,
  }) = _ConnectionHealth;

  factory ConnectionHealth.fromJson(Map<String, dynamic> json) =>
      _$ConnectionHealthFromJson(json);
}
