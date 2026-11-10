import 'dart:async';

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/chat/widgets/live_connection_button.dart';
import 'package:conduit/features/chat/widgets/model_selector_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/services/librechat_provenance.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

const _menuChannel = MethodChannel('cn_context_menu');

const _models = [
  Model(id: 'kite-small', name: 'Kite Small'),
  Model(id: 'kite-large', name: 'Kite Large'),
  Model(id: 'lantern', name: 'Lantern'),
];

class _Models extends Models {
  _Models([this.models = _models, this.pending]);

  final List<Model> models;

  /// Listed when this completes instead, when given.
  final Future<List<Model>>? pending;

  @override
  Future<List<Model>> build() => pending ?? Future.value(models);
}

class _SelectedModel extends SelectedModel {
  _SelectedModel({this.unpicked = false});

  final bool unpicked;

  @override
  Model? build() => unpicked ? null : _models.first;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

class _Active extends ActiveConversationNotifier {
  _Active([this.conversation]);

  final Conversation? conversation;

  @override
  Conversation? build() => conversation;
}

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const [];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const [];
}

class _Speech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Connectivity extends Fake implements ConnectivityService {
  @override
  Stream<ConnectivityStatus> get statusStream => const Stream.empty();
  @override
  ConnectivityStatus get currentStatus => ConnectivityStatus.online;
  @override
  bool get isOnline => true;
  @override
  bool get isAppForeground => true;
  @override
  int get lastLatencyMs => 0;
}

void main() {
  late List<Map<Object?, Object?>> menus;
  late List<int>? menuReply;

  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    menus = [];
    menuReply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_menuChannel, (call) async {
          if (call.method == 'show') {
            menus.add(call.arguments as Map<Object?, Object?>);
            return menuReply;
          }
          return null;
        });
  });

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_menuChannel, null);
  });

  Future<ProviderContainer> pumpChat(
    WidgetTester tester, {
    required List<String> pinned,
    List<Model> models = _models,
    Future<List<Model>>? pendingModels,
    Conversation? active,
    bool unpicked = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stubNativePlatformViews();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        effectivePinnedModelIdsProvider.overrideWithValue(pinned),
        activeConversationProvider.overrideWith(() => _Active(active)),
        appDatabaseProvider.overrideWith((ref) => null),
        connectivityServiceProvider.overrideWithValue(_Connectivity()),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(
          () => _SelectedModel(unpicked: unpicked),
        ),
        chatMessagesProvider.overrideWith(_Messages.new),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(() => _Models(models, pendingModels)),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        textToSpeechControllerProvider.overrideWith(_Speech.new),
        liveConnectionDisconnectedProvider.overrideWith(
          (ref) => Stream.value(false),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.conduit)
              .copyWith(platform: TargetPlatform.iOS),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => LegacyDesignCompatibility(child: child!),
          home: const ChatPage(),
        ),
      ),
    );
    if (pendingModels == null) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
    return container;
  }

  void useIOS18() {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(EditableText), text);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pump();
  }

  String draft(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  /// Lets a banner shown meanwhile run out its time.
  Future<void> outlastBanner(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  Finder pill() => find.byType(ConduitAdaptiveAppBarModelSelector);

  Future<void> tapPill(WidgetTester tester) async {
    tester.widget<ConduitAdaptiveAppBarModelSelector>(pill()).onPressed();
    await tester.pumpAndSettle();
  }

  Future<void> closeChat(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the pill opens the pinned models under it, the chat model checked',
    (tester) async {
      final container = await pumpChat(
        tester,
        pinned: const ['lantern', 'no-longer-offered', 'kite-small'],
      );
      menuReply = [0];
      final anchor = tester.getRect(pill()).bottomCenter;

      await tapPill(tester);

      final menu = menus.single;
      final entries = menu['menu']! as Map<Object?, Object?>;
      expect(entries['labels'], ['Lantern', 'Kite Small', '', 'All Models…']);
      expect(entries['checked'], [false, true, false, false]);
      expect(entries['isDivider'], [false, false, true, false]);
      expect((menu['x']! as num).toDouble(), anchor.dx);
      expect((menu['y']! as num).toDouble(), anchor.dy);
      // A pick here is a pick in the full list: the chat's model, kept
      // against a late default.
      expect(container.read(selectedModelProvider)?.id, 'lantern');
      expect(container.read(isManualModelSelectionProvider), isTrue);
      expect(find.byType(ModelSelectorSheet), findsNothing);
      await closeChat(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'All models opens the full list, and a closed menu changes nothing',
    (tester) async {
      final container = await pumpChat(tester, pinned: const ['kite-large']);

      await tapPill(tester);
      expect(menus, hasLength(1));
      expect(find.byType(ModelSelectorSheet), findsNothing);
      expect(container.read(selectedModelProvider)?.id, 'kite-small');
      expect(container.read(isManualModelSelectionProvider), isFalse);

      menuReply = [2];
      await tapPill(tester);
      expect(menus, hasLength(2));
      expect(find.byType(ModelSelectorSheet), findsOneWidget);
      expect(container.read(selectedModelProvider)?.id, 'kite-small');
      await closeChat(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('with no pinned model on offer the pill opens the full list', (
    tester,
  ) async {
    await pumpChat(tester, pinned: const ['no-longer-offered']);

    await tapPill(tester);

    expect(menus, isEmpty);
    expect(find.byType(ModelSelectorSheet), findsOneWidget);
    await closeChat(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    "a LibreChat chat's menu holds only its own backend's pinned models",
    (tester) async {
      final libreChat = libreChatCatalog(
        startupConfig: const <String, dynamic>{},
        endpoints: const <String, dynamic>{
          'Ollama': {'order': 1, 'type': 'custom'},
        },
        models: const {
          'Ollama': ['otter-mini'],
        },
      ).single;
      final now = DateTime(2026, 11);
      await pumpChat(
        tester,
        pinned: ['lantern', libreChat.id],
        models: [..._models, libreChat],
        active: withChatStorageProvenance(
          stampLibreChatProvenance(
            Conversation(
              id: 'lc-chat',
              title: 'Tide tables',
              createdAt: now,
              updatedAt: now,
            ),
          ),
          ChatStorageKind.libreChat,
        ),
      );

      await tapPill(tester);

      final entries = menus.single['menu']! as Map<Object?, Object?>;
      expect(entries['labels'], ['otter-mini', '', 'All Models…']);
      await closeChat(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    "a LibreChat chat with none of LibreChat's models says so",
    (tester) async {
      final now = DateTime(2026, 11);
      await pumpChat(
        tester,
        pinned: const ['lantern'],
        active: withChatStorageProvenance(
          stampLibreChatProvenance(
            Conversation(
              id: 'lc-chat',
              title: 'Tide tables',
              createdAt: now,
              updatedAt: now,
            ),
          ),
          ChatStorageKind.libreChat,
        ),
      );

      await tapPill(tester);

      expect(menus, isEmpty);
      expect(find.byType(ModelSelectorSheet), findsNothing);
      expect(find.text('No models available'), findsOneWidget);
      await outlastBanner(tester);
      await closeChat(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a model picked while a send waits for the models is the one it takes',
    (tester) async {
      useIOS18();
      final listed = Completer<List<Model>>();
      final container = await pumpChat(
        tester,
        pinned: const [],
        unpicked: true,
        pendingModels: listed.future,
      );

      await send(tester, 'Hello');
      container.read(selectedModelProvider.notifier).set(_models.last);
      listed.complete(_models);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(container.read(selectedModelProvider)?.id, 'lantern');
      await outlastBanner(tester);
      await closeChat(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a send with no model to take says so and keeps the draft',
    (tester) async {
      useIOS18();
      await pumpChat(
        tester,
        pinned: const [],
        models: const [],
        unpicked: true,
      );

      await send(tester, 'Hello');
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('No models available'), findsOneWidget);
      expect(draft(tester), 'Hello');
      await outlastBanner(tester);
      await closeChat(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('before iOS 26 the pill opens the full list', (tester) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await pumpChat(tester, pinned: const ['lantern']);

    tester.widget<ConduitAdaptiveAppBarModelSelector>(pill()).onPressed();
    // The pill shimmers while the list is up, so the page never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(menus, isEmpty);
    expect(find.byType(ModelSelectorSheet), findsOneWidget);
    await closeChat(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
