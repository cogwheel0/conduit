import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/widgets/model_selector_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _en = AppLocalizationsEn();

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _NoDrainEngine extends SyncEngine {
  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}

class _FixedPersonalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

Conversation _conversation(String id) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: 'Chat $id',
    createdAt: DateTime.utc(2026, 7, 13),
    updatedAt: DateTime.utc(2026, 7, 13),
  ),
  ChatStorageKind.openWebUi,
);

/// The Flutter reasoning picker: the sheet outlives the chat it was opened on.
void main() {
  const model = Model(id: 'gpt-5', name: 'GPT-5');
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    // Model rows draw an avatar through a cache that asks for a temp folder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await db.close();
  });

  Future<void> seed(String id) => db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Chat $id',
          createdAt: 1,
          updatedAt: 1,
          bodySynced: const Value(true),
          rawExtra: Value(jsonEncode(<String, dynamic>{})),
        ),
      );

  testWidgets(
    'a pick made after moving to another chat is saved on the chat the '
    'picker was opened for',
    (tester) async {
      await tester.runAsync(() async {
        await seed('opened-on');
        await seed('moved-to');
      });
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(
            ApiService(
              serverConfig: const ServerConfig(
                id: 'picker',
                name: 'picker',
                url: 'https://picker.example.test',
              ),
              workerManager: WorkerManager(),
            ),
          ),
          reviewerModeProvider.overrideWithValue(false),
          selectedModelProvider.overrideWithValue(model),
          activeConversationProvider.overrideWith(
            () => _SeededActive(_conversation('opened-on')),
          ),
          syncEngineProvider.overrideWith(_NoDrainEngine.new),
          personalizationSettingsProvider.overrideWith(
            _FixedPersonalization.new,
          ),
          directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'me',
              username: 'me',
              email: 'me@example.test',
              role: 'user',
            ),
          ),
          openWebUiChatSettingsAccessProvider.overrideWith(
            (ref) async => OpenWebUiChatSettingsAccess.all,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: ModelSelectorSheet(models: [model])),
          ),
        ),
      );
      // The sheet has a running animation, so it never "settles".
      Future<void> settle() => tester.pump(const Duration(milliseconds: 400));
      await settle();
      await settle();

      // Open the effort picker while "opened-on" is the chat on screen ...
      await tester.tap(find.text(_en.reasoningEffort));
      await settle();
      await settle();
      // ... the user opens another chat before choosing ...
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('moved-to'));
      await settle();
      // ... and then chooses.
      await tester.tap(find.text(_en.reasoningEffortHigh));
      await settle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle();

      final openedOn = await tester.runAsync(
        () => db.chatsDao.getChatParams('opened-on'),
      );
      final movedTo = await tester.runAsync(
        () => db.chatsDao.getChatParams('moved-to'),
      );
      expect(openedOn, {'reasoning_effort': 'high'});
      expect(movedTo, isEmpty);
    },
  );
}
