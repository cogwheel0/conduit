import 'dart:async';

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/features/hermes/widgets/hermes_history_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show isAuthenticatedProvider2;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart'
    show streamingHapticsEnabledProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _l10n = AppLocalizationsEn();

class _QuietSpeech extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _Seeded extends ActiveConversationNotifier {
  _Seeded(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => _chat;
}

/// Branches only once [gate] opens.
class _HeldBranch extends HermesSessionsController {
  final gate = Completer<void>();

  @override
  Future<List<HermesSessionSummary>> build() async => const [];

  @override
  Future<
    ({HermesSessionSummary session, List<Map<String, dynamic>>? transcript})?
  >
  branchFromMessage({
    required String sessionId,
    required String title,
    required List<ChatMessage> messages,
    required int index,
  }) async {
    await gate.future;
    return (
      session: const HermesSessionSummary(id: 'branch-1', title: 'Branch'),
      transcript: null,
    );
  }
}

ChatMessage _message(String id, String role, String content) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime.utc(2026, 11, 7),
);

final _chat = [
  _message('u1', 'user', 'Plan a synthetic picnic'),
  _message('a1', 'assistant', 'Bring sandwiches.'),
  _message('u2', 'user', 'And drinks?'),
  _message('a2', 'assistant', 'Lemonade.'),
];

Conversation _conversation({bool hermes = true}) {
  final conversation = Conversation(
    id: hermes ? 'local:hermes_stored-1' : 'owui-chat',
    title: 'Synthetic picnic',
    createdAt: DateTime.utc(2026, 11, 7),
    updatedAt: DateTime.utc(2026, 11, 7),
    messages: _chat,
    metadata: hermes
        ? const {'backend': 'hermes', 'hermesSessionId': 'stored-1'}
        : const {},
  );
  return hermes ? markNativeHermesConversation(conversation) : conversation;
}

HermesBackendService _desktop() {
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

HermesBackendService _rest() => HermesApiService(
  config: const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example',
    apiKey: 'synthetic-key',
  ),
);

Future<List<String>> _overflowLabels(
  WidgetTester tester, {
  required HermesBackendService service,
  required ChatMessage reply,
  Conversation? conversation,
  Future<void> Function()? beforeOverflow,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // No Open WebUI account: these are Hermes chats.
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
          () => _Seeded(conversation ?? _conversation()),
        ),
        chatMessagesProvider.overrideWith(_Messages.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AssistantMessageWidget(
            message: reply,
            isStreaming: false,
            showFollowUps: false,
            animateOnMount: false,
            onCopy: () {},
            onRegenerate: () {},
            onDelete: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await beforeOverflow?.call();
  await tester.tap(
    find.byKey(const ValueKey('assistant-response-overflow-button')),
  );
  await tester.pumpAndSettle();
  return [
    for (final label in [_l10n.hermesBranchFromHere, _l10n.hermesUndoLastTurn])
      if (find.text(label).evaluate().isNotEmpty) label,
  ];
}

void main() {
  testWidgets('a Desktop chat offers both on its last reply', (tester) async {
    expect(
      await _overflowLabels(tester, service: _desktop(), reply: _chat[3]),
      [_l10n.hermesBranchFromHere, _l10n.hermesUndoLastTurn],
    );
  });

  testWidgets('an earlier reply only branches', (tester) async {
    expect(
      await _overflowLabels(tester, service: _desktop(), reply: _chat[1]),
      [_l10n.hermesBranchFromHere],
    );
  });

  testWidgets('an API server chat branches but cannot undo', (tester) async {
    expect(
      await _overflowLabels(tester, service: _rest(), reply: _chat[3]),
      [_l10n.hermesBranchFromHere],
    );
  });

  testWidgets('an older answer shown in place of the reply does not '
      'branch', (tester) async {
    final reply = _chat[3].copyWith(
      versions: [
        ChatMessageVersion(
          id: 'a2-older',
          content: 'Synthetic iced tea.',
          timestamp: DateTime.utc(2026, 11, 7),
        ),
      ],
    );
    expect(
      await _overflowLabels(
        tester,
        service: _desktop(),
        reply: reply,
        beforeOverflow: () async {
          await tester.tap(
            find
                .descendant(
                  of: find.byKey(
                    const ValueKey<String>('assistant-version-pager'),
                  ),
                  matching: find.bySemanticsLabel(_l10n.previousLabel),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('Synthetic iced tea.'), findsOneWidget);
        },
      ),
      [_l10n.hermesUndoLastTurn],
    );
  });

  testWidgets('other chats offer neither', (tester) async {
    expect(
      await _overflowLabels(
        tester,
        service: _desktop(),
        reply: _chat[3],
        conversation: _conversation(hermes: false),
      ),
      isEmpty,
    );
  });

  testWidgets('a chat chosen while a branch is made is not left for it', (
    tester,
  ) async {
    final branches = _HeldBranch();
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(_rest()),
        hermesSessionsProvider.overrideWith(() => branches),
        activeConversationProvider.overrideWith(
          () => _Seeded(_conversation()),
        ),
        chatMessagesProvider.overrideWith(_Messages.new),
      ],
    );
    addTearDown(container.dispose);
    late BuildContext context;
    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (buildContext, ref, _) {
              context = buildContext;
              widgetRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final branching = branchHermesChatFromMessage(context, widgetRef, 'a1');
    await tester.pump();
    // The user opens another chat while Hermes makes the branch.
    final chosen = container
        .read(hermesSessionNavigationEpochProvider.notifier)
        .bump();
    branches.gate.complete();
    await branching;
    await tester.pump();

    expect(container.read(hermesSessionNavigationEpochProvider), chosen);
  });
}
