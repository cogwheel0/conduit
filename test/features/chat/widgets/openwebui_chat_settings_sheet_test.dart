import 'dart:convert';

import 'package:conduit/features/chat/widgets/openwebui_chat_settings_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

class _Settings extends AppSettingsNotifier {
  _Settings({required this.advanced});

  final bool advanced;
  final turnedOn = <bool>[];

  @override
  AppSettings build() => AppSettings(advancedFeaturesEnabled: advanced);

  @override
  Future<void> setAdvancedFeaturesEnabled(bool value) async {
    turnedOn.add(value);
    state = state.copyWith(advancedFeaturesEnabled: value);
  }
}

ApiService _api(String id) => ApiService(
  serverConfig: ServerConfig(id: id, name: id, url: 'https://$id.example.test'),
  workerManager: WorkerManager(),
);

const _phone = Size(390, 844);
const _keyboardHeight = 336.0;

const _model = Model(id: 'gpt-5', name: 'GPT-5');
const _plainModel = Model(id: 'plain-chat-model', name: 'Plain');

Conversation _conversation(String id, {Map<String, dynamic>? chatParams}) =>
    withChatStorageProvenance(
      Conversation(
        id: id,
        title: 'Chat',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
        chatParams: chatParams ?? const {},
      ),
      ChatStorageKind.openWebUi,
    );

void main() {
  late AppDatabase db;
  late _Settings settings;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed(String id, Map<String, dynamic> params) => db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Chat',
          createdAt: 1,
          updatedAt: 1,
          bodySynced: const Value(true),
          rawExtra: Value(
            jsonEncode(<String, dynamic>{
              'params': params,
              'tags': <String>['keep'],
            }),
          ),
        ),
      );

  Future<Map<String, dynamic>?> stored(WidgetTester tester, String id) async =>
      await tester.runAsync<Map<String, dynamic>?>(
        () => db.chatsDao.getChatParams(id),
      );

  /// Real database work completes outside the test's fake clock.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Future<ProviderContainer> openSheet(
    WidgetTester tester, {
    Conversation? active,
    OpenWebUiChatSettingsAccess access = OpenWebUiChatSettingsAccess.all,
    Model model = _model,
    bool advanced = true,
    bool native = false,
  }) async {
    if (native) {
      // The presenter iOS 26 devices use: CNBottomSheet supplies Flutter's
      // own Material, not the material_ui one these controls look up.
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
      tester.view.physicalSize = _phone;
      tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
    } else {
      // Tall enough that the lazy list builds every field, so a test does not
      // depend on where the list happens to be scrolled.
      tester.view.physicalSize = const Size(800, 4000);
    }
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    settings = _Settings(advanced: advanced);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(_api('sheet')),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWithValue(model),
        activeConversationProvider.overrideWith(() => _SeededActive(active)),
        syncEngineProvider.overrideWith(_NoDrainEngine.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        openWebUiChatSettingsAccessProvider.overrideWith((ref) async => access),
        appSettingsProvider.overrideWith(() => settings),
      ],
    );
    addTearDown(container.dispose);
    // The app resolves permissions long before the menu can be opened.
    container.listen(openWebUiChatSettingsAccessProvider, (_, _) {});
    await container.read(openWebUiChatSettingsAccessProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () => showOpenWebUiChatSettings(context, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Finder field(String key) => find.byKey(ValueKey('chat-setting-$key'));
  Finder saveButton() => find.byKey(const ValueKey('chat-settings-save'));

  Future<void> typeInto(WidgetTester tester, Finder finder, String text) async {
    await tester.enterText(
      find.descendant(of: finder, matching: find.byType(EditableText)),
      text,
    );
    await tester.pump();
  }

  bool saveEnabled(WidgetTester tester) {
    final native = find.descendant(
      of: saveButton(),
      matching: find.byType(CNButton),
    );
    if (native.evaluate().isNotEmpty) {
      return tester.widget<CNButton>(native).onPressed != null;
    }
    final button = tester.widget<ElevatedButton>(
      find.descendant(
        of: saveButton(),
        matching: find.byWidgetPredicate((w) => w is ElevatedButton),
      ),
    );
    return button.onPressed != null;
  }

  /// The software keyboard, as the engine reports it: it covers the bottom of
  /// the view and takes the home-indicator inset with it.
  void keyboard(WidgetTester tester, {required bool up}) {
    tester.view.viewInsets = FakeViewPadding(bottom: up ? _keyboardHeight : 0);
    tester.view.padding = FakeViewPadding(top: 62, bottom: up ? 0 : 34);
  }

  /// Scrolls the sheet's own list until [target] is on screen, above the
  /// keyboard when it is up.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    final keyboardTop =
        tester.view.physicalSize.height - tester.view.viewInsets.bottom;
    expect(tester.getBottomLeft(target).dy, lessThanOrEqualTo(keyboardTop));
  }

  group('editing a stored chat', () {
    testWidgets('changing one setting saves exactly that one', (tester) async {
      await tester.runAsync(
        () => seed('c1', {
          'temperature': 0.2,
          'top_p': 0.9,
          'system': 'Keep me',
          'custom_params': {'k': 1},
        }),
      );
      final c = await openSheet(
        tester,
        active: _conversation(
          'c1',
          chatParams: {
            'temperature': 0.2,
            'top_p': 0.9,
            'system': 'Keep me',
            'custom_params': {'k': 1},
          },
        ),
      );

      await typeInto(tester, field('temperature'), '0.8');
      await tester.tap(saveButton());
      await settle(tester);

      expect((await stored(tester, 'c1'))!['temperature'], 0.8);
      expect((await stored(tester, 'c1'))!['top_p'], 0.9);
      expect((await stored(tester, 'c1'))!['system'], 'Keep me');
      expect((await stored(tester, 'c1'))!['custom_params'], {'k': 1});
      expect(find.text(_en.chatSettingsTitle), findsNothing);
      expect(
        c.read(activeConversationProvider)!.chatParams['temperature'],
        0.8,
      );
      final ops = await tester.runAsync(
        () => db.outboxDao.pendingForChat('c1'),
      );
      expect(ops!.map((op) => op.kind), ['updateChat']);
    });

    testWidgets('reset restores inheritance and leaves hidden params alone', (
      tester,
    ) async {
      final params = {
        'temperature': 0.2,
        'top_p': 0.9,
        'num_gpu': 3,
        'custom_params': {'k': 1},
      };
      await tester.runAsync(() => seed('c1', params));
      await openSheet(tester, active: _conversation('c1', chatParams: params));

      await tester.tap(
        find.byKey(const ValueKey('chat-setting-reset-temperature')),
      );
      await tester.pump();
      await tester.tap(saveButton());
      await settle(tester);

      final saved = (await stored(tester, 'c1'))!;
      expect(saved.containsKey('temperature'), isFalse);
      expect(saved['top_p'], 0.9);
      expect(saved['num_gpu'], 3);
      expect(saved['custom_params'], {'k': 1});
    });

    testWidgets('reset all removes what the editor knows and nothing else', (
      tester,
    ) async {
      final params = {
        'system': 'S',
        'temperature': 0.2,
        'seed': 4,
        'num_gpu': 3,
        'custom_params': {'k': 1},
      };
      await tester.runAsync(() => seed('c1', params));
      await openSheet(tester, active: _conversation('c1', chatParams: params));

      await tester.tap(find.byKey(const ValueKey('chat-settings-reset-all')));
      await tester.pump();
      await tester.tap(saveButton());
      await settle(tester);

      expect(await stored(tester, 'c1'), {
        'num_gpu': 3,
        'custom_params': {'k': 1},
      });
    });

    testWidgets('an unreadable-to-the-editor value is kept, and noted', (
      tester,
    ) async {
      final params = {'temperature': 'hot', 'num_gpu': 3};
      await tester.runAsync(() => seed('c1', params));
      await openSheet(tester, active: _conversation('c1', chatParams: params));

      expect(find.text(_en.chatSettingsOtherKept), findsOneWidget);
      // Opening and changing nothing is not even saveable.
      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('closing without saving changes nothing', (tester) async {
      final params = {'temperature': 0.2};
      await tester.runAsync(() => seed('c1', params));
      await openSheet(tester, active: _conversation('c1', chatParams: params));

      await typeInto(tester, field('temperature'), '1.5');
      await tester.tap(find.byKey(const ValueKey('chat-settings-cancel')));
      await settle(tester);

      expect(await stored(tester, 'c1'), {'temperature': 0.2});
      final ops = await tester.runAsync(
        () => db.outboxDao.pendingForChat('c1'),
      );
      expect(ops, isEmpty);
    });
  });

  group('validation', () {
    testWidgets('a bad number shows why and cannot be saved', (tester) async {
      await tester.runAsync(() => seed('c1', {}));
      await openSheet(tester, active: _conversation('c1'));

      await typeInto(tester, field('temperature'), '3');

      expect(find.text(_en.chatSettingErrorRange('0', '2')), findsOneWidget);
      expect(saveEnabled(tester), isFalse);

      await typeInto(tester, field('seed'), '1.5');
      expect(find.text(_en.chatSettingErrorNotAWholeNumber), findsOneWidget);

      await typeInto(tester, field('max_tokens'), '0');
      expect(find.text(_en.chatSettingErrorMinimum('1')), findsOneWidget);

      await typeInto(tester, field('temperature'), '1');
      await typeInto(tester, field('seed'), '5');
      await typeInto(tester, field('max_tokens'), '10');
      expect(saveEnabled(tester), isTrue);
      expect(await stored(tester, 'c1'), isEmpty);
    });
  });

  group('system prompt', () {
    testWidgets(
      'an empty custom prompt is saved as an explicit empty override',
      (tester) async {
        await tester.runAsync(() => seed('c1', {}));
        await openSheet(tester, active: _conversation('c1'));

        await tester.tap(
          find.byKey(const ValueKey('chat-settings-system-custom')),
        );
        await tester.pump();
        // The consequence is spelled out before anything is saved.
        expect(
          find.byKey(const ValueKey('chat-settings-system-empty-note')),
          findsOneWidget,
        );
        expect(
          find.text(_en.chatSettingsSystemPromptEmptyNote),
          findsOneWidget,
        );
        await tester.tap(saveButton());
        await settle(tester);

        final saved = (await stored(tester, 'c1'))!;
        expect(saved.containsKey('system'), isTrue);
        expect(saved['system'], '');
      },
    );

    testWidgets('Inherit removes the override instead of saving an empty one', (
      tester,
    ) async {
      final params = {'system': 'Be brief.'};
      await tester.runAsync(() => seed('c1', params));
      await openSheet(tester, active: _conversation('c1', chatParams: params));

      await tester.tap(
        find.byKey(const ValueKey('chat-settings-system-inherit')),
      );
      await tester.pump();
      await tester.tap(saveButton());
      await settle(tester);

      expect((await stored(tester, 'c1'))!.containsKey('system'), isFalse);
    });

    testWidgets('typing a prompt saves it', (tester) async {
      await tester.runAsync(() => seed('c1', {}));
      await openSheet(tester, active: _conversation('c1'));

      await tester.tap(
        find.byKey(const ValueKey('chat-settings-system-custom')),
      );
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('chat-settings-system-field')),
          matching: find.byType(TextField),
        ),
        'Answer in French.',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-settings-system-empty-note')),
        findsNothing,
      );
      await tester.tap(saveButton());
      await settle(tester);

      expect((await stored(tester, 'c1'))!['system'], 'Answer in French.');
    });
  });

  group('choices', () {
    testWidgets('reasoning effort and tool calling save their picks', (
      tester,
    ) async {
      await tester.runAsync(() => seed('c1', {}));
      await openSheet(tester, active: _conversation('c1'));

      await tester.ensureVisible(
        find.byKey(const ValueKey('chat-setting-reasoning_effort-high')),
      );
      await tester.tap(
        find.byKey(const ValueKey('chat-setting-reasoning_effort-high')),
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('chat-setting-function_calling-native')),
      );
      await tester.tap(
        find.byKey(const ValueKey('chat-setting-function_calling-native')),
      );
      await tester.pump();
      await tester.tap(saveButton());
      await settle(tester);

      final saved = (await stored(tester, 'c1'))!;
      expect(saved['reasoning_effort'], 'high');
      expect(saved['function_calling'], 'native');
    });

    testWidgets('a model without reasoning support has no effort control', (
      tester,
    ) async {
      await tester.runAsync(() => seed('c1', {}));
      await openSheet(tester, active: _conversation('c1'), model: _plainModel);

      expect(
        find.byKey(const ValueKey('chat-setting-reasoning_effort-high')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('chat-setting-function_calling-native')),
        findsOneWidget,
      );
    });

    testWidgets(
      'response format is not offered to a model that cannot use it',
      (tester) async {
        await tester.runAsync(() => seed('c1', {}));
        await openSheet(tester, active: _conversation('c1'));

        expect(field('format'), findsNothing);
      },
    );

    testWidgets('response format is offered to an Ollama model and saved', (
      tester,
    ) async {
      await tester.runAsync(() => seed('c1', {}));
      await openSheet(
        tester,
        active: _conversation('c1'),
        model: const Model(
          id: 'llama',
          name: 'Llama',
          metadata: {'owned_by': 'ollama'},
        ),
      );

      expect(field('format'), findsOneWidget);
      await typeInto(tester, field('format'), '{"type":');
      expect(find.text(_en.chatSettingErrorNotJson), findsOneWidget);
      expect(saveEnabled(tester), isFalse);

      await typeInto(tester, field('format'), '{"type":"object"}');
      await tester.tap(saveButton());
      await settle(tester);

      expect((await stored(tester, 'c1'))!['format'], {'type': 'object'});
    });
  });

  group('on the native iOS 26 sheet', () {
    testWidgets('edits, resets and saves from a phone with the keyboard up', (
      tester,
    ) async {
      final params = {
        'temperature': 0.2,
        'top_p': 0.9,
        'system': 'Keep me',
        'num_gpu': 3,
        'custom_params': {'k': 1},
      };
      await tester.runAsync(() => seed('c1', params));
      final c = await openSheet(
        tester,
        native: true,
        active: _conversation('c1', chatParams: params),
      );

      expect(find.text(_en.chatSettingsTitle), findsOneWidget);

      keyboard(tester, up: true);
      await tester.pumpAndSettle();
      await typeInto(
        tester,
        find.byKey(const ValueKey('chat-settings-system-field')),
        'Be brief',
      );
      await reveal(tester, field('temperature'));
      await typeInto(tester, field('temperature'), '0.8');
      await reveal(
        tester,
        find.byKey(const ValueKey('chat-setting-reset-top_p')),
      );
      await tester.tap(find.byKey(const ValueKey('chat-setting-reset-top_p')));
      await tester.pump();
      final nativeCalling = find.byKey(
        const ValueKey('chat-setting-function_calling-native'),
      );
      await reveal(tester, nativeCalling);
      await tester.tap(nativeCalling);
      await tester.pump();

      // With the keyboard up the form scrolls above it and both buttons stay
      // reachable.
      const keyboardTop = 844 - _keyboardHeight;
      expect(
        tester.getBottomLeft(saveButton()).dy,
        lessThanOrEqualTo(keyboardTop),
      );
      expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey('chat-settings-cancel')))
            .dy,
        lessThanOrEqualTo(keyboardTop),
      );
      expect(saveEnabled(tester), isTrue);

      keyboard(tester, up: false);
      await tester.pumpAndSettle();
      await tester.tap(saveButton());
      await settle(tester);

      final saved = (await stored(tester, 'c1'))!;
      expect(saved['system'], 'Be brief');
      expect(saved['temperature'], 0.8);
      expect(saved.containsKey('top_p'), isFalse);
      expect(saved['function_calling'], 'native');
      expect(saved['num_gpu'], 3);
      expect(saved['custom_params'], {'k': 1});
      expect(find.text(_en.chatSettingsTitle), findsNothing);
      expect(
        c.read(activeConversationProvider)!.chatParams['temperature'],
        0.8,
      );
      final ops = await tester.runAsync(
        () => db.outboxDao.pendingForChat('c1'),
      );
      expect(ops!.map((op) => op.kind), ['updateChat']);
    });

    testWidgets('Cancel closes it and keeps what was saved', (tester) async {
      final params = {'temperature': 0.2};
      await tester.runAsync(() => seed('c1', params));
      await openSheet(
        tester,
        native: true,
        active: _conversation('c1', chatParams: params),
      );

      await typeInto(tester, field('temperature'), '1.5');
      await tester.tap(find.byKey(const ValueKey('chat-settings-cancel')));
      await settle(tester);

      expect(find.text(_en.chatSettingsTitle), findsNothing);
      expect(await stored(tester, 'c1'), {'temperature': 0.2});
    });
  });

  group('permissions', () {
    testWidgets('without parameter rights only the prompt can change', (
      tester,
    ) async {
      final params = {'seed': 1};
      await tester.runAsync(() => seed('c1', params));
      await openSheet(
        tester,
        active: _conversation('c1', chatParams: params),
        access: const OpenWebUiChatSettingsAccess(
          canEditSystemPrompt: true,
          canEditParameters: false,
        ),
      );

      expect(
        find.byKey(const ValueKey('chat-settings-parameters-locked')),
        findsOneWidget,
      );
      expect(field('temperature'), findsNothing);
      expect(find.text(_en.chatSettingsParametersLocked), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('chat-settings-system-custom')),
      );
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('chat-settings-system-field')),
          matching: find.byType(TextField),
        ),
        'New prompt',
      );
      await tester.pump();
      await tester.tap(saveButton());
      await settle(tester);

      expect(await stored(tester, 'c1'), {'seed': 1, 'system': 'New prompt'});
    });

    testWidgets('without system-prompt rights the prompt is locked', (
      tester,
    ) async {
      final params = {'system': 'Locked prompt'};
      await tester.runAsync(() => seed('c1', params));
      await openSheet(
        tester,
        active: _conversation('c1', chatParams: params),
        access: const OpenWebUiChatSettingsAccess(
          canEditSystemPrompt: false,
          canEditParameters: true,
        ),
      );

      expect(
        find.byKey(const ValueKey('chat-settings-system-locked')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-settings-system-field')),
        findsNothing,
      );

      // Reset all must not reach into the half the account may not change.
      await tester.tap(find.byKey(const ValueKey('chat-settings-reset-all')));
      await tester.pump();
      await typeInto(tester, field('seed'), '9');
      await tester.tap(saveButton());
      await settle(tester);

      expect(await stored(tester, 'c1'), {
        'system': 'Locked prompt',
        'seed': 9,
      });
    });
  });

  group('when saving fails', () {
    testWidgets(
      'a server switch mid-edit keeps the sheet and the typed value',
      (tester) async {
        final params = {'temperature': 0.2};
        await tester.runAsync(() => seed('c1', params));
        final c = await openSheet(
          tester,
          active: _conversation('c1', chatParams: params),
        );

        await typeInto(tester, field('temperature'), '0.9');
        c.updateOverrides([
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(_api('another-server')),
          reviewerModeProvider.overrideWithValue(false),
          selectedModelProvider.overrideWithValue(_model),
          activeConversationProvider.overrideWith(
            () => _SeededActive(_conversation('c1', chatParams: params)),
          ),
          syncEngineProvider.overrideWith(_NoDrainEngine.new),
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
          appSettingsProvider.overrideWith(() => settings),
        ]);
        await tester.tap(saveButton());
        await settle(tester);

        expect(
          find.byKey(const ValueKey('chat-settings-failure')),
          findsOneWidget,
        );
        expect(find.text(_en.chatSettingsOwnerChanged), findsOneWidget);
        // Still open, still holding what was typed, and nothing was written.
        expect(find.text(_en.chatSettingsTitle), findsOneWidget);
        expect(
          tester
              .widget<TextField>(
                find.descendant(
                  of: field('temperature'),
                  matching: find.byType(TextField),
                ),
              )
              .controller!
              .text,
          '0.9',
        );
        expect(await stored(tester, 'c1'), {'temperature': 0.2});
      },
    );
  });

  group('a chat that does not exist yet', () {
    testWidgets('edits seed the next chat and touch no database', (
      tester,
    ) async {
      final c = await openSheet(tester);

      await tester.tap(
        find.byKey(const ValueKey('chat-settings-system-custom')),
      );
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('chat-settings-system-field')),
          matching: find.byType(TextField),
        ),
        'Draft prompt',
      );
      await typeInto(tester, field('seed'), '3');
      await tester.tap(saveButton());
      await settle(tester);

      expect(c.read(pendingOpenWebUiChatSettingsProvider), {
        'system': 'Draft prompt',
        'seed': 3,
      });
      expect(await tester.runAsync(() => db.select(db.chats).get()), isEmpty);
    });
  });

  group('when the editor is not available', () {
    testWidgets('Advanced off shows what applies and offers to turn it on', (
      tester,
    ) async {
      await openSheet(
        tester,
        advanced: false,
        active: _conversation(
          'c1',
          chatParams: {'system': '', 'temperature': 0.2, 'top_k': null},
        ),
      );

      expect(find.text(_en.chatSettingsApplied), findsOneWidget);
      expect(find.text(_en.chatSettingTemperature), findsOneWidget);
      expect(find.text('0.2'), findsOneWidget);
      expect(find.text(_en.chatSettingsModelDefault), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-settings-save')), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('chat-settings-turn-on-advanced')),
      );
      await settle(tester);

      expect(settings.turnedOn, [true]);
    });

    testWidgets(
      'an account that may not edit sees the summary without the button',
      (tester) async {
        await openSheet(
          tester,
          access: OpenWebUiChatSettingsAccess.denied,
          active: _conversation('c1', chatParams: {'seed': 4}),
        );

        expect(find.text(_en.chatSettingsApplied), findsOneWidget);
        expect(
          find.byKey(const ValueKey('chat-settings-turn-on-advanced')),
          findsNothing,
        );
      },
    );

    testWidgets('nothing opens when there is nothing to show', (tester) async {
      await openSheet(tester, advanced: false, active: _conversation('c1'));

      expect(find.text(_en.chatSettingsApplied), findsNothing);
      expect(find.text(_en.chatSettingsTitle), findsNothing);
    });
  });
}
