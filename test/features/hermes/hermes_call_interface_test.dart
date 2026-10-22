import 'package:conduit/features/hermes/providers/hermes_decision_drafts.dart';
import 'package:conduit/features/hermes/widgets/hermes_call_interface.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_work.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/features/chat/voice_mode/call_audio_routes.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call extends ChatVoiceModeController {
  _Call(this.initial);
  final ChatVoiceModeSnapshot initial;
  @override
  ChatVoiceModeSnapshot build() => initial;
  void update(ChatVoiceModeSnapshot next) => state = next;
  @override
  Future<void> toggleMute() async =>
      state = state.copyWith(isMuted: !state.isMuted);
  @override
  Future<void> stop() async =>
      state = state.copyWith(phase: ChatVoiceModePhase.ended);
}

class _Routes extends CallAudioRoutesController {
  @override
  CallAudioRoutes build() => const CallAudioRoutes(
    routes: [
      CallAudioRoute('speaker', 'Speaker', 'speaker'),
      CallAudioRoute('phone', 'Phone earpiece', 'phone'),
      CallAudioRoute('bt', 'Pixel Buds Pro 2', 'bluetooth'),
    ],
    selected: 'speaker',
  );
  @override
  Future<bool> cycle() async {
    state = CallAudioRoutes(routes: state.routes, selected: state.next!.id);
    return true;
  }
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];
  void update(List<ChatMessage> messages) => state = messages;
}

void main() {
  ProviderContainer makeContainer({bool expanded = false}) => ProviderContainer(
    overrides: [
      chatVoiceModeControllerProvider.overrideWith(
        () => _Call(
          ChatVoiceModeSnapshot(
            phase: ChatVoiceModePhase.listening,
            startedAt: DateTime(2026, 10, 22),
            activeCallId: 'one-call',
            isCollapsed: !expanded,
          ),
        ),
      ),
      callAudioRoutesProvider.overrideWith(_Routes.new),
      chatMessagesProvider.overrideWith(_Messages.new),
      appSettingsProvider.overrideWithValue(const AppSettings()),
      hermesApiServiceProvider.overrideWithValue(null),
      hermesCallSkillsProvider.overrideWith(
        (ref) async => [
          const Prompt(
            command: '/research',
            title: 'Research a topic',
            content: '/research ',
          ),
        ],
      ),
    ],
  );
  Future<void> pump(
    WidgetTester tester,
    ProviderContainer container, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark(TweakcnThemes.t3Chat)
              : AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 800),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              appBar: AppBar(
                actions: [HermesCallHeaderActions(onStart: () {})],
              ),
              body: const Stack(
                children: [
                  Positioned.fill(child: SizedBox.expand()),
                  HermesCallOverlay(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('compact is the default; expand and minimize keep one call', (
    tester,
  ) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await pump(tester, container);
    expect(find.byKey(const ValueKey('hermes-expanded-call')), findsNothing);
    final expand = find.byKey(const ValueKey('hermes-call-expand'));
    final mute = find.byKey(const ValueKey('hermes-call-mute'));
    final end = find.byKey(const ValueKey('hermes-call-toggle'));
    expect(tester.getCenter(expand).dx, lessThan(tester.getCenter(mute).dx));
    expect(tester.getCenter(mute).dx, lessThan(tester.getCenter(end).dx));
    for (final target in [expand, mute, end]) {
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-expanded-call')), findsOneWidget);
    expect(
      container.read(chatVoiceModeControllerProvider).activeCallId,
      'one-call',
    );
    await tester.tap(find.byKey(const ValueKey('hermes-call-conversation')));
    await tester.pumpAndSettle();
    expect(container.read(chatVoiceModeControllerProvider).isCollapsed, isTrue);
    expect(find.byKey(const ValueKey('hermes-expanded-call')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'stable footer, real captions, and route cycle in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = makeContainer(expanded: true);
        addTearDown(container.dispose);
        container
            .read(hermesMobileNavigationProvider.notifier)
            .newConversation();
        final now = DateTime.now();
        container
            .read(activeConversationProvider.notifier)
            .set(
              Conversation(
                id: 'chat',
                title: 'Hermes',
                createdAt: now,
                updatedAt: now,
                metadata: {'hermesSessionId': 'session'},
              ),
            );
        await pump(tester, container, brightness: brightness, scale: 2);
        final end = find.byKey(const ValueKey('hermes-expanded-end'));
        final baseline = tester.getRect(end);
        final call =
            container.read(chatVoiceModeControllerProvider.notifier) as _Call;
        call.update(
          container
              .read(chatVoiceModeControllerProvider)
              .copyWith(
                phase: ChatVoiceModePhase.speaking,
                spokenResponse: 'An actual spoken sentence.',
              ),
        );
        await tester.pumpAndSettle();
        expect(find.text('An actual spoken sentence.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('hermes-call-captions')));
        await tester.pumpAndSettle();
        expect(find.text('An actual spoken sentence.'), findsNothing);
        expect(tester.getRect(end), baseline);
        container.read(chatMessagesProvider.notifier) as _Messages;
        (container.read(chatMessagesProvider.notifier) as _Messages).update([
          ChatMessage(
            id: 'question',
            role: 'assistant',
            content: '',
            timestamp: now,
            metadata: {
              'transport': kHermesTransport,
              'hermesSessionId': 'session',
              'hermesDecision': {
                'state': 'pending',
                'kind': 'clarification',
                'requestId': 'q',
                'runtimeId': 'r',
                'storedSessionId': 'session',
                'prompt': 'What sounds good?',
                'choices': ['Nearby', 'At home'],
                'expiresAt': now
                    .add(const Duration(minutes: 5))
                    .toUtc()
                    .toIso8601String(),
              },
            },
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('What sounds good?'), findsOneWidget);
        expect(tester.getRect(end), baseline);
        final audio = find.byKey(const ValueKey('hermes-call-audio'));
        await tester.tap(audio);
        await tester.pumpAndSettle();
        expect(container.read(callAudioRoutesProvider).selected, 'phone');
        await tester.tap(audio);
        await tester.pumpAndSettle();
        expect(find.text('Pixel Buds Pro 2'), findsOneWidget);
        expect(tester.getRect(end), baseline);
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.invalidate(hermesDecisionDraftsProvider);
        await tester.pump();
      },
    );
  }
  testWidgets('Skills opens compact names and intentional search', (
    tester,
  ) async {
    final container = makeContainer(expanded: true);
    addTearDown(container.dispose);
    await pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('hermes-call-skills')));
    await tester.pumpAndSettle();
    expect(find.text('Research'), findsOneWidget);
    expect(find.text('In this conversation'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Search skills'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No matching skills.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
