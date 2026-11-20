import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/providers/knowledge_cache_provider.dart';
import 'package:conduit_core/models/knowledge_base.dart';
import 'package:conduit_core/models/knowledge_base_file.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _empty = KnowledgeBase(
  id: 'base-garden',
  name: 'Garden Notes',
  description: 'Planting dates',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
);

void main() {
  // A base is attached whole without choosing any of its files, so it can be
  // attached however many files it has, none included. A failed file list
  // is stored as an empty one, which hid the row too.
  testWidgets('a knowledge base with no files can still be attached whole', (
    tester,
  ) async {
    final container = await _pumpComposer(tester);

    await tester.enterText(find.byType(TextField), '#');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.text('Browse Knowledge Base'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garden Notes'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Entire Knowledge Base'));
    await tester.pumpAndSettle();

    final attached = container.read(contextAttachmentsProvider).single;
    expect(attached.isKnowledgeBase, isTrue);
    expect(attached.id, 'base-garden');
    expect(find.text('Entire Knowledge Base'), findsNothing);
  });
}

Future<ProviderContainer> _pumpComposer(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedModelProvider.overrideWith(_SelectedServerModel.new),
        apiServiceProvider.overrideWithValue(_SearchlessApi()),
        authTokenProvider3.overrideWithValue('token'),
        isAuthenticatedProvider2.overrideWithValue(true),
        isChatStreamingProvider.overrideWithValue(false),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        knowledgeCacheProvider.overrideWith(_OneEmptyBase.new),
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ModernChatInput(onSendMessage: (_) {})),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
}

final class _SelectedServerModel extends SelectedModel {
  @override
  Model build() => const Model(id: 'server-model', name: 'Server Model');
}

/// One base, whose file list came back empty.
final class _OneEmptyBase extends KnowledgeCacheNotifier {
  @override
  KnowledgeCacheState build() => KnowledgeCacheState(
    bases: [_empty],
    files: {_empty.id: const <KnowledgeBaseFile>[]},
  );

  @override
  Future<void> ensureBases() async {}

  @override
  Future<void> fetchFilesForBase(String baseId) async {}
}

/// Finds nothing for `#`, so the composer offers to browse the bases.
final class _SearchlessApi extends ApiService {
  _SearchlessApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};

  @override
  Future<List<Map<String, dynamic>>> searchNotes({
    String? query,
    int? page,
  }) async => const [];

  @override
  Future<List<Map<String, dynamic>>> searchKnowledgeBases({
    String? query,
    String? viewOption,
    int? page,
  }) async => const [];

  @override
  Future<List<Map<String, dynamic>>> searchKnowledgeFiles({
    String? query,
    String? viewOption,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async => const [];
}
