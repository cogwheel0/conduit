import 'dart:convert';

import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';

/// The page an MCP App runs as: the host's tags first, as in Open WebUI's
/// web client, then the app's own HTML.
///
/// The host's tags turn DNS prefetching off, carry the content security
/// policy the server built from the app's declared domains (and the one
/// more it adds for frames), fit the page to its view and hide scroll
/// bars. An app that opens with a doctype keeps it first, so it is laid out
/// in standards mode as written; one without stays in quirks mode, as in
/// the web client.
String mcpAppPageDocument(OpenWebUiMcpAppResource resource) {
  String csp(String policy) => policy.trim().isEmpty
      ? ''
      : '<meta http-equiv="Content-Security-Policy" '
            'content="${const HtmlEscape(HtmlEscapeMode.attribute).convert(policy)}">';
  final doctype = _leadingDoctype.firstMatch(resource.html);
  final page = doctype == null
      ? resource.html
      : resource.html.substring(doctype.end);
  return '${doctype?.group(1) ?? ''}'
      '<meta http-equiv="X-DNS-Prefetch-Control" content="off">'
      '${csp(resource.csp)}${csp(resource.additionalCsp)}'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>*{scrollbar-width:none}::-webkit-scrollbar{display:none}</style>'
      '$page';
}

// Comments may come before the doctype and it still counts, so they move
// with it.
final RegExp _leadingDoctype = RegExp(
  r'^(\s*(?:<!--[\s\S]*?-->\s*)*<!doctype[^>]*>)',
  caseSensitive: false,
);
