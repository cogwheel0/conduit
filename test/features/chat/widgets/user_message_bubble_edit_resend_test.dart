import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

/// Holds the send's first outbox write so the test can unmount the edited
/// bubble while the send is still in flight, as a slow disk would.
class _GateOutboxEnqueue extends QueryInterceptor {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _gated = false;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (!_gated && statement.contains('outbox_ops')) {
      _gated = true;
      started.complete();
      await release.future;
    }
    return executor.runInsert(statement, args);
  }
}

/// Records the databases the send asked the engine to drain.
final class _RecordingSyncEngine extends SyncEngine {
  final List<AppDatabase> drained = <AppDatabase>[];

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    drained.add(expectedDatabase);
  }
}

/// Shows a bubble for every user message in the transcript, as the chat page
/// does, so resending an edit unmounts the bubble that started it.
class _Transcript extends ConsumerWidget {
  const _Transcript();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatMessagesProvider);
    return Column(
      children: [
        for (final message in messages.where((m) => m.role == 'user'))
          UserMessageBubble(
            key: ValueKey(message.id),
            message: message,
            isUser: true,
            onDelete: () {},
          ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'resending an edited message drains the outbox after its bubble is gone',
    (tester) async {
      final gate = _GateOutboxEnqueue();
      final db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
      addTearDown(db.close);
      const model = Model(id: 'server-model', name: 'Server model');
      final user = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Original prompt',
        timestamp: DateTime.utc(2026, 9, 30),
        metadata: const {
          'parentId': null,
          'childrenIds': <String>['assistant-1'],
        },
      );
      final assistant = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Original answer',
        timestamp: DateTime.utc(2026, 9, 30, 0, 1),
        model: model.id,
        metadata: const {'parentId': 'user-1', 'childrenIds': <String>[]},
      );
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'server-chat',
        blob: {
          'title': 'Edit me',
          'models': [model.id],
          'history': {
            'currentId': 'assistant-1',
            'messages': {
              'user-1': {
                'id': 'user-1',
                'parentId': null,
                'childrenIds': ['assistant-1'],
                'role': 'user',
                'content': 'Original prompt',
                'timestamp': 1,
              },
              'assistant-1': {
                'id': 'assistant-1',
                'parentId': 'user-1',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': 'Original answer',
                'model': model.id,
                'timestamp': 2,
              },
            },
          },
        },
        title: 'Edit me',
        createdAt: 1,
        updatedAt: 2,
      );
      await tester.runAsync(() => db.chatsDao.upsertLocalOnlyChat(rows: rows));

      final engine = _RecordingSyncEngine();
      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(_ActiveConversation.new),
          selectedModelProvider.overrideWithValue(model),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(null),
          socketServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(db),
          syncEngineProvider.overrideWith(() => engine),
        ],
      );
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      container
          .read(activeConversationProvider.notifier)
          .set(
            Conversation(
              id: 'server-chat',
              title: 'Edit me',
              createdAt: DateTime.utc(2026, 9, 30),
              updatedAt: DateTime.utc(2026, 9, 30),
              model: model.id,
              messages: [user, assistant],
            ),
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: _Transcript()),
          ),
        ),
      );
      await tester.pump();

      final menu = tester.widget<ConduitContextMenu>(
        find.byType(ConduitContextMenu),
      );
      await menu.actions.first.onSelected();
      await tester.pump();
      await tester.enterText(find.byType(AdaptiveTextField), 'Edited prompt');
      await tester.tap(find.text('Save'));
      // The send is parked on its outbox write. The frame that unmounts the
      // edited bubble comes now; only then does the write finish.
      await tester.runAsync(() => gate.started.future);
      await tester.pump();
      check(find.byKey(const ValueKey('user-1')).evaluate()).isEmpty();
      gate.release.complete();
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && engine.drained.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });

      // The edited bubble is gone: the transcript now holds the resent turn.
      check(find.byKey(const ValueKey('user-1')).evaluate()).isEmpty();
      check(container.read(chatMessagesProvider).map((m) => m.content))
          .contains('Edited prompt');
      // The completion op was queued and the engine was asked to run it now,
      // instead of leaving it for the next periodic sync.
      final pending = await tester.runAsync(
        () => db.outboxDao.pendingForChat('server-chat'),
      );
      check(pending).isNotNull().isNotEmpty();
      check(engine.drained).deepEquals([db]);

      // Release the streaming placeholder's poll timer with the scope.
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
