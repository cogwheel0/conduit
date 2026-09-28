import 'package:freezed_annotation/freezed_annotation.dart';

part 'terminal.freezed.dart';
part 'terminal.g.dart';

/// A terminal server the account can use: one of Open WebUI's own
/// (`system`), or one the user added to their settings (`direct`).
@freezed
abstract class TerminalServerDto with _$TerminalServerDto {
  const factory TerminalServerDto({
    /// What selects it: a system server's id, a direct server's URL.
    required String id,
    @Default('') String name,

    /// `system` or `direct`.
    @Default('system') String kind,

    /// Only usable from a chat that has been saved, not a new one.
    @Default(false) bool requiresSavedChat,
  }) = _TerminalServerDto;

  factory TerminalServerDto.fromJson(Map<String, dynamic> json) =>
      _$TerminalServerDtoFromJson(json);
}

/// Params for `terminal.servers`: the servers usable in [scopeId] -- a
/// chat id, or empty for the terminal page on its own.
@freezed
abstract class TerminalScope with _$TerminalScope {
  const factory TerminalScope({@Default('') String scopeId}) = _TerminalScope;

  factory TerminalScope.fromJson(Map<String, dynamic> json) =>
      _$TerminalScopeFromJson(json);
}

/// Reply to `terminal.servers` and `terminal.select`.
@freezed
abstract class TerminalServers with _$TerminalServers {
  const factory TerminalServers({
    @Default(<TerminalServerDto>[]) List<TerminalServerDto> servers,

    /// The one chats send as `terminal_id`, and the page opens.
    String? selectedId,
  }) = _TerminalServers;

  factory TerminalServers.fromJson(Map<String, dynamic> json) =>
      _$TerminalServersFromJson(json);
}

/// Params for `terminal.select`: null selects none.
@freezed
abstract class TerminalSelect with _$TerminalSelect {
  const factory TerminalSelect({String? serverId}) = _TerminalSelect;

  factory TerminalSelect.fromJson(Map<String, dynamic> json) =>
      _$TerminalSelectFromJson(json);
}

/// Params for `terminal.attach`.
@freezed
abstract class TerminalAttach with _$TerminalAttach {
  const factory TerminalAttach({
    required String serverId,
    @Default('') String scopeId,
  }) = _TerminalAttach;

  factory TerminalAttach.fromJson(Map<String, dynamic> json) =>
      _$TerminalAttachFromJson(json);
}

/// Reply to `terminal.attach`: a handle for the server in that scope.
/// The shell is `WS /terminal/{handle}`, each connection a new session;
/// files, ports and uploads name the handle too. The daemon holds the
/// credential; the handle is all the window has.
@freezed
abstract class TerminalAttached with _$TerminalAttached {
  const factory TerminalAttached({
    required String handle,

    /// Where the shell starts, and the files panel opens.
    @Default('/') String cwd,

    /// Whether the server says it has a terminal at all.
    @Default(true) bool supported,
  }) = _TerminalAttached;

  factory TerminalAttached.fromJson(Map<String, dynamic> json) =>
      _$TerminalAttachedFromJson(json);
}

/// Params naming a path through a handle.
@freezed
abstract class TerminalPath with _$TerminalPath {
  const factory TerminalPath({required String handle, required String path}) =
      _TerminalPath;

  factory TerminalPath.fromJson(Map<String, dynamic> json) =>
      _$TerminalPathFromJson(json);
}

@freezed
abstract class TerminalEntry with _$TerminalEntry {
  const factory TerminalEntry({
    required String name,

    /// Absolute; a directory's ends in `/`.
    required String path,
    @Default(false) bool directory,
    int? size,
    int? modifiedAtMs,
  }) = _TerminalEntry;

  factory TerminalEntry.fromJson(Map<String, dynamic> json) =>
      _$TerminalEntryFromJson(json);
}

/// Reply to `terminal.list`: one directory, folders first.
@freezed
abstract class TerminalListing with _$TerminalListing {
  const factory TerminalListing({
    required String path,
    @Default(<TerminalEntry>[]) List<TerminalEntry> entries,
  }) = _TerminalListing;

  factory TerminalListing.fromJson(Map<String, dynamic> json) =>
      _$TerminalListingFromJson(json);
}

/// Reply to `terminal.read` and `terminal.download`: [text] when the
/// server read it as text, otherwise the bytes as [base64].
@freezed
abstract class TerminalFileContent with _$TerminalFileContent {
  const factory TerminalFileContent({
    required String name,
    @Default('application/octet-stream') String contentType,
    String? text,
    String? base64,
  }) = _TerminalFileContent;

  factory TerminalFileContent.fromJson(Map<String, dynamic> json) =>
      _$TerminalFileContentFromJson(json);
}

enum TerminalFileOp { mkdir, delete, move }

/// Params for `terminal.fileAction`. [destination] is where a move goes.
@freezed
abstract class TerminalFileAction with _$TerminalFileAction {
  const factory TerminalFileAction({
    required String handle,
    required TerminalFileOp op,
    required String path,
    String? destination,
  }) = _TerminalFileAction;

  factory TerminalFileAction.fromJson(Map<String, dynamic> json) =>
      _$TerminalFileActionFromJson(json);
}

@freezed
abstract class TerminalPort with _$TerminalPort {
  const factory TerminalPort({required int port, int? pid, String? process}) =
      _TerminalPort;

  factory TerminalPort.fromJson(Map<String, dynamic> json) =>
      _$TerminalPortFromJson(json);
}

/// Reply to `terminal.ports`: what is listening on the terminal's machine.
@freezed
abstract class TerminalPorts with _$TerminalPorts {
  const factory TerminalPorts({
    @Default(<TerminalPort>[]) List<TerminalPort> ports,
  }) = _TerminalPorts;

  factory TerminalPorts.fromJson(Map<String, dynamic> json) =>
      _$TerminalPortsFromJson(json);
}

/// Params naming a handle.
@freezed
abstract class TerminalHandleRef with _$TerminalHandleRef {
  const factory TerminalHandleRef({required String handle}) =
      _TerminalHandleRef;

  factory TerminalHandleRef.fromJson(Map<String, dynamic> json) =>
      _$TerminalHandleRefFromJson(json);
}

/// Params for `terminal.previewPort`.
@freezed
abstract class TerminalPortRef with _$TerminalPortRef {
  const factory TerminalPortRef({required String handle, required int port}) =
      _TerminalPortRef;

  factory TerminalPortRef.fromJson(Map<String, dynamic> json) =>
      _$TerminalPortRefFromJson(json);
}

/// Reply to `terminal.previewPort`: an address on this computer that
/// shows the port, for the system browser. It carries a one-time key;
/// the daemon adds the credential on the way through.
@freezed
abstract class TerminalPreview with _$TerminalPreview {
  const factory TerminalPreview({required String url}) = _TerminalPreview;

  factory TerminalPreview.fromJson(Map<String, dynamic> json) =>
      _$TerminalPreviewFromJson(json);
}

/// Payload of `terminal.displayFile`: a model's tool asks to show a file
/// from the chat's terminal, scoped to the chat.
@freezed
abstract class TerminalDisplayFile with _$TerminalDisplayFile {
  const factory TerminalDisplayFile({
    required String chatId,
    required String path,
  }) = _TerminalDisplayFile;

  factory TerminalDisplayFile.fromJson(Map<String, dynamic> json) =>
      _$TerminalDisplayFileFromJson(json);
}
