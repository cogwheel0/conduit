import 'dart:async';

import 'package:conduit/features/chat/providers/composer_draft_provider.dart';
import 'package:conduit/features/chat/widgets/composer_recordings.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_database.dart';

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  const channel = MethodChannel('app.cogwheel.conduit/native_stt');
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  testWidgets('sending audio retires its pending retry and ignores late text', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = ComposerDraftStore(db);
    final ComposerDraftContext owner = (
      owner: (
        backend: 'account',
        account: 'sample',
        principal: 'reader',
        session: null,
      ),
      scope: 'chat',
      chatId: 'tiles',
      store: store,
      temporary: false,
    );
    final replies = <Completer<String>>[];
    final cancelled = <String>[];
    final inserted = <String>[];
    final busy = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cancelRecordingTranscription') {
        cancelled.add((call.arguments as Map)['requestId'] as String);
        return null;
      }
      final reply = Completer<String>();
      replies.add(reply);
      return reply.future;
    });
    final container = ProviderContainer(
      overrides: [
        composerDraftContextProvider.overrideWithValue(owner),
        appSettingsProvider.overrideWith(_Settings.new),
        serverSpeechProviderProvider.overrideWithValue(null),
      ],
    );
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> add(String id) => pumpDatabaseOperation(tester, () async {
      final writer = await store.recordings.begin(
        id: id,
        scope: 'chat',
        chatId: 'tiles',
        onFailure: () => fail('Save failed'),
      );
      writer.add(Uint8List.fromList([1, 0, 2, 0]));
      await writer.close();
    });
    try {
      await pumpDatabaseOperation(
        tester,
        () => db
            .into(db.chats)
            .insert(
              ChatsCompanion.insert(
                id: 'tiles',
                title: 'Tiles',
                createdAt: 1,
                updatedAt: 1,
              ),
            ),
      );
      await add('first');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ComposerRecordings(
                owner: owner,
                onInsert: inserted.add,
                onTranscribingChanged: (_, value) => busy.add(value),
              ),
            ),
          ),
        ),
      );
      await settle();
      Future<void> retry() async {
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Transcribe on device').last);
        await settle();
      }

      await retry();
      expect(replies, hasLength(1));
      await pumpDatabaseOperation(
        tester,
        () => store.recordings.discard('first'),
      );
      await settle();
      expect(cancelled, hasLength(1));
      await add('second');
      await settle();
      await retry();
      expect(replies, hasLength(2));
      replies.first.complete('retired text');
      await settle();
      expect(find.text('retired text'), findsNothing);
      // The retired completion must not clear the second attempt's busy state.
      expect(find.byType(AdaptiveProgressIndicator), findsOneWidget);
      replies.last.complete('four amber tiles');
      await settle();
      expect(inserted, ['four amber tiles']);
      expect(busy, [true, false, true, false]);
      expect(find.text('Insert transcription'), findsNothing);
      await pumpDatabaseOperation(
        tester,
        () => store.recordings.discard('second'),
      );
      await settle();
      expect(find.text('four amber tiles'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump();
      await pumpDatabaseOperation(tester, db.close);
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
