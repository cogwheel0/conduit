import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../external_sign_in.dart';
import 'direct_providers.dart';
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

/// The live state of the active server: reachability, version, capabilities.
///
/// Separate from [serverListProvider], which is stored configuration. This
/// one costs a request to the server, so it is not folded into the list that
/// every settings repaint reads.
final serverStatusProvider = FutureProvider<ServerStatus>((ref) async {
  ref.watch(coreConnectionProvider);
  return ref
      .watch(rpcClientProvider)
      .call(ConduitMethods.serversStatus, decode: ServerStatus.fromJson);
});

/// What the UI is allowed to offer, from the active server.
///
/// Falls back to [Capabilities.none] while loading or on error, which is the
/// safe direction: a sidebar entry that dead-ends is worse than one that
/// appears a moment late.
final serverCapabilitiesProvider = Provider<Capabilities>(
  (ref) =>
      ref.watch(serverStatusProvider).value?.capabilities ?? Capabilities.none,
);

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
/// Whether the app is used with direct connections and no server (M4):
/// the welcome screen's "Connect directly", with a connection that works.
/// Such a window neither onboards nor signs in.
final directOnlyProvider = Provider<AsyncValue<bool>>((ref) {
  final servers = ref.watch(serverListProvider);
  final direct = ref.watch(directConnectionsProvider);
  if (servers.isLoading || direct.isLoading) {
    return const AsyncValue<bool>.loading();
  }
  final list = direct.value;
  return AsyncValue<bool>.data(
    servers.value?.activeServerId == null &&
        (list?.preferred ?? false) &&
        (list?.usable ?? false),
  );
});

final needsOnboardingProvider = Provider<AsyncValue<bool>>((ref) {
  final servers = ref.watch(serverListProvider);
  final auth = ref.watch(authStatusProvider);
  final directOnly = ref.watch(directOnlyProvider);
  if (servers.isLoading || auth.isLoading || directOnly.isLoading) {
    return const AsyncValue<bool>.loading();
  }
  // Set up with direct connections and no server: nothing to onboard.
  if (directOnly.value == true) return const AsyncValue<bool>.data(false);
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

  /// Runs an external sign-in end to end: open the window, hand what it
  /// captured to the daemon, let the daemon decide.
  ///
  /// Returns null when the user closed the window, which is a cancellation
  /// and not a failure -- nothing is sent, and the form stays as it was.
  Future<AuthSnapshot?> signInExternally({
    required String serverUrl,
    String? startUrl,
  }) async {
    final outcome = await _ref
        .read(externalSignInProvider)
        .run(
          // Open WebUI's own sign-in page is the default entry point: a
          // reverse proxy challenges on the way there, and a configured SSO
          // provider is linked from it. A caller with a provider-specific
          // authorize URL passes it instead.
          startUrl: startUrl ?? serverUrl,
          serverUrl: serverUrl,
        );

    return switch (outcome) {
      ExternalSignInAbandoned() => null,
      ExternalSignInCaptured(:final origin, :final cookies, :final token) =>
        completeExternalSignIn(
          ExternalAuthCompletion(
            origin: origin,
            cookies: cookies,
            token: token,
          ),
        ),
    };
  }

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
    // The status too: a different server has a different version and
    // different capabilities, and a stale capability set is how the sidebar
    // ends up offering a section the new server does not have.
    _ref.invalidate(serverStatusProvider);
  }
}
