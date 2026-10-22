import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_files.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_work.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/widgets/hermes_mobile_shell.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Selected extends SelectedModel {
  @override
  Model? build() => hermesSyntheticModel();
}

class _Sessions extends HermesSessionsController {
  @override
  Future<List<HermesSessionSummary>> build() async => const [
    HermesSessionSummary(id: 'one', title: 'Website redesign'),
    HermesSessionSummary(id: 'two', title: 'Trip planning'),
    HermesSessionSummary(
      id: 'cron_morning_run',
      title: 'Morning Pulse',
      source: 'cron',
    ),
  ];
}

class _Jobs extends HermesJobsController {
  _Jobs(this.jobs);
  final List<HermesJob> jobs;
  @override
  Future<List<HermesJob>> build() async => jobs;
  void clear() => state = const AsyncData([]);
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('navigation exposes a selected surface in ${brightness.name}', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        var selected = HermesWorkArea.explore;
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark
                ? AppTheme.dark(TweakcnThemes.t3Chat)
                : AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) => HermesBottomNavigation(
                    selected: selected,
                    onSelected: (area) => setState(() => selected = area),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final navigation = find.byType(HermesBottomNavigation);
        final theme = tester.element(navigation).conduitTheme;
        ButtonStyle style(String area) => tester
            .widget<TextButton>(find.byKey(ValueKey('hermes-nav-$area')))
            .style!;
        expect(
          tester.getSize(navigation).height,
          HermesBottomNavigation.height,
        );
        expect(
          style('explore').backgroundColor!.resolve({}),
          theme.navigationSelectedBackground,
        );
        expect(
          style('explore').foregroundColor!.resolve({}),
          theme.navigationSelected,
        );
        expect(
          find.byKey(const ValueKey('hermes-nav-label-explore')),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.byKey(const ValueKey('hermes-nav-explore'))),
          isSemantics(
            isSelected: true,
            label: 'Skills',
            isButton: true,
            hasTapAction: true,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
        await tester.pumpAndSettle();
        expect(selected, HermesWorkArea.tasks);
        expect(
          style('tasks').backgroundColor!.resolve({}),
          theme.navigationSelectedBackground,
        );
        expect(
          style('explore').backgroundColor!.resolve({}),
          Colors.transparent,
        );
        expect(
          find.byKey(const ValueKey('hermes-nav-label-explore')),
          findsOneWidget,
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('hermes-nav-label-tasks')),
          findsOneWidget,
        );
        expect(
          tester.getSize(navigation).height,
          HermesBottomNavigation.heightFor(tester.element(navigation)),
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  test(
    'compact schedules expose uncommon cron as custom, keeping natural wording',
    () {
      expect(hermesScheduleSummary('0 9 1,15 * *'), 'Custom schedule');
      expect(hermesScheduleSummary('0 9 * * 1-5'), 'Weekdays at 9:00 AM');
      expect(
        hermesScheduleSummary('every Monday at 9 AM'),
        'every Monday at 9 AM',
      );
    },
  );

  test('conversation groups use this-week days, last week, months and stable unknown dates', () {
    final now = DateTime(2026, 10, 10);
    final groups = groupHermesConversations([
      HermesSessionSummary(
        id: 'month',
        title: 'Month',
        updatedAt: DateTime(2026, 9, 17),
      ),
      const HermesSessionSummary(id: 'unknown', title: 'Unknown'),
      HermesSessionSummary(
        id: 'week',
        title: 'Week',
        updatedAt: DateTime(2026, 10, 3),
      ),
      HermesSessionSummary(
        id: 'today',
        title: 'Today',
        updatedAt: DateTime(2026, 10, 10),
      ),
      HermesSessionSummary(
        id: 'friday',
        title: 'Friday',
        updatedAt: DateTime(2026, 10, 9),
      ),
    ], now);
    expect(groups.map((g) => g.kind), [
      HermesConversationPeriod.day,
      HermesConversationPeriod.day,
      HermesConversationPeriod.lastWeek,
      HermesConversationPeriod.month,
      HermesConversationPeriod.older,
    ]);
    expect(groups.map((g) => g.sessions.single.id), [
      'today',
      'friday',
      'week',
      'month',
      'unknown',
    ]);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'Mobile work areas support 200 percent text in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        await _pump(
          tester,
          brightness: brightness,
          textScale: 2,
          jobs: const [
            HermesJob(
              id: 'large',
              name: 'Weekly review',
              prompt: 'Review work',
              schedule: '0 9 * * 0',
            ),
          ],
        );
        for (final area in ['chat', 'tasks', 'files', 'explore']) {
          await tester.tap(find.byKey(ValueKey('hermes-nav-$area')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: area);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          if (area == 'tasks') {
            expect(find.text('Weekly review'), findsOneWidget);
          }
        }
        semantics.dispose();
      },
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'native Back cancels a pending history open without leaving Conduit',
    (tester) async {
      final container = await _pump(tester);
      final epoch = container
          .read(hermesSessionNavigationEpochProvider.notifier)
          .bump();
      final opening = container.read(hermesSessionOpeningProvider.notifier);
      opening.start('waiting', epoch);
      final token = opening.tokenFor(epoch)!;
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(container.read(hermesSessionOpeningProvider), isNull);
      expect(token.isCancelled, true);
      expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native route Back closes the model panel before the chat', (
    tester,
  ) async {
    final container = await _pump(tester);
    final navigation = container.read(hermesMobileNavigationProvider.notifier);
    navigation.showConversation();
    await tester.pumpAndSettle();
    final panel = container.read(hermesMobileModelPanelProvider);
    final owner = Object();
    var closes = 0;
    panel.register(owner, () {
      closes++;
      panel.clear(owner);
    });
    // Predictive Android Back can reach the route's PopScope directly, without
    // going through an overlay's Router BackButtonListener.
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(closes, 1);
    expect(container.read(hermesMobileNavigationProvider).conversation, isTrue);
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(
      container.read(hermesMobileNavigationProvider).conversation,
      isFalse,
    );
  });

  testWidgets('Android Back walks visited work areas before leaving the app', (
    tester,
  ) async {
    final container = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('hermes-nav-files')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hermes-nav-explore')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      container.read(hermesMobileNavigationProvider).area,
      HermesWorkArea.files,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      container.read(hermesMobileNavigationProvider).area,
      HermesWorkArea.chat,
    );
    expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
    expect(
      container.read(hermesMobileNavigationProvider.notifier).canGoBack,
      isFalse,
    );
  });

  testWidgets('Tasks shows recent runs without an empty active-task row', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.text('No active tasks'), findsNothing);
    expect(find.text('Recent task runs'), findsOneWidget);
  });

  testWidgets('Tasks keeps a completed request after leaving and returning', (
    tester,
  ) async {
    final container = await _pump(tester);
    container
        .read(hermesTaskReceiptsProvider.notifier)
        .record(
          markNativeHermesConversation(
            Conversation(
              id: 'local:hermes_completed',
              title: 'Calculate the total',
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
              metadata: const {'hermesSessionId': 'completed'},
            ),
          ),
          ChatMessage(
            id: 'answer',
            role: 'assistant',
            content: '338350',
            timestamp: DateTime(2026),
          ),
          HermesChatOutcome.completed,
        );
    await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.text('Calculate the total'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hermes-nav-explore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-task-completed')), findsOneWidget);
  });

  for (final newerSnapshot in [false, true]) {
    testWidgets(
      newerSnapshot
          ? 'Tasks shows a newer remote run instead of the previous completed receipt'
          : 'Tasks keeps a completed receipt instead of an older active snapshot',
      (tester) async {
        final activeTasks = <Map<String, dynamic>>[];
        final container = await _pump(tester, activeTasks: activeTasks);
        final now = DateTime(2026, 10, 17);
        final taskA = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_task-a',
            title: 'Summarize task A',
            createdAt: now,
            updatedAt: now,
            metadata: const {'hermesSessionId': 'task-a'},
          ),
        );
        container
            .read(hermesTaskReceiptsProvider.notifier)
            .record(
              taskA,
              ChatMessage(
                id: 'task-a-answer',
                role: 'assistant',
                content: 'Summary complete',
                timestamp: now,
              ),
              HermesChatOutcome.completed,
            );
        final receipt = container.read(hermesTaskReceiptsProvider).single;
        final recordedAt = receipt.session.updatedAt!.millisecondsSinceEpoch;
        activeTasks.add({
          'session_key': 'task-a',
          'title': 'Summarize task A',
          'status': 'working',
          '_conduitObservedAt': recordedAt + (newerSnapshot ? 1 : -1),
        });
        final taskB = markNativeHermesConversation(
          Conversation(
            id: 'local:hermes_task-b',
            title: 'Another conversation',
            createdAt: now,
            updatedAt: now,
            metadata: const {'hermesSessionId': 'task-b'},
          ),
        );
        container.read(activeConversationProvider.notifier).set(taskB);
        container.read(hermesActiveSessionProvider.notifier).set('task-b');
        await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
        await tester.pumpAndSettle();

        expect(find.text('Summarize task A'), findsOneWidget);
        expect(
          find.text('Done'),
          newerSnapshot ? findsNothing : findsOneWidget,
        );
        expect(
          find.text('Running'),
          newerSnapshot ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const ValueKey('hermes-task-task-a')),
          newerSnapshot ? findsNothing : findsOneWidget,
        );
        expect(container.read(activeConversationProvider)?.id, taskB.id);
        expect(container.read(hermesActiveSessionProvider), 'task-b');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Tasks has one creation action with task and schedule choices', (
    tester,
  ) async {
    await _pump(
      tester,
      jobs: const [
        HermesJob(
          id: 'weekly',
          name: 'Weekly',
          prompt: 'Review',
          schedule: '0 9 * * 0',
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.byType(HermesScheduleCreateAction), findsOneWidget);
    expect(find.byKey(const ValueKey('hermes-create-task')), findsNothing);
    await tester.tap(find.byType(HermesScheduleCreateAction));
    await tester.pumpAndSettle();
    expect(find.text('New schedule'), findsOneWidget);
    expect(find.text('Create a task'), findsOneWidget);
  });

  test('Files discovers a generated output returned only by a tool', () {
    final raw = <Map<String, dynamic>>[
      {
        'id': 'tool-output',
        'role': 'tool',
        'name': 'generate_report',
        'content': '{"output_file":"/workspace/output/report.pdf"}',
      },
      {'id': 'reply', 'role': 'assistant', 'content': 'Your report is ready.'},
    ];
    final files = hermesLibraryFilesForTranscript(
      raw,
      const HermesSessionSummary(id: 'report-session', title: 'Report'),
    );
    expect(files.map((file) => file.name), contains('report.pdf'));
  });

  test('Files recognizes terminal and media outputs without indexing inputs or remote links', () {
    final files = hermesLibraryFilesForTranscript([
      {
        'id': 'terminal',
        'role': 'tool',
        'name': 'terminal',
        'content': '{"stdout":"Wrote /workspace/report.pdf"}',
      },
      {
        'id': 'image',
        'role': 'tool',
        'name': 'image_generate',
        'content': '<untrusted_tool_result>{"outputs":[{"file_path":"/workspace/image.png"}]}</untrusted_tool_result>',
      },
      {
        'id': 'reply',
        'role': 'assistant',
        'content': 'MEDIA:/workspace/audio.mp3\nSaved /workspace/report.pdf',
      },
      {'id': 'user', 'role': 'user', 'content': '/workspace/private.txt'},
      {
        'id': 'read',
        'role': 'tool',
        'name': 'read_file',
        'content': {'path': '/workspace/input.txt'},
      },
      {
        'id': 'web',
        'role': 'assistant',
        'content': '[Remote](https://example.org/file.pdf)',
      },
    ], const HermesSessionSummary(id: 'outputs', title: 'Outputs'));
    expect(files.map((file) => file.name).toSet(), {
      'report.pdf',
      'image.png',
      'audio.mp3',
    });
    expect(files.where((file) => file.name == 'report.pdf'), hasLength(1));
  });

  testWidgets(
    'Chat starts on recent conversations and searches without opening a chat',
    (tester) async {
      final container = await _pump(tester);
      expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
      expect(find.text('Chat content'), findsNothing);
      expect(find.text('Website redesign'), findsOneWidget);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('hermes-new-conversation')))
            .dy,
        lessThan(tester.getTopLeft(find.text('Trip planning')).dy),
      );
      await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('messages-search-input')),
        'website',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('Trip planning'), findsNothing);
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isFalse,
      );
    },
  );

  testWidgets(
    'Tasks plus opens a fresh task chat; bottom navigation returns to section roots',
    (tester) async {
      final container = await _pump(tester, child: const HermesTaskStarter());
      await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-create-task')));
      await tester.pumpAndSettle();
      expect(container.read(hermesMobileNavigationProvider).taskDraft, isTrue);
      expect(find.text('Describe what you want to happen'), findsOneWidget);
      await tester.tap(
        find.text('Every weekday at 8 AM, help me plan my day.'),
      );
      await tester.pump();
      expect(
        container.read(prefilledInputTextProvider),
        'Every weekday at 8 AM, help me plan my day.',
      );
      await tester.tap(find.byKey(const ValueKey('hermes-nav-files')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-nav-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isFalse,
      );
      expect(container.read(hermesMobileNavigationProvider).taskDraft, isTrue);
    },
  );

  testWidgets(
    'Files shows conversation outputs without requiring folder browsing',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-files')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-files-folders')), findsNothing);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
    },
  );

  testWidgets('Explore uses a selected skill to prefill a new conversation', (
    tester,
  ) async {
    final container = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('hermes-nav-explore')));
    await tester.pumpAndSettle();
    expect(find.text('Plan a project'), findsOneWidget);
    expect(find.textContaining('Browse and manage skills'), findsNothing);
    expect(find.text('Planning'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hermes-skill-/planning')));
    await tester.pumpAndSettle();
    expect(find.text('Plan a project'), findsNWidgets(2));
    expect(
      container.read(hermesMobileNavigationProvider).conversation,
      isFalse,
    );
    await tester.tap(find.text('New Chat'));
    await tester.pumpAndSettle();
    expect(container.read(prefilledInputTextProvider), '/planning ');
    expect(container.read(hermesMobileNavigationProvider).conversation, isTrue);
    expect(find.text('Chat content'), findsOneWidget);
  });

  testWidgets(
    'Skill category filter narrows groups and All categories restores them',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-explore')));
      await tester.pumpAndSettle();
      expect(find.text('Planning'), findsOneWidget);
      expect(find.text('Academic Search'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('hermes-skill-category-filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Research').last);
      await tester.pumpAndSettle();
      expect(find.text('Planning'), findsNothing);
      expect(find.text('Academic Search'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('hermes-skill-category-filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All categories'));
      await tester.pumpAndSettle();
      expect(find.text('Planning'), findsOneWidget);
      expect(find.text('Academic Search'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'research');
      await tester.pumpAndSettle();
      expect(find.text('Academic Search'), findsOneWidget);
      expect(find.text('Planning'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Scheduled runs belong to Tasks, not recent conversations', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Morning Pulse'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent task runs'));
    await tester.pumpAndSettle();
    expect(find.text('Morning Pulse'), findsOneWidget);
  });

  testWidgets(
    'Skills opens directly, exposes purpose, and filters before starting a chat',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-explore')));
      await tester.pumpAndSettle();
      expect(find.text('Search skills'), findsOneWidget);
      expect(find.text('Plan a project'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'planning');
      await tester.pumpAndSettle();
      expect(find.text('Planning'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.text('Planning'), findsNothing);
      expect(find.text('Hermes settings'), findsNothing);
      expect(find.text('App settings'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-nav-explore')));
      await tester.pumpAndSettle();
      expect(find.text('Search skills'), findsOneWidget);
      expect(find.text('Planning'), findsOneWidget);
    },
  );

  testWidgets(
    'Schedule errors open on demand and repair starts an unsent chat draft',
    (tester) async {
      const error = 'Provider rejected thinking_level with HTTP 400';
      final container = await _pump(
        tester,
        jobs: const [
          HermesJob(
            id: 'weekly',
            name: 'Weekly review',
            prompt: 'Review work',
            schedule: '0 9 * * 0',
            lastStatus: 'error',
            lastError: error,
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
      await tester.pumpAndSettle();
      expect(find.text('Schedules'), findsOneWidget);
      expect(find.text('Manage schedules'), findsNothing);
      expect(find.text(error), findsNothing);
      expect(find.text('Last run failed'), findsOneWidget);
      final icon = find.text('Weekly review');
      await tester.ensureVisible(icon);
      await tester.tap(icon);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Schedule actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View schedule error'));
      await tester.pumpAndSettle();
      expect(find.text(error), findsOneWidget);
      // A background jobs refresh can remove the source card while the
      // independent details modal stays open.
      (container.read(hermesJobsProvider.notifier) as _Jobs).clear();
      await tester.pumpAndSettle();
      expect(find.byType(HermesScheduleCard), findsNothing);
      await tester.tap(find.byKey(const ValueKey('hermes-job-fix-weekly')));
      await tester.pumpAndSettle();
      expect(container.read(prefilledInputTextProvider), contains(error));
      expect(
        container.read(prefilledInputTextProvider),
        contains('Job ID: weekly'),
      );
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isTrue,
      );
      expect(find.text('Chat content'), findsOneWidget);
    },
  );

  testWidgets('Schedules show compact rows and reveal actions in details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      jobs: [
        HermesJob(
          id: 'news',
          name: 'Latest News',
          prompt: 'Find news',
          schedule: '30 13 * * 2,6',
          nextRun: DateTime(2026, 10, 10, 13, 30),
          lastStatus: 'completed',
          lastRun: DateTime(2026, 10, 6),
        ),
        const HermesJob(
          id: 'weekly',
          name: 'Weekly Review',
          prompt: 'Review work',
          schedule: '0 9 * * 0',
          lastStatus: 'error',
          lastError: 'Provider error',
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('hermes-nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.text('Last run completed'), findsNothing);
    expect(find.text('Run now'), findsNothing);
    expect(find.byTooltip('Delete schedule'), findsNothing);
    expect(find.byTooltip('Schedule details'), findsNothing);
    expect(find.byKey(const ValueKey('hermes-job-run-news')), findsNothing);
    await tester.tap(find.text('Latest News'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-job-run-news')), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();
    // Ahem's fixed-width test glyphs wrap cadence differently from app fonts.
    // Check physical layout only in the render fixture with Roboto loaded.
    if (const String.fromEnvironment('CONDUIT_RENDER_FONT').isNotEmpty) {
      expect(
        tester.getSize(find.byType(HermesScheduleCard).first).height,
        lessThan(140),
      );
    }
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CONDUIT_CAPTURE_RENDER')) {
      await tester.runAsync(() async {
        final boundary =
            tester
                    .element(
                      find.byKey(const ValueKey('hermes-mobile-preview')),
                    )
                    .findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/mobile-preview/compact-schedules.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  test('Schedule cadence covers comma weekdays without guessing unknown cron forms', () {
    expect(
      describeHermesCronSchedule('30 13 * * 2,6'),
      'Every Tuesday, Saturday at 1:30 PM',
    );
    expect(
      describeHermesCronSchedule('30 13 * * TUE,SAT'),
      'Every Tuesday, Saturday at 1:30 PM',
    );
    expect(describeHermesCronSchedule('30 13 * * 2,8'), '30 13 * * 2,8');
    expect(describeHermesCronSchedule('-1 13 * * *'), '-1 13 * * *');
    expect(
      const HermesSessionSummary(
        id: 'cron_old',
        title: 'Old run',
      ).isScheduledRun,
      isTrue,
    );
    expect(
      const HermesSessionSummary(
        id: 'cron_named',
        title: 'Human chat',
        source: 'telegram',
      ).isScheduledRun,
      isFalse,
    );
    expect(
      const HermesSessionSummary(
        id: 'human',
        title: 'Skill Evolution Cycle',
        source: 'desktop',
      ).isScheduledRun,
      isFalse,
    );
  });

  test('file categories use attachment provenance, and text paths are not promoted', () {
    const session = HermesSessionSummary(id: 'one', title: 'Example');
    final files = hermesLibraryFilesForMessages([
      ChatMessage(
        id: 'user',
        role: 'user',
        content: 'Look at /tmp/private.txt',
        timestamp: DateTime(2026),
        files: [
          {'name': 'notes.txt'},
        ],
      ),
      ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: 'Done',
        timestamp: DateTime(2026),
        files: [
          {'name': 'report.pdf'},
          {'name': 'results.json'},
        ],
      ),
    ], session);
    expect(files.map((file) => file.category), [
      HermesFileCategory.uploads,
      HermesFileCategory.artifacts,
      HermesFileCategory.outputs,
    ]);
    expect(files.map((file) => file.name), [
      'notes.txt',
      'report.pdf',
      'results.json',
    ]);
  });

  test('File discovery recognizes assistant file links and ignores user paths and remote links', () {
    const session = HermesSessionSummary(id: 'one', title: 'Example');
    final files = hermesLibraryFilesForMessages([
      ChatMessage(
        id: 'u',
        role: 'user',
        content: '[Secret](/tmp/secret.txt)',
        timestamp: DateTime(2026),
      ),
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: '[Report](/workspace/report.pdf) [Remote](https://example.org/file.pdf) [Again](/workspace/report.pdf)',
        timestamp: DateTime(2026),
      ),
    ], session);
    expect(files, hasLength(1));
    expect(files.single.outputPath, '/workspace/report.pdf');
    expect(files.single.category, HermesFileCategory.artifacts);
  });
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Widget child = const Text('Chat content'),
  List<HermesJob> jobs = const [],
  Brightness brightness = Brightness.light,
  double textScale = 1,
  List<Map<String, dynamic>>? activeTasks,
}) async {
  const renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
  if (renderFont.isNotEmpty) {
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(renderFont).readAsBytes()),
          ),
        );
      await loader.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
  }
  final container = ProviderContainer(
    overrides: [
      hermesMobileLayoutProvider.overrideWithValue(true),
      selectedModelProvider.overrideWith(_Selected.new),
      apiServiceProvider.overrideWithValue(null),
      hermesApiServiceProvider.overrideWithValue(null),
      hermesSessionsProvider.overrideWith(_Sessions.new),
      hermesJobsProvider.overrideWith(() => _Jobs(jobs)),
      hermesCapabilitiesProvider.overrideWith(
        (_) async => HermesCapabilities(jobs: jobs.isNotEmpty, toolsets: false),
      ),
      isChatStreamingProvider.overrideWithValue(false),
      if (activeTasks != null)
        hermesMobileActiveTasksProvider.overrideWith((_) async => activeTasks),
      hermesMobileSkillsProvider.overrideWith(
        (_) async => const [
          Prompt(
            command: '/planning',
            title: 'Plan a project',
            content: '/planning ',
            meta: {'hermesSkillCategory': 'productivity'},
          ),
          Prompt(
            command: '/academic-search',
            title: 'Find academic papers',
            content: '/academic-search ',
            meta: {'hermesSkillCategory': 'research'},
          ),
        ],
      ),
      hermesMobileFilesProvider.overrideWith(
        (_) => Stream.value(
          const HermesFileLibrary([
            HermesLibraryFile(
              name: 'report.pdf',
              category: HermesFileCategory.artifacts,
              session: HermesSessionSummary(
                id: 'one',
                title: 'Website redesign',
              ),
              messageId: 'a',
            ),
            HermesLibraryFile(
              name: 'notes.txt',
              category: HermesFileCategory.uploads,
              session: HermesSessionSummary(
                id: 'one',
                title: 'Website redesign',
              ),
              messageId: 'b',
            ),
          ]),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme:
            (brightness == Brightness.dark
                    ? AppTheme.dark(TweakcnThemes.conduit)
                    : AppTheme.light(TweakcnThemes.conduit))
                .copyWith(
                  textTheme:
                      (brightness == Brightness.dark
                              ? AppTheme.dark(TweakcnThemes.conduit)
                              : AppTheme.light(TweakcnThemes.conduit))
                          .textTheme
                          .apply(
                            fontFamily: renderFont.isEmpty ? null : 'Roboto',
                          ),
                ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepaintBoundary(
          key: const ValueKey('hermes-mobile-preview'),
          child: HermesMobileShell(child: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
