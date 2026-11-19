@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/features/workspace/providers/workspace_session.dart'
    show WorkspaceSessionChanged;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart'
    show primaryAccountProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/account_scope.dart'
    show accountSwitchCountProvider;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

/// `POST /upload`'s service over one signed-in account whose server
/// answers from memory.
void main() {
  late _Api api;
  late Object epoch;
  Object? detailFails;

  setUp(() {
    api = _Api();
    epoch = Object();
    detailFails = null;
  });
  tearDown(() => api.dispose());

  ProviderContainer container() {
    final container = ProviderContainer(
      // A failed read stays failed (no retry timer left running).
      retry: (_, _) => null,
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        authStateManagerProvider.overrideWith(_SignedIn.new),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        activeServerProvider.overrideWith((ref) async => _server),
        workspaceModelDetailProvider.overrideWith((ref, id) async {
          if (detailFails case final error?) throw error;
          return null;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a file goes up under the account its request began with', () async {
    final c = container();
    await c.read(authStateManagerProvider.future);
    final files = FilesService(c);
    final began = files.session();
    // Another account signs in while the body is still arriving.
    epoch = Object();
    c.invalidate(openWebUiAuthSessionEpochProvider);
    await expectLater(
      files.upload(
        name: 'trail-map.pdf',
        bytes: Uint8List.fromList([1, 2, 3]),
        session: began,
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    expect(api.uploaded, isEmpty, reason: 'it went to the next account');
    // Under the account it began with, it goes.
    final file = await files.upload(
      name: 'trail-map.pdf',
      bytes: Uint8List.fromList([1, 2, 3]),
      session: files.session(),
    );
    expect(file.name, 'trail-map.pdf');
    expect(api.uploaded, ['trail-map.pdf']);
  });

  test('a model\'s picture is not handed over once another account signs in '
      'while it loads', () async {
    final c = container();
    await c.read(authStateManagerProvider.future);
    // Settled, as in a running daemon: the account in charge is known.
    await c.read(activeServerProvider.future);
    c.read(primaryAccountProvider);
    c.read(accountSwitchCountProvider);
    final files = FilesService(c);
    final gate = Completer<void>();
    api.avatarGate = gate.future;
    final loading = files.modelImage('server', 'trail-guide');
    await api.avatarAsked.future;
    // Another account signs in while the picture is on its way.
    epoch = Object();
    c.invalidate(openWebUiAuthSessionEpochProvider);
    gate.complete();
    await expectLater(
      loading,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    // Under the account in charge, it is handed over.
    api.avatarAsked = Completer<void>();
    final image = await files.modelImage('server', 'trail-guide');
    expect(image.contentType, 'image/png');
  });

  test('a model\'s picture is not fetched once the session it was asked '
      'under has changed', () async {
    final c = container();
    await c.read(authStateManagerProvider.future);
    await c.read(activeServerProvider.future);
    c.read(primaryAccountProvider);
    c.read(accountSwitchCountProvider);
    final files = FilesService(c);
    detailFails = const WorkspaceSessionChanged();
    await expectLater(
      files.modelImage('server', 'trail-guide'),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    expect(api.avatarAsked.isCompleted, isFalse, reason: 'it was fetched');
    // Unreadable for another reason (offline): the endpoint still answers.
    detailFails = StateError('offline');
    c.invalidate(workspaceModelDetailProvider);
    final image = await files.modelImage('server', 'trail-guide');
    expect(image.contentType, 'image/png');
  });
}

final class _SignedIn extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'token');
}

/// The account's server, answered from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  final uploaded = <String>[];
  Future<void>? avatarGate;
  var avatarAsked = Completer<void>();

  @override
  Future<List<int>?> getWorkspaceModelAvatar(
    String id, {
    String? imageUrl,
  }) async {
    avatarAsked.complete();
    final gate = avatarGate;
    avatarGate = null;
    if (gate != null) await gate;
    return const [0x89, 0x50, 0x4E, 0x47, 0, 0];
  }

  @override
  Future<String> uploadFileBytes(
    String fileName,
    List<int> bytes, {
    void Function(int sent, int total)? onProgress,
    Map<String, dynamic>? metadata,
  }) async {
    uploaded.add(fileName);
    return 'file-${uploaded.length}';
  }
}
