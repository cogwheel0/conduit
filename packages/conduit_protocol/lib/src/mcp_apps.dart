import 'package:freezed_annotation/freezed_annotation.dart';

part 'mcp_apps.freezed.dart';
part 'mcp_apps.g.dart';

/// An MCP App a tool call showed in an Open WebUI chat (0.13 and later), as
/// the server recorded it. Sent back as is to `mcpApps.open`: the server
/// reads the app again through its app RPC, which accepts only the
/// [binding] it signed for this server and tool.
@freezed
abstract class McpAppDto with _$McpAppDto {
  const factory McpAppDto({
    required String serverId,
    required String toolName,
    required String binding,

    /// The arguments the tool was called with: a JSON object, as text.
    @Default('{}') String arguments,

    /// The tool's MCP `CallToolResult`: a JSON object, as text.
    @Default('{}') String result,
  }) = _McpAppDto;

  factory McpAppDto.fromJson(Map<String, dynamic> json) =>
      _$McpAppDtoFromJson(json);
}

/// Params for `mcpApps.open`: run [app] for the chat [chatId], in a page
/// [width] points wide.
@freezed
abstract class McpAppOpen with _$McpAppOpen {
  const factory McpAppOpen({
    required String chatId,
    required McpAppDto app,

    /// `light` or `dark`.
    @Default('light') String theme,

    /// A BCP 47 tag, such as `en` or `pt-BR`.
    @Default('en') String locale,
    @Default(0) double width,
  }) = _McpAppOpen;

  factory McpAppOpen.fromJson(Map<String, dynamic> json) =>
      _$McpAppOpenFromJson(json);
}

/// Reply to `mcpApps.open`: the page to load, sealed, and what it may
/// reach. The page talks to its host with `mcpApps.message`, and hears back
/// through `mcpApps.event`.
@freezed
abstract class McpAppSession with _$McpAppSession {
  const factory McpAppSession({
    /// This run of the app; every later call and event names it.
    required String appId,

    /// The whole page: the server's content security policy and the
    /// host's tags first, then the app's HTML.
    required String document,

    /// The origins the app declared, by kind; its policy already holds
    /// them, these let a host refuse anything else it can see.
    @Default(<String>[]) List<String> connectDomains,
    @Default(<String>[]) List<String> resourceDomains,
    @Default(<String>[]) List<String> frameDomains,
  }) = _McpAppSession;

  factory McpAppSession.fromJson(Map<String, dynamic> json) =>
      _$McpAppSessionFromJson(json);
}

/// Params for `mcpApps.message`: one message the page posted to its host
/// (a JSON-RPC 2.0 object, as text).
@freezed
abstract class McpAppMessage with _$McpAppMessage {
  const factory McpAppMessage({
    required String appId,
    required String payload,
  }) = _McpAppMessage;

  factory McpAppMessage.fromJson(Map<String, dynamic> json) =>
      _$McpAppMessageFromJson(json);
}

/// Params for `mcpApps.context`: what changed about the app's place.
@freezed
abstract class McpAppContext with _$McpAppContext {
  const factory McpAppContext({
    required String appId,

    /// `light` or `dark`, when the window's appearance changed.
    String? theme,

    /// The page's new width in points.
    double? width,
  }) = _McpAppContext;

  factory McpAppContext.fromJson(Map<String, dynamic> json) =>
      _$McpAppContextFromJson(json);
}

/// Params for `mcpApps.close`: the app's view is going.
@freezed
abstract class McpAppRef with _$McpAppRef {
  const factory McpAppRef({required String appId}) = _McpAppRef;

  factory McpAppRef.fromJson(Map<String, dynamic> json) =>
      _$McpAppRefFromJson(json);
}

/// What an [McpAppEvent] tells the window.
enum McpAppEventKind {
  /// Deliver [McpAppEvent.message] to the page.
  deliver,

  /// The page asked for [McpAppEvent.height] points.
  resize,

  /// The app finished its handshake: its view can show.
  started,

  /// The host stopped answering the app (it did not start in time, or the
  /// account changed): show it as closed.
  closed,
}

/// Payload of `mcpApps.event`, scoped to the app's chat.
@freezed
abstract class McpAppEvent with _$McpAppEvent {
  const factory McpAppEvent({
    required String appId,
    required McpAppEventKind kind,

    /// [McpAppEventKind.deliver]: a JSON-RPC 2.0 message, as text.
    String? message,

    /// [McpAppEventKind.resize]: the content's height in points.
    double? height,
  }) = _McpAppEvent;

  factory McpAppEvent.fromJson(Map<String, dynamic> json) =>
      _$McpAppEventFromJson(json);
}
