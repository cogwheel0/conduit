import 'package:conduit/features/hermes/providers/hermes_messages.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/widgets/hermes_chat_quick_switcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Service extends Fake implements HermesBackendService {
  @override
  HermesConfig get config => const HermesConfig(
    enabled: true,
    baseUrl: 'http://hermes.test',
    mode: HermesBackendMode.desktopGateway,
  );
}

class _Sessions extends HermesSessionsController {
  @override
  Future<List<HermesSessionSummary>> build() async => const [
    HermesSessionSummary(id: 'server-one', title: 'Server conversation one'),
    HermesSessionSummary(id: 'server-two', title: 'Server conversation two'),
    HermesSessionSummary(
      id: 'cron_run',
      title: 'Scheduled work',
      source: 'cron',
    ),
  ];
}

void main() {
  test('recent chats exclude scheduled, archived, bot, and group sessions', () {
    final sessions = [
      for (var i = 0; i < 8; i++)
        HermesSessionSummary(
          id: 'chat-$i',
          title: 'Chat $i',
          updatedAt: DateTime(2026, 10, 15, i),
        ),
      const HermesSessionSummary(id: 'archived', title: 'Old', archived: true),
      const HermesSessionSummary(id: 'cron_run', title: 'Run', source: 'cron'),
      const HermesSessionSummary(id: 'bot', title: 'Bot Chat'),
      const HermesSessionSummary(
        id: 'group',
        title: 'Group',
        source: 'bot_room',
      ),
      const HermesSessionSummary(id: 'canonical', title: 'Renamed bot'),
    ];
    final recent = hermesQuickSwitcherSessions(sessions, const [
      HermesBot(name: 'default', title: 'Hermes', chatSessionId: 'canonical'),
    ], profile: 'default');
    expect(recent.map((s) => s.id), [
      'chat-7',
      'chat-6',
      'chat-5',
      'chat-4',
      'chat-3',
      'chat-2',
    ]);
    expect(sessions.first.id, 'chat-0');
  });

  testWidgets('Hermes preview uses server history and Back cancels it', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hermesApiServiceProvider.overrideWithValue(_Service()),
          hermesSessionsProvider.overrideWith(_Sessions.new),
          hermesMessagesBotsProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GestureDetector(
              onTap: () {},
              child: const HermesChatQuickSwitcher(bottomOffset: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(HermesChatQuickSwitcher));
    final container = ProviderScope.containerOf(element);
    final back = container.read(hermesMobileChatSwitcherProvider);
    final newChat = tester.getSemantics(find.bySemanticsLabel('New Chat'));
    expect(newChat.rect.size, const Size(60, 60));
    semanticsHandle.dispose();
    expect(back.dismiss(), isFalse);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-switcher-button'))),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Server conversation one'), findsOneWidget);
    expect(find.text('Server conversation two'), findsOneWidget);
    expect(find.text('Scheduled work'), findsNothing);
    expect(back.dismiss(), isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('chat-switcher-picker')), findsNothing);
    expect(back.dismiss(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(back.dismiss(), isFalse);
  });
}
