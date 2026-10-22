import 'package:conduit_core/features/hermes/models/hermes_group_live_reply.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit/features/hermes/providers/hermes_group_runtime.dart';
import 'package:conduit_core/features/hermes/services/hermes_workspace_service.dart';
import 'package:conduit/features/hermes/views/hermes_bot_workspace_page.dart';
import 'package:conduit/features/hermes/views/hermes_bot_setup_page.dart';
import 'package:conduit/features/hermes/views/hermes_jobs_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_schedule_details.dart';
import 'package:conduit/features/hermes/widgets/hermes_schedule_editor.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/features/hermes/widgets/hermes_conversation_stage.dart';
import 'package:conduit/features/hermes/widgets/hermes_capability_picker.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce/hive.dart';
import 'package:dio/dio.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:conduit/features/hermes/widgets/hermes_mobile_shell.dart';
import 'package:conduit/features/hermes/widgets/hermes_messages_home.dart';
import 'package:conduit/features/hermes/providers/hermes_messages.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_work.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_messages_backend.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

class _Selected extends SelectedModel {
  @override
  Model? build() => hermesSyntheticModel();
}

class _Settings extends AppSettingsNotifier {
  _Settings([this.reduced = true]);
  final bool reduced;
  @override
  AppSettings build() => AppSettings(reduceMotion: reduced);
}

class _Backend extends Fake
    implements HermesBackendService, HermesMessagesBackend {
  @override
  final config = const HermesConfig(
    enabled: true,
    baseUrl: 'http://fixture.invalid:9119',
    mode: HermesBackendMode.desktopGateway,
  );
  final calls = <({String method, String profile, String? id})>[];
  final drafts = <HermesBotDraft>[];
  bool partialSetup = false;
  bool rosterFailed = false;
  int finishAttempts = 0;
  final approvals = <({String id, String choice})>[];
  final bots = [
    const HermesBot(
      name: 'research',
      title: 'Researcher',
      chatSessionId: 'research-chat',
    ),
    const HermesBot(
      name: 'coding',
      title: 'Coding',
      chatSessionId: 'coding-chat',
    ),
  ];
  final groups = [
    HermesBotGroup(
      key: 'id:team',
      roomId: 'team',
      name: 'Project team',
      memberProfiles: const ['research', 'coding'],
      coordinator: 'coding',
      messages: [
        HermesGroupMessage(
          id: 'seed',
          text: 'The next steps are ready.',
          at: DateTime(2026, 9, 22),
        ),
      ],
    ),
  ];
  int extraChats = 0;
  Completer<List<Map<String, dynamic>>>? heldTranscript;
  CancelToken? heldCancel;
  bool holdApproval = false;
  bool requestSpecialist = false;
  int coordinatorTurns = 0;
  StreamController<HermesRunEvent>? pending;
  @override
  Future<List<HermesBot>> listBots() async {
    if (rosterFailed) throw StateError('Roster unavailable');
    return bots;
  }

  @override
  Future<String?> botAvatar(String profile) async => null;
  @override
  Future<List<Map<String, dynamic>>> listSessions() async => [
    {
      'id': 'website',
      'title': 'Website redesign',
      'last_active': DateTime.now().millisecondsSinceEpoch / 1000,
    },
    for (var i = 0; i < extraChats; i++)
      {
        'id': 'extra-$i',
        'title': 'Earlier conversation $i',
        'last_active': DateTime.now().millisecondsSinceEpoch / 1000,
      },
  ];
  @override
  Future<List<HermesSessionSummary>> listProfileSessions(
    String profile, {
    CancelToken? cancelToken,
  }) async {
    calls.add((method: 'list', profile: profile, id: null));
    return profile == 'default'
        ? [
            HermesSessionSummary(
              id: 'website',
              title: 'Website redesign',
              updatedAt: DateTime.now(),
            ),
            for (var i = 0; i < extraChats; i++)
              HermesSessionSummary(
                id: 'extra-$i',
                title: 'Earlier conversation $i',
                updatedAt: DateTime.now(),
              ),
          ]
        : [
            HermesSessionSummary(
              id: '$profile-chat',
              title: 'Bot Chat',
              updatedAt: DateTime.now(),
            ),
          ];
  }

  @override
  Future<List<Map<String, dynamic>>> readStoredTranscript(
    String id, {
    String? profile,
    CancelToken? cancelToken,
  }) async {
    calls.add((method: 'read', profile: profile ?? 'default', id: id));
    if (heldTranscript != null) {
      heldCancel = cancelToken;
      return heldTranscript!.future;
    }
    if (id == 'website') {
      return [
        {'role': 'user', 'content': 'Please find orchid references.'},
        {'role': 'assistant', 'content': 'Let’s simplify the navigation.'},
      ];
    }
    if (id == 'research-chat') {
      return [
        {'role': 'assistant', 'content': 'Earlier source: orchid paper.'},
        {
          'role': 'tool',
          'name': 'generate_report',
          'content': '{"output_file":"/workspace/report.pdf"}',
        },
        {'role': 'assistant', 'content': 'I found three primary sources.'},
      ];
    }
    return [
      {'role': 'assistant', 'content': 'The settings change is ready.'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getSessionMessages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    calls.add((method: 'resume', profile: 'default', id: id));
    return [];
  }

  @override
  void bindBotSession(String profile, String sessionId) {
    calls.add((method: 'bind', profile: profile, id: sessionId));
  }

  @override
  Future<HermesSessionSummary?> findBotChat(
    String profile, {
    CancelToken? cancelToken,
  }) async {
    calls.add((method: 'canonical', profile: profile, id: null));
    final id = profile == 'default' ? 'default-bot-chat' : '$profile-chat';
    return HermesSessionSummary(
      id: id,
      title: 'Bot Chat',
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<String> openBotChat(HermesBot bot) async {
    calls.add((method: 'open', profile: bot.name, id: null));
    return bot.chatSessionId ?? '${bot.name}-chat';
  }

  @override
  Future<List<HermesBotGroup>> listBotGroups() async => List.of(groups);
  @override
  Future<HermesBotGroup> saveBotGroup(HermesBotGroup group) async {
    groups.removeWhere((g) => g.identity == group.identity);
    groups.add(group);
    return group;
  }

  @override
  Future<HermesBot> createBot(HermesBotDraft draft) async {
    drafts.add(draft);
    final bot = HermesBot(name: draft.profile, title: draft.title);
    bots.add(bot);
    if (partialSetup) throw HermesBotSetupIncomplete(draft.profile);
    return bot;
  }

  @override
  Future<String> openGroupMemberSession(
    HermesBotGroup group,
    String profile, {
    CancelToken? cancelToken,
  }) async {
    calls.add((method: 'group-session', profile: profile, id: group.identity));
    return 'group-${group.identity}-$profile';
  }

  @override
  Future<HermesResponseStream> streamGroupMemberResponse(
    String sessionId,
    String text, {
    CancelToken? cancelToken,
  }) async {
    final profile = sessionId.endsWith('research') ? 'research' : 'coding';
    calls.add((method: 'prompt', profile: profile, id: sessionId));
    if (holdApproval) {
      holdApproval = false;
      pending = StreamController<HermesRunEvent>();
      scheduleMicrotask(
        () => pending!.add(
          const HermesApprovalRequested(
            approvalId: 'confirm',
            summary: 'Run a fixture command',
            choices: ['once', 'deny'],
          ),
        ),
      );
      return HermesResponseStream(
        events: pending!.stream,
        sessionId: sessionId,
      );
    }
    return HermesResponseStream(
      events: Stream.fromIterable([
        HermesTokenDelta(
          requestSpecialist && profile == 'coding' && coordinatorTurns++ == 0
              ? '@research Please check the sources.'
              : '$profile answered.',
        ),
        const HermesRunDone(),
      ]),
      sessionId: sessionId,
    );
  }

  @override
  Future<void> resolveApprovalChoiceForSession(
    String storedSessionId, {
    required String approvalId,
    required String choice,
  }) async {
    approvals.add((id: storedSessionId, choice: choice));
    pending!.add(const HermesTokenDelta('coding answered.'));
    pending!.add(const HermesRunDone());
    await pending!.close();
  }

  @override
  Future<List<Map<String, dynamic>>> listJobs() async => [
    {
      'id': 'digest',
      'name': 'Research digest',
      'prompt': 'Compare new papers',
      'schedule': '0 9 * * 1-5',
    },
  ];
  @override
  Future<List<Map<String, dynamic>>> listProfileJobs(
    String profile, {
    CancelToken? cancelToken,
  }) => profile == 'coding' ? Future.value([]) : listJobs();
  @override
  Future<List<Map<String, dynamic>>> listSkills() async => [
    {'name': 'research', 'description': 'Find sources'},
  ];
  @override
  Future<HermesBot> finishBotSetup(HermesBotDraft draft) async {
    finishAttempts++;
    return HermesBot(name: draft.profile, title: draft.title);
  }

  @override
  Future<List<Map<String, dynamic>>> listProfileSkills(String profile) async =>
      [
        {'name': 'research', 'description': 'Find sources', 'enabled': true},
      ];
  @override
  Future<List<Map<String, dynamic>>> listProfileToolsets(
    String profile,
  ) async => [
    {'name': 'terminal', 'label': 'Terminal', 'enabled': true},
  ];
  @override
  void close() {}
}

class _WorkspaceBackend extends _Backend implements HermesWorkspaceService {
  bool hasArchived = false, failSave = false;
  final changes = <Map<String, dynamic>>[];
  List<Map<String, dynamic>>? profileJobs;
  final scheduleMutations =
      <
        ({
          String profile,
          String? id,
          String action,
          Map<String, dynamic> values,
        })
      >[];
  @override
  Future<List<Map<String, dynamic>>> listProfileJobs(
    String profile, {
    CancelToken? cancelToken,
  }) async =>
      profileJobs ??
      await super.listProfileJobs(profile, cancelToken: cancelToken);
  @override
  Future<void> mutateBotJob(
    String profile, {
    String? id,
    required String action,
    Map<String, dynamic> values = const {},
  }) async {
    scheduleMutations.add((
      profile: profile,
      id: id,
      action: action,
      values: values,
    ));
    if (profileJobs != null && id != null) {
      profileJobs = [
        for (final row in profileJobs!)
          if (row['id'] == id)
            {
              ...row,
              ...values,
              if (action == 'pause') 'enabled': false,
              if (action == 'resume') 'enabled': true,
            }
          else
            row,
      ];
    }
  }

  @override
  Future<List<HermesSessionSummary>> archivedChats() async => hasArchived
      ? [
          const HermesSessionSummary(
            id: 'archived-one',
            title: 'Archived conversation',
            archived: true,
          ),
        ]
      : [];
  @override
  Future<Map<String, dynamic>> describeBot(String profile) async => {
    'description': 'Find reliable sources',
    'soul': '# Researcher\nBe concise.',
    'model': {'provider': 'fixture', 'default': 'fixture-model'},
    'skills': [
      {'name': 'research', 'enabled': true},
    ],
    'toolsets': [
      {'name': 'terminal', 'enabled': false},
    ],
    'mcp_servers': [
      {'name': 'Library', 'enabled': true},
    ],
    'ui_meta': {
      'hermes-bots': {
        'title': 'Researcher',
        'shape': 'squircle',
        'color': '#8b5cf6',
      },
    },
    'ui_meta_revisions': {'hermes-bots': 0},
  };
  @override
  Future<void> configureBot(String profile, Map<String, dynamic> data) async {
    if (failSave) throw StateError('Temporary save failure');
    changes.add(data);
  }

  @override
  Future<String> readBotMemory(
    String profile, {
    bool aboutUser = false,
  }) async => aboutUser ? 'Prefers primary sources.' : 'Research notes.';
  @override
  Future<List<HermesDesktopModelOption>> botModels(String profile) async => [
    HermesDesktopModelOption.fromJson({
      'id': 'fixture-model',
      'name': 'Fixture model',
      'provider': 'fixture',
    }),
  ];
  @override
  Future<List<Map<String, dynamic>>> botPlugins(String profile) async => [
    {'key': 'library', 'name': 'Library', 'enabled': true},
  ];
}

class _HostedBackend extends _WorkspaceBackend {
  _HostedBackend() {
    groups[0] = groups[0].copyWith(raw: {'hosted': true, 'hostedRoom': room});
  }
  final live = StreamController<HermesGroupLiveReply>.broadcast();
  final log = <Map<String, dynamic>>[];
  bool working = true;
  Map<String, dynamic> get room => {
    'room_id': 'team',
    'name': 'Project team',
    'members': [
      {'member_id': 'research', 'profile': 'research', 'handle': 'research'},
      {'member_id': 'coding', 'profile': 'coding', 'handle': 'coding'},
    ],
  };
  @override
  Stream<HermesGroupLiveReply> watchGroupReplies(HermesBotGroup group) =>
      live.stream;
  @override
  Future<Map<String, dynamic>> groupRequest(
    String action,
    Map<String, dynamic> params,
  ) async => switch (action) {
    'log' => {'events': log, 'cursor': log.length, 'has_more': false},
    'state' => {
      'room': room,
      'driver_status': {'working': working, 'pending_actions': []},
    },
    _ => {},
  };
}

Future<({ProviderContainer container, _Backend backend})> pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool reduceMotion = true,
  int extraChats = 0,
  _Backend? suppliedBackend,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await (FontLoader(
    'HermesControls',
  )..addFont(rootBundle.load('assets/icons/hermes-controls.ttf'))).load();
  const renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
  final renderTheme = brightness == Brightness.dark
      ? AppTheme.dark(TweakcnThemes.conduit)
      : AppTheme.light(TweakcnThemes.conduit);
  final backend = (suppliedBackend ?? _Backend())..extraChats = extraChats;
  final overrides = [
    hermesApiServiceProvider.overrideWithValue(backend),
    hermesMobileLayoutProvider.overrideWithValue(true),
    hermesOnlyModeProvider.overrideWithValue(true),
    selectedModelProvider.overrideWith(_Selected.new),
    apiServiceProvider.overrideWithValue(null),
    appSettingsProvider.overrideWith(() => _Settings(reduceMotion)),
    isChatStreamingProvider.overrideWithValue(false),
    hermesBotsProvider.overrideWith((_) async => backend.bots),
    hermesGroupArchiveProvider.overrideWith(
      (_) async => HermesGroupArchive(
        await SharedPreferences.getInstance(),
        'messages-fixture',
      ),
    ),
    hermesCapabilitiesProvider.overrideWith(
      (_) async => const HermesCapabilities(toolsets: false),
    ),
    hermesMobileSkillsProvider.overrideWith(
      (_) async => const [
        Prompt(
          command: '/research',
          title: 'Find sources',
          content: '/research ',
        ),
      ],
    ),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: renderTheme.copyWith(
          textTheme: renderTheme.textTheme.apply(
            fontFamily: renderFont.isEmpty ? null : 'Roboto',
          ),
          primaryTextTheme: renderTheme.primaryTextTheme.apply(
            fontFamily: renderFont.isEmpty ? null : 'Roboto',
          ),
        ),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('messages-render'),
          child: MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: const HermesMobileShell(child: Text('Conversation body')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HermesMobileShell)),
    listen: false,
  );
  return (container: container, backend: backend);
}

Future<void> search(WidgetTester tester, String value) async {
  await tester.enterText(
    find.byKey(const ValueKey('messages-search-input')),
    value,
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('MESSAGES_CAPTURE')) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('messages-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.impeccable/review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test(
    'message previews omit a duplicate title and retain distinct replies',
    () {
      expect(
        hermesMessagePreview('Website redesign', 'Website redesign'),
        isNull,
      );
      expect(
        hermesMessagePreview('Website redesign', '**Website   redesign**\n'),
        isNull,
      );
      expect(
        hermesMessagePreview('Website redesign', 'Website redesign is ready.'),
        'Website redesign is ready.',
      );
      expect(
        hermesMessagePreview(
          'Website redesign',
          '**Ready**: [Open the report](https://example.invalid) &amp; `review` ✅',
        ),
        'Ready: Open the report & review ✅',
      );
      expect(
        hermesMessagePreview('Tasks', '- **Review**\n- `Ship`'),
        'Review Ship',
      );
    },
  );
  test('message previews omit a repeated ellipsis-truncated prompt title', () {
    expect(
      hermesMessagePreview(
        'Design review test: use your terminal t...',
        '**Design review test:** use your terminal to inspect the app.',
      ),
      isNull,
    );
    expect(
      hermesMessagePreview(
        'Review the deployment checklist and confirm…',
        'Review the deployment checklist and confirm all required checks pass.',
      ),
      isNull,
    );
    expect(
      hermesMessagePreview(
        'Release plan…',
        '**Release plan** is ready for review.',
      ),
      'Release plan is ready for review.',
    );
    expect(
      hermesMessagePreview(
        'Design review test: use your terminal t...',
        '**Terminal review is complete**; the checks pass.',
      ),
      'Terminal review is complete; the checks pass.',
    );
    expect(
      hermesMessagePreview(
        'Design review test: use your terminal',
        'Design review test: use your terminal to inspect the app.',
      ),
      'to inspect the app.',
    );
  });
  testWidgets(
    'history keeps row elements and scroll owner while logical detail is visible',
    (tester) async {
      final fixture = await pump(tester, extraChats: 40);
      final lists = find.descendant(
        of: find.byType(HermesMessagesHome),
        matching: find.byType(ListView),
      );
      final controller = tester.widget<ListView>(lists.first).controller!;
      controller.jumpTo(200);
      await tester.pumpAndSettle();
      final offset = controller.offset;
      final visibleRow = find.byType(HermesMessageRow).first;
      final row = find.byKey(
        tester.widget<HermesMessageRow>(visibleRow).key!,
        skipOffstage: false,
      );
      final element = tester.element(row);
      final selected = tester.widget<HermesMessageRow>(row);
      final link = HermesConversationLinkScope.of(element)!;
      link.begin(selected.conversationId!, selected.title, 17);
      link.finish(17, resolved: true);
      fixture.container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversation();
      await tester.pumpAndSettle();
      expect(tester.element(row), same(element));
      expect(controller.hasClients, true);
      expect(controller.offset, offset);
      fixture.container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversations();
      await tester.pumpAndSettle();
      expect(tester.element(row), same(element));
      expect(controller.offset, offset);
      expect(tester.takeException(), isNull);
    },
  );

  setUpAll(() async {
    await initializeDateFormatting('en');
    const renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
    if (renderFont.isNotEmpty) {
      await (FontLoader('Roboto')..addFont(
            Future.value(
              ByteData.sublistView(await File(renderFont).readAsBytes()),
            ),
          ))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'timestamp uses a 12-hour boundary, yesterday, and abbreviated dates',
    () {
      final now = DateTime(2026, 10, 11, 16);
      expect(
        hermesMessageTimestamp(
          now.subtract(const Duration(hours: 1)),
          now,
          'en',
        ).replaceAll('\u202f', ' '),
        '3:00 PM',
      );
      expect(
        hermesMessageTimestamp(
          now.subtract(const Duration(hours: 12)),
          now,
          'en',
        ),
        'Oct 11',
      );
      expect(
        hermesMessageTimestamp(DateTime(2026, 10, 10, 12), now, 'en'),
        'Yesterday',
      );
      expect(
        hermesMessageTimestamp(DateTime(2026, 9, 22), now, 'en'),
        'Sep 22',
      );
    },
  );
  test(
    'regular Chats filter canonical sessions only in their owning profile',
    () {
      const bots = [
        HermesBot(name: 'coding', title: 'Coding', chatSessionId: 'shared'),
        HermesBot(
          name: 'default',
          title: 'Hermes',
          chatSessionId: 'default-bot',
        ),
      ];
      const sessions = [
        HermesSessionSummary(id: 'shared', title: 'Ordinary chat'),
        HermesSessionSummary(id: 'default-bot', title: 'Renamed bot'),
        HermesSessionSummary(
          id: 'root-tagged',
          title: 'New name',
          rootTitle: 'Bot Chat',
        ),
      ];
      expect(
        hermesRegularConversations(
          sessions,
          bots,
          profile: 'default',
        ).map((s) => s.id),
        ['shared'],
      );
    },
  );
  testWidgets(
    'Search cancels a pending read and rejects late results after exit',
    (tester) async {
      final fixture = await pump(tester);
      fixture.backend.heldTranscript = Completer();
      await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('messages-search-input')),
        'orchid',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 100));
      expect(fixture.backend.heldCancel, isNotNull);
      fixture.container
          .read(hermesMessagesNavigationProvider.notifier)
          .closeSearch();
      await tester.pumpAndSettle();
      expect(fixture.backend.heldCancel!.isCancelled, isTrue);
      fixture.backend.heldTranscript!.complete([
        {'role': 'assistant', 'content': 'Late orchid result'},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Late orchid result'), findsNothing);
      expect(find.byKey(const ValueKey('messages-search-input')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Search restores the retained conversation list offset', (
    tester,
  ) async {
    final fixture = await pump(tester, reduceMotion: false, extraChats: 40);
    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, -900));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    final original = position.pixels;
    expect(original, greaterThan(100));
    await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
    await tester.pumpAndSettle();
    fixture.container
        .read(hermesMessagesNavigationProvider.notifier)
        .closeSearch();
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(original, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Search preserves field identity and Back cancels opening focus',
    (tester) async {
      final fixture = await pump(tester, reduceMotion: false);
      final field = find.byKey(
        const ValueKey('messages-search-input'),
        skipOffstage: false,
      );
      final original = tester.element(field);
      final nav = fixture.container.read(
        hermesMessagesNavigationProvider.notifier,
      );
      await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.element(field), same(original));
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(nav.state.search, isFalse);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
      await tester.pumpAndSettle();
      expect(tester.element(field), same(original));
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await search(tester, 'orchid');
      nav.closeSearch();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(find.byKey(const ValueKey('messages-search-input')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Search keeps its scope visible and marks the selected choice', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('messages-search-categories')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('messages-search-category-state-all')),
        ),
        isSemantics(isSelected: true),
      );
      await tester.tap(
        find.byKey(const ValueKey('messages-search-category-files')),
      );
      await tester.pumpAndSettle();
      await search(tester, 'report');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('messages-search-category-value')),
            )
            .data,
        'Files',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('messages-search-input')),
            )
            .decoration!
            .hintText,
        'Search',
      );
      await tester.tap(
        find.byKey(const ValueKey('messages-search-categories')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('messages-search-category-state-files')),
        ),
        isSemantics(isSelected: true),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('messages-search-category-files')),
          matching: find.byKey(
            const ValueKey('messages-search-category-selected'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('messages-search-category-all')),
          matching: find.byKey(
            const ValueKey('messages-search-category-selected'),
          ),
        ),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('New Chat stays outside the conversation list while scrolling', (
    tester,
  ) async {
    await pump(tester, extraChats: 30);
    final list = find
        .descendant(
          of: find.byType(HermesMessagesHome),
          matching: find.byType(ListView),
        )
        .first;
    await tester.drag(list, const Offset(0, -10000));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('messages-chat-extra-29'));
    expect(row, findsOneWidget);
    final action = find.byKey(const ValueKey('hermes-new-conversation'));
    expect(tester.getRect(row).overlaps(tester.getRect(action)), isFalse);
    expect(
      tester.getRect(action).bottom,
      lessThanOrEqualTo(tester.getRect(list).top),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty Bots offers creation directly and Cancel keeps the list', (
    tester,
  ) async {
    final backend = _Backend();
    backend.bots.clear();
    backend.groups.clear();
    await pump(tester, suppliedBackend: backend);
    await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('messages-empty-create-bot')));
    await tester.pumpAndSettle();
    expect(find.byType(HermesBotSetupPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bot-setup-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('messages-empty-create-bot')),
      findsOneWidget,
    );
    expect(backend.calls.where((c) => c.method == 'clone'), isEmpty);
  });

  testWidgets('Search owns its category route when closed externally', (
    tester,
  ) async {
    final fixture = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('messages-search-categories')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('messages-search-category-all')),
      findsOneWidget,
    );
    fixture.container
        .read(hermesMessagesNavigationProvider.notifier)
        .closeSearch();
    await tester.pumpAndSettle();
    expect(find.text('All'), findsNothing);
    expect(find.byKey(const ValueKey('hermes-nav-label-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Bot Mode shows canonical bot chats, not ordinary sessions from the same profile',
    (tester) async {
      final fixture = await pump(tester);
      fixture.backend.bots.insert(
        0,
        const HermesBot(
          name: 'default',
          title: 'Hermes',
          chatSessionId: 'default-bot-chat',
        ),
      );
      fixture.container.invalidate(hermesMessagesBotsProvider);
      await tester.pumpAndSettle();
      expect(find.text('Website redesign'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      final rows = fixture.container
          .read(hermesBotConversationsProvider)
          .requireValue
          .rows;
      expect(
        rows.where((r) => r.bot.name == 'default').map((r) => r.session?.id),
        ['default-bot-chat'],
      );
      expect(
        fixture.backend.calls.where(
          (c) => c.method == 'read' && c.id == 'website',
        ),
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('messages-search-bots')));
      await tester.pumpAndSettle();
      await search(tester, 'orchid');
      final results = fixture.container
          .read(
            hermesMessagesSearchProvider((
              tab: HermesMessagesTab.bots,
              query: 'orchid',
            )),
          )
          .requireValue;
      expect(
        results.conversations.any((r) => r.session.id == 'website'),
        isFalse,
      );
    },
  );
  testWidgets(
    'Messages tabs, title-only groups, last assistant replies and creation menu',
    (tester) async {
      final fixture = await pump(tester);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
      expect(find.text('Recent conversations'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      expect(find.text('Researcher'), findsOneWidget);
      expect(find.text('I found three primary sources.'), findsOneWidget);
      expect(find.text('Earlier source: orchid paper.'), findsNothing);
      expect(find.text('Project team'), findsOneWidget);
      expect(find.text('The next steps are ready.'), findsNothing);
      final row = fixture.backend.calls.where((c) => c.method == 'read');
      expect(row.map((c) => c.profile).toSet(), {'research', 'coding'});
      expect(fixture.backend.calls.where((c) => c.method == 'resume'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
      await tester.pumpAndSettle();
      expect(find.text('New bot'), findsOneWidget);
      expect(find.text('New group chat'), findsOneWidget);
    },
  );
  testWidgets(
    'Chats search is blank, tab-specific, and finds earlier messages without resuming',
    (tester) async {
      final fixture = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('messages-search-chats')));
      await tester.pumpAndSettle();
      expect(find.text('Search bots'), findsNothing);
      expect(find.text('Search chats'), findsNothing);
      expect(
        find.text('Search conversation titles or messages.'),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('messages-search-input')),
            )
            .decoration!
            .hintText,
        'Search',
      );
      await tester.tap(
        find.byKey(const ValueKey('messages-search-categories')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Group chats'), findsNothing);
      expect(find.text('Bots'), findsNothing);
      expect(
        find.byKey(const ValueKey('messages-search-category-files')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('messages-search-category-all')),
      );
      await tester.pumpAndSettle();
      await search(tester, 'ORCHID');
      expect(find.text('Website redesign'), findsOneWidget);
      expect(fixture.backend.calls.where((c) => c.method == 'resume'), isEmpty);
      fixture.container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversation();
      await tester.pumpAndSettle();
      fixture.container
          .read(hermesMobileNavigationProvider.notifier)
          .showConversations();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('messages-search-input')),
            )
            .controller!
            .text,
        'ORCHID',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('messages-search-input')), findsNothing);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.byKey(const ValueKey('messages-tab-chats')), findsOneWidget);
    },
  );
  testWidgets(
    'Bots search includes bot/group categories, real transcript files and routines',
    (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('messages-search-bots')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('messages-search-categories')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bots'), findsOneWidget);
      expect(find.text('Group chats'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('messages-search-category-files')),
      );
      await tester.pumpAndSettle();
      await search(tester, 'report');
      expect(find.text('report.pdf'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('messages-search-categories')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Routines'));
      await tester.pumpAndSettle();
      await search(tester, 'digest');
      expect(find.text('Research digest'), findsOneWidget);
    },
  );
  testWidgets(
    'New bot preserves profile capabilities and retries setup without cloning twice',
    (tester) async {
      final fixture = await pump(tester);
      fixture.backend.partialSetup = true;
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New bot'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-name')),
        'Planner',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-role')),
        'Plan projects',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bot-setup-continue')));
      await tester.pumpAndSettle();
      await capture(tester, 'phone-new-bot');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bot-setup-create')),
        250,
        scrollable: find
            .descendant(
              of: find.byType(HermesBotSetupPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('bot-setup-create'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-create')));
      await tester.pumpAndSettle();
      expect(fixture.backend.drafts, hasLength(1));
      final draft = fixture.backend.drafts.single;
      expect(draft.profile, 'planner');
      expect(draft.shareAuth, isFalse);
      expect(draft.disabledSkills, isEmpty);
      expect(draft.toolsets, ['terminal']);
      await tester.tap(find.byKey(const ValueKey('bot-setup-advanced')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('bot-setup-instructions')),
            )
            .enabled,
        isFalse,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bot-setup-create')),
        250,
        scrollable: find
            .descendant(
              of: find.byType(HermesBotSetupPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('bot-setup-create'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-create')));
      await tester.pumpAndSettle();
      expect(fixture.backend.drafts, hasLength(1));
      expect(fixture.backend.finishAttempts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'Bot creation uses name/title/description and compact capability sheets',
    (tester) async {
      final backend = _WorkspaceBackend();
      await pump(tester, suppliedBackend: backend);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New bot'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-name')),
        'Trey',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-title')),
        'Inbox Triage',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-role')),
        'Sort the inbox.',
      );
      await capture(tester, 'bot-create-identity');
      await tester.tap(find.byKey(const ValueKey('bot-setup-continue')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bot-setup-instructions')),
        findsNothing,
      );
      expect(find.text('research'), findsNothing);
      for (final kind in ['skills', 'tools', 'integrations']) {
        expect(
          tester.getSize(find.byKey(ValueKey('bot-setup-$kind'))).height,
          greaterThanOrEqualTo(48),
        );
      }
      await capture(tester, 'bot-create-capabilities');
      // Dismissal is staged: Cancel keeps the original selection.
      await tester.tap(find.byKey(const ValueKey('bot-setup-skills')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('research'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-skills')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('research'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // An empty toolset list means default access on Hermes; require a choice.
      await tester.tap(find.byKey(const ValueKey('bot-setup-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminal'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byType(HermesCapabilityPicker),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-integrations')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Library'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-advanced')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('bot-setup-instructions')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-instructions')),
        '# Custom personality\nUse short answers.',
      );
      await capture(tester, 'bot-create-advanced');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bot-setup-create')),
        250,
        scrollable: find
            .descendant(
              of: find.byType(HermesBotSetupPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('bot-setup-create'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-create')));
      await tester.pumpAndSettle();
      final draft = backend.drafts.single;
      expect(draft.profile, 'trey');
      expect(draft.title, 'Inbox Triage');
      expect(draft.description, 'Sort the inbox.');
      expect(draft.disabledSkills, ['research']);
      expect(draft.toolsets, ['terminal']);
      expect(draft.mcpServers, isEmpty);
      expect(draft.soul, '# Custom personality\nUse short answers.');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Name-only creation generates personality and Back preserves identity fields',
    (tester) async {
      final fixture = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New bot'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-name')),
        'Trey',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bot-setup-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-back')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bot-setup-name')))
            .controller!
            .text,
        'Trey',
      );
      await tester.tap(find.byKey(const ValueKey('bot-setup-continue')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bot-setup-create')),
        250,
        scrollable: find
            .descendant(
              of: find.byType(HermesBotSetupPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('bot-setup-create'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-create')));
      await tester.pumpAndSettle();
      final draft = fixture.backend.drafts.single;
      expect(draft.instructions, isEmpty);
      expect(draft.soul, contains('You are Trey, a persistent named agent'));
      expect(draft.soul, isNot(contains('**Mission:**')));
    },
  );
  for (final variant in [
    (Brightness.light, 1.0),
    (Brightness.dark, 1.0),
    (Brightness.dark, 2.0),
  ]) {
    testWidgets(
      'Bot form renders ${variant.$1.name} at ${variant.$2} text scale',
      (tester) async {
        await pump(
          tester,
          brightness: variant.$1,
          scale: variant.$2,
          suppliedBackend: _WorkspaceBackend(),
        );
        await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New bot'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('bot-setup-name')),
          'Trey',
        );
        await tester.enterText(
          find.byKey(const ValueKey('bot-setup-title')),
          'Inbox Triage',
        );
        await tester.enterText(
          find.byKey(const ValueKey('bot-setup-role')),
          'Organize mail and flag important messages.',
        );
        await tester.pumpAndSettle();
        final label = 'bot-form-${variant.$1.name}-${variant.$2}';
        await capture(tester, '$label-identity');
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('bot-setup-continue')),
          200,
          scrollable: find
              .descendant(
                of: find.byType(HermesBotSetupPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const ValueKey('bot-setup-continue')));
        await tester.pumpAndSettle();
        await capture(tester, '$label-capabilities');
        await tester.tap(find.byKey(const ValueKey('bot-setup-skills')));
        await tester.pumpAndSettle();
        await capture(tester, '$label-picker');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('bot-setup-advanced')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('bot-setup-instructions')),
        );
        await capture(tester, '$label-advanced');
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final brightness in Brightness.values) {
    testWidgets('capture approved layout in ${brightness.name}', (
      tester,
    ) async {
      await pump(tester, brightness: brightness);
      await capture(tester, 'phone-chats-${brightness.name}');
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await capture(tester, 'phone-bots-${brightness.name}');
      await tester.tap(find.byKey(const ValueKey('messages-search-bots')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('messages-search-categories')),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'phone-categories-${brightness.name}');
    });
  }
  testWidgets('Bots Retry reloads the failed roster', (tester) async {
    final fixture = await pump(tester);
    fixture.backend.rosterFailed = true;
    fixture.container.invalidate(hermesMessagesBotsProvider);
    await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
    await tester.pumpAndSettle();
    expect(find.byType(HermesLoadError), findsOneWidget);
    fixture.backend.rosterFailed = false;
    await tester.tap(
      find.text(
        AppLocalizations.of(tester.element(find.byType(HermesLoadError)))!
            .mobileRetry,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Researcher'), findsOneWidget);
    expect(find.byType(HermesLoadError), findsNothing);
  });
  testWidgets('archive access keeps Search and New chat inside the toolbar', (
    tester,
  ) async {
    final backend = _WorkspaceBackend()..hasArchived = true;
    await pump(tester, suppliedBackend: backend);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show archived chats'), findsOneWidget);
    final plus = find.byKey(const ValueKey('hermes-new-conversation'));
    expect(plus, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Show archived chats'));
    await tester.pumpAndSettle();
    expect(find.text('Archived conversation'), findsOneWidget);
  });
  testWidgets(
    'Bot workspace keeps identity concise and uses the shared model control',
    (tester) async {
      final backend = _WorkspaceBackend();
      await pump(tester, suppliedBackend: backend);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Researcher'),
            matching: find.byType(HermesMessageRow),
          ),
          matching: find.byTooltip('Bot actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open bot'));
      await tester.pumpAndSettle();
      expect(find.byType(HermesBotWorkspacePage), findsOneWidget);
      expect(find.text('Researcher'), findsOneWidget);
      final identityTab = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('bot-workspace-tab-Identity')),
      );
      expect((identityTab.decoration as BoxDecoration).border!.bottom.width, 2);
      expect(find.text('SOUL'), findsOneWidget);
      expect(find.text('Memory'), findsOneWidget);
      expect(find.text('About you'), findsNothing);
      expect(find.text('Ready · Own workspace'), findsNothing);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.memory_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(CompactModelSelector), findsOneWidget);
      expect(
        find.byType(DropdownButtonFormField<HermesDesktopModelOption>),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Memory'));
      await tester.pumpAndSettle();
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('About you'), findsOneWidget);
      expect(find.text('Research notes.'), findsOneWidget);
      await tester.tap(find.text('About you'));
      await tester.pumpAndSettle();
      expect(find.text('Prefers primary sources.'), findsOneWidget);
    },
  );
  testWidgets(
    'Bot schedules reuse schedule details and keep edits in their profile',
    (tester) async {
      final backend = _WorkspaceBackend()
        ..profileJobs = [
          {
            'id': 'bot-digest',
            'name': '[bot:research] Digest',
            'prompt': 'Compare new papers',
            'schedule': {'kind': 'cron', 'expr': '0 9 * * 1-5'},
            'enabled': false,
            'last_status': 'fail',
          },
        ];
      await pump(tester, suppliedBackend: backend);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Researcher'),
            matching: find.byType(HermesMessageRow),
          ),
          matching: find.byTooltip('Bot actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open bot'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Schedules'));
      await tester.tap(find.text('Schedules'));
      await tester.pumpAndSettle();
      expect(find.byType(HermesScheduleCard), findsOneWidget);
      expect(find.text('Digest'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.textContaining('{kind:'), findsNothing);
      final schedulesTab = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('bot-workspace-tab-Schedules')),
      );
      expect(
        (schedulesTab.decoration as BoxDecoration).border!.bottom.width,
        2,
      );
      await tester.tap(find.text('Digest'));
      await tester.pumpAndSettle();
      expect(find.byType(HermesScheduleDetail), findsOneWidget);
      expect(find.byType(HermesScheduleEditor), findsNothing);
      expect(find.text('Weekdays at 9:00 AM'), findsOneWidget);
      await tester.ensureVisible(
        find.descendant(
          of: find.byType(HermesScheduleDetail),
          matching: find.text('Last run failed'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(HermesScheduleDetail),
          matching: find.text('Last run failed'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Last: fail'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('hermes-job-fix-bot-digest')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Schedule actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(backend.scheduleMutations.single.profile, 'research');
      expect(backend.scheduleMutations.single.id, 'bot-digest');
      expect(backend.scheduleMutations.single.action, 'resume');
      await tester.tap(find.byTooltip('Schedule actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit schedule'));
      await tester.pumpAndSettle();
      expect(find.byType(HermesScheduleEditor), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('schedule-save')));
      await tester.pumpAndSettle();
      expect(backend.scheduleMutations.last.profile, 'research');
      expect(backend.scheduleMutations.last.action, 'update');
      expect(
        backend.scheduleMutations.last.values['name'],
        '[bot:research] Digest',
      );
      expect(backend.scheduleMutations.last.values['schedule'], '0 9 * * 1-5');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('failed bot identity save keeps the draft for retry', (
    tester,
  ) async {
    final backend = _WorkspaceBackend()..failSave = true;
    await pump(tester, suppliedBackend: backend);
    await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Researcher'),
          matching: find.byType(HermesMessageRow),
        ),
        matching: find.byTooltip('Bot actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open bot'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Edit Researcher',
      ),
    );
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'Researcher',
    );
    await tester.enterText(name, 'Edited researcher');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save. Your changes are kept here.'),
      findsOneWidget,
    );
    expect(find.text('Edited researcher'), findsOneWidget);
    backend.failSave = false;
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(
      backend.changes.last['ui_meta']['hermes-bots']['title'],
      'Edited researcher',
    );
    expect(
      find.text('Could not save. Your changes are kept here.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('Bot identity has a single editor and saves the custom color', (
    tester,
  ) async {
    final backend = _WorkspaceBackend();
    await pump(tester, suppliedBackend: backend);
    await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Researcher'),
          matching: find.byType(HermesMessageRow),
        ),
        matching: find.byTooltip('Bot actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open bot'));
    await tester.pumpAndSettle();
    await capture(tester, 'phone-bot-workspace');
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Edit Researcher',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit bot'), findsNothing);
    expect(find.text('Color'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Custom color',
      ),
    );
    await tester.pumpAndSettle();
    final hex = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Hex',
    );
    await tester.enterText(hex, '#387a65');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(backend.changes.last['ui_meta']['hermes-bots']['color'], '#387a65');
    expect(
      backend.changes.last['ui_meta_expected_revisions']['hermes-bots'],
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Group creation saves selected participants and coordinator', (
    tester,
  ) async {
    final fixture = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group chat'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-setup-name')),
      'Build room',
    );
    await tester.tap(find.byKey(const ValueKey('group-member-research')));
    await tester.tap(find.byKey(const ValueKey('group-member-coding')));
    await tester.pumpAndSettle();
    final coordinator = find.byType(DropdownButtonFormField<String>);
    await tester.tap(coordinator);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coding').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('group-setup-create')),
    );
    await tester.tap(find.byKey(const ValueKey('group-setup-create')));
    await tester.pumpAndSettle();
    final group = fixture.backend.groups.firstWhere(
      (g) => g.name == 'Build room',
    );
    expect(group.memberProfiles, containsAll(['research', 'coding']));
    expect(group.coordinator, 'coding');
    await capture(tester, 'phone-new-group');
    expect(find.text('Build room'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'Group setup creates a missing participant and retains the draft',
    (tester) async {
      final backend = _Backend()..bots.removeLast();
      await pump(tester, suppliedBackend: backend);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('messages-create-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New group chat'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-setup-name')),
        'Planning room',
      );
      await tester.tap(find.byKey(const ValueKey('group-member-research')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('group-setup-purpose')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('group-setup-purpose')),
        'Plan the next release',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('group-setup-create')),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('group-setup-create-bot')),
      );
      await tester.tap(find.byKey(const ValueKey('group-setup-create-bot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('group-setup-name')))
            .controller!
            .text,
        'Planning room',
      );
      await tester.tap(find.byKey(const ValueKey('group-setup-create-bot')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-name')),
        'Planner',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bot-setup-role')),
        'Plan projects',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bot-setup-continue')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bot-setup-create')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('bot-setup-create'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bot-setup-create')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('group-member-planner')),
            )
            .value,
        isTrue,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('group-setup-create')),
      );
      await tester.tap(find.byKey(const ValueKey('group-setup-create')));
      await tester.pumpAndSettle();
      final group = backend.groups.singleWhere(
        (g) => g.name == 'Planning room',
      );
      expect(group.purpose, 'Plan the next release');
      expect(group.memberProfiles, ['research', 'planner']);
      expect(group.coordinator, 'research');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'hosted group shows growing replies and commits each reply once in ${brightness.name}',
      (tester) async {
        final backend = _HostedBackend();
        final fixture = await pump(
          tester,
          suppliedBackend: backend,
          brightness: brightness,
        );
        await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Project team'));
        await tester.pumpAndSettle();
        expect(backend.live.hasListener, true);
        backend.live.add(
          const HermesGroupLiveReply(
            id: 'live-research-1',
            profile: 'research',
            text: 'A streamed',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        Iterable<StreamingMarkdownWidget> replies(String text) => tester
            .widgetList<StreamingMarkdownWidget>(
              find.byType(StreamingMarkdownWidget),
            )
            .where((w) => w.content == text);
        expect(replies('A streamed').single.isStreaming, true);
        expect(
          fixture.container
              .read(hermesGroupRuntimeProvider('team'))
              .group
              .messages
              .any((m) => m.text == 'A streamed'),
          false,
        );
        backend.live.add(
          const HermesGroupLiveReply(
            id: 'live-research-1',
            profile: 'research',
            text: 'A streamed reply',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(replies('A streamed'), isEmpty);
        expect(replies('A streamed reply'), hasLength(1));
        await capture(tester, 'group-live-${brightness.name}');
        backend.live.add(
          const HermesGroupLiveReply(
            id: 'live-research-1',
            profile: 'research',
            text: 'A streamed reply',
            complete: true,
          ),
        );
        backend.log.add({
          'event_id': 'committed-reply',
          'kind': 'message.member',
          'created_at': DateTime.now().millisecondsSinceEpoch / 1000,
          'payload': {'member_id': 'research', 'text': 'A streamed reply'},
        });
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(replies('A streamed reply'), hasLength(1));
        expect(replies('A streamed reply').single.isStreaming, false);
        expect(
          fixture.container
              .read(hermesGroupRuntimeProvider('team'))
              .liveReplies,
          isEmpty,
        );
        backend.live.add(
          const HermesGroupLiveReply(
            id: 'live-research-1',
            profile: 'research',
            text: 'A streamed reply',
            complete: true,
          ),
        );
        await tester.pump();
        expect(replies('A streamed reply'), hasLength(1));
        backend.live.add(
          const HermesGroupLiveReply(
            id: 'coding-pass',
            profile: 'coding',
            text: 'PASS',
            complete: true,
          ),
        );
        await tester.pump();
        expect(
          fixture.container
              .read(hermesGroupRuntimeProvider('team'))
              .liveReplies,
          isEmpty,
        );
        backend.working = false;
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(backend.live.hasListener, false);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await backend.live.close();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Group coordinator requests a relevant specialist and synthesizes its reply',
    (tester) async {
      final fixture = await pump(tester);
      fixture.backend.requestSpecialist = true;
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Project team'));
      await tester.pumpAndSettle();
      final input = find
          .descendant(
            of: find.byType(ModernChatInput),
            matching: find.byWidgetPredicate((w) => w is TextField),
          )
          .first;
      await tester.enterText(input, 'Compare these options');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
      await tester.pumpAndSettle();
      expect(
        fixture.backend.calls
            .where((c) => c.method == 'prompt')
            .map((c) => c.profile),
        ['coding', 'research', 'coding'],
      );
      expect(fixture.backend.calls.where((c) => c.method == 'open'), isEmpty);
      expect(
        fixture.backend.groups.single.messages.map((m) => m.text),
        containsAll([
          'Compare these options',
          'research answered.',
          'coding answered.',
        ]),
      );
      expect(
        fixture.backend.groups.single.memberSessions.values.every(
          (id) => id.startsWith('group-'),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'Group tool approval waits for the human and resolves its member session',
    (tester) async {
      final fixture = await pump(tester);
      fixture.backend.holdApproval = true;
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Project team'));
      await tester.pumpAndSettle();
      final input = find
          .descendant(
            of: find.byType(ModernChatInput),
            matching: find.byWidgetPredicate((w) => w is TextField),
          )
          .first;
      await tester.enterText(input, 'Do the task');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
      await tester.pumpAndSettle();
      expect(fixture.backend.approvals, isEmpty);
      expect(find.text('Run a fixture command'), findsOneWidget);
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(fixture.backend.approvals.single.id, 'group-team-coding');
      expect(fixture.backend.approvals.single.choice, 'once');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets('Messages and search fit large text in ${brightness.name}', (
      tester,
    ) async {
      await pump(tester, brightness: brightness, scale: 2);
      await tester.tap(find.byKey(const ValueKey('messages-tab-bots')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      await capture(tester, 'phone-bots-large-${brightness.name}');
      await tester.tap(find.byKey(const ValueKey('messages-search-bots')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'lazy group archive persists full history with account partitions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conduit-messages-archive-test-',
      );
      final box = await Hive.openLazyBox<String>(
        'messages_fixture_${DateTime.now().microsecondsSinceEpoch}',
        path: directory.path,
      );
      addTearDown(() async {
        await box.close();
        await directory.delete(recursive: true);
      });
      final archive = HermesGroupArchive.onDisk(box, 'fixture-first');
      final group = HermesBotGroup(
        key: 'id:disk',
        name: 'Disk',
        memberProfiles: const ['research', 'coding'],
        messages: [
          HermesGroupMessage(
            id: 'long',
            text: 'Full reply ' * 6000,
            at: DateTime(2026),
          ),
        ],
      );
      await archive.write(group);
      final remote = group.copyWith(messages: const []);
      expect(
        (await archive.read(remote)).messages.single.text,
        group.messages.single.text,
      );
      expect(
        (await HermesGroupArchive.onDisk(box, 'fixture-second').read(remote))
            .messages,
        isEmpty,
      );
    },
  );
  test(
    'group archive restores full replies and does not cross connection keys',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final first = HermesGroupArchive(preferences, 'fixture-account-one'),
          other = HermesGroupArchive(preferences, 'fixture-account-two');
      final group = HermesBotGroup(
        key: 'id:archive',
        roomId: 'archive',
        name: 'Archive',
        memberProfiles: const ['research', 'coding'],
        messages: [
          HermesGroupMessage(
            id: 'reply',
            text: 'Full original reply',
            at: DateTime(2026),
          ),
        ],
      );
      await first.write(group);
      final remote = group.copyWith(
        messages: [
          HermesGroupMessage(
            id: 'reply',
            text: 'Full… [truncated]',
            at: DateTime(2026),
          ),
        ],
      );
      expect(first.merge(remote).messages.single.text, 'Full original reply');
      expect(other.merge(remote).messages.single.text, 'Full… [truncated]');
    },
  );
}
