@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/hermes_page.dart';
import 'package:conduit_desktop_ui/src/pages/hermes_settings_tab.dart';
import 'package:conduit_desktop_ui/src/pages/workspace/workspace_common.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/hermes_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button;
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// The daemon's Hermes, in memory.
class _FakeHermes extends HermesActions {
  _FakeHermes(super.ref);

  HermesSettings current = const HermesSettings(
    enabled: true,
    baseUrl: 'https://hermes.example.com/v1',
    hasApiKey: true,
    usable: true,
  );
  final List<HermesSettingsEdit> saved = [];
  final List<HermesSettingsEdit> tested = [];
  HermesSessions sessionList = const HermesSessions(
    sessions: [
      HermesSessionDto(
        id: 's1',
        chatId: 'local:hermes_s1',
        title: 'Trip plans',
        preview: 'Where to go in May',
      ),
    ],
  );
  final List<String> deleted = [];
  List<HermesJobDto> jobList = const [
    HermesJobDto(
      id: 'j1',
      name: 'Morning brief',
      prompt: 'Summarise the news',
      schedule: '0 8 * * *',
      scheduleText: 'Every day at 08:00',
    ),
  ];
  final List<HermesJobEdit> savedJobs = [];
  final List<(String, bool)> toggled = [];
  final List<String> ran = [];

  @override
  Future<HermesSettings> settings() async => current;

  @override
  Future<HermesSettings> save(HermesSettingsEdit edit) async {
    saved.add(edit);
    return current;
  }

  @override
  Future<HermesTestResult> test(HermesSettingsEdit edit) async {
    tested.add(edit);
    return const HermesTestResult(reason: 'unauthorized');
  }

  @override
  Future<HermesStatus> status() async => const HermesStatus(
    configured: true,
    reachable: true,
    capabilities: HermesCapabilitiesDto(
      jobs: true,
      jobsAdmin: true,
      skills: true,
      toolsets: true,
    ),
  );

  @override
  Future<HermesCatalog> catalog() async => const HermesCatalog(
    skills: [HermesSkillDto(name: 'review', description: 'Reviews code')],
    toolsets: [
      HermesToolsetDto(name: 'web', label: 'Web', tools: ['search', 'fetch']),
    ],
  );

  @override
  Future<HermesSessions> sessions() async => sessionList;

  @override
  Future<HermesSessions> delete(String id) async {
    deleted.add(id);
    return const HermesSessions();
  }

  @override
  Future<HermesJobs> jobs() async => HermesJobs(jobs: jobList);

  @override
  Future<HermesJobs> saveJob(HermesJobEdit edit) async {
    savedJobs.add(edit);
    return HermesJobs(jobs: jobList);
  }

  @override
  Future<HermesJobs> setJobEnabled(String id, {required bool enabled}) async {
    toggled.add((id, enabled));
    return HermesJobs(jobs: jobList);
  }

  @override
  Future<HermesJobs> runJob(String id) async {
    ran.add(id);
    return HermesJobs(jobs: jobList);
  }
}

class _Chats extends ChatActions {
  _Chats(super.ref);

  final List<String?> selected = [];

  @override
  void select(String? chatId) => selected.add(chatId);
}

void main() {
  late _FakeHermes hermes;
  late _Chats chats;
  late List<String> went;

  Component scoped(Component child) {
    went = <String>[];
    return ProviderScope(
      overrides: [
        hermesActionsProvider.overrideWith((ref) => hermes = _FakeHermes(ref)),
        chatActionsProvider.overrideWith((ref) => chats = _Chats(ref)),
        workspaceNavigateProvider.overrideWithValue(
          (context, to, {replace = false}) => went.add(to),
        ),
      ],
      child: child,
    );
  }

  Finder buttonWith(String text) => find.componentWithText(button, text);

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await pumpEventQueue();
    }
  }

  testComponents('settings: tested and saved, the key never shown', (
    tester,
  ) async {
    tester.pumpComponent(scoped(const HermesSettingsTab()));
    await settle();
    expect(find.text(t.app.hermesServerStatusTitle), findsOneComponent);
    expect(find.text('/review'), findsOneComponent);
    expect(find.text('Web'), findsOneComponent);

    await tester.click(buttonWith(t.app.directMcpTestConnection));
    await settle();
    expect(hermes.tested.single.baseUrl, 'https://hermes.example.com/v1');
    // Blank keeps the saved key: nothing is sent for it.
    expect(hermes.tested.single.apiKey, isNull);
    expect(
      find.text(t.desktop.desktopHermesTestUnauthorized),
      findsOneComponent,
    );
    await tester.click(buttonWith(t.app.save));
    await settle();
    expect(hermes.saved.single.enabled, isTrue);
    expect(find.text(t.app.saved), findsOneComponent);
  });

  testComponents('conversations open in the chat, and go when deleted', (
    tester,
  ) async {
    tester.pumpComponent(scoped(const HermesPage()));
    await settle();
    expect(find.text('Trip plans'), findsOneComponent);
    expect(find.text('Where to go in May'), findsOneComponent);

    await tester.click(buttonWith('Trip plans'));
    await settle();
    expect(chats.selected, ['local:hermes_s1']);
    expect(went, ['/']);

    await tester.click(buttonWith(t.app.delete).first);
    await settle();
    expect(find.text(t.app.hermesSessionDeleteTitle), findsOneComponent);
    await tester.click(buttonWith(t.app.delete).at(1));
    await settle();
    expect(hermes.deleted, ['s1']);
  });

  testComponents('scheduled agents are made, run and paused', (tester) async {
    tester.pumpComponent(scoped(const HermesPage()));
    await settle();
    expect(find.text('Morning brief'), findsOneComponent);
    expect(find.textContaining('Every day at 08:00'), findsOneComponent);

    await tester.click(buttonWith(t.app.hermesJobRunNow));
    await settle();
    expect(hermes.ran, ['j1']);
    expect(find.text(t.app.hermesJobStarted), findsOneComponent);

    await tester.click(buttonWith(t.app.edit));
    await settle();
    await tester.click(
      find.byComponentPredicate(
        (c) => c is DomComponent && c.id == 'hermes-job-save',
      ),
    );
    await settle();
    expect(hermes.savedJobs.single.id, 'j1');
    expect(hermes.savedJobs.single.prompt, 'Summarise the news');
    expect(find.text(t.app.hermesJobUpdated), findsOneComponent);
  });
}
