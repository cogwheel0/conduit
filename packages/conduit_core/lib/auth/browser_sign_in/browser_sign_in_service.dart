import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';
import 'package:conduit_core/auth/jwt_claims.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/models/browser_sign_in_session.dart';
import 'package:conduit_core/models/oauth_login_probe.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/server_version_compat.dart';

/// The Open WebUI OAuth providers a browser sign-in works with: those whose
/// token exchange takes an access token issued to Conduit's own client.
/// GitHub and Feishu stay with the in-app sign-in.
const Set<String> browserSignInProviders = {'oidc', 'microsoft', 'google'};

/// The first Open WebUI release with token exchange.
const String browserSignInMinimumServerVersion = '0.8.0';

/// Which of [providers] can sign in through the system browser, in the order
/// the server lists them.
List<String> browserSignInEligibleProviders(OAuthProviders providers) => [
  for (final provider in providers.enabledProviders)
    if (browserSignInProviders.contains(provider)) provider,
];

/// Whether a server reporting [version] has token exchange. An unknown
/// version counts as one that has.
bool browserSignInServerSupported(String? version) =>
    ServerVersionCompat.isAtLeast(version, browserSignInMinimumServerVersion);

/// Whether a browser sign-in can be set up for a server: [port] has a system
/// browser, and [backendConfig], when known, is recent enough and has an
/// eligible provider ([browserSignInEligibleProviders]).
typedef BrowserSignInAvailability = ({
  bool browserSupported,
  bool serverSupported,
  List<String> providers,
});

BrowserSignInAvailability browserSignInAvailabilityFor({
  required BrowserAuthPort port,
  BackendConfig? backendConfig,
}) => (
  browserSupported: port.isSupported,
  serverSupported: browserSignInServerSupported(backendConfig?.version),
  providers: backendConfig == null
      ? const <String>[]
      : browserSignInEligibleProviders(backendConfig.oauthProviders),
);

/// Whether an Open WebUI session [token] should be renewed before it is
/// used again: it expires within ten minutes, or within the last tenth of
/// its lifetime. A token that does not say when it expires is left alone.
bool browserSessionNeedsRenewal(String token, {DateTime? now}) {
  final claims = jwtClaims(token);
  final exp = claims?['exp'];
  if (exp is! num) return false;
  final current = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
  final remaining = exp - current;
  if (remaining <= 600) return true;
  final iat = claims?['iat'];
  if (iat is num && exp > iat) return remaining <= (exp - iat) / 10;
  return false;
}

/// Whether an Open WebUI session [token] has expired. One that does not say
/// when it expires has not.
bool browserSessionExpired(String token, {DateTime? now}) {
  final exp = jwtClaims(token)?['exp'];
  if (exp is! num) return false;
  return exp <= (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
}

/// Whether [a] and [b] are the same browser sign-in settings, the issuer
/// compared as [normalizeBrowserSignInIssuer] puts it.
bool browserSignInConfigsMatch(BrowserSignInConfig a, BrowserSignInConfig? b) {
  if (b == null || a.provider != b.provider || a.clientId != b.clientId) {
    return false;
  }
  final issuerA = a.issuer;
  final issuerB = b.issuer;
  if (issuerA == null || issuerB == null) return issuerA == issuerB;
  return normalizeBrowserSignInIssuer(issuerA) ==
      normalizeBrowserSignInIssuer(issuerB);
}

/// What a browser sign-in got from the identity provider, for Open WebUI's
/// token exchange: the access token, held in memory only, and what the
/// account keeps to renew the sign-in later.
@immutable
final class BrowserSignInGrant {
  const BrowserSignInGrant({
    required this.serverId,
    required this.provider,
    required this.clientId,
    required this.issuer,
    required this.tokenEndpoint,
    this.revocationEndpoint,
    required this.accessToken,
    this.refreshToken,
    this.scope = '',
  });

  /// The registry server of the account signing in.
  final String serverId;
  final String provider;
  final String clientId;
  final String issuer;
  final Uri tokenEndpoint;
  final Uri? revocationEndpoint;

  /// For Open WebUI's token exchange, and nothing else. Never stored.
  final String accessToken;

  /// Null when the identity provider issued none: the sign-in then cannot
  /// be renewed, and is saved as a plain SSO sign-in.
  final String? refreshToken;
  final String scope;

  /// What the account keeps once Open WebUI signed it in as [owuiUserId];
  /// null without a refresh token.
  BrowserSignInSession? session({required String owuiUserId}) {
    final refresh = refreshToken;
    if (refresh == null || refresh.isEmpty) return null;
    return BrowserSignInSession(
      serverId: serverId,
      provider: provider,
      clientId: clientId,
      issuer: issuer,
      tokenEndpoint: tokenEndpoint.toString(),
      revocationEndpoint: revocationEndpoint?.toString(),
      refreshToken: refresh,
      scope: scope,
      owuiUserId: owuiUserId,
    );
  }

  @override
  String toString() => 'BrowserSignInGrant($provider, <redacted>)';
}

/// Open WebUI's answer to a token exchange that did not fail: a session, or
/// a second step to take before one (Open WebUI 0.12 two-step verification).
sealed class BrowserSignInAnswer {
  const BrowserSignInAnswer();
}

final class BrowserSignInSessionToken extends BrowserSignInAnswer {
  const BrowserSignInSessionToken(this.token);

  final String token;

  @override
  String toString() => 'BrowserSignInSessionToken(<redacted>)';
}

final class BrowserSignInSecondStep extends BrowserSignInAnswer {
  const BrowserSignInSecondStep(this.challenge);

  final OpenWebUiTwoStepChallenge challenge;

  @override
  String toString() => 'BrowserSignInSecondStep(${challenge.kind.name})';
}

/// A renewed Open WebUI session, and the account's session it was renewed
/// with, its refresh token already saved if the provider rotated it.
typedef BrowserSignInRenewal = ({String token, BrowserSignInSession session});

/// What the Test button found out about a server's browser sign-in settings.
@immutable
final class BrowserSignInDiagnosis {
  const BrowserSignInDiagnosis({
    this.issuer,
    this.discoveryFailure,
    this.exchangeFailure,
  });

  /// The identity provider found, when one was.
  final String? issuer;

  /// Why the identity provider was not found; null when it was.
  final BrowserSignInFailure? discoveryFailure;

  /// Why Open WebUI's token exchange would refuse a sign-in; null when it is
  /// on and checks tokens with the provider.
  /// [BrowserSignInFailure.cannotDetermineClient] means it only trusts listed
  /// clients, and cannot tell this provider's tokens apart.
  final BrowserSignInFailure? exchangeFailure;

  bool get ready => discoveryFailure == null && exchangeFailure == null;

  @override
  String toString() =>
      'BrowserSignInDiagnosis(discovery: ${discoveryFailure?.name ?? 'ok'}, '
      'exchange: ${exchangeFailure?.name ?? 'ok'})';
}

/// Builds the client for one sign-in's requests to its identity provider;
/// [route] is the Open WebUI address in use, whose TLS settings an identity
/// provider on exactly its origin shares.
typedef OidcHttpFactory = OidcHttp Function(ServerConfig? route);

/// Signs in through the system browser: Conduit's own authorization-code
/// sign-in with PKCE at the identity provider Open WebUI uses, whose access
/// token Open WebUI's token exchange (0.8 and later) trades for a session.
/// The refresh token it comes with renews that session later, without the
/// browser.
///
/// Holds no auth state: the auth state manager decides which account signs
/// in, and commits what this returns.
class BrowserSignInService {
  BrowserSignInService({
    required BrowserAuthPort port,
    OidcHttpFactory? http,
    Random? random,
    this.revocationTimeout = const Duration(seconds: 4),
  }) : _port = port,
       _http = http ?? ((route) => OidcHttp(route: route)),
       _random = random;

  final BrowserAuthPort _port;
  final OidcHttpFactory _http;
  final Random? _random;
  final Duration revocationTimeout;

  /// Renewals in flight, by account: a second caller joins the first rather
  /// than spending the refresh token again.
  final Map<String, Future<BrowserSignInRenewal>> _renewals = {};

  bool get isSupported => _port.isSupported;

  /// Steps 1 to 5 of a sign-in, through [api], the account's client on the
  /// address in use: asks Open WebUI where [config]'s provider signs in,
  /// finds that identity provider, signs in to it in the browser, and
  /// redeems the code.
  ///
  /// [prompt] and [loginHint] go to the identity provider as given.
  ///
  /// Returns null when the user closed the browser. Throws
  /// [BrowserSignInException] for anything else that stops it.
  Future<BrowserSignInGrant?> authorize({
    required ApiService api,
    required BrowserSignInConfig config,
    required String serverId,
    String? prompt,
    String? loginHint,
  }) async {
    if (!_port.isSupported) {
      throw const BrowserSignInException(
        BrowserSignInFailure.browserUnavailable,
      );
    }
    final redirectUri = oidcRedirectUriFor(
      provider: config.provider,
      clientId: config.clientId,
    );
    if (redirectUri == null) {
      throw const BrowserSignInException(BrowserSignInFailure.invalidClientId);
    }

    final probe = await _probe(api, config.provider);
    final http = _http(api.serverConfig);
    try {
      final metadata = await _discover(http, config, probe);
      final request = OidcAuthorizationRequest.create(
        metadata: metadata,
        provider: config.provider,
        clientId: config.clientId,
        redirectUri: redirectUri,
        audience: probe.audience,
        prompt: prompt,
        loginHint: loginHint,
        random: _random,
      );
      final result = await _port.authorize(
        request.url,
        redirectUri: redirectUri,
      );
      final failure = browserSignInFailureForResult(result);
      if (failure == BrowserSignInFailure.cancelled) {
        DebugLogger.auth('browser-sign-in-cancelled');
        return null;
      }
      if (failure != null) {
        DebugLogger.warning(
          'browser-sign-in-browser-failed',
          scope: 'auth/browser-sign-in',
          data: {'failure': failure.name, 'channel': result.channel},
        );
        throw BrowserSignInException(failure);
      }
      final code = request.codeFromCallback(result.callbackUri!);
      final tokens = await OidcTokenClient(http).exchangeCode(request, code);
      return BrowserSignInGrant(
        serverId: serverId,
        provider: config.provider,
        clientId: config.clientId,
        issuer: metadata.issuer,
        tokenEndpoint: metadata.tokenEndpoint,
        revocationEndpoint: metadata.revocationEndpoint,
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        scope: tokens.scope ?? request.scope,
      );
    } on OidcException catch (error) {
      throw _oidcFailure(error, step: 'authorize');
    } finally {
      http.close();
    }
  }

  /// Step 7: trades [accessToken] for an Open WebUI session at [api], the
  /// account's client on the address in use now.
  ///
  /// Throws [BrowserSignInException]: for a refusal, by its reason, and
  /// [BrowserSignInFailure.accountPendingApproval] for an account awaiting
  /// approval.
  Future<BrowserSignInAnswer> exchange({
    required ApiService api,
    required String provider,
    required String accessToken,
    bool renewal = false,
  }) async {
    final Map<String, dynamic> answer;
    try {
      answer = await api.exchangeOAuthToken(provider, accessToken);
    } on DioException catch (error) {
      final failure = browserSignInFailureForExchange(error, renewal: renewal);
      DebugLogger.warning(
        'browser-sign-in-exchange-refused',
        scope: 'auth/browser-sign-in',
        data: {'status': error.response?.statusCode, 'failure': failure.name},
      );
      throw BrowserSignInException(failure);
    } on FormatException {
      throw const BrowserSignInException(BrowserSignInFailure.failed);
    }

    final token = answer['token'];
    if (token is String && token.isNotEmpty) {
      return BrowserSignInSessionToken(token);
    }
    if (answer['next_step'] == 'pending') {
      throw const BrowserSignInException(
        BrowserSignInFailure.accountPendingApproval,
      );
    }
    final challenge = OpenWebUiTwoStepChallenge.fromJson(answer);
    if (challenge != null) return BrowserSignInSecondStep(challenge);
    throw const BrowserSignInException(BrowserSignInFailure.failed);
  }

  /// Renews [accountId]'s Open WebUI session with its saved refresh token,
  /// through [api], a client for the account's server: refreshes at the
  /// identity provider, saves a rotated refresh token before using it, and
  /// trades the new access token at Open WebUI.
  ///
  /// One renewal per account at a time; a caller while one runs gets its
  /// result.
  ///
  /// Throws [BrowserSignInException]: [BrowserSignInFailure.refreshExpired]
  /// when the account has no session to renew with,
  /// [BrowserSignInFailure.configMismatch] when the server's settings
  /// changed since it signed in, [BrowserSignInFailure.accountChanged] when
  /// something replaced or ended the session meanwhile, and
  /// [BrowserSignInFailure.twoStepRequired] when Open WebUI asks for a code.
  Future<BrowserSignInRenewal> renew({
    required String accountId,
    required ApiService api,
    required OptimizedStorageService storage,
  }) {
    final running = _renewals[accountId];
    if (running != null) return running;
    final renewal = _renew(accountId: accountId, api: api, storage: storage);
    _renewals[accountId] = renewal;
    return renewal.whenComplete(() {
      if (identical(_renewals[accountId], renewal)) {
        _renewals.remove(accountId);
      }
    });
  }

  /// Completes once no renewal of [accountId] is running: one that is has
  /// spent its refresh token, and saves the rotated one before it ends.
  Future<void> renewalSettled(String accountId) async {
    final running = _renewals[accountId];
    if (running == null) return;
    try {
      await running;
    } catch (_) {
      // Its caller handles how it ended.
    }
  }

  Future<BrowserSignInRenewal> _renew({
    required String accountId,
    required ApiService api,
    required OptimizedStorageService storage,
  }) async {
    final session = await storage.browserSignInSessionFor(accountId);
    if (session == null) {
      throw const BrowserSignInException(BrowserSignInFailure.refreshExpired);
    }
    final registry = await storage.getOpenWebUiRegistryStrict();
    final account = registry.account(accountId);
    final config = account == null
        ? null
        : registry.server(account.serverId)?.browserSignIn;
    if (account == null ||
        !session.matches(serverId: account.serverId, config: config)) {
      throw const BrowserSignInException(BrowserSignInFailure.configMismatch);
    }

    final tokenEndpoint = Uri.tryParse(session.tokenEndpoint);
    if (tokenEndpoint == null) {
      throw const BrowserSignInException(BrowserSignInFailure.configMismatch);
    }
    final http = _http(api.serverConfig);
    final OidcTokenSet tokens;
    try {
      tokens = await OidcTokenClient(http).refresh(
        tokenEndpoint: tokenEndpoint,
        clientId: session.clientId,
        refreshToken: session.refreshToken,
        scope: session.scope,
      );
    } on OidcException catch (error) {
      throw _oidcFailure(error, step: 'refresh', renewal: true);
    } finally {
      http.close();
    }

    // Saved before it is used: a rotating provider has already spent the old
    // one, and a renewal lost after this point must not strand the account.
    var current = session;
    final rotated = session.copyWith(
      refreshToken: tokens.refreshToken,
      scope: tokens.scope,
    );
    if (rotated != session) {
      if (!await storage.replaceBrowserSignInSessionIfCurrent(
        accountId,
        expected: session,
        next: rotated,
      )) {
        throw const BrowserSignInException(BrowserSignInFailure.accountChanged);
      }
      current = rotated;
    }

    final answer = await exchange(
      api: api,
      provider: session.provider,
      accessToken: tokens.accessToken,
      renewal: true,
    );
    return switch (answer) {
      BrowserSignInSessionToken(:final token) => (
        token: token,
        session: current,
      ),
      BrowserSignInSecondStep() => throw const BrowserSignInException(
        BrowserSignInFailure.twoStepRequired,
      ),
    };
  }

  /// Checks [config] against the server [api] reaches, for the Test button:
  /// whether its identity provider is found, and whether Open WebUI's token
  /// exchange is on for it. Opens no browser, and signs nobody in.
  Future<BrowserSignInDiagnosis> diagnose({
    required ApiService api,
    required BrowserSignInConfig config,
  }) async {
    String? issuer;
    BrowserSignInFailure? discoveryFailure;
    if (oidcRedirectUriFor(
          provider: config.provider,
          clientId: config.clientId,
        ) ==
        null) {
      discoveryFailure = BrowserSignInFailure.invalidClientId;
    } else {
      try {
        final probe = await _probe(api, config.provider);
        final http = _http(api.serverConfig);
        try {
          issuer = (await _discover(http, config, probe)).issuer;
        } on OidcException catch (error) {
          discoveryFailure = browserSignInFailureForOidc(error);
        } finally {
          http.close();
        }
      } on BrowserSignInException catch (error) {
        discoveryFailure = error.failure;
      }
    }

    // A token no provider issued: an exchange that is on refuses it once the
    // provider has, while one that is off, or only trusts listed clients,
    // refuses it before asking.
    BrowserSignInFailure? exchangeFailure;
    try {
      await api.exchangeOAuthToken(
        config.provider,
        'conduit-browser-sign-in-check',
      );
    } on DioException catch (error) {
      final failure = browserSignInFailureForExchange(error);
      exchangeFailure = failure == BrowserSignInFailure.tokenRejectedByServer
          ? null
          : failure;
    } on FormatException {
      exchangeFailure = BrowserSignInFailure.failed;
    }

    final diagnosis = BrowserSignInDiagnosis(
      issuer: issuer,
      discoveryFailure: discoveryFailure,
      exchangeFailure: exchangeFailure,
    );
    DebugLogger.info(
      'browser-sign-in-diagnosed',
      scope: 'auth/browser-sign-in',
      data: {
        'discovery': discoveryFailure?.name ?? 'ok',
        'exchange': exchangeFailure?.name ?? 'ok',
      },
    );
    return diagnosis;
  }

  /// Asks the identity provider to revoke [session]'s refresh token, when it
  /// has a revocation endpoint. Best effort, within [revocationTimeout]:
  /// never throws. [route] is the address the account was reached through.
  Future<void> revokeBestEffort(
    BrowserSignInSession session, {
    ServerConfig? route,
  }) async {
    final endpoint = switch (session.revocationEndpoint) {
      final String value => Uri.tryParse(value),
      null => null,
    };
    if (endpoint == null) return;
    OidcHttp? http;
    try {
      http = _http(route);
      final revoked = await OidcTokenClient(http)
          .revoke(
            revocationEndpoint: endpoint,
            clientId: session.clientId,
            token: session.refreshToken,
            timeout: revocationTimeout,
          )
          .timeout(revocationTimeout, onTimeout: () => false);
      DebugLogger.auth(
        revoked ? 'browser-session-revoked' : 'browser-session-revoke-failed',
      );
    } catch (_) {
      DebugLogger.auth('browser-session-revoke-failed');
    } finally {
      http?.close();
    }
  }

  Future<OAuthLoginProbe> _probe(ApiService api, String provider) async {
    try {
      return await api.probeOAuthLogin(provider);
    } catch (error) {
      final failure = browserSignInFailureForProbe(error);
      DebugLogger.warning(
        'browser-sign-in-probe-failed',
        scope: 'auth/browser-sign-in',
        data: {'failure': failure.name},
      );
      throw BrowserSignInException(failure);
    }
  }

  Future<OidcProviderMetadata> _discover(
    OidcHttp http,
    BrowserSignInConfig config,
    OAuthLoginProbe probe,
  ) => OidcDiscoveryClient(http).discover(
    provider: config.provider,
    authorizationEndpoint: probe.authorizationEndpoint,
    clientId: config.clientId,
    issuer: config.issuer,
  );

  BrowserSignInException _oidcFailure(
    OidcException error, {
    required String step,
    bool renewal = false,
  }) {
    final failure = browserSignInFailureForOidc(error, renewal: renewal);
    DebugLogger.warning(
      'browser-sign-in-idp-failed',
      scope: 'auth/browser-sign-in',
      data: {
        'step': step,
        'failure': failure.name,
        'kind': error.kind.name,
        'error': ?error.errorCode,
        'status': ?error.statusCode,
      },
    );
    return BrowserSignInException(failure);
  }
}

/// The browser sign-in service, kept for the app's lifetime so renewals of
/// one account coalesce.
final browserSignInServiceProvider = Provider<BrowserSignInService>(
  (ref) => BrowserSignInService(port: ref.watch(browserAuthPortProvider)),
);
