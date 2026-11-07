import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/providers/hermes_context_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _en = AppLocalizationsEn();

class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'model-1', name: 'Model 1'),
  ];
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

class _Tools extends ToolsList {
  @override
  Future<List<Tool>> build() async => const <Tool>[];
}

class _SelectedModel extends SelectedModel {
  @override
  Model? build() => const Model(id: 'model-1', name: 'Model 1');
}

class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}
}

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

Conversation _hermesChat() => markNativeHermesConversation(
  Conversation(
    id: 'local:hermes_stored-1',
    title: 'Synthetic picnic',
    createdAt: DateTime.utc(2026, 11, 7),
    updatedAt: DateTime.utc(2026, 11, 7),
    metadata: const {'backend': 'hermes', 'hermesSessionId': 'stored-1'},
  ),
);

Conversation _otherChat() => Conversation(
  id: 'owui-chat',
  title: 'A chat',
  createdAt: DateTime.utc(2026, 11, 7),
  updatedAt: DateTime.utc(2026, 11, 7),
);

void main() {
  late bool previousWarning;
  setUpAll(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
  });

  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> mountPage(
    WidgetTester tester,
    Conversation active, {
    bool hermes = true,
  }) async {
    final rest = HermesApiService(
      config: const HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        apiKey: 'synthetic-key',
      ),
    );
    addTearDown(rest.close);
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        appSettingsProvider.overrideWith(_Settings.new),
        apiServiceProvider.overrideWithValue(null),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        selectedModelProvider.overrideWith(_SelectedModel.new),
        activeConversationProvider.overrideWith(() => _Active(active)),
        chatMessagesProvider.overrideWith(_Messages.new),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        isChatStreamingProvider.overrideWith((ref) => false),
        conversationsProvider.overrideWith(_Conversations.new),
        modelsProvider.overrideWith(_Models.new),
        foldersProvider.overrideWith(_Folders.new),
        toolsListProvider.overrideWith(_Tools.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
        userPermissionsProvider.overrideWith((ref) async => const {}),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => Object()),
        hermesApiServiceProvider.overrideWithValue(hermes ? rest : null),
        hermesContextReportProvider.overrideWith(
          (ref, sessionId) async => const HermesContextReport(
            totals: HermesTokenTotals(input: 900, output: 300),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final originalErrorWidgetBuilder = ErrorWidget.builder;
    final originalFlutterErrorOnError = FlutterError.onError;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      ErrorWidget.builder = originalErrorWidgetBuilder;
      FlutterError.onError = originalFlutterErrorOnError;
    });
    await container.read(userPermissionsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  testWidgets('a Hermes chat opens Context & usage from its overflow', (
    tester,
  ) async {
    await mountPage(tester, _hermesChat());

    await openOverflow(tester);
    await tester.tap(find.text(_en.hermesContextUsage));
    await tester.pumpAndSettle();

    // The sheet's title, and its totals for the chat's session.
    expect(find.text(_en.hermesContextUsage), findsOneWidget);
    expect(find.text(_en.hermesContextTotals), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
  });

  testWidgets('another chat has no Context & usage', (tester) async {
    await mountPage(tester, _otherChat());

    await openOverflow(tester);

    expect(find.text(_en.hermesContextUsage), findsNothing);
  });

  testWidgets('a Hermes chat without a Hermes connection has none', (
    tester,
  ) async {
    await mountPage(tester, _hermesChat(), hermes: false);

    // The menu may have nothing else to offer either.
    if (find.byIcon(Icons.more_vert).evaluate().isNotEmpty) {
      await openOverflow(tester);
    }

    expect(find.text(_en.hermesContextUsage), findsNothing);
  });
}
