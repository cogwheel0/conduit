import 'dart:async';

import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The composer's "Compare models" command, from the overflow menu through the
/// setup sheet to the host's answer about whether the turn was admitted. What
/// the composer does with the draft depends on that answer and on who owns the
/// composer when it arrives.
///
/// Turns are admitted by the real [durableCompareSend] into an in-memory
/// database, so the committed turn, its chat and a new chat's remap to a server
/// id are what production produces. Only the server drain is held or quiet.
void main() {
  const alpha = Model(id: 'alpha', name: 'Alpha');
  const beta = Model(id: 'beta', name: 'Beta');
  const draft = 'compare this';
  final l10n = AppLocalizationsEn();

  late AppDatabase db;
  late _DrainEngine engine;
  late List<({String text, List<String> models})> sends;
  late List<String> ordinarySends;
  late _SignInEpoch signIn;
  ProviderContainer? open;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    engine = _DrainEngine();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  /// Pumps the composer on [chatId]'s page, or on a new chat when it is null.
  /// [host] replaces the real admission with a canned answer.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String? chatId = 'chat-a',
    Future<ChatSendPlaceholderHandle?> Function()? host,
    bool hostsComparison = true,
    List<Model>? savedComparison,
  }) async {
    sends = [];
    ordinarySends = [];
    if (chatId != null) {
      await tester.runAsync(() => _seedChat(db, chatId));
    }
    final container = ProviderContainer(
      overrides: [
        selectedModelProvider.overrideWith(() => _Selected(alpha)),
        activeConversationProvider.overrideWith(
          () => _Active(chatId == null ? null : _stored(chatId)),
        ),
        modelsProvider.overrideWith(() => _Models(const [alpha, beta])),
        apiServiceProvider.overrideWithValue(_api()),
        appDatabaseProvider.overrideWith((ref) => db),
        chatMessagesProvider.overrideWith(_Messages.new),
        syncEngineProvider.overrideWith(() => engine),
        reviewerModeProvider.overrideWithValue(false),
        isOnlineProvider.overrideWithValue(true),
        temporaryChatEnabledProvider.overrideWith(_NotTemporary.new),
        webSearchEnabledProvider.overrideWith(_WebSearchOff.new),
        imageGenerationEnabledProvider.overrideWith(_ImageGenerationOff.new),
        authTokenProvider3.overrideWithValue('token'),
        isAuthenticatedProvider2.overrideWithValue(true),
        appSettingsProvider.overrideWith(_AdvancedSettings.new),
        isChatStreamingProvider.overrideWithValue(false),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        comparisonCommandAvailableProvider.overrideWithValue(true),
        folderDraftComparisonModelsProvider.overrideWithValue(savedComparison),
        personalizationSettingsProvider.overrideWith(_Personalization.new),
        directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_signInEpoch),
        ),
      ],
    );
    open = container;
    signIn = container.read(_signInEpoch.notifier);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModernChatInput(
              onSendMessage: ordinarySends.add,
              onCompareSend: hostsComparison
                  ? (text, models) async {
                      sends.add((
                        text: text,
                        models: [for (final m in models) m.id],
                      ));
                      if (host != null) return host();
                      final handles = await durableCompareSend(
                        container,
                        text,
                        null,
                        models: models,
                      );
                      return handles.first;
                    }
                  : null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  /// Runs the real command: overflow menu, "Compare models", a second model in
  /// the setup sheet, then Compare. The admission is then in flight.
  Future<void> compare(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);
    await tester.tap(find.text(l10n.chatCompareModelsAction));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('comparison-slot-1')));
    await settle(tester);
    await tester.tap(find.text('Beta'));
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ElevatedButton, l10n.chatCompareStart),
    );
    await tester.pump();
  }

  /// Compares [draft] with the drain held: the turn is committed and the
  /// composer is still waiting for the host's answer.
  Future<void> compareWhileCommitting(WidgetTester tester) async {
    engine.hold();
    await tester.enterText(find.byType(TextField), draft);
    await compare(tester);
    await tester.runAsync(() => engine.reachedDrain);
    await tester.pump();
    expect(composerText(tester), draft);
  }

  Future<void> finishCommit(WidgetTester tester) async {
    engine.release();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
  }

  /// A widget test that unmounts the composer and disposes its providers before
  /// it ends: a committed turn leaves a streaming placeholder whose task poll
  /// is a timer the framework would otherwise find still pending.
  void composerTest(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      open = null;
      await body(tester);
      // Dropping the streaming placeholders and finishing the stream ends the
      // task poll they started.
      open?.read(chatMessagesProvider.notifier)
        ?..clearMessages()
        ..finishStreaming();
      await tester.pumpWidget(const SizedBox.shrink());
      open?.dispose();
    });
  }

  composerTest('a screen that cannot admit a comparison offers no Compare '
      'models command', (tester) async {
    await pump(tester, hostsComparison: false);

    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);

    expect(find.text(l10n.chatCompareModelsAction), findsNothing);
  });

  composerTest('Compare models opens a sheet, so it shows a chevron, and waits '
      'for a message before it can be chosen', (tester) async {
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);
    final row = find.ancestor(
      of: find.text(l10n.chatCompareModelsAction),
      matching: find.byType(ToggleTile),
    );
    expect(find.text(l10n.chatCompareNeedsMessage), findsOneWidget);
    expect(tester.widget<ToggleTile>(row).enabled, isFalse);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );

    // Typing a message makes it available.
    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);
    await tester.enterText(find.byType(TextField), draft);
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);
    expect(tester.widget<ToggleTile>(row).enabled, isTrue);
    expect(find.text(l10n.chatCompareModelsDescription), findsOneWidget);
  });

  composerTest('Send on a draft that starts with saved models sends to both '
      'through the comparison host', (tester) async {
    final refusal = Completer<ChatSendPlaceholderHandle?>();
    await pump(
      tester,
      host: () => refusal.future,
      savedComparison: const [alpha, beta],
    );
    await tester.enterText(find.byType(TextField), draft);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pump();

    expect(sends.single.text, draft);
    expect(sends.single.models, ['alpha', 'beta']);
    expect(ordinarySends, isEmpty);
    // The host has not committed anything, so the draft is still the user's.
    expect(composerText(tester), draft);

    refusal.complete(null);
    await settle(tester);
    expect(composerText(tester), draft);
  });

  composerTest('a screen that cannot admit a comparison sends the draft the '
      'ordinary way', (tester) async {
    await pump(
      tester,
      hostsComparison: false,
      savedComparison: const [alpha, beta],
    );
    await tester.enterText(find.byType(TextField), draft);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pump();

    expect(ordinarySends, [draft]);
    expect(sends, isEmpty);
  });

  composerTest('a refused admission keeps the draft where it was', (
    tester,
  ) async {
    final refusal = Completer<ChatSendPlaceholderHandle?>();
    await pump(tester, host: () => refusal.future);
    await tester.enterText(find.byType(TextField), draft);
    await compare(tester);

    expect(sends.single.text, draft);
    expect(sends.single.models, ['alpha', 'beta']);
    // Nothing is cleared while the host is still deciding.
    expect(composerText(tester), draft);

    refusal.complete(null);
    await settle(tester);
    expect(composerText(tester), draft);
  });

  composerTest('a chat opened while the setup sheet is showing is not sent '
      'the turn composed in the one before', (tester) async {
    final container = await pump(tester);
    await tester.enterText(find.byType(TextField), draft);
    await tester.tap(
      find.byKey(const ValueKey<String>('composer-overflow-button')),
    );
    await settle(tester);
    await tester.tap(find.text(l10n.chatCompareModelsAction));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('comparison-slot-1')));
    await settle(tester);
    await tester.tap(find.text('Beta'));
    await settle(tester);

    container.read(activeConversationProvider.notifier).set(_stored('chat-b'));
    await tester.tap(
      find.widgetWithText(ElevatedButton, l10n.chatCompareStart),
    );
    await settle(tester);

    expect(sends, isEmpty);
    expect(composerText(tester), draft);
  });

  composerTest('a committed turn clears the draft', (tester) async {
    await pump(tester);
    await compareWhileCommitting(tester);

    await finishCommit(tester);

    expect(composerText(tester), isEmpty);
  });

  composerTest('a committed new chat clears the draft', (tester) async {
    final container = await pump(tester, chatId: null);
    await compareWhileCommitting(tester);

    // The chat did not exist when the command started; the turn made it.
    expect(
      container.read(activeConversationProvider)?.id,
      startsWith('local:'),
    );
    await finishCommit(tester);

    expect(composerText(tester), isEmpty);
  });

  composerTest('a new chat the server has since given its own id still counts '
      'as the chat the turn is in', (tester) async {
    engine.remapActiveChatTo = 'server-chat';
    final container = await pump(tester, chatId: null);
    await compareWhileCommitting(tester);

    await finishCommit(tester);

    expect(container.read(activeConversationProvider)?.id, 'server-chat');
    expect(composerText(tester), isEmpty);
  });

  composerTest('text typed while the turn is admitted is a newer draft and '
      'survives the commit', (tester) async {
    await pump(tester);
    await compareWhileCommitting(tester);

    await tester.enterText(find.byType(TextField), 'something else entirely');
    await finishCommit(tester);

    expect(composerText(tester), 'something else entirely');
  });

  composerTest('a draft edited and then typed back to the sent text is still '
      'a newer draft', (tester) async {
    await pump(tester);
    await compareWhileCommitting(tester);

    await tester.enterText(find.byType(TextField), 'a newer draft');
    await tester.enterText(find.byType(TextField), draft);
    await finishCommit(tester);

    expect(composerText(tester), draft);
  });

  composerTest('a result that arrives after the account changed never clears '
      'the new account\'s composer', (tester) async {
    await pump(tester);
    await compareWhileCommitting(tester);

    signIn.rotate();
    await tester.pump();
    await tester.enterText(find.byType(TextField), draft);
    await finishCommit(tester);

    expect(composerText(tester), draft);
  });

  composerTest('a result that arrives after another chat opened with the same '
      'text never clears that chat\'s composer', (tester) async {
    final container = await pump(tester);
    await compareWhileCommitting(tester);

    container.read(activeConversationProvider.notifier).set(_stored('chat-b'));
    await tester.pump();
    await finishCommit(tester);

    // The composer still holds the text it was sent with, now in chat B.
    expect(composerText(tester), draft);
  });

  composerTest('a new chat the user left before the turn finished does not '
      'clear the chat they moved to', (tester) async {
    final container = await pump(tester, chatId: null);
    await compareWhileCommitting(tester);

    container.read(activeConversationProvider.notifier).set(_stored('chat-b'));
    await tester.pump();
    await finishCommit(tester);

    expect(composerText(tester), draft);
  });
}

Conversation _stored(String id) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: id,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  ChatStorageKind.openWebUi,
);

Future<void> _seedChat(AppDatabase db, String id) => db
    .into(db.chats)
    .insert(
      ChatsCompanion.insert(
        id: id,
        title: id,
        createdAt: 1,
        updatedAt: 1,
        bodySynced: const Value(true),
      ),
    );

ApiService _api() => _QuietApi(
  serverConfig: const ServerConfig(
    id: 'compare-composer',
    name: 'compare-composer',
    url: 'https://compare.example.test',
  ),
  workerManager: WorkerManager(),
);

/// Answers the settings read an admission makes, without a network.
final class _QuietApi extends ApiService {
  _QuietApi({required super.serverConfig, required super.workerManager});

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      const <String, dynamic>{};
}

/// The server drain that follows a commit. It sends nothing; it can be held,
/// which keeps the turn committed and the host's answer pending, and it can
/// remap the new chat to a server id the way the real drain does once the
/// server has created the chat.
final class _DrainEngine extends SyncEngine {
  Completer<void>? _gate;
  final Completer<void> _reached = Completer<void>();
  String? remapActiveChatTo;

  Future<void> get reachedDrain => _reached.future;

  void hold() => _gate = Completer<void>();

  void release() => _gate?.complete();

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    final remapTo = remapActiveChatTo;
    final active = ref.read(activeConversationProvider);
    if (remapTo != null && active != null && active.id.startsWith('local:')) {
      ref
          .read(activeConversationProvider.notifier)
          .remapIdInPlace(fromId: active.id, toId: remapTo);
    }
    if (!_reached.isCompleted) _reached.complete();
    await _gate?.future;
  }
}

final class _Selected extends SelectedModel {
  _Selected(this.model);

  final Model model;

  @override
  Model build() => model;
}

final class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

final class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

final class _NotTemporary extends TemporaryChatEnabled {
  @override
  bool build() => false;
}

final class _WebSearchOff extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

final class _ImageGenerationOff extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

final class _Models extends Models {
  _Models(this.listed);

  final List<Model> listed;

  @override
  Future<List<Model>> build() async => listed;
}

final class _AdvancedSettings extends AppSettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(sendOnEnter: true, advancedFeaturesEnabled: true);
}

final class _Personalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

final class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

/// A new sign-in session: another account, or the same one signing back in.
final class _SignInEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

final _signInEpoch = NotifierProvider<_SignInEpoch, Object>(_SignInEpoch.new);
