@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The daemon's LibreChat service against the core's fake LibreChat server
/// (an in-process Dio adapter): no network.
void main() {
  test(
    "a memory write begun for one LibreChat account is not the next one's",
    () async {
      final bench = await _Bench.start();
      final asked = Completer<void>();
      final release = Completer<void>();
      final created = <String>[];
      // The first account's memories are read slowly: another account signs
      // in meanwhile.
      bench.fake
        ..on('GET', '/api/memories', (request, _) async {
          if (bench.fake.userFor(request)?.email == _avery &&
              !release.isCompleted) {
            if (!asked.isCompleted) asked.complete();
            await release.future;
          }
          return _noMemories();
        })
        ..on('POST', '/api/memories', (request, _) {
          created.add(bench.fake.userFor(request)!.email);
          return FakeLibreChatResponse.json({'created': true});
        });

      final saving = bench.service.saveMemory(
        const LibreChatMemoryEdit(key: 'trail_notes', value: 'Ridge loop'),
      );
      await asked.future;
      bench.switchToBlake();
      release.complete();
      await expectLater(saving, _refusedForTheSwitch);
      expect(created, isEmpty, reason: 'the memory was saved for an account');
    },
  );

  test(
    "one LibreChat account's memories never go out with the next one's rights",
    () async {
      final asked = Completer<void>();
      final capabilities = Completer<LibreChatCapabilities>();
      final bench = await _Bench.start(
        capabilities: () {
          if (!asked.isCompleted) asked.complete();
          return capabilities.future;
        },
      );
      bench.fake.on('GET', '/api/memories', (request, _) {
        return FakeLibreChatResponse.json({
          'memories': [
            if (bench.fake.userFor(request)?.email == _avery)
              {'key': 'trail_notes', 'value': 'Ridge loop', 'tokenCount': 3},
          ],
          'totalTokens': 3,
          'tokenLimit': 1000,
          'usagePercentage': 0,
        });
      });
      final reading = bench.service.memories();
      // The first account's memories are read; its rights are still out
      // when another account signs in.
      await asked.future;
      bench.switchToBlake();
      capabilities.complete(LibreChatCapabilities.minimal);
      await expectLater(reading, _refusedForTheSwitch);
    },
  );

  test('a two-step sign-in that a newer one began after puts no account in '
      'charge', () async {
    final fake = FakeLibreChatServer()
      ..addUser(email: _avery, password: 'pw-avery', totpCode: '246810')
      ..addUser(email: _blake, password: 'pw-blake');
    final container = ProviderContainer(
      overrides: [libreChatHttpAdapterProvider.overrideWithValue(fake)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final service = LibreChatService(
      container,
      events: EventBus(),
      accounts: AccountsService(container, events: EventBus()),
    );
    final first = await service.signIn(
      LibreChatSignIn(url: fake.baseUrl, email: _avery, password: 'pw-avery'),
    );
    expect(first.outcome, LibreChatSignInOutcome.twoFactorRequired);

    // The form starts over and signs in again (refused here).
    final second = await service.signIn(
      LibreChatSignIn(url: fake.baseUrl, email: _blake, password: 'nope'),
    );
    expect(second.outcome, LibreChatSignInOutcome.rejected);

    // The first form's code, sent late: no account goes in charge.
    final late = await service.verify(
      LibreChatVerify(flowId: first.flowId!, code: '246810'),
    );
    expect(late.outcome, LibreChatSignInOutcome.expired);
    expect(late.accountId, isNull);
  });
}

const _avery = 'avery@example.com';
const _blake = 'blake@example.com';
const _server = LibreChatServer(baseUrl: 'https://chat.example.com');

final _refusedForTheSwitch = throwsA(
  isA<RpcError>().having(
    (e) => e.code,
    'code',
    ConduitErrorCodes.sessionExpired,
  ),
);

FakeLibreChatResponse _noMemories() => FakeLibreChatResponse.json({
  'memories': <Object?>[],
  'totalTokens': 0,
  'tokenLimit': 1000,
  'usagePercentage': 0,
});

/// Two signed-in LibreChat accounts on one fake server, the first in use,
/// and the daemon's service over them.
final class _Bench {
  _Bench._(this.fake, this._blakeApi, this._current, this.container, this.service);

  final FakeLibreChatServer fake;
  final LibreChatApiService _blakeApi;
  final _Holder _current;
  final ProviderContainer container;
  final LibreChatService service;

  /// Another account signs in.
  void switchToBlake() {
    _current.api = _blakeApi;
    container.invalidate(libreChatApiServiceProvider);
  }

  /// [capabilities] answers the rights read (at once by default).
  static Future<_Bench> start({
    Future<LibreChatCapabilities> Function()? capabilities,
  }) async {
    final fake = FakeLibreChatServer()
      ..addUser(email: _avery, password: 'pw-avery')
      ..addUser(email: _blake, password: 'pw-blake');
    Future<LibreChatApiService> apiFor(String email, String password) async {
      final auth = LibreChatAuthService(_server, adapter: fake);
      addTearDown(auth.close);
      final signedIn =
          await auth.signIn(email: email, password: password)
              as LibreChatSignedIn;
      final client = LibreChatHttpClient(
        server: _server,
        adapter: fake,
        session: LibreChatSessionHandle(
          session: signedIn.session,
          store: InMemoryLibreChatSessionStore(),
          renew: auth.renew,
        ),
      );
      addTearDown(client.close);
      return LibreChatApiService(client);
    }

    final current = _Holder(await apiFor(_avery, 'pw-avery'));
    final blake = await apiFor(_blake, 'pw-blake');
    final container = ProviderContainer(
      overrides: [
        libreChatApiServiceProvider.overrideWith((ref) => current.api),
        libreChatCapabilitiesProvider.overrideWith(
          (ref) =>
              capabilities?.call() ??
              Future.value(LibreChatCapabilities.minimal),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final service = LibreChatService(
      container,
      events: EventBus(),
      accounts: AccountsService(container, events: EventBus()),
    );
    return _Bench._(fake, blake, current, container, service);
  }
}

final class _Holder {
  _Holder(this.api);
  LibreChatApiService api;
}
