import 'dart:async';

import 'package:conduit/core/providers/backend_mode_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit/features/direct_connections/views/direct_connection_editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<void> directTestExpandAdvancedSettings(WidgetTester tester) async {
  final toggle = find.byKey(
    const ValueKey<String>('direct-advanced-settings-toggle'),
  );
  await tester.scrollUntilVisible(
    toggle,
    400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

GoRouter directTestOnboardingRouter() => GoRouter(
  initialLocation: '/editor/new?onboarding=true',
  routes: [
    GoRoute(
      path: '/editor/:id',
      name: RouteNames.directConnectionEditor,
      builder: (_, state) => DirectConnectionEditorPage(
        mode: DirectConnectionEditorMode.fromRoute(
          profileId: state.pathParameters['id']!,
          source: DirectConnectionEditorSource.local,
        ),
        isOnboarding: true,
      ),
    ),
    GoRoute(
      path: '/overview',
      name: RouteNames.directConnections,
      builder: (_, _) => const Scaffold(body: Text('Connection overview')),
    ),
  ],
);

Future<void> directTestSubmitOnboarding(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('direct-api-key-field')),
    'test-secret',
  );
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey<String>('direct-editor-save-button')),
  );
  await tester.pumpAndSettle();
}

void directTestNoop() {}

final class DirectTestStaticOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  DirectTestStaticOpenWebUiConnections(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;
}

final class DirectTestRefreshFailureOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  DirectTestRefreshFailureOpenWebUiConnections(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;

  void failRefresh() {
    state = AsyncError<OpenWebUiDirectConnectionsSnapshot?>(
      StateError('refresh failed'),
      StackTrace.current,
    );
  }
}

final class DirectTestTrackingReloadOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  DirectTestTrackingReloadOpenWebUiConnections(this.snapshot);

  final OpenWebUiDirectConnectionsSnapshot snapshot;
  int reloadCount = 0;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;

  @override
  Future<void> reload() async {
    reloadCount++;
  }
}

final class DirectTestMutableOpenWebUiConnections
    extends OpenWebUiDirectConnectionsController {
  DirectTestMutableOpenWebUiConnections(this.snapshot);

  OpenWebUiDirectConnectionsSnapshot snapshot;
  int deleteCalls = 0;
  int updateCalls = 0;
  OpenWebUiDirectConnectionRecord? lastUpdatedRecord;
  DirectConnectionProfile? lastUpdatedProfile;
  String? lastUpdatedAuthType;
  Future<void> Function()? updateHandler;
  Future<void> Function()? deleteHandler;

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async => snapshot;

  void setSnapshot(OpenWebUiDirectConnectionsSnapshot value) {
    snapshot = value;
    state = AsyncData(value);
  }

  @override
  Future<void> delete(OpenWebUiDirectConnectionRecord record) async {
    deleteCalls++;
    await deleteHandler?.call();
  }

  @override
  Future<void> updateConnection(
    OpenWebUiDirectConnectionRecord record,
    DirectConnectionProfile profile, {
    String? authType,
  }) async {
    updateCalls++;
    lastUpdatedRecord = record;
    lastUpdatedProfile = profile;
    lastUpdatedAuthType = authType;
    await updateHandler?.call();
  }
}

final class DirectTestStaticDirectProfiles
    extends DirectConnectionProfilesController {
  DirectTestStaticDirectProfiles(this.profiles);

  final List<DirectConnectionProfile> profiles;
  int probeCalls = 0;

  @override
  Future<List<DirectConnectionProfile>> build() async => profiles;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    probeCalls++;
    return const DirectConnectionProbe(reachable: true);
  }
}

final class DirectTestOnboardingDirectProfiles
    extends DirectConnectionProfilesController {
  DirectTestOnboardingDirectProfiles(this.result, {this.probeCompleter});

  final DirectConnectionProbe result;
  final Completer<DirectConnectionProbe>? probeCompleter;
  int probeCalls = 0;
  int upsertCalls = 0;
  DirectConnectionProfile? lastProbe;
  DirectConnectionProfile? lastUpsert;

  @override
  Future<List<DirectConnectionProfile>> build() async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async {
    probeCalls++;
    lastProbe = profile;
    return probeCompleter?.future ?? result;
  }

  @override
  Future<void> upsert(
    DirectConnectionProfile profile, {
    DirectConnectionProfile? expectedPrevious,
    bool secretsConfirmedForNewOrigin = false,
  }) async {
    upsertCalls++;
    lastUpsert = profile;
    state = AsyncData([profile]);
  }
}

final class DirectTestMutableAuthEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

final class DirectTestStaticHistoryPolicy
    extends DirectHistoryPolicyController {
  @override
  DirectHistoryPolicy build() => DirectHistoryPolicy.syncWithOpenWebUI;
}

final class DirectTestFailingPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    throw StateError('preference write failed');
  }
}

final class DirectTestTrackingPreferredBackendController
    extends PreferredBackendController {
  final List<PreferredBackend> writes = [];

  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    writes.add(backend);
    state = backend;
  }
}

final class DirectTestBlockingPreferredBackendController
    extends PreferredBackendController {
  final List<PreferredBackend> writes = [];
  final Completer<void> unsetStarted = Completer<void>();
  final Completer<void> _releaseUnset = Completer<void>();

  @override
  PreferredBackend build() => PreferredBackend.direct;

  @override
  Future<void> set(PreferredBackend backend) async {
    writes.add(backend);
    if (backend == PreferredBackend.unset) {
      if (!unsetStarted.isCompleted) unsetStarted.complete();
      await _releaseUnset.future;
    }
    state = backend;
  }

  void release() {
    if (!_releaseUnset.isCompleted) _releaseUnset.complete();
  }
}

final class DirectTestRejectingProfileWriteSecureStorage
    implements FlutterSecureStorage {
  DirectTestRejectingProfileWriteSecureStorage(this.raw);

  final String raw;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => raw;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('profile write failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
