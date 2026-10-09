import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';

/// The id Conduit installs the function under and looks for. Open WebUI
/// lowercases ids, and the function reads its own id from the module name.
const String kConduitPushFunctionId = 'conduit_push';
const String kConduitPushFunctionName = 'Conduit Push';

/// The oldest Open WebUI the function runs on (its `Event` functions and
/// `function.valves_updated`).
const String kConduitPushMinOpenWebUiVersion = '0.10.0';

/// The function bundled with the app (`assets/server_plugins/…`).
final class OpenWebUiFunctionSource {
  const OpenWebUiFunctionSource({
    required this.content,
    required this.version,
    required this.description,
  });

  final String content;

  /// The frontmatter `version:`.
  final String version;
  final String description;

  /// Reads the frontmatter of a function file. Null when it has none or no
  /// version.
  static OpenWebUiFunctionSource? parse(String content) {
    final start = content.indexOf('"""');
    if (start < 0) return null;
    final end = content.indexOf('"""', start + 3);
    if (end < 0) return null;
    final fields = <String, String>{};
    for (final line in content.substring(start + 3, end).split('\n')) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      fields[line.substring(0, colon).trim()] = line
          .substring(colon + 1)
          .trim();
    }
    final version = fields['version'];
    if (version == null || version.isEmpty) return null;
    return OpenWebUiFunctionSource(
      content: content,
      version: version,
      description: fields['description'] ?? '',
    );
  }
}

/// Loads the bundled function, or answers null when this host has none.
typedef OpenWebUiFunctionSourceLoader =
    Future<OpenWebUiFunctionSource?> Function();

/// Compares dotted versions such as `0.11.4`, `v1.0.0` or `0.6.5-dev.1`.
/// Pre-release and build suffixes are ignored. Negative when [a] is older.
int comparePushVersions(String a, String b) {
  List<int> parts(String value) {
    var text = value.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
    final cut = text.indexOf(RegExp(r'[-+\s]'));
    if (cut >= 0) text = text.substring(0, cut);
    return [for (final part in text.split('.')) int.tryParse(part) ?? 0];
  }

  final left = parts(a);
  final right = parts(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Puts [entry] into [existing]: drops entries with its `sid` or `did` and
/// appends it. Every other device's entry is kept untouched, including
/// fields this app does not know.
@visibleForTesting
List<Object?> mergeOpenWebUiSubscriptions(
  List<Object?> existing,
  Map<String, Object?> entry,
) {
  final sid = entry['sid'];
  final did = entry['did'];
  return [
    for (final item in existing)
      if (!(item is Map && (item['sid'] == sid || item['did'] == did))) item,
    entry,
  ];
}

/// [existing] without the entry for [sid].
@visibleForTesting
List<Object?> removeOpenWebUiSubscription(List<Object?> existing, String sid) =>
    [
      for (final item in existing)
        if (!(item is Map && item['sid'] == sid)) item,
    ];

/// The `subscriptions` user valve as a list, or empty when it is unset or
/// unreadable.
List<Object?> openWebUiSubscriptionList(Map<String, dynamic>? valves) {
  final raw = valves?['subscriptions'];
  if (raw is List) return List<Object?>.of(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return List<Object?>.of(decoded);
    } on FormatException {
      return const [];
    }
  }
  return const [];
}

Map<String, Object?> _statusMap(Map<String, dynamic>? valves) {
  final raw = valves?['status'];
  if (raw is Map) return Map<String, Object?>.from(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      return const {};
    }
  }
  return const {};
}

/// Push through the Open WebUI "Conduit Push" Event function.
///
/// [dio] is an Open WebUI client for one account: its base URL and bearer
/// token. Requests ask the auth interceptor not to raise an app-wide auth
/// failure, because a push check must never sign the user out of the
/// account in use.
final class OpenWebUiPushBackend implements PushBackend {
  OpenWebUiPushBackend({
    required Dio dio,
    required OpenWebUiFunctionSourceLoader bundledFunction,
    void Function()? onClose,
    DateTime Function()? clock,
  }) : _dio = dio,
       _bundledFunction = bundledFunction,
       _onClose = onClose,
       _clock = clock ?? DateTime.now;

  final Dio _dio;
  final OpenWebUiFunctionSourceLoader _bundledFunction;
  final void Function()? _onClose;
  final DateTime Function() _clock;
  OpenWebUiFunctionSource? _bundled;
  bool _bundledLoaded = false;
  bool? _admin;

  static const String _functions = '/api/v1/functions';
  static const String _function = '$_functions/id/$kConduitPushFunctionId';

  Options get _options =>
      Options(extra: const {'suppressAuthFailureNotification': true});

  @override
  Future<PushProbe> probe() async {
    try {
      final config = _map(
        (await _dio.get('/api/config', options: _options)).data,
      );
      final version = config?['version']?.toString();
      if (version != null &&
          comparePushVersions(version, kConduitPushMinOpenWebUiVersion) < 0) {
        return PushProbe(PushProbeOutcome.serverTooOld, serverVersion: version);
      }
      final features = config?['features'];
      if (features is Map && features['enable_plugins'] == false) {
        return PushProbe(
          PushProbeOutcome.pluginsDisabled,
          serverVersion: version,
        );
      }
      final function = await _installedFunction();
      final bundled = await _loadBundled();
      final installedVersion = _manifestVersion(function);
      if (function == null || function['is_active'] != true) {
        final canInstall = bundled != null && await _isAdmin();
        return PushProbe(
          canInstall
              ? PushProbeOutcome.canInstall
              : PushProbeOutcome.needsAdminSetup,
          serverVersion: version,
          pluginVersion: installedVersion,
          bundledVersion: bundled?.version,
        );
      }
      final outdated =
          bundled != null &&
          (installedVersion == null ||
              comparePushVersions(installedVersion, bundled.version) < 0);
      return PushProbe.ready(
        updateAvailable: outdated && await _isAdmin(),
        serverVersion: version,
        pluginVersion: installedVersion,
        bundledVersion: bundled?.version,
      );
    } on DioException catch (error) {
      return _probeFailure(error);
    } on PushBackendException catch (error) {
      if (error.signInNeeded) {
        return const PushProbe(PushProbeOutcome.signInNeeded);
      }
      return PushProbe(PushProbeOutcome.failed, failure: error.failure);
    }
  }

  @override
  Future<void> install() async {
    final bundled = await _loadBundled();
    if (bundled == null) {
      throw const PushBackendException(
        PushFailure(
          PushFailureReason.installFailed,
          detail: 'bundled_function_unavailable',
        ),
      );
    }
    try {
      final existing = await _installedFunction();
      final form = {
        'id': kConduitPushFunctionId,
        'name': kConduitPushFunctionName,
        'content': bundled.content,
        'meta': {'description': bundled.description, 'manifest': {}},
      };
      bool active;
      if (existing == null) {
        final created = _map(
          (await _dio.post(
            '$_functions/create',
            data: form,
            options: _options,
          )).data,
        );
        active = created?['is_active'] == true;
      } else {
        final installed = _manifestVersion(existing);
        if (installed == null ||
            comparePushVersions(installed, bundled.version) < 0) {
          final updated = _map(
            (await _dio.post(
              '$_function/update',
              data: form,
              options: _options,
            )).data,
          );
          active = updated?['is_active'] == true;
        } else {
          active = existing['is_active'] == true;
        }
      }
      // Toggle flips the state, so it is only called while the function is
      // off, and checked afterwards.
      for (var attempt = 0; !active && attempt < 2; attempt++) {
        final toggled = _map(
          (await _dio.post('$_function/toggle', options: _options)).data,
        );
        active = toggled?['is_active'] == true;
      }
      if (!active) {
        throw const PushBackendException(
          PushFailure(
            PushFailureReason.installFailed,
            detail: 'function_inactive',
          ),
        );
      }
    } on DioException catch (error) {
      final failure = _backendError(error);
      throw PushBackendException(
        PushFailure(
          PushFailureReason.installFailed,
          detail: failure.failure.detail == 'not_admin'
              ? 'not_admin'
              : _detail(error) ?? failure.failure.detail,
        ),
        signInNeeded: failure.signInNeeded,
      );
    }
  }

  @override
  Future<PushTestDispatch?> subscribe(
    PushServerSubscription subscription, {
    String? testNonce,
  }) async {
    final now = _clock();
    final entry = <String, Object?>{
      ...subscription.toJson(),
      'origin': subscription.origin.name,
      'seen': now.millisecondsSinceEpoch ~/ 1000,
      if (testNonce != null)
        'test': {'nonce': testNonce, 'at': now.millisecondsSinceEpoch ~/ 1000},
    };
    await _guard(() async {
      for (var attempt = 0; attempt < 2; attempt++) {
        final current = openWebUiSubscriptionList(await _readValves());
        await _writeSubscriptions(mergeOpenWebUiSubscriptions(current, entry));
        // Read back: another device's write can land in between and drop
        // this one.
        final stored = openWebUiSubscriptionList(await _readValves());
        final kept = stored.any(
          (item) =>
              item is Map &&
              item['sid'] == subscription.sid &&
              item['endpoint'] == subscription.endpoint &&
              (testNonce == null ||
                  (item['test'] is Map && item['test']['nonce'] == testNonce)),
        );
        if (kept) return;
      }
      throw const PushBackendException(
        PushFailure(PushFailureReason.subscriptionLost),
      );
    });
    return testNonce == null ? null : const PushTestDispatch();
  }

  @override
  Future<void> unsubscribe(String sid) => _guard(() async {
    final current = openWebUiSubscriptionList(await _readValves());
    final remaining = removeOpenWebUiSubscription(current, sid);
    if (remaining.length == current.length) return;
    await _writeSubscriptions(remaining);
  });

  @override
  Future<PushTestDispatch> requestTest(
    PushServerSubscription subscription,
    String nonce,
  ) async =>
      await subscribe(subscription, testNonce: nonce) ??
      const PushTestDispatch();

  @override
  Future<PushServerDiagnostics?> diagnose(String sid) => _guard(
    () async => PushServerDiagnostics.fromStatusEntry(
      _statusMap(await _readValves())[sid],
    ),
  );

  @override
  void close() => _onClose?.call();

  Future<Map<String, dynamic>?> _readValves() async =>
      _map((await _dio.get('$_function/valves/user', options: _options)).data);

  /// Writes only `subscriptions`: the update replaces every user valve, and
  /// `status` belongs to the function.
  Future<void> _writeSubscriptions(List<Object?> subscriptions) => _dio.post(
    '$_function/valves/user/update',
    data: {'subscriptions': jsonEncode(subscriptions)},
    options: _options,
  );

  Future<Map<String, dynamic>?> _installedFunction() async {
    final data = (await _dio.get('$_functions/', options: _options)).data;
    if (data is! List) return null;
    for (final item in data) {
      if (item is Map && item['id'] == kConduitPushFunctionId) {
        return Map<String, dynamic>.from(item);
      }
    }
    return null;
  }

  Future<bool> _isAdmin() async {
    final known = _admin;
    if (known != null) return known;
    final user = _map(
      (await _dio.get('/api/v1/auths/', options: _options)).data,
    );
    return _admin = user?['role'] == 'admin';
  }

  Future<OpenWebUiFunctionSource?> _loadBundled() async {
    if (_bundledLoaded) return _bundled;
    try {
      _bundled = await _bundledFunction();
    } catch (_) {
      _bundled = null;
    }
    _bundledLoaded = true;
    return _bundled;
  }

  static String? _manifestVersion(Map<String, dynamic>? function) {
    final meta = function?['meta'];
    final manifest = meta is Map ? meta['manifest'] : null;
    final version = manifest is Map ? manifest['version'] : null;
    return version?.toString();
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DioException catch (error) {
      throw _backendError(error);
    }
  }

  static PushBackendException _backendError(DioException error) {
    if (_isAuthError(error)) {
      return const PushBackendException(
        PushFailure(PushFailureReason.serverRejected, detail: '401'),
        signInNeeded: true,
      );
    }
    final status = error.response?.statusCode;
    if (status == null) {
      return const PushBackendException(
        PushFailure(PushFailureReason.serverUnreachable),
      );
    }
    final detail = _detail(error);
    return PushBackendException(
      PushFailure(
        PushFailureReason.serverRejected,
        detail: switch (detail) {
          'Function is not active' => 'function_inactive',
          _notFoundDetail => 'function_missing',
          _accessProhibitedDetail => 'not_admin',
          _ => status.toString(),
        },
      ),
    );
  }

  // Open WebUI answers 401 with these for a missing function and for a user
  // who is not an admin; neither means the session ended.
  static const String _notFoundDetail =
      "We could not find what you're looking for :/";
  static const String _accessProhibitedDetail =
      'You do not have permission to access this resource. Please contact '
      'your administrator for assistance.';

  static PushProbe _probeFailure(DioException error) {
    if (_isAuthError(error))
      return const PushProbe(PushProbeOutcome.signInNeeded);
    return PushProbe(
      PushProbeOutcome.failed,
      failure: _backendError(error).failure,
    );
  }

  static bool _isAuthError(DioException error) {
    if (error.response?.statusCode != 401) return false;
    final detail = _detail(error);
    return detail != _notFoundDetail && detail != _accessProhibitedDetail;
  }

  static String? _detail(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['detail'] is String)
      return data['detail'] as String;
    return null;
  }

  static Map<String, dynamic>? _map(Object? data) =>
      data is Map ? Map<String, dynamic>.from(data) : null;
}
