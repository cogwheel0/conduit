import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';

/// The mirror repository the Hermes `conduit` plugin is installed from.
const String kConduitHermesPluginRepo = 'cogwheel0/conduit-hermes-push';

/// The mirror commit Conduit installs: the full 40-character hex SHA of a
/// commit in [kConduitHermesPluginRepo].
///
/// MAINTAINERS: this is empty only because the mirror has not been
/// published yet. Set it to the mirror's commit SHA after the first publish
/// (and bump it with every plugin release). While it is empty, or anything
/// but 40 hex characters, Conduit never installs the plugin in one tap: an
/// unpinned dashboard install would run whatever the mirror's default branch
/// holds on the user's server. The copyable command is offered instead, and
/// says that it installs the latest published version.
const String kConduitHermesPluginRef = '';

/// Whether [ref] pins one mirror commit: exactly 40 lowercase hex
/// characters.
bool hermesPluginRefIsPinned(String ref) =>
    RegExp(r'^[0-9a-f]{40}$').hasMatch(ref);

/// Whether this build pins the plugin it installs ([kConduitHermesPluginRef]).
/// Without a pin there is no one-tap install.
final bool kConduitHermesPluginPinned = hermesPluginRefIsPinned(
  kConduitHermesPluginRef,
);

/// The plugin's name in the Hermes plugin hub.
const String kConduitHermesPluginName = 'conduit';

/// How long a Hermes reply stays watched after Conduit starts it (the
/// plugin's maximum).
const int kConduitHermesWatchTtlSeconds = 21600;

/// Whether [profile] names the default Hermes profile (`~/.hermes`).
bool isDefaultHermesProfile(String? profile) =>
    profile == null || profile.isEmpty || profile == 'default';

/// The command that installs and enables the plugin for [profile] (null or
/// `default` for the default profile), then restarts the gateway, or null
/// when [profile] is not a Hermes profile name (lowercase letters, digits,
/// `-` and `_`, starting with a letter or digit, at most 64 characters).
///
/// The profile is shell-quoted. The commit is pinned with `--ref` only when
/// [ref] is a full SHA; otherwise the command installs the latest published
/// version.
String? hermesPluginInstallCommand({
  String? profile,
  String ref = kConduitHermesPluginRef,
}) {
  final String flag;
  if (isDefaultHermesProfile(profile)) {
    flag = '';
  } else if (HermesConfig.isValidDesktopProfile(profile!)) {
    flag = " -p '$profile'";
  } else {
    return null;
  }
  final pin = hermesPluginRefIsPinned(ref) ? ' --ref $ref' : '';
  return 'hermes$flag plugins install $kConduitHermesPluginRepo$pin --enable'
      ' && hermes$flag gateway restart';
}

/// The profile in a `/p/<profile>` API server root, or null.
@visibleForTesting
String? hermesApiProfile(String root) {
  final match = RegExp(r'/p/([a-z0-9][a-z0-9_-]{0,63})/*$')
      .firstMatch(Uri.tryParse(root)?.path ?? '');
  return match?.group(1);
}

/// A push endpoint's HTTP status as the delivery categories Open WebUI's
/// function records, so both servers read the same in the UI.
@visibleForTesting
String? pushStatusCategory(int status) {
  if (status >= 200 && status < 300) return null;
  if (status <= 0) return 'network';
  if (status == 404 || status == 410) return 'gone';
  if (status == 413) return 'too_large';
  if (status == 429) return 'rate_limited';
  if (status >= 500) return 'server_error';
  return 'rejected';
}

/// The `deliver` value of a Hermes cron job with Conduit pushes on or off.
///
/// `deliver` is a comma-separated list of targets; empty means `local`.
/// Turning pushes on appends `conduit`, turning them off removes it.
String hermesDeliverWithConduit(String? deliver, {required bool notify}) {
  final targets = [
    for (final part in (deliver ?? '').split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];
  if (targets.isEmpty) targets.add('local');
  targets.removeWhere((target) => target == kConduitHermesPluginName);
  if (notify) {
    targets.add(kConduitHermesPluginName);
  } else if (targets.isEmpty) {
    targets.add('local');
  }
  return targets.join(',');
}

/// Whether a cron job's [deliver] includes Conduit pushes.
bool hermesDeliverIncludesConduit(String? deliver) => (deliver ?? '')
    .split(',')
    .any((part) => part.trim() == kConduitHermesPluginName);

/// What the Hermes dashboard REST surface needs to look like for push setup.
abstract interface class HermesDashboardClient {
  Future<HermesDashboardResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  });

  /// Whether the gateway behind the dashboard is running.
  Future<bool> gatewayRunning();
  void close();
}

/// [HermesDashboardClient] over a [HermesDesktopApiService].
final class HermesDesktopDashboardClient implements HermesDashboardClient {
  HermesDesktopDashboardClient(this._service);

  final HermesDesktopApiService _service;

  @override
  Future<HermesDashboardResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) => _service.dashboardRequest(method, path, body: body, query: query);

  @override
  Future<bool> gatewayRunning() async {
    final status = await _service.statusProbe(refresh: true);
    return status['gateway_running'] == true;
  }

  @override
  void close() => _service.close();
}

/// Push through the Hermes `conduit` plugin.
sealed class HermesPushBackend implements PushBackend {
  /// The `hermes plugins install` command for this connection, or null
  /// when its profile is not one a command can name.
  String? get installCommand;

  /// One op; throws [PushBackendException] for an op error.
  Future<Map<String, Object?>> _op(Map<String, Object?> request);

  Future<PushTestDispatch?> _subscribe(
    PushServerSubscription subscription,
    String? testNonce,
  ) async {
    await _op({'op': 'subscribe', 'sub': subscription.toJson()});
    if (testNonce == null) return null;
    final result = await _op({
      'op': 'test',
      'sid': subscription.sid,
      'nonce': testNonce,
    });
    final status = result['push_status'];
    final code = status is num ? status.toInt() : 0;
    return PushTestDispatch(
      diagnostics: PushServerDiagnostics(
        code: code,
        at: DateTime.now(),
        error: pushStatusCategory(code),
        nonce: testNonce,
      ),
    );
  }

  @override
  Future<PushTestDispatch?> subscribe(
    PushServerSubscription subscription, {
    String? testNonce,
  }) => _subscribe(subscription, testNonce);

  @override
  Future<void> unsubscribe(String sid) async {
    await _op({'op': 'unsubscribe', 'sid': sid});
  }

  /// Subscribes again first: the plugin forgets a device whose endpoint
  /// reported it gone, and subscribing is idempotent.
  @override
  Future<PushTestDispatch> requestTest(
    PushServerSubscription subscription,
    String nonce,
  ) async => (await _subscribe(subscription, nonce))!;

  /// Hermes records nothing per device; a test answers synchronously.
  @override
  Future<PushServerDiagnostics?> diagnose(String sid) async => null;

  /// Marks [sessionId] as Conduit's, so the plugin pushes its reply even
  /// though the session runs on the API server.
  Future<void> watch(
    String sessionId, {
    int ttl = kConduitHermesWatchTtlSeconds,
  }) async {
    await _op({'op': 'watch', 'session_id': sessionId, 'ttl': ttl});
  }

  /// The sids subscribed on this profile.
  Future<List<String>> listSids() async {
    final sids = (await _op({'op': 'list'}))['sids'];
    return sids is List ? sids.whereType<String>().toList() : const [];
  }

  static Map<String, Object?> _json(String body) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
    } on FormatException {
      return const {};
    }
  }

  static Map<String, Object?> _opResult(Map<String, Object?> json) {
    if (json['ok'] == true) return json;
    final error = json['error'];
    throw PushBackendException(
      PushFailure(
        PushFailureReason.serverRejected,
        detail: error is String ? error : 'invalid_response',
      ),
    );
  }
}

/// The plugin through the gateway API server (`responsesApi` connections):
/// `POST <root>/api/platforms/conduit/events` with the API server key.
final class HermesApiPushBackend extends HermesPushBackend {
  HermesApiPushBackend({required String root, required Dio dio})
    : _root = root.endsWith('/') ? root.substring(0, root.length - 1) : root,
      _dio = dio {
    _dio.options
      ..followRedirects = false
      ..responseType = ResponseType.plain
      ..validateStatus = ((_) => true);
  }

  final String _root;
  final Dio _dio;

  /// The request root: the configured URL without a trailing `/v1`, which
  /// keeps a `/p/<profile>` prefix.
  static String rootOf(String baseUrl) {
    var root = baseUrl.trim();
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    if (root.endsWith('/v1')) root = root.substring(0, root.length - 3);
    return root;
  }

  @override
  String? get installCommand =>
      hermesPluginInstallCommand(profile: hermesApiProfile(_root));

  Future<(int, Map<String, Object?>)> _post(Map<String, Object?> body) async {
    try {
      final response = await _dio.post<String>(
        '$_root/api/platforms/conduit/events',
        data: jsonEncode(body),
        options: Options(contentType: Headers.jsonContentType),
      );
      return (
        response.statusCode ?? 0,
        HermesPushBackend._json(response.data ?? ''),
      );
    } on DioException {
      throw const PushBackendException(
        PushFailure(PushFailureReason.serverUnreachable),
      );
    }
  }

  @override
  Future<Map<String, Object?>> _op(Map<String, Object?> request) async {
    final (status, json) = await _post(request);
    if (status == 200) return HermesPushBackend._opResult(json);
    throw PushBackendException(_failureFor(status, json));
  }

  static String? _errorCode(Map<String, Object?> json) {
    final error = json['error'];
    if (error is Map && error['code'] is String) return error['code'] as String;
    if (error is String) return error;
    return null;
  }

  static PushFailure _failureFor(int status, Map<String, Object?> json) {
    final code = _errorCode(json);
    if (status == 401 || status == 403) {
      return PushFailure(
        PushFailureReason.hermesAuthFailed,
        detail: code ?? '$status',
      );
    }
    return PushFailure(
      PushFailureReason.serverRejected,
      detail: code ?? '$status',
    );
  }

  @override
  Future<PushProbe> probe() async {
    final int status;
    final Map<String, Object?> json;
    try {
      (status, json) = await _post({'op': 'hello'});
    } on PushBackendException catch (error) {
      return PushProbe(PushProbeOutcome.failed, failure: error.failure);
    }
    final code = _errorCode(json);
    if (status == 200 && json['ok'] == true) {
      return PushProbe.ready(pluginVersion: json['version']?.toString());
    }
    if (status == 503) {
      // platform_unavailable: the plugin is missing, not enabled, or the
      // gateway has not restarted since it was enabled.
      return PushProbe(
        PushProbeOutcome.needsHermesPlugin,
        hermesInstallCommand: installCommand,
      );
    }
    if (status == 404 && code == null) {
      // No platform event route at all: Hermes predates it.
      return const PushProbe(PushProbeOutcome.serverTooOld);
    }
    return PushProbe(
      PushProbeOutcome.failed,
      failure: _failureFor(status, json),
    );
  }

  @override
  Future<void> install() => Future.error(
    const PushBackendException(
      PushFailure(PushFailureReason.installFailed, detail: 'use_command'),
    ),
  );

  @override
  void close() => _dio.close();
}

/// The plugin through the Hermes dashboard (`desktopGateway` connections):
/// `/api/plugins/conduit/v1/…`, behind the dashboard's own sign-in.
///
/// Only the plugin's events route takes a `?profile=`; its hello route
/// answers for the dashboard's own process. The dashboard's plugin hub takes
/// one too. Its install and enable routes always act on the profile the
/// dashboard was started with, so a connection to another profile gets the
/// command (with `-p <profile>`) instead of a one-tap install.
final class HermesDashboardPushBackend extends HermesPushBackend {
  HermesDashboardPushBackend({
    required HermesDashboardClient client,
    required this.profile,
    String pluginRef = kConduitHermesPluginRef,
  }) : _client = client,
       _pluginRef = pluginRef;

  final HermesDashboardClient _client;

  /// The Hermes profile this connection uses.
  final String profile;

  /// The mirror commit a one-tap install pins ([kConduitHermesPluginRef]).
  final String _pluginRef;

  static const String _hello = '/api/plugins/conduit/v1/hello';
  static const String _events = '/api/plugins/conduit/v1/events';

  @override
  String? get installCommand =>
      hermesPluginInstallCommand(profile: profile, ref: _pluginRef);

  /// Whether [install] may run: the plugin commit is pinned, and the
  /// connection uses the dashboard's own (default) profile.
  bool get canInstallInOneTap =>
      hermesPluginRefIsPinned(_pluginRef) && isDefaultHermesProfile(profile);

  /// The hub's `?profile=` for this connection: none for the default
  /// profile, which is the dashboard's own.
  Map<String, dynamic>? get _hubQuery =>
      isDefaultHermesProfile(profile) ? null : {'profile': profile};

  Future<HermesDashboardResponse> _request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    try {
      return await _client.request(method, path, body: body, query: query);
    } on DioException {
      throw const PushBackendException(
        PushFailure(PushFailureReason.serverUnreachable),
      );
    } on StateError {
      // The dashboard client throws this when its sign-in is missing or
      // expired.
      throw const PushBackendException(
        PushFailure(PushFailureReason.hermesAuthFailed),
        signInNeeded: true,
      );
    }
  }

  @override
  Future<Map<String, Object?>> _op(Map<String, Object?> request) async {
    final response = await _request(
      'POST',
      _events,
      body: request,
      query: {'profile': profile},
    );
    if (response.status == 401 || response.status == 403) {
      throw const PushBackendException(
        PushFailure(PushFailureReason.hermesAuthFailed),
        signInNeeded: true,
      );
    }
    final json = HermesPushBackend._json(response.body);
    if (response.ok || json.containsKey('ok')) {
      return HermesPushBackend._opResult(json);
    }
    throw PushBackendException(
      PushFailure(
        PushFailureReason.serverRejected,
        detail: '${response.status}',
      ),
    );
  }

  /// The plugin's row in the dashboard's plugin hub, `{}` when it has none,
  /// or null when the dashboard has no plugin hub.
  Future<Map<String, Object?>?> _hubRow() async {
    final response = await _request(
      'GET',
      '/api/dashboard/plugins/hub',
      query: _hubQuery,
    );
    if (response.status == 404) return null;
    if (response.status == 401 || response.status == 403) {
      throw const PushBackendException(
        PushFailure(PushFailureReason.hermesAuthFailed),
        signInNeeded: true,
      );
    }
    if (!response.ok) {
      throw PushBackendException(
        PushFailure(
          PushFailureReason.serverRejected,
          detail: '${response.status}',
        ),
      );
    }
    final plugins = HermesPushBackend._json(response.body)['plugins'];
    if (plugins is List) {
      for (final row in plugins) {
        if (row is Map && row['name'] == kConduitHermesPluginName) {
          return Map<String, Object?>.from(row);
        }
      }
    }
    return const {};
  }

  @override
  Future<PushProbe> probe() async {
    try {
      final hello = await _request('GET', _hello);
      final json = HermesPushBackend._json(hello.body);
      if (hello.ok && json['ok'] == true) {
        return PushProbe.ready(pluginVersion: json['version']?.toString());
      }
      if (hello.status == 401 || hello.status == 403) {
        return const PushProbe(PushProbeOutcome.signInNeeded);
      }
      if (hello.status != 404) {
        return PushProbe(
          PushProbeOutcome.failed,
          failure: PushFailure(
            PushFailureReason.serverRejected,
            detail: '${hello.status}',
          ),
        );
      }
      final detail = json['detail'];
      final row = await _hubRow();
      if (row == null) {
        // A dashboard without a plugin hub predates dashboard plugins.
        return const PushProbe(PushProbeOutcome.serverTooOld);
      }
      final loaded =
          detail is String && detail.startsWith('No such API endpoint');
      if (loaded && row['runtime_status'] == 'enabled') {
        // Installed and enabled, but the dashboard mounts plugin routes only
        // when it starts.
        return PushProbe(
          PushProbeOutcome.restartHermes,
          hermesInstallCommand: installCommand,
          pluginVersion: row['version']?.toString(),
        );
      }
      return PushProbe(
        PushProbeOutcome.needsHermesPlugin,
        hermesInstallCommand: installCommand,
        canInstallHermesPlugin: canInstallInOneTap,
        pluginVersion: row['version']?.toString(),
      );
    } on PushBackendException catch (error) {
      if (error.signInNeeded) {
        return const PushProbe(PushProbeOutcome.signInNeeded);
      }
      return PushProbe(PushProbeOutcome.failed, failure: error.failure);
    }
  }

  /// Installs the pinned plugin and enables it, or enables an installed
  /// one, then restarts a running gateway. Never forces past Hermes' plugin
  /// scan: a "caution" verdict, a consent request, or any answer that does
  /// not say the plugin is in and enabled comes back as
  /// [PushFailureReason.installFailed] with Hermes' message.
  ///
  /// Refused without a pinned commit ([canInstallInOneTap]) or for another
  /// profile than the dashboard's own: those use the command.
  @override
  Future<void> install() async {
    if (!hermesPluginRefIsPinned(_pluginRef)) {
      throw const PushBackendException(
        PushFailure(PushFailureReason.installFailed, detail: 'unpinned'),
      );
    }
    if (!isDefaultHermesProfile(profile)) {
      throw const PushBackendException(
        PushFailure(PushFailureReason.installFailed, detail: 'use_command'),
      );
    }
    final row = await _hubRow();
    if (row == null) {
      throw const PushBackendException(
        PushFailure(PushFailureReason.installFailed, detail: 'no_plugin_hub'),
      );
    }
    if (row.isEmpty) {
      _checkInstalled(
        await _request(
          'POST',
          '/api/dashboard/agent-plugins/install',
          body: {
            'identifier': kConduitHermesPluginRepo,
            'ref': _pluginRef,
            'enable': true,
            'force': false,
          },
        ),
      );
    } else if (row['runtime_status'] != 'enabled') {
      _checkInstalled(
        await _request(
          'POST',
          '/api/dashboard/agent-plugins/$kConduitHermesPluginName/enable',
        ),
      );
    }
    bool running;
    try {
      running = await _client.gatewayRunning();
    } catch (_) {
      running = false;
    }
    if (running) {
      // Best effort: the dashboard itself still has to restart to mount the
      // plugin's routes, which the caller waits for.
      try {
        await _request(
          'POST',
          '/api/gateway/restart',
          query: {'profile': profile},
        );
      } on PushBackendException {
        // The user restarts Hermes instead.
      }
    }
  }

  /// Throws unless [response] says the plugin was installed (or enabled):
  /// a 2xx whose body has `"ok": true`, asks for no consent, and did not
  /// leave the plugin disabled.
  static void _checkInstalled(HermesDashboardResponse response) {
    final json = HermesPushBackend._json(response.body);
    final verdict = json['scan_verdict'];
    final succeeded =
        response.ok &&
        json['ok'] == true &&
        json['consent_required'] != true &&
        json['scan_blocked'] != true &&
        json['enabled'] != false;
    if (succeeded) return;
    final message = [json['detail'], json['error']]
        .whereType<String>()
        .firstWhere((text) => text.isNotEmpty, orElse: () => '');
    final String detail;
    if (message.isNotEmpty) {
      detail = message;
    } else if (verdict is String && verdict.isNotEmpty) {
      detail = 'scan_$verdict';
    } else if (json['consent_required'] == true) {
      detail = 'consent_required';
    } else if (json['enabled'] == false) {
      detail = 'not_enabled';
    } else {
      detail = response.ok ? 'invalid_response' : '${response.status}';
    }
    throw PushBackendException(
      PushFailure(PushFailureReason.installFailed, detail: detail),
      signInNeeded: response.status == 401 || response.status == 403,
    );
  }

  @override
  void close() => _client.close();
}
