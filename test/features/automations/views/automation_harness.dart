import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/automations/views/scheduled_task_detail_page.dart';
import 'package:conduit/features/automations/views/scheduled_task_editor_page.dart';
import 'package:conduit/features/automations/views/scheduled_tasks_page.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

const automationTestServer = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

const advancedSettings = AppSettings(advancedFeaturesEnabled: true);

/// A task in the shape the pinned server returns it, nanosecond timestamps
/// included.
Map<String, dynamic> taskJson(
  String id, {
  String name = 'Digest',
  bool active = true,
  String rrule = 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
  String? folderId,
  Map<String, dynamic>? target,
  Map<String, dynamic>? terminal,
  Map<String, dynamic>? meta,
  String model = 'gpt-4o',
  int createdAt = 1790000000000000000,
}) => {
  'id': id,
  'user_id': 'user-1',
  'folder_id': folderId,
  'name': name,
  'data': {
    'prompt': 'Summarize the news',
    'model_id': model,
    'rrule': rrule,
    'terminal': terminal,
    'target': target ?? {'type': 'chat'},
  },
  'meta': meta,
  'is_active': active,
  'last_run_at': null,
  'next_run_at': 1791320967000000001,
  'created_at': createdAt,
  'updated_at': createdAt,
};

Map<String, dynamic> runJson(
  String id, {
  String status = 'success',
  String? chatId,
  String? error,
  int createdAt = 1791320967000000001,
}) => {
  'id': id,
  'automation_id': 'a',
  'chat_id': chatId,
  'status': status,
  'error': error,
  'created_at': createdAt,
};

/// Answers the automation routes like the pinned server: update overwrites
/// name, folder, data and meta from the form and keeps only the data keys its
/// model knows, and toggle flips whatever it holds.
final class AutomationWire implements HttpClientAdapter {
  AutomationWire(this.tasks);

  final List<Map<String, dynamic>> tasks;
  final Map<String, List<Map<String, dynamic>>> runs = {};
  final requests = <RequestOptions>[];
  int pageSize = 30;
  bool channelWrite = true;
  ({int status, String detail})? rejectWrites;
  Completer<void>? holdRuns;

  Iterable<RequestOptions> get writes =>
      requests.where((r) => r.method != 'GET' && !r.uri.path.endsWith('/run'));

  Iterable<RequestOptions> get runRequests =>
      requests.where((r) => r.uri.path.endsWith('/run'));

  Iterable<RequestOptions> where(String method, String suffix) =>
      requests.where((r) => r.method == method && r.uri.path.endsWith(suffix));

  final _holds = <String, AutomationHold>{};

  /// Holds the answer to the next request for [method] [path] until the hold
  /// is released. The server has already acted on it by then, as a slow
  /// network would leave things: a write is committed, but the app has not
  /// heard.
  AutomationHold hold(String method, String path) =>
      _holds['$method $path'] = AutomationHold();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final answer = await _answer(options);
    final held = _holds.remove('${options.method} ${options.uri.path}');
    if (held != null) {
      held._entered.complete();
      await held._gate.future;
    }
    return answer;
  }

  Future<ResponseBody> _answer(RequestOptions options) async {
    requests.add(options);
    final path = options.uri.path;
    final isWrite = options.method != 'GET';
    final rejection = rejectWrites;
    if (isWrite && rejection != null) {
      return _json({'detail': rejection.detail}, rejection.status);
    }
    if (path.contains('/channels/')) {
      return _json({'id': 'c', 'write_access': channelWrite});
    }
    if (path.endsWith('/list')) {
      final query = options.uri.queryParameters;
      final page = int.parse(query['page'] ?? '1');
      var matches = tasks.where((t) {
        final status = query['status'];
        if (status == 'active' && t['is_active'] != true) return false;
        if (status == 'paused' && t['is_active'] != false) return false;
        final text = query['query']?.toLowerCase();
        return text == null ||
            (t['name'] as String).toLowerCase().contains(text);
      }).toList();
      final items = matches.skip((page - 1) * pageSize).take(pageSize).toList();
      return _json({'items': items, 'total': matches.length});
    }
    if (path.endsWith('/create')) {
      final body = options.data as Map<String, dynamic>;
      final created = _store(taskJson('new-1'), body);
      tasks.insert(0, created);
      return _json(_enrich(created));
    }
    final runsMatch = RegExp(r'/automations/([^/]+)/runs$').firstMatch(path);
    if (runsMatch != null) {
      await holdRuns?.future;
      final all = runs[Uri.decodeComponent(runsMatch.group(1)!)] ?? const [];
      final skip = int.parse(options.uri.queryParameters['skip'] ?? '0');
      final limit = int.parse(options.uri.queryParameters['limit'] ?? '50');
      return _json(all.skip(skip).take(limit).toList());
    }
    final match = RegExp(r'/automations/([^/]+)(?:/(\w+))?$').firstMatch(path);
    if (match == null) return _json({'detail': 'unexpected $path'}, 500);
    final id = Uri.decodeComponent(match.group(1)!);
    final index = tasks.indexWhere((t) => t['id'] == id);
    if (index < 0) {
      return _json({
        'detail': "We could not find what you're looking for :/",
      }, 404);
    }
    final task = tasks[index];
    switch (match.group(2)) {
      case 'update':
        tasks[index] = _store(task, options.data as Map<String, dynamic>);
        return _json(_enrich(tasks[index]));
      case 'toggle':
        task['is_active'] = !(task['is_active'] as bool);
        return _json(_enrich(task));
      case 'delete':
        tasks.removeAt(index);
        return _json(true);
      default:
        return _json(_enrich(task));
    }
  }

  Map<String, dynamic> _store(
    Map<String, dynamic> base,
    Map<String, dynamic> form,
  ) {
    final data = form['data'] as Map<String, dynamic>;
    return {
      ...base,
      'name': form['name'],
      'folder_id': form['folder_id'],
      // Only the keys the server's model declares survive; absent ones become
      // null, which is how an omitted terminal or meta is erased.
      'data': {
        'prompt': data['prompt'],
        'model_id': data['model_id'],
        'rrule': data['rrule'],
        'terminal': data['terminal'],
        'target': data['target'],
      },
      'meta': form['meta'],
      'is_active': form['is_active'] ?? base['is_active'],
    };
  }

  Map<String, dynamic> _enrich(Map<String, dynamic> task) => {
    ...task,
    'last_run': (runs[task['id']] ?? const []).firstOrNull,
    'next_runs': [1791320967000000001, 1791407367000000003],
  };

  ResponseBody _json(Object body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// One answer [AutomationWire] is holding back.
final class AutomationHold {
  final _entered = Completer<void>();
  final _gate = Completer<void>();

  /// Whether the request reached the server and its answer is being held.
  bool get hasEntered => _entered.isCompleted;

  void release() => _gate.complete();
}

/// Pumps frames until [hold] has the request, so the test acts while the
/// answer is still on its way.
Future<void> reach(WidgetTester tester, AutomationHold hold) async {
  for (var i = 0; i < 30 && !hold.hasEntered; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    hold.hasEntered,
    isTrue,
    reason: 'The request never reached the server',
  );
}

/// Records a chat the detail page asked to open, then reports it opened.
final class FakeSelection extends ConversationSelection {
  static final selected = <Conversation>[];

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async {
    selected.add(summary);
    return const ConversationSelectionResult.committed();
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

class _Config extends BackendConfigNotifier {
  _Config(this._config);

  final BackendConfig _config;

  @override
  Future<BackendConfig?> build() async => _config;
}

class _Models extends Models {
  _Models(this._models);

  final List<Model> _models;

  @override
  Future<List<Model>> build() async => _models;
}

class _Folders extends Folders {
  _Folders(this._folders);

  final List<Folder> _folders;

  @override
  Future<List<Folder>> build() async => _folders;
}

class _Channels extends ChannelsList {
  _Channels(this._channels);

  final List<Channel> _channels;

  @override
  Future<List<Channel>> build() async => _channels;
}

class _Storage extends Fake implements OptimizedStorageService {
  @override
  bool isUncommittedServerConfigCandidate(ServerConfig config) => false;

  @override
  Future<List<ServerConfig>> getServerConfigs() async => const [
    automationTestServer,
  ];

  @override
  Future<List<ServerConfig>> getServerConfigsStrict() async => const [
    automationTestServer,
  ];

  @override
  Future<String?> getActiveServerId() async => automationTestServer.id;
}

/// A signed-in client under test. The same [ApiService] serves the next account
/// after [switchAccount], as when another user signs in on the same server.
final class AutomationSession {
  AutomationSession(this.wire, this.container, this.router, this.api);

  final AutomationWire wire;
  final ProviderContainer container;
  final GoRouter router;
  final ApiService api;
  Object epoch = Object();
  String token = 'token-a';

  void switchAccount() {
    epoch = Object();
    token = 'token-b';
    api.updateAuthToken('token-b');
    container
      ..invalidate(openWebUiAuthSessionEpochProvider)
      ..invalidate(authTokenProvider3);
  }
}

/// The shell the chat, folder and channel pages live in, and the page each
/// stub destination shows. Present on screen only while that page is the one
/// the user sees.
const automationShellKey = Key('automation-shell');
const automationChatKey = Key('automation-chat');
const automationFolderKey = Key('automation-folder');
Key automationChannelKey(String id) => Key('automation-channel-$id');

Future<AutomationSession> pumpAutomations(
  WidgetTester tester, {
  String location = Routes.scheduledTasks,
  String shellLocation = Routes.chat,
  AppSettings settings = advancedSettings,
  Map<String, dynamic> permissions = const {
    'features': {'automations': true, 'channels': true},
  },
  bool serverEnabled = true,
  String role = 'user',
  List<Map<String, dynamic>>? tasks,
  List<Model>? models,
  List<Folder> folders = const [],
  List<Channel> channels = const [],
  void Function(AutomationWire wire)? configureWire,
  List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      conduitLocalizationsDelegates,
}) async {
  tester.view
    ..physicalSize = const Size(800, 3200)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FakeSelection.selected.clear();
  final wire = AutomationWire(tasks ?? [taskJson('a')]);
  configureWire?.call(wire);
  final api = ApiService(
    serverConfig: automationTestServer,
    workerManager: WorkerManager(),
    authToken: 'token-a',
  );
  api.dio.httpClientAdapter = wire;
  addTearDown(api.dispose);

  late final AutomationSession session;
  // The same shape as the app's router: chat, folder and channel are children
  // of one shell that is already mounted before Settings is opened over it, and
  // the scheduled-task pages are top-level routes outside it.
  final router = GoRouter(
    initialLocation: shellLocation,
    routes: [
      ShellRoute(
        builder: (_, _, child) =>
            KeyedSubtree(key: automationShellKey, child: child),
        routes: [
          for (final (path, name, key) in [
            (Routes.chat, RouteNames.chat, automationChatKey),
            (Routes.folder, RouteNames.folder, automationFolderKey),
            (Routes.channel, RouteNames.channel, null),
          ])
            GoRoute(
              path: path,
              name: name,
              pageBuilder: (_, state) => NoTransitionPage<void>(
                key: state.pageKey,
                name: state.name,
                child: SizedBox.expand(
                  key: key ?? automationChannelKey(state.pathParameters['id']!),
                ),
              ),
            ),
        ],
      ),
      GoRoute(
        path: Routes.scheduledTasks,
        name: RouteNames.scheduledTasks,
        builder: (_, _) => const ScheduledTasksPage(),
      ),
      GoRoute(
        path: Routes.scheduledTaskNew,
        name: RouteNames.scheduledTaskNew,
        builder: (_, _) => const ScheduledTaskEditorPage(),
      ),
      GoRoute(
        path: Routes.scheduledTaskDetail,
        name: RouteNames.scheduledTaskDetail,
        builder: (_, state) =>
            ScheduledTaskDetailPage(taskId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: Routes.scheduledTaskEdit,
        name: RouteNames.scheduledTaskEdit,
        builder: (_, state) =>
            ScheduledTaskEditorPage(taskId: state.pathParameters['id']!),
      ),
    ],
  );
  addTearDown(router.dispose);

  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(() => _Settings(settings)),
      apiServiceProvider.overrideWithValue(api),
      optimizedStorageServiceProvider.overrideWithValue(_Storage()),
      currentUserProvider2.overrideWithValue(
        User(
          id: 'user-1',
          username: 'user',
          email: 'user@example.com',
          role: role,
        ),
      ),
      isAuthenticatedProvider2.overrideWithValue(true),
      authTokenProvider3.overrideWith((ref) => session.token),
      openWebUiAuthSessionEpochProvider.overrideWith((ref) => session.epoch),
      backendConfigProvider.overrideWith(
        () => _Config(
          BackendConfig(
            serverId: automationTestServer.id,
            enableAutomations: serverEnabled,
          ),
        ),
      ),
      userPermissionsProvider.overrideWith((ref) async => permissions),
      modelsProvider.overrideWith(
        () => _Models(
          models ??
              const [
                Model(id: 'gpt-4o', name: 'GPT-4o'),
                Model(id: 'claude', name: 'Claude'),
              ],
        ),
      ),
      foldersProvider.overrideWith(() => _Folders(folders)),
      channelsListProvider.overrideWith(() => _Channels(channels)),
      conversationSelectionProvider.overrideWith(FakeSelection.new),
    ],
  );
  addTearDown(container.dispose);
  session = AutomationSession(wire, container, router, api);
  // The task list rebuilds when the active server resolves. In the app it is
  // long resolved by the time Settings opens, so settle it first.
  await container.read(activeServerProvider.future);
  await container.read(userPermissionsProvider.future);
  await container.read(backendConfigProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(router.push<void>(location));
  await tester.pumpAndSettle();
  return session;
}
