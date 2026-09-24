@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/external_sign_in.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_client.dart';
import 'package:conduit_desktop_ui/src/rpc/direct_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/hermes_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/session_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:test/test.dart';

/// Answers whatever the test tells it to, and records what was asked.
///
/// `implements RpcClient` rather than a subclass: the point is to replace the
/// socket entirely, and `noSuchMethod` makes any *unexpected* call a loud
/// failure instead of a silent default.
class _FakeRpcClient implements RpcClient {
  _FakeRpcClient(this.responses);

  final Map<String, Object Function()> responses;
  final List<({String method, Map<String, dynamic>? params})> calls =
      <({String method, Map<String, dynamic>? params})>[];

  @override
  Future<T> call<T>(
    String method, {
    Map<String, dynamic>? params,
    required T Function(Map<String, dynamic> json) decode,
  }) async {
    calls.add((method: method, params: params));
    // Every window asks for the direct connections, which decide whether a
    // setup with no server is a setup at all. None, unless a test says.
    // Hermes too: not set up, unless a test says.
    final responder =
        responses[method] ??
        (method == ConduitMethods.directList
            ? () => const DirectConnectionList()
            : method == ConduitMethods.hermesSettings
            ? () => const HermesSettings()
            : null);
    if (responder == null) {
      throw StateError('no fake response for $method');
    }
    return decode((responder() as dynamic).toJson() as Map<String, dynamic>);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected ${invocation.memberName}');
}

/// Stands in for the Electron auth window.
class _FakeExternalSignIn implements ExternalSignInPort {
  _FakeExternalSignIn(this.outcome);

  final ExternalSignIn outcome;
  int runs = 0;
  String? lastStartUrl;

  @override
  Future<ExternalSignIn> run({
    required String startUrl,
    required String serverUrl,
    String? title,
  }) async {
    runs++;
    lastStartUrl = startUrl;
    return outcome;
  }
}

ProviderContainer _container(
  _FakeRpcClient client, {
  ExternalSignInPort? externalSignIn,
}) {
  final container = ProviderContainer(
    overrides: [
      rpcClientProvider.overrideWithValue(client),
      if (externalSignIn != null)
        externalSignInProvider.overrideWithValue(externalSignIn),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _signedOut = AuthSnapshot(phase: AuthPhase.unauthenticated);
const _signedIn = AuthSnapshot(
  phase: AuthPhase.authenticated,
  isAuthenticated: true,
  hasToken: true,
);
const _emptyList = ServerList();
const _oneServer = ServerList(
  servers: <ServerSummary>[
    ServerSummary(
      id: 'server-1',
      name: 'Home',
      url: 'https://chat.example.com',
      isActive: true,
    ),
  ],
  activeServerId: 'server-1',
);

void main() {
  group('needsOnboarding', () {
    test('is unknown while either query is in flight', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _emptyList,
          ConduitMethods.authStatus: () => _signedOut,
        }),
      );

      // Before either future settles. Rendering onboarding here is what makes
      // a signed-in user's window flash a setup screen on every launch.
      expect(container.read(needsOnboardingProvider).isLoading, isTrue);
    });

    test('is true with no active server', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _emptyList,
          ConduitMethods.authStatus: () => _signedOut,
        }),
      );
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      await container.read(directConnectionsProvider.future);
      await container.read(hermesSettingsProvider.future);

      expect(container.read(needsOnboardingProvider).value, isTrue);
    });

    test('is false once a server is active', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _oneServer,
          ConduitMethods.authStatus: () => _signedIn,
        }),
      );
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      await container.read(directConnectionsProvider.future);
      await container.read(hermesSettingsProvider.future);

      expect(container.read(needsOnboardingProvider).value, isFalse);
    });

    test('reviewer mode is a session, not onboarding', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _emptyList,
          ConduitMethods.authStatus: () => const AuthSnapshot(
            phase: AuthPhase.unauthenticated,
            isReviewerMode: true,
          ),
        }),
      );
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      await container.read(directConnectionsProvider.future);
      await container.read(hermesSettingsProvider.future);

      // No server configured, and still not onboarding: the demo path runs
      // against canned data with no server at all.
      expect(container.read(needsOnboardingProvider).value, isFalse);
    });

    test('direct connections and no server are a setup', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _emptyList,
          ConduitMethods.authStatus: () => _signedOut,
          ConduitMethods.directList: () =>
              const DirectConnectionList(preferred: true, usable: true),
        }),
      );
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      await container.read(directConnectionsProvider.future);
      await container.read(hermesSettingsProvider.future);

      expect(container.read(directOnlyProvider).value, isTrue);
      expect(container.read(needsOnboardingProvider).value, isFalse);
    });

    test('Hermes Agent and no server are a setup too', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _emptyList,
          ConduitMethods.authStatus: () => _signedOut,
          ConduitMethods.hermesSettings: () =>
              const HermesSettings(enabled: true, usable: true),
        }),
      );
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      await container.read(directConnectionsProvider.future);
      await container.read(hermesSettingsProvider.future);

      expect(container.read(directOnlyProvider).value, isTrue);
      expect(container.read(needsOnboardingProvider).value, isFalse);
    });

    test('chosen but with nothing that works yet, it is still setup', () async {
      final container = _container(
        _FakeRpcClient(<String, Object Function()>{
          ConduitMethods.serversList: () => _emptyList,
          ConduitMethods.authStatus: () => _signedOut,
          ConduitMethods.directList: () =>
              const DirectConnectionList(preferred: true),
        }),
      );
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      await container.read(directConnectionsProvider.future);
      await container.read(hermesSettingsProvider.future);

      expect(container.read(needsOnboardingProvider).value, isTrue);
    });
  });

  group('SessionActions', () {
    test('signing in refetches both the session and the servers', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.serversList: () => _oneServer,
        ConduitMethods.authStatus: () => _signedOut,
        ConduitMethods.authLoginWithPassword: () => _signedIn,
      });
      final container = _container(client);
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);
      client.calls.clear();

      await container
          .read(sessionActionsProvider)
          .signInWithPassword(
            const PasswordLogin(username: 'ada', password: 'x'),
          );

      // Both, because signing in changes which server is active as often as
      // it changes the session.
      expect(
        container.read(authStatusProvider),
        isA<AsyncValue<AuthSnapshot>>().having(
          (v) => v.isLoading || v.hasValue,
          'refetching or refetched',
          isTrue,
        ),
      );
      expect(container.read(serverListProvider).isLoading, isTrue);
    });

    test('adding a server does not disturb the session', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.serversList: () => _emptyList,
        ConduitMethods.authStatus: () => _signedOut,
        ConduitMethods.serversAdd: () => _oneServer.servers.single,
      });
      final container = _container(client);
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);

      await container
          .read(sessionActionsProvider)
          .addServer(
            const ServerDraft(name: 'Home', url: 'https://chat.example.com'),
          );

      expect(container.read(serverListProvider).isLoading, isTrue);
      // Adding is not connecting; the session is untouched.
      expect(container.read(authStatusProvider).hasValue, isTrue);
    });

    test('connecting refetches the session too', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.serversList: () => _oneServer,
        ConduitMethods.authStatus: () => _signedIn,
        ConduitMethods.serversConnect: () => _oneServer,
      });
      final container = _container(client);
      await container.read(serverListProvider.future);
      await container.read(authStatusProvider.future);

      await container.read(sessionActionsProvider).connectToServer('server-1');

      // Connecting signs out, so a cached "authenticated" would be a lie.
      expect(container.read(authStatusProvider).isLoading, isTrue);
      expect(container.read(serverListProvider).isLoading, isTrue);
    });

    test('sign-out sends the keep-server-details choice through', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.serversList: () => _oneServer,
        ConduitMethods.authStatus: () => _signedIn,
        ConduitMethods.authSignOut: () =>
            const SignOutResult(outcome: SignOutOutcome.cleared),
      });
      final container = _container(client);

      final result = await container
          .read(sessionActionsProvider)
          .signOut(const SignOutRequest(keepServerDetails: false));

      expect(result.outcome, SignOutOutcome.cleared);
      expect(client.calls.single.params, <String, dynamic>{
        'keepServerDetails': false,
      });
    });

    test('external sign-in hands the capture to the daemon', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.serversList: () => _oneServer,
        ConduitMethods.authStatus: () => _signedOut,
        ConduitMethods.authCompleteExternal: () => _signedIn,
      });
      final container = _container(
        client,
        externalSignIn: _FakeExternalSignIn(
          const ExternalSignInCaptured(
            origin: 'https://chat.example.com',
            cookies: <String, String>{'oauth2_proxy': 'opaque'},
            token: 'jwt-from-trusted-headers',
          ),
        ),
      );

      final snapshot = await container
          .read(sessionActionsProvider)
          .signInExternally(serverUrl: 'https://chat.example.com');

      expect(snapshot?.isAuthenticated, isTrue);
      expect(client.calls.single.params, <String, dynamic>{
        'origin': 'https://chat.example.com',
        'cookies': <String, String>{'oauth2_proxy': 'opaque'},
        'token': 'jwt-from-trusted-headers',
      });
    });

    test('a closed window sends nothing and is not an error', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.serversList: () => _oneServer,
        ConduitMethods.authStatus: () => _signedOut,
      });
      final container = _container(
        client,
        externalSignIn: _FakeExternalSignIn(
          const ExternalSignInAbandoned(timedOut: false),
        ),
      );

      final snapshot = await container
          .read(sessionActionsProvider)
          .signInExternally(serverUrl: 'https://chat.example.com');

      // Null, not a throw: the user closed it on purpose. And crucially no
      // RPC -- `authCompleteExternal` has no fake, so calling it would fail.
      expect(snapshot, isNull);
      expect(client.calls, isEmpty);
    });

    test('a timeout is also a cancellation, not a failure', () async {
      final container = _container(
        _FakeRpcClient(const <String, Object Function()>{}),
        externalSignIn: _FakeExternalSignIn(
          const ExternalSignInAbandoned(timedOut: true),
        ),
      );

      expect(
        await container
            .read(sessionActionsProvider)
            .signInExternally(serverUrl: 'https://chat.example.com'),
        isNull,
      );
    });

    test('a capture without a token is still sent', () async {
      final client = _FakeRpcClient(<String, Object Function()>{
        ConduitMethods.authCompleteExternal: () => _signedOut,
      });
      final container = _container(
        client,
        externalSignIn: _FakeExternalSignIn(
          const ExternalSignInCaptured(
            origin: 'https://chat.example.com',
            cookies: <String, String>{'authelia_session': 'opaque'},
          ),
        ),
      );

      // The proxy let us through and Open WebUI still wants credentials.
      // That is a real outcome the daemon has to see, not a reason to skip
      // the call.
      final snapshot = await container
          .read(sessionActionsProvider)
          .signInExternally(serverUrl: 'https://chat.example.com');

      expect(snapshot?.isAuthenticated, isFalse);
      expect((client.calls.single.params!)['token'], isNull);
    });

    test('the server url is the default entry point', () async {
      final external = _FakeExternalSignIn(
        const ExternalSignInAbandoned(timedOut: false),
      );
      final container = _container(
        _FakeRpcClient(const <String, Object Function()>{}),
        externalSignIn: external,
      );

      await container
          .read(sessionActionsProvider)
          .signInExternally(serverUrl: 'https://chat.example.com');
      expect(external.lastStartUrl, 'https://chat.example.com');

      await container
          .read(sessionActionsProvider)
          .signInExternally(
            serverUrl: 'https://chat.example.com',
            startUrl: 'https://idp.example.com/authorize',
          );
      expect(external.lastStartUrl, 'https://idp.example.com/authorize');
    });

    test('the dev browser explains itself rather than doing nothing', () {
      final container = _container(
        _FakeRpcClient(const <String, Object Function()>{}),
      );
      expect(
        () => container
            .read(sessionActionsProvider)
            .signInExternally(serverUrl: 'https://chat.example.com'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('an unknown method is a failure, not a silent default', () async {
      final container = _container(
        _FakeRpcClient(const <String, Object Function()>{}),
      );
      expect(
        () => container.read(sessionActionsProvider).restoreSession(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
