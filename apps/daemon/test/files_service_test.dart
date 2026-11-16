@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
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

  setUp(() {
    api = _Api();
    epoch = Object();
  });
  tearDown(() => api.dispose());

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        authStateManagerProvider.overrideWith(_SignedIn.new),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
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
