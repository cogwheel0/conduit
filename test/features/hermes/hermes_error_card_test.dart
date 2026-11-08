import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/hermes/widgets/hermes_error_card.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/services/hermes_bot_chat.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show isAuthenticatedProvider2;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/providers/hermes_context_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart'
    show streamingHapticsEnabledProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _l10n = AppLocalizationsEn();

/// A Desktop Gateway service that never opens its socket.
HermesDesktopApiService _desktop() {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://desktop.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.legacyToken,
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) =>
          throw StateError('no socket in this test'),
    ),
  );
  addTearDown(service.close);
  return service;
}

class _Seeded extends ActiveConversationNotifier {
  _Seeded(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

class _QuietSpeech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _Selected extends SelectedModel {
  @override
  Model? build() => null;
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

List<Override> _overrides(
  HermesBackendService? service, {
  Conversation? conversation,
}) => [
  apiServiceProvider.overrideWithValue(null),
  openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
  isAuthenticatedProvider2.overrideWithValue(false),
  reviewerModeProvider.overrideWithValue(false),
  socketServiceProvider.overrideWithValue(null),
  textToSpeechControllerProvider.overrideWith(_QuietSpeech.new),
  streamingHapticsEnabledProvider.overrideWithValue(false),
  isChatStreamingProvider.overrideWithValue(false),
  hermesApiServiceProvider.overrideWithValue(service),
  activeConversationProvider.overrideWith(
    () => _Seeded(conversation ?? _hermesChat()),
  ),
  chatMessagesProvider.overrideWith(_Messages.new),
  selectedModelProvider.overrideWith(_Selected.new),
  hermesDesktopModelsProvider.overrideWith((ref) async => const []),
  hermesContextReportProvider.overrideWith(
    (ref, sessionId) async => const HermesContextReport(
      contextUsed: 128000,
      contextMax: 131072,
      canCompact: true,
    ),
  ),
];

Widget _app(List<Override> overrides, Widget child) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Future<ProviderContainer> _pumpCard(
  WidgetTester tester,
  HermesErrorSurface surface, {
  HermesBackendService? service,
  VoidCallback? onRetry,
  Future<void> Function()? onContinue,
  String? errorText = 'Synthetic provider error',
}) async {
  await tester.pumpWidget(
    _app(
      _overrides(service),
      HermesErrorCard(
        surface: surface,
        errorText: errorText,
        onRetry: onRetry,
        onContinue: onContinue,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(HermesErrorCard)),
  );
}

void main() {
  testWidgets('a blocking failure says what broke and offers its action', (
    tester,
  ) async {
    var retried = 0;
    await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.auth,
        code: 'auth',
        retryable: false,
        provider: 'openrouter',
        providerLabel: 'OpenRouter',
        model: 'synthetic/model-a',
        authKind: 'api_key',
      ),
      onRetry: () => retried++,
    );

    expect(find.text(_l10n.hermesErrorAuth), findsOneWidget);
    expect(find.text(_l10n.hermesErrorBlocking), findsOneWidget);
    expect(find.text('OpenRouter · synthetic/model-a'), findsOneWidget);
    expect(find.text('Synthetic provider error'), findsOneWidget);

    await tester.tap(find.text(_l10n.retry));
    await tester.pumpAndSettle();
    expect(retried, 1);
  });

  testWidgets('a cut-off reply can go on with Continue', (tester) async {
    var continued = 0;
    await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.provider,
        code: 'truncated',
        partial: true,
      ),
      onContinue: () async => continued++,
    );

    expect(find.text(_l10n.hermesErrorTruncated), findsOneWidget);
    expect(find.text(_l10n.hermesErrorDegraded), findsOneWidget);
    expect(find.text(_l10n.hermesErrorPartialKept), findsOneWidget);

    await tester.tap(find.text(_l10n.hermesErrorContinue));
    await tester.pumpAndSettle();
    expect(continued, 1);
  });

  testWidgets('a plan limit names its message and reset, and switches to '
      'the suggested model before retrying', (tester) async {
    var retried = 0;
    final reset = DateTime.now().add(const Duration(hours: 2));
    final container = await _pumpCard(
      tester,
      HermesErrorSurface(
        layer: HermesErrorLayer.billing,
        code: 'usage_window',
        provider: 'nous',
        message: 'Synthetic daily allowance used up.',
        resetsAt: reset,
        suggestions: const [
          HermesModelSuggestion(
            model: 'synthetic-small',
            label: 'Synthetic Small',
            provider: 'nous',
          ),
        ],
        creditsAction: 'use_credits',
      ),
      onRetry: () => retried++,
    );

    expect(find.text(_l10n.hermesErrorUsageLimit), findsOneWidget);
    expect(find.text('Synthetic daily allowance used up.'), findsOneWidget);
    expect(find.textContaining('Resets at'), findsOneWidget);
    // Hermes' own sentence replaces the raw error text.
    expect(find.text('Synthetic provider error'), findsNothing);

    await tester.tap(
      find.text(_l10n.hermesErrorSwitchModel('Synthetic Small')),
    );
    await tester.pumpAndSettle();

    final selected = container.read(selectedModelProvider);
    expect(selected?.metadata?['hermesModelId'], 'synthetic-small');
    expect(selected?.metadata?['hermesProvider'], 'nous');
    expect(container.read(isManualModelSelectionProvider), isTrue);
    expect(retried, 1);
  });

  testWidgets('a Bot Chat is not offered a model its retry cannot use', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _overrides(
          _desktop(),
          conversation: markNativeHermesConversation(
            _hermesChat().copyWith(
              metadata: {
                ..._hermesChat().metadata,
                ...hermesBotChatMetadata(
                  bot: const HermesBot(name: 'scout', title: 'Scout'),
                ),
              },
            ),
          ),
        ),
        HermesErrorCard(
          surface: const HermesErrorSurface(
            layer: HermesErrorLayer.billing,
            code: 'usage_window',
            provider: 'nous',
            suggestions: [
              HermesModelSuggestion(
                model: 'synthetic-small',
                label: 'Synthetic Small',
                provider: 'nous',
              ),
            ],
            creditsAction: 'use_credits',
          ),
          errorText: 'Synthetic provider error',
          onRetry: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(_l10n.hermesErrorSwitchModel('Synthetic Small')),
      findsNothing,
    );
    // The next way out is offered instead.
    expect(find.text(_l10n.hermesErrorUseCredits), findsOneWidget);
  });

  testWidgets('a plan limit without suggestions offers Use credits on a '
      'Desktop Gateway', (tester) async {
    const surface = HermesErrorSurface(
      layer: HermesErrorLayer.billing,
      code: 'usage_window',
      provider: 'nous',
      creditsAction: 'use_credits',
    );
    await _pumpCard(tester, surface, service: _desktop(), onRetry: () {});
    expect(find.text(_l10n.hermesErrorUseCredits), findsOneWidget);

    // An API server connection cannot turn credits on.
    await _pumpCard(tester, surface, onRetry: () {});
    expect(find.text(_l10n.hermesErrorUseCredits), findsNothing);
  });

  testWidgets('a context overflow opens Context & usage to compact', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.provider,
        code: 'context_overflow',
        retryable: false,
      ),
      service: _desktop(),
    );

    await tester.tap(find.text(_l10n.hermesErrorCompact));
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextUsage), findsOneWidget);
    expect(find.text(_l10n.hermesContextCompactNow), findsOneWidget);
  });

  testWidgets('an action this chat cannot take is not offered', (tester) async {
    await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.provider,
        code: 'rate_limit',
      ),
    );

    expect(find.text(_l10n.hermesErrorRateLimit), findsOneWidget);
    expect(find.text(_l10n.retry), findsNothing);
  });

  testWidgets('a context overflow it cannot compact here offers a new chat', (
    tester,
  ) async {
    // No Desktop Gateway session to compact: the second option shows.
    await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.provider,
        code: 'context_overflow',
        retryable: false,
      ),
    );

    expect(find.text(_l10n.hermesErrorCompact), findsNothing);
    expect(
      find.byKey(const ValueKey('hermes-error-action-newChat')),
      findsOneWidget,
    );
  });

  // The card read the connection and chat once: a chat switched under it
  // kept offering the action it had before.
  testWidgets('the action follows the open chat while the card shows', (
    tester,
  ) async {
    final elsewhere = markNativeHermesConversation(
      Conversation(
        id: 'local:hermes_pending',
        title: 'Not saved yet',
        createdAt: DateTime.utc(2026, 11, 7),
        updatedAt: DateTime.utc(2026, 11, 7),
        metadata: const {'backend': 'hermes'},
      ),
    );
    await tester.pumpWidget(
      _app(
        _overrides(_desktop(), conversation: elsewhere),
        const HermesErrorCard(
          surface: HermesErrorSurface(
            layer: HermesErrorLayer.provider,
            code: 'context_overflow',
            retryable: false,
          ),
          errorText: 'Synthetic provider error',
        ),
      ),
    );
    await tester.pumpAndSettle();
    // No session of its own yet: nothing to compact.
    expect(find.text(_l10n.hermesErrorCompact), findsNothing);

    ProviderScope.containerOf(
      tester.element(find.byType(HermesErrorCard)),
    ).read(activeConversationProvider.notifier).set(_hermesChat());
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesErrorCompact), findsOneWidget);
  });

  testWidgets('a new chat stays on the Hermes model', (tester) async {
    final container = await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.gateway,
        code: 'SESSION_NOT_OWNED',
        retryable: false,
      ),
    );
    final hermes = hermesSyntheticModel(name: 'Synthetic Hermes');
    container.read(selectedModelProvider.notifier).set(hermes);

    await tester.tap(find.byKey(const ValueKey('hermes-error-action-newChat')));
    await tester.pumpAndSettle();

    expect(container.read(activeConversationProvider), isNull);
    expect(container.read(selectedModelProvider), same(hermes));
    expect(container.read(isManualModelSelectionProvider), isTrue);
  });

  testWidgets('a new chat picks Hermes when another model is selected', (
    tester,
  ) async {
    final container = await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.gateway,
        code: 'SESSION_NOT_OWNED',
        retryable: false,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('hermes-error-action-newChat')));
    await tester.pumpAndSettle();

    final selected = container.read(selectedModelProvider);
    expect(selected, isNotNull);
    expect(isHermesModel(selected!), isTrue);
  });

  testWidgets('a session another gateway owns offers a new chat', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      const HermesErrorSurface(
        layer: HermesErrorLayer.gateway,
        code: 'SESSION_NOT_OWNED',
        retryable: false,
      ),
    );

    expect(find.text(_l10n.hermesErrorSession), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hermes-error-action-newChat')),
      findsOneWidget,
    );
  });

  group('in a reply', () {
    Future<void> pumpReply(WidgetTester tester, ChatMessage reply) async {
      await tester.pumpWidget(
        _app(
          _overrides(_desktop()),
          AssistantMessageWidget(
            message: reply,
            isStreaming: false,
            showFollowUps: false,
            animateOnMount: false,
            onCopy: () {},
            onRegenerate: () {},
            onDelete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final reply = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026, 11, 7),
      metadata: const {'transport': kHermesTransport},
    );

    testWidgets('a classified failure shows the card', (tester) async {
      await pumpReply(
        tester,
        hermesFailedMessage(
          reply,
          'Synthetic overflow.',
          surface: const HermesErrorSurface(
            layer: HermesErrorLayer.provider,
            code: 'context_overflow',
            retryable: false,
          ),
        ),
      );

      expect(find.byType(HermesErrorCard), findsOneWidget);
      expect(find.text(_l10n.hermesErrorContextOverflow), findsOneWidget);
    });

    testWidgets('a failed turn read back from its transcript keeps its card', (
      tester,
    ) async {
      // A reloaded or reopened chat: the row Hermes stored to close the
      // failed turn carries the live frame's descriptor.
      final stored = hermesMessagesToChatMessages([
        {'id': 1, 'role': 'user', 'content': 'Synthetic prompt'},
        {
          'id': 2,
          'role': 'assistant',
          'content': 'Synthetic notice: the request was not run.',
          'display_kind': 'failed_turn',
          'display_metadata': {
            'error': 'HTTP 401: synthetic key refused',
            'error_surface': {
              'layer': 'auth',
              'code': 'auth',
              'retryable': false,
              'provider': 'custom',
              'auth_kind': 'api_key',
            },
          },
        },
      ]).last;

      await pumpReply(tester, stored);

      expect(find.byType(HermesErrorCard), findsOneWidget);
      expect(find.text(_l10n.hermesErrorAuth), findsOneWidget);
      expect(find.text('HTTP 401: synthetic key refused'), findsOneWidget);
    });

    testWidgets('any other failure keeps the plain banner', (tester) async {
      await pumpReply(
        tester,
        hermesFailedMessage(reply, 'Synthetic plain failure.'),
      );

      expect(find.byType(HermesErrorCard), findsNothing);
      expect(find.text('Synthetic plain failure.'), findsOneWidget);
    });
  });
}
