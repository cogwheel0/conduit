import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _accountA = User(
  id: 'account-a',
  username: 'A',
  email: 'a@example.test',
  role: 'user',
);
const _accountB = User(
  id: 'account-b',
  username: 'B',
  email: 'b@example.test',
  role: 'user',
);

class _Account extends Notifier<User?> {
  @override
  User? build() => _accountA;

  void signInAs(User user) => state = user;
}

final _accountProvider = NotifierProvider<_Account, User?>(_Account.new);

class _Epoch extends Notifier<Object> {
  @override
  Object build() => Object();

  /// A new sign-in session: another account, or the same one signing back in.
  void rotate() => state = Object();
}

final _epochProvider = NotifierProvider<_Epoch, Object>(_Epoch.new);

/// An Open WebUI server's permissions route, answering per bearer token. It
/// sits behind the real [ApiService] auth interceptor, so what it records is
/// what the server would have received.
class _PermissionsAdapter implements HttpClientAdapter {
  /// What each bearer token is told; a token not listed gets `{}`.
  final Map<String, Map<String, dynamic>> bodies = {};

  /// Bearer tokens whose read fails with a server error.
  final Set<String> failing = {};

  /// Bearer tokens whose answer is held until the gate is completed.
  final Map<String, Completer<void>> gates = {};

  final Map<String, Completer<void>> _arrived = {};

  /// The `Authorization` header of every read that reached the wire.
  final List<String?> bearers = [];

  int get calls => bearers.length;

  Future<void> arrival(String bearer) =>
      (_arrived[bearer] ??= Completer<void>()).future;

  ResponseBody _json(Object body, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    final bearer = options.headers['Authorization'] as String?;
    bearers.add(bearer);
    final arrived = _arrived[bearer ?? ''] ??= Completer<void>();
    if (!arrived.isCompleted) arrived.complete();
    final gate = gates[bearer];
    if (gate != null) await gate.future;
    if (failing.contains(bearer)) {
      return _json(const <String, dynamic>{}, status: 500);
    }
    return _json(bodies[bearer] ?? const <String, dynamic>{});
  }

  @override
  void close({bool force = false}) {}
}

/// Account A may edit everything (it is simply not told otherwise); account B
/// has chat controls switched off.
const _policyAllows = <String, dynamic>{
  'chat': {'controls': true},
};
const _policyDenies = <String, dynamic>{
  'chat': {'controls': false},
};

void main() {
  late ApiService api;
  late _PermissionsAdapter adapter;

  setUp(() {
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'same-server',
        name: 'Same',
        url: 'https://example.test',
      ),
      workerManager: WorkerManager(),
    );
    adapter = _PermissionsAdapter();
    api.dio.httpClientAdapter = adapter;
    adapter.bodies['Bearer token-a'] = _policyAllows;
    adapter.bodies['Bearer token-b'] = _policyDenies;
    api.updateAuthToken('token-a');
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWith((ref) => ref.watch(_accountProvider)),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_epochProvider),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(userPermissionsProvider, (_, _) {});
    c.listen(openWebUiChatSettingsAccessProvider, (_, _) {});
    return c;
  }

  /// B signs in on the same server: same API object, a new token, account and
  /// session.
  void switchToB(ProviderContainer c) {
    api.updateAuthToken('token-b');
    c.read(_accountProvider.notifier).signInAs(_accountB);
    c.read(_epochProvider.notifier).rotate();
  }

  test(
    'a switched account on the same API reads its own permissions',
    () async {
      final c = container();
      final a = await c.read(userPermissionsProvider.future);
      expect((a['chat'] as Map)['controls'], true);

      switchToB(c);

      final b = await c.read(userPermissionsProvider.future);
      expect((b['chat'] as Map)['controls'], false);
      expect(adapter.bearers, ['Bearer token-a', 'Bearer token-b']);
    },
  );

  test(
    'chat settings access comes from the shared read, not a second request',
    () async {
      final c = container();

      final access = await c.read(openWebUiChatSettingsAccessProvider.future);
      await c.read(userPermissionsProvider.future);

      expect(access.canEditAnything, isTrue);
      expect(adapter.calls, 1);

      switchToB(c);

      final next = await c.read(openWebUiChatSettingsAccessProvider.future);
      expect(next.canEditAnything, isFalse);
      expect(adapter.bearers, ['Bearer token-a', 'Bearer token-b']);
    },
  );

  test('a late answer for the previous account is never the next one\'s '
      'policy', () async {
    adapter.gates['Bearer token-a'] = Completer<void>();
    final c = container();
    final lateA = c.read(userPermissionsProvider.future);
    final lateAccessA = c.read(openWebUiChatSettingsAccessProvider.future);
    await adapter.arrival('Bearer token-a');

    // B signs in while A's request is still on the wire.
    switchToB(c);
    final b = await c.read(userPermissionsProvider.future);
    expect((b['chat'] as Map)['controls'], false);

    // Now A's answer ("allowed") finally arrives.
    adapter.gates['Bearer token-a']!.complete();
    final settledA = await lateA.then<Map<String, dynamic>?>(
      (value) => value,
      onError: (Object _) => null,
    );
    final settledAccessA = await lateAccessA;

    // Whatever A's own future became, it did not carry A's policy to B...
    expect((settledA?['chat'] as Map?)?['controls'], isNot(true));
    expect(settledAccessA.canEditAnything, isFalse);
    // ...and B's provider state is still B's.
    final current = c.read(userPermissionsProvider).requireValue;
    expect((current['chat'] as Map)['controls'], false);
    expect(
      (await c.read(openWebUiChatSettingsAccessProvider.future))
          .canEditAnything,
      isFalse,
    );
  });

  test(
    'the same user signing back in reads again under the new session',
    () async {
      final c = container();
      expect(
        (await c.read(openWebUiChatSettingsAccessProvider.future))
            .canEditAnything,
        isTrue,
      );

      // Same account, same API: only the token (and so the session) is new, and
      // the server now answers differently for it.
      adapter.bodies['Bearer token-a2'] = _policyDenies;
      api.updateAuthToken('token-a2');
      c.read(_epochProvider.notifier).rotate();

      final perms = await c.read(userPermissionsProvider.future);
      expect((perms['chat'] as Map)['controls'], false);
      expect(
        (await c.read(openWebUiChatSettingsAccessProvider.future))
            .canEditAnything,
        isFalse,
      );
      expect(adapter.bearers, ['Bearer token-a', 'Bearer token-a2']);
    },
  );

  test('a read prepared before the token rotated is refused at dispatch, '
      'not sent as the next account', () async {
    final c = container();

    // Built under A's token, but the token changes before the request is
    // dispatched: the request carries A's frozen snapshot and is refused.
    final prepared = c.read(userPermissionsProvider.future);
    api.updateAuthToken('token-b');

    await expectLater(prepared, throwsA(isA<DioException>()));
    expect(adapter.calls, 0);
  });

  group('a failed read is not a successful empty answer', () {
    test(
      'it surfaces as an error and chat settings access fails closed',
      () async {
        adapter.failing.add('Bearer token-a');
        final c = container();

        await expectLater(
          c.read(userPermissionsProvider.future),
          throwsA(isA<DioException>()),
        );
        final access = await c.read(openWebUiChatSettingsAccessProvider.future);
        expect(access.canEditSystemPrompt, isFalse);
        expect(access.canEditParameters, isFalse);
      },
    );

    test('a successful answer that omits the flags still allows', () async {
      adapter.bodies['Bearer token-a'] = const <String, dynamic>{};
      final c = container();

      expect(await c.read(userPermissionsProvider.future), isEmpty);
      final access = await c.read(openWebUiChatSettingsAccessProvider.future);
      expect(access.canEditSystemPrompt, isTrue);
      expect(access.canEditParameters, isTrue);
    });

    test('feature availability keeps its assume-available fallback', () async {
      adapter.failing.add('Bearer token-a');
      final c = container();
      await expectLater(
        c.read(userPermissionsProvider.future),
        throwsA(isA<DioException>()),
      );

      expect(c.read(imageGenerationAvailableProvider), isTrue);
    });
  });
}
