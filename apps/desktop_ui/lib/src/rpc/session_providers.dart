import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_client.dart';
import 'rpc_providers.dart';

/// The configured servers, as the daemon reports them.
///
/// Read-only: every mutation goes through [SessionActions] so the list is
/// refetched from the daemon rather than patched locally. The daemon is the
/// only thing that knows whether a write landed, and a locally-patched list
/// that disagrees with it is the bug this avoids.
final serverListProvider = FutureProvider<ServerList>((ref) async {
  // Refetches on reconnect: the daemon may have restarted, and anything
  // cached from the previous process is a guess.
  ref.watch(coreConnectionProvider);
  return ref
      .watch(rpcClientProvider)
      .call(ConduitMethods.serversList, decode: ServerList.fromJson);
});

/// The current session.
final authStatusProvider = FutureProvider<AuthSnapshot>((ref) async {
  ref.watch(coreConnectionProvider);
  return ref
      .watch(rpcClientProvider)
      .call(ConduitMethods.authStatus, decode: AuthSnapshot.fromJson);
});

/// Whether this launch should start at onboarding.
///
/// Three states, not two: while either query is in flight the answer is
/// unknown, and rendering onboarding during that window is what makes a
/// signed-in user's app flash a setup screen on every launch.
final needsOnboardingProvider = Provider<AsyncValue<bool>>((ref) {
  final servers = ref.watch(serverListProvider);
  final auth = ref.watch(authStatusProvider);
  if (servers.isLoading || auth.isLoading) {
    return const AsyncValue<bool>.loading();
  }
  return servers.when(
    loading: () => const AsyncValue<bool>.loading(),
    error: AsyncValue<bool>.error,
    data: (list) => auth.when(
      loading: () => const AsyncValue<bool>.loading(),
      error: AsyncValue<bool>.error,
      data: (snapshot) => AsyncValue<bool>.data(
        // Reviewer mode is a complete session with no server, so it is not
        // onboarding even though there is nothing configured.
        !snapshot.isReviewerMode && list.activeServerId == null,
      ),
    ),
  );
});

/// Mutations on the session.
///
/// A plain class rather than a notifier: none of these hold state. Each calls
/// the daemon and then invalidates what the call could have changed, so the
/// next read comes from the daemon.
final sessionActionsProvider = Provider<SessionActions>(
  (ref) => SessionActions(ref),
);

class SessionActions {
  SessionActions(this._ref);

  final Ref _ref;

  RpcClient get _client => _ref.read(rpcClientProvider);

  Future<ServerSummary> addServer(ServerDraft draft) async {
    final added = await _client.call(
      ConduitMethods.serversAdd,
      params: draft.toJson(),
      decode: ServerSummary.fromJson,
    );
    _ref.invalidate(serverListProvider);
    return added;
  }

  Future<ServerSummary> updateServer(ServerDraft draft) async {
    final updated = await _client.call(
      ConduitMethods.serversUpdate,
      params: draft.toJson(),
      decode: ServerSummary.fromJson,
    );
    _ref.invalidate(serverListProvider);
    return updated;
  }

  Future<ServerList> removeServer(String id) async {
    final list = await _client.call(
      ConduitMethods.serversRemove,
      params: ServerRef(id: id).toJson(),
      decode: ServerList.fromJson,
    );
    _ref.invalidate(serverListProvider);
    return list;
  }

  /// Connects to [id]. **Destructive** -- see [ConduitMethods.serversConnect]:
  /// the core signs out and drops every other configured server, because it
  /// stores one auth token. Callers confirm with the user first.
  Future<ServerList> connectToServer(String id) async {
    final list = await _client.call(
      ConduitMethods.serversConnect,
      params: ServerRef(id: id).toJson(),
      decode: ServerList.fromJson,
    );
    _invalidateSession();
    return list;
  }

  Future<AuthSnapshot> signInWithPassword(PasswordLogin login) =>
      _signIn(ConduitMethods.authLoginWithPassword, login.toJson());

  Future<AuthSnapshot> signInWithLdap(PasswordLogin login) =>
      _signIn(ConduitMethods.authLoginWithLdap, login.toJson());

  Future<AuthSnapshot> signInWithApiKey(ApiKeyLogin login) =>
      _signIn(ConduitMethods.authLoginWithApiKey, login.toJson());

  Future<AuthSnapshot> completeExternalSignIn(
    ExternalAuthCompletion completion,
  ) => _signIn(ConduitMethods.authCompleteExternal, completion.toJson());

  Future<AuthSnapshot> restoreSession() =>
      _signIn(ConduitMethods.authSilentLogin, null);

  Future<SignOutResult> signOut(SignOutRequest request) async {
    final result = await _client.call(
      ConduitMethods.authSignOut,
      params: request.toJson(),
      decode: SignOutResult.fromJson,
    );
    _invalidateSession();
    return result;
  }

  Future<AuthSnapshot> setReviewerMode({required bool enabled}) => _signIn(
    ConduitMethods.authSetReviewerMode,
    <String, dynamic>{'enabled': enabled},
  );

  Future<AuthSnapshot> _signIn(
    String method,
    Map<String, dynamic>? params,
  ) async {
    final snapshot = await _client.call(
      method,
      params: params,
      decode: AuthSnapshot.fromJson,
    );
    _invalidateSession();
    return snapshot;
  }

  /// Both, always. Signing in or out changes which server is active as often
  /// as it changes the session, and refreshing only one leaves the window
  /// showing a server list that contradicts its own sign-in state.
  void _invalidateSession() {
    _ref.invalidate(authStatusProvider);
    _ref.invalidate(serverListProvider);
  }
}
