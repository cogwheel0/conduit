import 'package:freezed_annotation/freezed_annotation.dart';

part 'mcp.freezed.dart';
part 'mcp.g.dart';

/// How the app signs in to an MCP server (M4).
enum McpAuth { none, bearer, oauth }

/// A tool call the user said to always allow on one server.
@freezed
abstract class McpApprovalSummary with _$McpApprovalSummary {
  const factory McpApprovalSummary({
    /// What the approval is keyed by: the tool and its schema, so a tool
    /// that changes what it takes is asked about again.
    required String digest,
    required String toolName,
    required int createdAtMs,
  }) = _McpApprovalSummary;

  factory McpApprovalSummary.fromJson(Map<String, dynamic> json) =>
      _$McpApprovalSummaryFromJson(json);
}

/// An MCP server the app talks to itself, as the settings list shows it.
///
/// Secrets only as present, the rule `direct.*` follows.
@freezed
abstract class McpServerSummary with _$McpServerSummary {
  const factory McpServerSummary({
    required String id,
    required String name,
    required String endpoint,
    @Default(true) bool enabled,
    @Default(McpAuth.none) McpAuth auth,
    @Default(false) bool hasBearerToken,

    /// Names only; values are secrets.
    @Default(<String>[]) List<String> customHeaderNames,

    /// Whether an OAuth sign-in has been completed and is still held.
    @Default(false) bool oauthConnected,

    /// The user agreed to send credentials over plain HTTP to this
    /// endpoint.
    @Default(false) bool allowInsecureCredentials,
    @Default(<McpApprovalSummary>[]) List<McpApprovalSummary> approvals,
  }) = _McpServerSummary;

  factory McpServerSummary.fromJson(Map<String, dynamic> json) =>
      _$McpServerSummaryFromJson(json);
}

/// Reply to `mcp.list` and to every change.
@freezed
abstract class McpServerList with _$McpServerList {
  const factory McpServerList({
    @Default(<McpServerSummary>[]) List<McpServerSummary> servers,
  }) = _McpServerList;

  factory McpServerList.fromJson(Map<String, dynamic> json) =>
      _$McpServerListFromJson(json);
}

/// Params for `mcp.save` and `mcp.test`.
///
/// Secrets follow the `direct.*` rule: null keeps what is stored, empty
/// clears it.
@freezed
abstract class McpServerEdit with _$McpServerEdit {
  const factory McpServerEdit({
    /// Null adds a server.
    String? id,
    required String name,
    required String endpoint,
    @Default(true) bool enabled,
    @Default(McpAuth.none) McpAuth auth,
    String? bearerToken,
    Map<String, String>? customHeaders,

    /// Sending credentials over plain HTTP to a host that is not this
    /// computer needs saying so. Without it the save is refused with
    /// `invalidParams` and `args.reason == 'insecure'`, and the window
    /// asks.
    @Default(false) bool allowInsecureCredentials,
  }) = _McpServerEdit;

  factory McpServerEdit.fromJson(Map<String, dynamic> json) =>
      _$McpServerEditFromJson(json);
}

/// Reply to `mcp.test`.
@freezed
abstract class McpTestResult with _$McpTestResult {
  const factory McpTestResult({
    required bool reachable,
    int? toolCount,
    String? message,
  }) = _McpTestResult;

  factory McpTestResult.fromJson(Map<String, dynamic> json) =>
      _$McpTestResultFromJson(json);
}

/// Params naming one MCP server.
@freezed
abstract class McpRef with _$McpRef {
  const factory McpRef({required String id}) = _McpRef;

  factory McpRef.fromJson(Map<String, dynamic> json) => _$McpRefFromJson(json);
}

/// Params for `mcp.setEnabled`.
@freezed
abstract class McpEnable with _$McpEnable {
  const factory McpEnable({required String id, required bool enabled}) =
      _McpEnable;

  factory McpEnable.fromJson(Map<String, dynamic> json) =>
      _$McpEnableFromJson(json);
}

/// Params for `mcp.forgetApproval`: one remembered approval, or with no
/// [digest], all of a server's.
@freezed
abstract class McpForgetApproval with _$McpForgetApproval {
  const factory McpForgetApproval({required String serverId, String? digest}) =
      _McpForgetApproval;

  factory McpForgetApproval.fromJson(Map<String, dynamic> json) =>
      _$McpForgetApprovalFromJson(json);
}

/// Payload of `shell.openUrl`: the daemon needs a page opened in the
/// system browser -- an MCP server's sign-in -- and has no browser of its
/// own. A window opens it.
@freezed
abstract class OpenUrl with _$OpenUrl {
  const factory OpenUrl({required String url}) = _OpenUrl;

  factory OpenUrl.fromJson(Map<String, dynamic> json) =>
      _$OpenUrlFromJson(json);
}
