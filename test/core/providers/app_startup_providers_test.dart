import 'dart:async';

import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> _flushMicrotasks([int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ProviderContainer> _createAuthenticatedWarmupContainer({
  Override? authNavigationOverride,
  Override? apiOverride,
  Override? conversationsOverride,
  Override? foldersOverride,
  List<Override> extraOverrides = const <Override>[],
}) async {
  final container = ProviderContainer(
    overrides: [
      authNavigationOverride ??
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
      isOnlineProvider.overrideWithValue(true),
      authTokenProvider3.overrideWithValue('test-token'),
      apiOverride ?? apiServiceProvider.overrideWithValue(_StubApiService()),
      connectivityServiceProvider.overrideWithValue(_FakeConnectivityService()),
      conversationsOverride ??
          conversationsProvider.overrideWith(_RecordingWarmupConversations.new),
      foldersOverride ??
          foldersProvider.overrideWith(_RecordingWarmupFolders.new),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  await container.read(conversationsProvider.future);
  return container;
}

typedef _WarmupNotifiers = ({
  _RecordingWarmupConversations conversations,
  _TrackingWarmupFolders folders,
});

_WarmupNotifiers _readWarmupNotifiers(ProviderContainer container) {
  return (
    conversations:
        container.read(conversationsProvider.notifier)
            as _RecordingWarmupConversations,
    folders: container.read(foldersProvider.notifier) as _TrackingWarmupFolders,
  );
}

void _expectForcedWarmup(
  _RecordingWarmupConversations conversations,
  _TrackingWarmupFolders folders, {
  required int warmIfNeededCalls,
}) {
  expect(conversations.refreshCalls, 1);
  expect(conversations.lastForceFresh, isTrue);
  expect(conversations.lastIncludeFolders, isFalse);
  expect(folders.warmIfNeededCalls, warmIfNeededCalls);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup queue requests a frame for ready delayed work', () async {
    void Function(Duration)? postFrameCallback;
    var ensureVisualUpdateCalls = 0;
    var runCalls = 0;

    debugScheduleReadyStartupQueueTaskForTesting(
      onEnsureVisualUpdate: () {
        ensureVisualUpdateCalls += 1;
      },
      onAddPostFrameCallback: (callback) {
        postFrameCallback = callback;
      },
      run: () {
        runCalls += 1;
      },
    );

    expect(ensureVisualUpdateCalls, 1);
    expect(postFrameCallback, isNotNull);
    expect(runCalls, 0);

    postFrameCallback!(Duration.zero);
    await _flushMicrotasks(2);

    expect(runCalls, 1);
  });

  test(
    'forced warmup refreshes populated conversations while warming folders',
    () async {
      final container = await _createAuthenticatedWarmupContainer();

      container
          .read(appStartupFlowProvider.notifier)
          .scheduleConversationWarmup(force: true);
      await _flushMicrotasks(2);

      final notifiers = _readWarmupNotifiers(container);

      _expectForcedWarmup(
        notifiers.conversations,
        notifiers.folders,
        warmIfNeededCalls: 1,
      );
    },
  );

  test(
    'forced warmup queued during an in-flight warmup reruns after folders finish',
    () async {
      final conversations = _RecordingWarmupConversations();
      final folders = _BlockingWarmupFolders();
      final container = await _createAuthenticatedWarmupContainer(
        conversationsOverride: conversationsProvider.overrideWith(
          () => conversations,
        ),
        foldersOverride: foldersProvider.overrideWith(() => folders),
      );

      container
          .read(appStartupFlowProvider.notifier)
          .scheduleConversationWarmup();
      await _flushMicrotasks(2);

      expect(folders.warmIfNeededCalls, 1);
      expect(conversations.refreshCalls, 0);

      container
          .read(appStartupFlowProvider.notifier)
          .scheduleConversationWarmup(force: true);
      await _flushMicrotasks();

      expect(conversations.refreshCalls, 0);

      folders.completeFirstWarmup();
      await _flushMicrotasks(3);

      _expectForcedWarmup(conversations, folders, warmIfNeededCalls: 2);
    },
  );

  test(
    'already-authenticated startup runs post-auth warmup on start',
    () async {
      final container = await _createAuthenticatedWarmupContainer();

      container.read(appStartupFlowProvider.notifier).activateForTesting();
      await _flushMicrotasks(3);

      final notifiers = _readWarmupNotifiers(container);

      _expectForcedWarmup(
        notifiers.conversations,
        notifiers.folders,
        warmIfNeededCalls: 1,
      );
    },
  );

  test(
    'post-auth startup waits for api service before forcing warmup',
    () async {
      ApiService? currentApi;
      final container = await _createAuthenticatedWarmupContainer(
        apiOverride: apiServiceProvider.overrideWith((ref) => currentApi),
      );

      final startupFuture = container
          .read(appStartupFlowProvider.notifier)
          .runPostAuthenticationStartup(
            apiWaitTimeout: const Duration(milliseconds: 250),
          );

      final notifiers = _readWarmupNotifiers(container);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(notifiers.conversations.refreshCalls, 0);
      expect(notifiers.folders.warmIfNeededCalls, 0);

      currentApi = _StubApiService();
      container.invalidate(apiServiceProvider);

      await startupFuture;
      await _flushMicrotasks(2);

      _expectForcedWarmup(
        notifiers.conversations,
        notifiers.folders,
        warmIfNeededCalls: 1,
      );
    },
  );

  test(
    'already-authenticated startup retries when api service becomes ready after the initial wait',
    () async {
      ApiService? currentApi;
      final container = await _createAuthenticatedWarmupContainer(
        apiOverride: apiServiceProvider.overrideWith((ref) => currentApi),
      );

      container
          .read(appStartupFlowProvider.notifier)
          .activateForTesting(apiWaitTimeout: const Duration(milliseconds: 40));

      final notifiers = _readWarmupNotifiers(container);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(notifiers.conversations.refreshCalls, 0);
      expect(notifiers.folders.warmIfNeededCalls, 0);

      currentApi = _StubApiService();
      container.invalidate(apiServiceProvider);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _flushMicrotasks();

      _expectForcedWarmup(
        notifiers.conversations,
        notifiers.folders,
        warmIfNeededCalls: 1,
      );
    },
  );

  test(
    'post-auth startup cancels delayed model preload after leaving authenticated flow',
    () async {
      var navState = AuthNavigationState.authenticated;
      var defaultModelLoads = 0;
      final container = await _createAuthenticatedWarmupContainer(
        authNavigationOverride: authNavigationStateProvider.overrideWith(
          (ref) => navState,
        ),
        extraOverrides: [
          defaultModelProvider.overrideWith((ref) async {
            defaultModelLoads += 1;
            return null;
          }),
        ],
      );

      container.read(appStartupFlowProvider.notifier).activateForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      navState = AuthNavigationState.needsLogin;
      container.invalidate(authNavigationStateProvider);

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(defaultModelLoads, 0);
    },
  );

  test('resume warmup reuses the foreground conversations refresh', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final container = await _createAuthenticatedWarmupContainer();
    container.read(foregroundRefreshProvider);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks(3);

    final notifiers = _readWarmupNotifiers(container);

    _expectForcedWarmup(
      notifiers.conversations,
      notifiers.folders,
      warmIfNeededCalls: 1,
    );
  });
}

abstract class _TrackingWarmupFolders extends Folders {
  int warmIfNeededCalls = 0;
}

class _RecordingWarmupConversations extends Conversations {
  int refreshCalls = 0;
  bool? lastIncludeFolders;
  bool? lastForceFresh;

  @override
  Future<List<Conversation>> build() async => <Conversation>[
    _conversation('existing-chat'),
  ];

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {
    refreshCalls += 1;
    lastIncludeFolders = includeFolders;
    lastForceFresh = forceFresh;
    state = AsyncData<List<Conversation>>(<Conversation>[
      _conversation('refreshed-chat'),
    ]);
  }
}

class _RecordingWarmupFolders extends _TrackingWarmupFolders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];

  @override
  Future<void> warmIfNeeded() async {
    warmIfNeededCalls += 1;
    state = const AsyncData<List<Folder>>(<Folder>[]);
  }
}

class _BlockingWarmupFolders extends _TrackingWarmupFolders {
  final Completer<void> _firstWarmupCompleter = Completer<void>();

  @override
  Future<List<Folder>> build() async => const <Folder>[];

  @override
  Future<void> warmIfNeeded() async {
    warmIfNeededCalls += 1;
    if (warmIfNeededCalls == 1) {
      await _firstWarmupCompleter.future;
    }
    state = const AsyncData<List<Folder>>(<Folder>[]);
  }

  void completeFirstWarmup() {
    if (!_firstWarmupCompleter.isCompleted) {
      _firstWarmupCompleter.complete();
    }
  }
}

class _FakeConnectivityService extends Fake implements ConnectivityService {
  @override
  bool get isAppForeground => true;

  @override
  int get lastLatencyMs => 0;
}

class _StubApiService extends ApiService {
  _StubApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );
}

Conversation _conversation(String id) {
  final timestamp = DateTime.utc(2026, 1, 1);
  return Conversation(
    id: id,
    title: id,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}
