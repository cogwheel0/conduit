import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'settled.dart';

/// Implements `composer.*`: what the composer may offer (WP-3.3).
///
/// The rules are the core's `webSearchAvailableProvider` and
/// `imageGenerationAvailableProvider`, the same ones mobile reads. Those
/// providers are synchronous views over asynchronous sources: the backend
/// config, the account's permissions, the model list. A cold read would see
/// every source still loading, and each provider's own fallback for
/// "loading" would decide the answer. So the sources are awaited first.
final class ComposerService {
  ComposerService(this._container);

  final ProviderContainer _container;

  Future<ComposerOptions> options() async {
    await Future.wait<Object?>(<Future<Object?>>[
      _settle(backendConfigProvider.future),
      _settle(userPermissionsProvider.future),
      _settle(modelsProvider.future),
    ]);

    List<ToolSummary> tools;
    try {
      final all = await readSettled(_container, toolsListProvider.future);
      tools = <ToolSummary>[
        for (final tool in all)
          ToolSummary(
            id: tool.id,
            name: tool.name,
            description: tool.description,
          ),
      ];
    } on Object catch (error) {
      // A server with no tools, or none this account may use, should
      // leave the picker empty rather than break the composer.
      DebugLogger.error('tools-failed', scope: 'daemon/composer', error: error);
      tools = const <ToolSummary>[];
    }

    // Listed without connecting to them: opening every server to count
    // its tools would make the composer wait on the slowest one.
    var mcpTools = const <ToolSummary>[];
    try {
      final servers = await readSettled(
        _container,
        directMcpServersProvider.future,
      );
      mcpTools = <ToolSummary>[
        for (final server in servers)
          if (server.enabled)
            ToolSummary(
              id: '$kDirectMcpToolIdPrefix${server.id}',
              name: server.name,
              description: Uri.tryParse(server.endpoint)?.host,
            ),
      ];
    } on Object catch (error) {
      DebugLogger.error('mcp-failed', scope: 'daemon/composer', error: error);
    }

    return ComposerOptions(
      webSearch: _container.read(webSearchAvailableProvider),
      imageGeneration: _container.read(imageGenerationAvailableProvider),
      tools: tools,
      mcpTools: mcpTools,
    );
  }

  /// Knowledge bases matching [query], for the `#` menu (WP-3.3).
  Future<KnowledgeList> knowledge(String query) async {
    final api = _container.read(apiServiceProvider);
    if (api == null) return const KnowledgeList();
    final rows = await api.searchKnowledgeBases(query: query.trim());
    return KnowledgeList(
      items: <KnowledgeSummary>[
        for (final row in rows)
          if (row['id'] != null)
            KnowledgeSummary(
              id: '${row['id']}',
              name: '${row['name'] ?? row['id']}',
              description:
                  (row['description'] as String?)?.trim().isEmpty ?? true
                  ? null
                  : row['description'] as String,
            ),
      ],
    );
  }

  /// Waits for a source, and lets it fail. The availability rules have
  /// their own answer for a source that errored, and that answer is the
  /// one to use.
  Future<Object?> _settle<T>(ProviderListenable<Future<T>> provider) =>
      readSettled<T>(
        _container,
        provider,
      ).then<Object?>((value) => value, onError: (Object _) => null);
}
