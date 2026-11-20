/// What the user's own devices offer an Open WebUI server through Tether
/// (0.13.4 and later), as the server lists it among its own models, tools
/// and terminals.
library;

import 'package:conduit_core/models/chat_message.dart'
    show kCompletionViaTetherKey;
import 'package:conduit_core/models/model.dart';

/// The device and connection a model comes from (`Studio Mac · Lab`), when
/// one of the user's devices offers it; null for every other model.
///
/// Open WebUI marks such a model with a `tether://<device>` base URL and
/// tags it with that label. Its `connection_type` is `local`, as the
/// server's own connections can be too, so that says nothing here.
String? tetherModelDeviceTag(Model model) {
  if (!isTetherModel(model)) return null;
  final tags = model.metadata?['tags'];
  if (tags is! List) return null;
  for (final tag in tags) {
    final name = (tag is Map ? tag['name'] : tag)?.toString().trim();
    if (name != null && name.isNotEmpty) return name;
  }
  return null;
}

/// Whether one of the user's devices offers [model]: Open WebUI gives it a
/// `tether://<device>` base URL.
bool isTetherModel(Model? model) {
  final baseUrl = model?.metadata?['base_url'];
  return baseUrl is String && baseUrl.startsWith(kTetherUrlScheme);
}

/// What an answer records, in its `metadata`, when its request is made to
/// [model]: that one of the user's devices offers it
/// ([kCompletionViaTetherKey]), or nothing.
Map<String, dynamic> tetherAnswerRecord(Model? model) => isTetherModel(model)
    ? const <String, dynamic>{kCompletionViaTetherKey: true}
    : const <String, dynamic>{};

/// The scheme of the address Open WebUI gives a device's connection.
const String kTetherUrlScheme = 'tether://';

/// Whether [toolId] names an OpenAPI or MCP tool server one of the user's
/// devices offers (`server:tether:…`, `server:mcp:tether:…`).
bool isTetherToolId(String toolId) =>
    toolId.startsWith('server:tether:') ||
    toolId.startsWith('server:mcp:tether:');

/// Whether [terminalId], a server terminal's id, names one of the user's
/// devices (`tether:<device>` or `tether:<device>:<service>`).
bool isTetherTerminalId(String? terminalId) =>
    terminalId != null && terminalId.startsWith('tether:');
