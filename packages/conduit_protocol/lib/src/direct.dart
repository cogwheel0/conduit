import 'package:freezed_annotation/freezed_annotation.dart';

part 'direct.freezed.dart';
part 'direct.g.dart';

/// Which kind of server a direct connection talks to (M4).
///
/// OpenRouter, Azure and LM Studio are OpenAI-compatible servers, not kinds
/// of their own: the core tells OpenRouter apart by its address, and Azure
/// by its `api-version` and key header.
enum DirectKind { openai, ollama }

/// For [DirectKind.openai]: the chat completions API, or the newer
/// responses API.
enum DirectApiMode { chat, responses }

/// A direct connection, as the settings list shows it (WP-4.1).
///
/// Never its secrets. An API key or a header value is written once and
/// then only reported as present -- the same rule `servers.*` follows,
/// because a key read back is a key a compromised window could copy out.
@freezed
abstract class DirectConnectionSummary with _$DirectConnectionSummary {
  const factory DirectConnectionSummary({
    required String id,
    required String name,
    required DirectKind kind,
    required String baseUrl,
    @Default(DirectApiMode.chat) DirectApiMode apiMode,

    /// Azure's `api-version`, when set.
    String? apiVersion,

    /// Send the key in an `api-key` header (Azure) rather than as a bearer
    /// token.
    @Default(false) bool apiKeyHeader,
    String? modelIdPrefix,
    @Default(true) bool enabled,
    @Default(false) bool hasApiKey,

    /// Names only; values are secrets like the key.
    @Default(<String>[]) List<String> customHeaderNames,

    /// For servers without model discovery.
    @Default(<String>[]) List<String> manualModelIds,
    @Default(false) bool allowSelfSignedCertificates,
    @Default(false) bool openRouter,
    @Default(false) bool ollamaCloud,

    /// Kept in the Open WebUI account's settings rather than on this
    /// computer (M4). Its chats go through Open WebUI, which asks the app
    /// to make the request -- Open WebUI's own "direct connections".
    @Default(false) bool openWebUi,

    /// False for an Open WebUI connection this app cannot use (an
    /// authentication kind it does not support). Listed, not editable.
    @Default(true) bool compatible,
  }) = _DirectConnectionSummary;

  factory DirectConnectionSummary.fromJson(Map<String, dynamic> json) =>
      _$DirectConnectionSummaryFromJson(json);
}

/// Reply to `direct.list` and to every change.
@freezed
abstract class DirectConnectionList with _$DirectConnectionList {
  const factory DirectConnectionList({
    @Default(<DirectConnectionSummary>[])
    List<DirectConnectionSummary> connections,

    /// Keep direct chats on this computer only, rather than mirroring them
    /// to the Open WebUI server.
    @Default(false) bool localHistory,

    /// The signed-in server lets its users keep direct connections in their
    /// account, so the settings offer a section for them.
    @Default(false) bool openWebUiAvailable,

    /// The app was set up to use direct connections rather than an Open
    /// WebUI server (the welcome screen's choice).
    @Default(false) bool preferred,

    /// At least one connection on this computer is on and complete, so the
    /// app can be used with no server at all.
    @Default(false) bool usable,
  }) = _DirectConnectionList;

  factory DirectConnectionList.fromJson(Map<String, dynamic> json) =>
      _$DirectConnectionListFromJson(json);
}

/// Params for `direct.save` and `direct.test`.
///
/// [apiKey] and [customHeaders] follow the servers rule: null keeps what is
/// stored, an empty value clears it. Changing where the connection points
/// drops its stored secrets unless new ones are given in the same edit --
/// the core's own rule, so a key cannot silently follow a URL somewhere
/// else.
@freezed
abstract class DirectConnectionEdit with _$DirectConnectionEdit {
  const factory DirectConnectionEdit({
    /// Null adds a connection.
    String? id,
    required String name,
    required DirectKind kind,
    required String baseUrl,
    @Default(DirectApiMode.chat) DirectApiMode apiMode,
    String? apiVersion,
    @Default(false) bool apiKeyHeader,
    String? modelIdPrefix,
    @Default(true) bool enabled,

    /// For a new connection: keep it in the Open WebUI account instead of
    /// on this computer. An existing one stays where it is.
    @Default(false) bool openWebUi,
    String? apiKey,
    Map<String, String>? customHeaders,
    @Default(<String>[]) List<String> manualModelIds,
    @Default(false) bool allowSelfSignedCertificates,
  }) = _DirectConnectionEdit;

  factory DirectConnectionEdit.fromJson(Map<String, dynamic> json) =>
      _$DirectConnectionEditFromJson(json);
}

/// Reply to `direct.test`.
@freezed
abstract class DirectTestResult with _$DirectTestResult {
  const factory DirectTestResult({
    required bool reachable,
    int? modelCount,
    String? message,
  }) = _DirectTestResult;

  factory DirectTestResult.fromJson(Map<String, dynamic> json) =>
      _$DirectTestResultFromJson(json);
}

/// Params naming one connection.
@freezed
abstract class DirectRef with _$DirectRef {
  const factory DirectRef({required String id}) = _DirectRef;

  factory DirectRef.fromJson(Map<String, dynamic> json) =>
      _$DirectRefFromJson(json);
}

/// Params for `direct.setEnabled`.
@freezed
abstract class DirectEnable with _$DirectEnable {
  const factory DirectEnable({required String id, required bool enabled}) =
      _DirectEnable;

  factory DirectEnable.fromJson(Map<String, dynamic> json) =>
      _$DirectEnableFromJson(json);
}

/// Params for `direct.setHistory`.
@freezed
abstract class DirectHistory with _$DirectHistory {
  const factory DirectHistory({required bool localOnly}) = _DirectHistory;

  factory DirectHistory.fromJson(Map<String, dynamic> json) =>
      _$DirectHistoryFromJson(json);
}

/// One of an Ollama connection's models, with what can be done to it
/// (M4).
@freezed
abstract class OllamaModelStatus with _$OllamaModelStatus {
  const factory OllamaModelStatus({
    /// The id Ollama knows it by, as `/api/tags` lists it.
    required String id,
    required String name,

    /// In memory now, as `/api/ps` says. Null when that could not be read.
    bool? loaded,

    /// How long it stays loaded after a chat: an Ollama duration (`5m`,
    /// `-1` for always, `0` to unload straight away). Null is the server's
    /// default.
    String? keepAlive,

    /// For Ollama Cloud: `disabled`, `low`, `medium` or `high`. Null
    /// leaves it to the model.
    String? thinking,
  }) = _OllamaModelStatus;

  factory OllamaModelStatus.fromJson(Map<String, dynamic> json) =>
      _$OllamaModelStatusFromJson(json);
}

/// Reply to `direct.ollamaModels` and to each Ollama action.
@freezed
abstract class OllamaModelList with _$OllamaModelList {
  const factory OllamaModelList({
    @Default(<OllamaModelStatus>[]) List<OllamaModelStatus> models,

    /// Load, unload and keep-alive apply: a local server, not Ollama Cloud.
    @Default(false) bool lifecycle,

    /// Ollama Cloud, where a model's thinking can be set.
    @Default(false) bool cloud,
  }) = _OllamaModelList;

  factory OllamaModelList.fromJson(Map<String, dynamic> json) =>
      _$OllamaModelListFromJson(json);
}

/// Params for the Ollama model actions. [value] is the keep-alive or the
/// thinking setting; null resets it.
@freezed
abstract class OllamaModelAction with _$OllamaModelAction {
  const factory OllamaModelAction({
    required String id,
    required String model,
    String? value,
  }) = _OllamaModelAction;

  factory OllamaModelAction.fromJson(Map<String, dynamic> json) =>
      _$OllamaModelActionFromJson(json);
}

/// Params for `direct.setPreferred`.
@freezed
abstract class DirectPreferred with _$DirectPreferred {
  const factory DirectPreferred({required bool preferred}) = _DirectPreferred;

  factory DirectPreferred.fromJson(Map<String, dynamic> json) =>
      _$DirectPreferredFromJson(json);
}
