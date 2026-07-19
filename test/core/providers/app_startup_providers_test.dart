import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/providers/app_startup_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/services/media_upload_controller.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/file_attachment_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> _flushMicrotasks([int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitForFileDeletion(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (await file.exists() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _testServer = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
);

typedef _AuthOwnerSignal = ({String? token, AuthNavigationState navigation});

final _authOwnerSignalProvider =
    NotifierProvider<_AuthOwnerSignalNotifier, _AuthOwnerSignal>(
      _AuthOwnerSignalNotifier.new,
    );

final class _AuthOwnerSignalNotifier extends Notifier<_AuthOwnerSignal> {
  @override
  _AuthOwnerSignal build() =>
      (token: 'test-token', navigation: AuthNavigationState.authenticated);

  void signOut() {
    state = (token: null, navigation: AuthNavigationState.needsLogin);
  }

  void signIn({String token = 'replacement-token'}) {
    state = (token: token, navigation: AuthNavigationState.authenticated);
  }

  void beginSameSessionRevalidation() {
    state = (token: state.token, navigation: AuthNavigationState.loading);
  }
}

class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

class _CertifiedDatabaseServer
    extends OpenWebUiCertifiedDatabaseServerNotifier {
  @override
  String? build() => _testServer.id;
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
      openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
      openWebUiCertifiedDatabaseServerProvider.overrideWith(
        _CertifiedDatabaseServer.new,
      ),
      activeServerProvider.overrideWith((ref) async => _testServer),
      // No active server DB in these warmup-focused tests: keep the sync
      // engine / remap-route consumer inert so building AppStartupFlow does
      // not reach the (unimplemented) hiveBoxesProvider via appDatabase.
      appDatabaseProvider.overrideWithValue(null),
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
  await container.read(activeServerProvider.future);
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

  test('auth owner loss clears attachments through owned cleanup', () async {
    final stagingDirectory = Directory(
      '${Directory.systemTemp.path}/conduit-native-paste',
    );
    await stagingDirectory.create();
    final image = File(
      '${stagingDirectory.path}/'
      '123e4567-e89b-12d3-a456-426614174110-paste.png',
    );
    await image.writeAsBytes([1]);
    addTearDown(() async {
      if (await image.exists()) await image.delete();
    });

    final container = ProviderContainer(
      overrides: [
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(_authOwnerSignalProvider).token,
        ),
        authNavigationStateProvider.overrideWith(
          (ref) => ref.watch(_authOwnerSignalProvider).navigation,
        ),
        isAuthLoadingProvider2.overrideWithValue(false),
        openWebUiAccountStorageIsolationProvider.overrideWith(
          _NoopAccountStorageIsolation.new,
        ),
        selectedModelProvider.overrideWith(_NullSelectedModel.new),
        apiServiceProvider.overrideWithValue(null),
        appDatabaseProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    container.read(attachedFilesProvider.notifier).addFiles([
      LocalAttachment(file: image, displayName: 'paste.png'),
    ]);
    container.read(userScopedProviderCleanupProvider);

    container.read(_authOwnerSignalProvider.notifier).signOut();
    await _flushMicrotasks(2);
    check(container.read(authTokenProvider3)).isNull();
    check(
      container.read(authNavigationStateProvider),
    ).equals(AuthNavigationState.needsLogin);

    for (var attempt = 0; attempt < 50; attempt++) {
      if (container.read(attachedFilesProvider).isEmpty &&
          !await image.exists()) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    check(container.read(attachedFilesProvider)).isEmpty();
    check(await image.exists()).isFalse();
    check(
      container
          .read(mediaUploadControllerProvider)
          .debugTrackedPathGenerationCount,
    ).equals(0);
  });

  test(
    'same-token reauthentication retires only departing attachment owners',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final oldImage = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174111-old.png',
      );
      final replacementImage = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174112-new.png',
      );
      await oldImage.writeAsBytes([1]);
      await replacementImage.writeAsBytes([2]);
      addTearDown(() async {
        if (await oldImage.exists()) await oldImage.delete();
        if (await replacementImage.exists()) await replacementImage.delete();
      });

      final container = ProviderContainer(
        overrides: [
          authTokenProvider3.overrideWith(
            (ref) => ref.watch(_authOwnerSignalProvider).token,
          ),
          authNavigationStateProvider.overrideWith(
            (ref) => ref.watch(_authOwnerSignalProvider).navigation,
          ),
          isAuthLoadingProvider2.overrideWithValue(false),
          openWebUiAccountStorageIsolationProvider.overrideWith(
            _NoopAccountStorageIsolation.new,
          ),
          selectedModelProvider.overrideWith(_NullSelectedModel.new),
          apiServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(attachedFilesProvider.notifier).addFiles([
        LocalAttachment(file: oldImage, displayName: 'old.png'),
      ]);
      container.read(userScopedProviderCleanupProvider);

      final authOwner = container.read(_authOwnerSignalProvider.notifier);
      authOwner.signOut();
      await _flushMicrotasks();
      check(container.read(authTokenProvider3)).isNull();
      check(
        container.read(authNavigationStateProvider),
      ).equals(AuthNavigationState.needsLogin);
      authOwner.signIn(token: 'test-token');
      container.read(attachedFilesProvider.notifier).addFiles([
        LocalAttachment(file: replacementImage, displayName: 'new.png'),
      ]);

      for (var attempt = 0; attempt < 50; attempt++) {
        final attachments = container.read(attachedFilesProvider);
        if (attachments.length == 1 &&
            attachments.single.file.path == replacementImage.path &&
            !await oldImage.exists()) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final attachments = container.read(attachedFilesProvider);
      check(attachments).length.equals(1);
      check(attachments.single.file.path).equals(replacementImage.path);
      check(await oldImage.exists()).isFalse();
      check(await replacementImage.exists()).isTrue();
    },
  );

  test(
    'same-token navigation revalidation preserves composer attachments',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final image = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174116-revalidation.png',
      );
      await image.writeAsBytes([1]);
      addTearDown(() async {
        if (await image.exists()) await image.delete();
      });

      final container = ProviderContainer(
        overrides: [
          authTokenProvider3.overrideWith(
            (ref) => ref.watch(_authOwnerSignalProvider).token,
          ),
          authNavigationStateProvider.overrideWith(
            (ref) => ref.watch(_authOwnerSignalProvider).navigation,
          ),
          isAuthLoadingProvider2.overrideWith(
            (ref) =>
                ref.watch(_authOwnerSignalProvider).navigation ==
                AuthNavigationState.loading,
          ),
          openWebUiAccountStorageIsolationProvider.overrideWith(
            _NoopAccountStorageIsolation.new,
          ),
          selectedModelProvider.overrideWith(_NullSelectedModel.new),
          apiServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(attachedFilesProvider.notifier).addFiles([
        LocalAttachment(file: image, displayName: 'revalidation.png'),
      ]);
      container.read(userScopedProviderCleanupProvider);

      check(container.read(isAuthLoadingProvider2)).isFalse();

      container
          .read(_authOwnerSignalProvider.notifier)
          .beginSameSessionRevalidation();
      check(container.read(isAuthLoadingProvider2)).isTrue();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      check(container.read(authTokenProvider3)).equals('test-token');
      check(container.read(attachedFilesProvider)).length.equals(1);
      check(await image.readAsBytes()).deepEquals([1]);
    },
  );

  test(
    'reauthentication during slow attachment cleanup preserves new providers',
    () async {
      final stagingDirectory = Directory(
        '${Directory.systemTemp.path}/conduit-native-paste',
      );
      await stagingDirectory.create();
      final oldImage = File(
        '${stagingDirectory.path}/'
        '123e4567-e89b-12d3-a456-426614174117-old.png',
      );
      await oldImage.writeAsBytes([1]);
      addTearDown(() async {
        if (await oldImage.exists()) await oldImage.delete();
      });
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();

      final container = ProviderContainer(
        overrides: [
          authTokenProvider3.overrideWith(
            (ref) => ref.watch(_authOwnerSignalProvider).token,
          ),
          authNavigationStateProvider.overrideWith(
            (ref) => ref.watch(_authOwnerSignalProvider).navigation,
          ),
          isAuthLoadingProvider2.overrideWithValue(false),
          openWebUiAccountStorageIsolationProvider.overrideWith(
            _NoopAccountStorageIsolation.new,
          ),
          selectedModelProvider.overrideWith(_NullSelectedModel.new),
          apiServiceProvider.overrideWithValue(null),
          appDatabaseProvider.overrideWithValue(null),
          terminalAttachmentCleanupProvider.overrideWithValue((
            filePath, {
            required beforeDeleteAdmission,
            required canDelete,
          }) async {
            if (!cleanupStarted.isCompleted) cleanupStarted.complete();
            await releaseCleanup.future;
            await beforeDeleteAdmission();
            if (!canDelete()) return true;
            final file = File(filePath);
            if (await file.exists()) await file.delete();
            return true;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(attachedFilesProvider.notifier).addFiles([
        LocalAttachment(file: oldImage, displayName: 'old.png'),
      ]);
      container.read(userScopedProviderCleanupProvider);

      final authOwner = container.read(_authOwnerSignalProvider.notifier);
      authOwner.signOut();
      await _flushMicrotasks(2);
      check(container.read(authTokenProvider3)).isNull();
      check(
        container.read(authNavigationStateProvider),
      ).equals(AuthNavigationState.needsLogin);
      await cleanupStarted.future.timeout(const Duration(seconds: 1));
      authOwner.signIn();
      final replacementConversation = _conversation('replacement-chat');
      container
          .read(activeConversationProvider.notifier)
          .set(replacementConversation);
      releaseCleanup.complete();
      await _waitForFileDeletion(oldImage);

      check(container.read(authTokenProvider3)).equals('replacement-token');
      check(
        container.read(activeConversationProvider),
      ).identicalTo(replacementConversation);
      check(await oldImage.exists()).isFalse();
    },
  );

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

  test(
    'direct completion relay is owned only by an authenticated session',
    () async {
      var navState = AuthNavigationState.authenticated;
      var relayStarts = 0;
      var relayDisposals = 0;
      final container = await _createAuthenticatedWarmupContainer(
        authNavigationOverride: authNavigationStateProvider.overrideWith(
          (ref) => navState,
        ),
        extraOverrides: [
          openWebUiDirectCompletionSocketRelayProvider.overrideWith((ref) {
            relayStarts += 1;
            ref.onDispose(() => relayDisposals += 1);
          }),
        ],
      );

      container.read(appStartupFlowProvider.notifier).activateForTesting();
      await _flushMicrotasks(4);
      expect(relayStarts, 1);
      expect(relayDisposals, 0);

      navState = AuthNavigationState.needsLogin;
      container.invalidate(authNavigationStateProvider);
      await _flushMicrotasks(2);
      expect(relayDisposals, 1);

      navState = AuthNavigationState.authenticated;
      container.invalidate(authNavigationStateProvider);
      await _flushMicrotasks(4);
      expect(relayStarts, 2);
      expect(relayDisposals, 1);
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

    // CDT-RFC-001 Phase 1: the resume refresh flows through the sync
    // engine (refreshConversationsCache -> requestPull), so the notifier's
    // own refresh is NOT re-invoked; the warmup pass only warms folders.
    expect(notifiers.conversations.refreshCalls, 0);
    expect(notifiers.folders.warmIfNeededCalls, 1);
  });

  test('resume refreshes the active conversation from the server', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final api = _StubApiService(
      conversations: {
        'active-chat': _conversation(
          'active-chat',
        ).copyWith(title: 'Server copy'),
      },
    );
    final container = await _createAuthenticatedWarmupContainer(
      apiOverride: apiServiceProvider.overrideWithValue(api),
    );
    container
        .read(activeConversationProvider.notifier)
        .set(_conversation('active-chat').copyWith(title: 'Local copy'));
    container.read(foregroundRefreshProvider);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks(5);

    expect(api.requestedConversationIds, ['active-chat']);
    expect(container.read(activeConversationProvider)?.title, 'Server copy');
    expect(
      container
          .read(conversationsProvider)
          .requireValue
          .any(
            (conversation) =>
                conversation.id == 'active-chat' &&
                conversation.title == 'Server copy',
          ),
      isTrue,
    );
  });

  test(
    'resume active conversation refresh ignores server fetch failures',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final api = _StubApiService(getConversationError: StateError('offline'));
      final container = await _createAuthenticatedWarmupContainer(
        apiOverride: apiServiceProvider.overrideWithValue(api),
      );
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('active-chat').copyWith(title: 'Local copy'));
      container.read(foregroundRefreshProvider);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flushMicrotasks(5);

      expect(api.requestedConversationIds, ['active-chat']);
      expect(container.read(activeConversationProvider)?.title, 'Local copy');
    },
  );

  test('resume active conversation refresh ignores stale fetches', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final getConversationGate = Completer<void>();
    final api = _StubApiService(
      conversations: {
        'active-chat': _conversation(
          'active-chat',
        ).copyWith(title: 'Server copy'),
      },
      getConversationGate: getConversationGate,
    );
    final container = await _createAuthenticatedWarmupContainer(
      apiOverride: apiServiceProvider.overrideWithValue(api),
    );
    container
        .read(activeConversationProvider.notifier)
        .set(_conversation('active-chat').copyWith(title: 'Local copy'));
    container.read(foregroundRefreshProvider);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushMicrotasks(2);

    container
        .read(activeConversationProvider.notifier)
        .set(_conversation('other-chat'));
    getConversationGate.complete();
    await _flushMicrotasks(5);

    expect(api.requestedConversationIds, ['active-chat']);
    expect(container.read(activeConversationProvider)?.id, 'other-chat');
  });

  test(
    'resume active conversation refresh skips protected streaming state',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final api = _StubApiService(
        conversations: {
          'active-chat': _conversation(
            'active-chat',
          ).copyWith(title: 'Server copy'),
        },
      );
      final container = await _createAuthenticatedWarmupContainer(
        apiOverride: apiServiceProvider.overrideWithValue(api),
        extraOverrides: [
          shouldProtectLocalStreamingStateProvider.overrideWithValue(true),
        ],
      );
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('active-chat').copyWith(title: 'Local copy'));
      container.read(foregroundRefreshProvider);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flushMicrotasks(5);

      expect(api.requestedConversationIds, isEmpty);
      expect(container.read(activeConversationProvider)?.title, 'Local copy');
    },
  );
}

abstract class _TrackingWarmupFolders extends Folders {
  int warmIfNeededCalls = 0;
}

final class _NoopAccountStorageIsolation
    extends OpenWebUiAccountStorageIsolation {
  @override
  void build() {}
}

final class _NullSelectedModel extends SelectedModel {
  @override
  Model? build() => null;
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
  _StubApiService({
    Map<String, Conversation>? conversations,
    this.getConversationGate,
    this.getConversationError,
  }) : _conversations = conversations ?? const <String, Conversation>{},
       super(serverConfig: _testServer, workerManager: WorkerManager());

  final Map<String, Conversation> _conversations;
  final Completer<void>? getConversationGate;
  final Object? getConversationError;
  final List<String> requestedConversationIds = <String>[];

  @override
  Future<Conversation> getConversation(String id) async {
    requestedConversationIds.add(id);
    final gate = getConversationGate;
    if (gate != null) {
      await gate.future;
    }
    final error = getConversationError;
    if (error != null) {
      throw error;
    }
    return _conversations[id] ?? _conversation(id);
  }
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
