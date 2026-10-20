import 'package:conduit/features/chat/widgets/openwebui_task_list.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/native.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'server checklist survives reload, updates statuses, and clears on chat changes',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final response = <String, dynamic>{
        'id': 'chat-1',
        'title': 'Tasks',
        'tasks': [
          {'id': '1', 'content': 'Read references', 'status': 'completed'},
          {'id': '2', 'content': 'Check findings', 'status': 'in_progress'},
          {'id': '3', 'content': 'Write report', 'status': 'pending'},
          {'id': '4', 'content': 'Optional appendix', 'status': 'cancelled'},
        ],
        'created_at': 1,
        'updated_at': 1,
        'meta': {
          'tags': ['verification'],
        },
        'chat': {'messages': []},
      };
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final pull = PullSync(
        client: _ChecklistClient(response),
        db: db,
        locks: ConversationLocks(),
      );
      await tester.runAsync(() => pull.pullChat('chat-1'));
      final loaded = (await tester.runAsync(() async {
        final row = (await db.chatsDao.getChat('chat-1'))!;
        final messages = await db.messagesDao.getForChat('chat-1');
        final envelope = buildChatResponseEnvelope(row, messages);
        expect(envelope['meta'], {
          'tags': ['verification'],
        });
        expect((envelope['chat'] as Map).containsKey('tasks'), isFalse);
        return assembleConversation(row, messages);
      }))!;
      final active = container.read(activeConversationProvider.notifier);
      active.set(loaded);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: OpenWebUiTaskList(
                  keyboardVisible: MediaQuery.viewInsetsOf(context).bottom > 0,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Tasks: 1 of 4 completed'), findsOneWidget);
      await tester.tap(find.text('Tasks: 1 of 4 completed'));
      await tester.pumpAndSettle();
      expect(find.text('Read references'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 350);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks: 1 of 4 completed'));
      await tester.pumpAndSettle();
      // Tasks can change without the server bumping the chat body timestamp.
      response['tasks'] = [
        {'id': '2', 'content': 'Check findings', 'status': 'completed'},
      ];
      active.set(
        (await tester.runAsync(() async => (await pull.pullChat('chat-1'))!))!,
      );
      await tester.pumpAndSettle();
      expect(find.text('Tasks: 1 of 1 completed'), findsOneWidget);
      expect(find.text('Read references'), findsNothing);
      expect(find.text('Completed'), findsOneWidget);
      active.set(loaded.copyWith(id: 'chat-2', metadata: {}));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      response.remove('tasks');
      response.remove('meta');
      await tester.runAsync(() => pull.pullChat('chat-1'));
      final retained = (await tester.runAsync(
        () async => (await db.chatsDao.getChat('chat-1'))!,
      ))!;
      final retainedEnvelope = buildChatResponseEnvelope(retained, const []);
      expect(retainedEnvelope['meta'], {
        'tags': ['verification'],
      });
      expect((retainedEnvelope['tasks'] as List).single['status'], 'completed');
      response['tasks'] = [];
      active.set(
        (await tester.runAsync(() async => (await pull.pullChat('chat-1'))!))!,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
    },
  );
}

class _ChecklistClient extends FakeSyncApiClient {
  _ChecklistClient(this.response) : super(FakeOpenWebUiServer());

  final Map<String, dynamic> response;

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async => response;
}
