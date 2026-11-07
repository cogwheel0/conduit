import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// An MCP App a tool call showed in an Open WebUI chat (0.13 and later).
///
/// Open WebUI records it as an embed of the tool call's output:
/// `{type: 'mcp_app', server_id, tool_name, binding, arguments, result}`.
/// The app itself, its HTML and what it may reach, is read again through the
/// server's app RPC, which accepts only the [binding] the server signed for
/// this server and tool.
@immutable
final class OpenWebUiMcpApp {
  const OpenWebUiMcpApp({
    required this.serverId,
    required this.toolName,
    required this.binding,
    this.arguments = const <String, dynamic>{},
    this.result = const <String, dynamic>{},
  });

  final String serverId;
  final String toolName;
  final String binding;

  /// The arguments the tool was called with.
  final Map<String, dynamic> arguments;

  /// The tool's MCP `CallToolResult`, as the app receives it.
  final Map<String, dynamic> result;

  /// The app an embed names, or null for any other embed.
  static OpenWebUiMcpApp? tryParse(Object? embed) {
    if (embed is! Map || embed['type'] != 'mcp_app') return null;
    final serverId = embed['server_id'];
    final toolName = embed['tool_name'];
    final binding = embed['binding'];
    if (serverId is! String || serverId.isEmpty) return null;
    if (toolName is! String || toolName.isEmpty) return null;
    if (binding is! String || binding.isEmpty) return null;
    return OpenWebUiMcpApp(
      serverId: serverId,
      toolName: toolName,
      binding: binding,
      arguments: _stringKeyed(embed['arguments']),
      result: _stringKeyed(embed['result']),
    );
  }

  /// The apps among [embeds], in order.
  static List<OpenWebUiMcpApp> listFrom(Object? embeds) => [
    if (embeds is List)
      for (final embed in embeds) ?tryParse(embed),
  ];

  static Map<String, dynamic> _stringKeyed(Object? value) => value is Map
      ? {for (final entry in value.entries) entry.key.toString(): entry.value}
      : const <String, dynamic>{};

  /// Two calls of the same tool share a binding; an app is the same only
  /// with the same input and result too.
  @override
  bool operator ==(Object other) =>
      other is OpenWebUiMcpApp &&
      other.serverId == serverId &&
      other.toolName == toolName &&
      other.binding == binding &&
      const DeepCollectionEquality().equals(other.arguments, arguments) &&
      const DeepCollectionEquality().equals(other.result, result);

  @override
  int get hashCode => Object.hash(
    serverId,
    toolName,
    binding,
    const DeepCollectionEquality().hash(arguments),
    const DeepCollectionEquality().hash(result),
  );
}

/// What `ui/resource` answers: the app's HTML, the content security policy
/// the server built from the app's declared domains (and one more the server
/// adds for frames), the app's `ui` metadata and the tool that showed it.
///
/// The policy is what keeps the page to the domains it declared, so an app
/// the server sends none for is refused rather than shown without one.
@immutable
final class OpenWebUiMcpAppResource {
  const OpenWebUiMcpAppResource({
    required this.html,
    required this.csp,
    this.additionalCsp = '',
    this.ui = const <String, dynamic>{},
    this.tool = const <String, dynamic>{},
  });

  final String html;
  final String csp;
  final String additionalCsp;
  final Map<String, dynamic> ui;
  final Map<String, dynamic> tool;

  /// The domains the app declared, by kind (`connectDomains`,
  /// `resourceDomains`, `frameDomains`, `baseUriDomains`).
  Map<String, dynamic> get declaredCsp {
    final csp = ui['csp'];
    return csp is Map
        ? {for (final entry in csp.entries) entry.key.toString(): entry.value}
        : const <String, dynamic>{};
  }

  /// The domains of [kind] the app declared.
  List<String> declaredDomains(String kind) {
    final domains = declaredCsp[kind];
    return domains is List
        ? [for (final domain in domains) if (domain is String) domain]
        : const <String>[];
  }

  factory OpenWebUiMcpAppResource.fromJson(Map<String, dynamic> json) {
    final html = json['html'];
    if (html is! String || html.isEmpty) {
      throw const McpAppRpcException('The app sent no page.');
    }
    final csp = json['csp'];
    if (csp is! String || csp.trim().isEmpty) {
      throw const McpAppRpcException(
        'The server sent no security policy for the app.',
      );
    }
    Map<String, dynamic> map(Object? value) => value is Map
        ? {for (final entry in value.entries) entry.key.toString(): entry.value}
        : const <String, dynamic>{};
    return OpenWebUiMcpAppResource(
      html: html,
      csp: csp,
      additionalCsp: json['additional_csp'] is String
          ? json['additional_csp'] as String
          : '',
      ui: map(json['ui']),
      tool: map(json['tool']),
    );
  }
}

/// The server refused or failed an MCP App request; [message] is its reason,
/// such as "Invalid app binding. Run the tool again.".
final class McpAppRpcException implements Exception {
  const McpAppRpcException(this.message);

  final String message;

  @override
  String toString() => 'McpAppRpcException: $message';
}
