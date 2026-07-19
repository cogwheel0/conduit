import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/server_config.dart';
import '../network/conduit_user_agent.dart';
import '../providers/app_providers.dart';
import 'server_tls_http_client_factory.dart';

part 'connectivity_service.g.dart';

/// Connectivity status for the app.
/// - [online]: Server is reachable
/// - [offline]: No network or server unreachable
enum ConnectivityStatus { online, offline }

/// Simplified connectivity service that monitors network and server health.
///
/// Key improvements:
/// - No "checking" state to prevent UI flashing
/// - Assumes online by default (optimistic)
/// - Only shows offline when explicitly confirmed
/// - Minimal state changes during startup
class ConnectivityService with WidgetsBindingObserver {
  ConnectivityService(
    this._dio,
    this._ref, [
    Connectivity? connectivity,
    this._ownsDio = false,
  ]) : _connectivity = connectivity ?? Connectivity() {
    _initialize();
  }

  final Dio _dio;
  final Ref _ref;
  final Connectivity _connectivity;
  final bool _ownsDio;
  final Random _random = Random();

  final _statusController = StreamController<ConnectivityStatus>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<Uri>? _transportFailureSubscription;
  StreamSubscription<Uri>? _successfulTrafficSubscription;
  Timer? _pollTimer;
  DateTime? _pollDeadline;
  bool _pollForcesProbe = false;
  Timer? _noNetworkGraceTimer;
  DateTime? _offlineSuppressedUntil;
  bool _isAppForeground = true;

  // Start optimistically as online to prevent flash
  ConnectivityStatus _currentStatus = ConnectivityStatus.online;
  bool _hasNetworkInterface = false;
  bool _hasConfirmedNetwork = false;
  int _consecutiveFailures = 0;
  int _lastLatencyMs = -1;
  Future<void>? _healthCheckFuture;
  bool _activeHealthCheckSatisfiesForce = false;

  static const Duration _healthyProbeInterval = Duration(minutes: 2);
  static const Duration _recentTrafficWindow = Duration(minutes: 1);
  static const Duration _maximumFailureBackoff = Duration(minutes: 5);
  static const Duration _probeDeadline = Duration(seconds: 6);
  static const Duration _probeConnectTimeout = Duration(seconds: 5);

  Stream<ConnectivityStatus> get statusStream => _statusController.stream;
  ConnectivityStatus get currentStatus => _currentStatus;
  int get lastLatencyMs => _lastLatencyMs;
  bool get isOnline => _currentStatus == ConnectivityStatus.online;
  bool get isAppForeground => _isAppForeground;
  bool get isOfflineSuppressed => _isOfflineSuppressed;

  @visibleForTesting
  bool get debugHasScheduledHealthCheck => _pollTimer?.isActive ?? false;

  @visibleForTesting
  Future<void> debugCheckServerHealth() => _checkServerHealth();

  void _initialize() {
    // Listen to network interface changes
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      _handleNetworkChange,
      onError: (_) {}, // Ignore connectivity errors
    );

    // Check initial network state immediately
    _connectivity.checkConnectivity().then(_handleNetworkChange);

    _transportFailureSubscription = _transportFailures.stream.listen((uri) {
      if (_originKey(uri) != _originKey(_getServerUri())) return;
      if (!_isAppForeground || !_hasNetworkInterface) return;
      // Fixed-window coalescing: a continuing failure burst must not keep
      // pushing the probe one second into the future forever.
      _scheduleNextCheck(
        delay: const Duration(seconds: 1),
        force: true,
        retainEarlierDeadline: true,
      );
    });

    _successfulTrafficSubscription = _successfulTraffic.stream.listen((uri) {
      if (_originKey(uri) != _originKey(_getServerUri())) return;

      // A completed request is stronger evidence than an interface callback or
      // a stale health failure. Recover this exact server instance immediately
      // and return to the low-frequency healthy polling cadence.
      _cancelNoNetworkGrace();
      _hasNetworkInterface = true;
      _hasConfirmedNetwork = true;
      _consecutiveFailures = 0;
      _updateStatus(ConnectivityStatus.online);
      _scheduleNextCheck();
    });

    // Keep a low-frequency stale-connection fallback. Interface changes,
    // lifecycle resumes, and failed requests are the primary triggers.
    _scheduleNextCheck();

    WidgetsBinding.instance.addObserver(this);
    _extendOfflineSuppression(const Duration(seconds: 3));
  }

  void _handleNetworkChange(List<ConnectivityResult> results) {
    if (_statusController.isClosed) return;
    final hadNetwork = _hasNetworkInterface;
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);
    _hasNetworkInterface = hasNetwork;

    if (!hasNetwork) {
      if (hadNetwork || _hasConfirmedNetwork) {
        // Lost network after previously confirming it
        _cancelNoNetworkGrace();
        _updateStatus(ConnectivityStatus.offline);
        _stopPolling();
      } else {
        // During startup we often get a transient "none" result.
        // Defer emitting offline until it persists beyond the grace window.
        _noNetworkGraceTimer ??= Timer(const Duration(seconds: 2), () {
          if (!_hasNetworkInterface) {
            _updateStatus(ConnectivityStatus.offline);
            _stopPolling();
          }
        });
      }
      return;
    }

    // Network available
    _cancelNoNetworkGrace();
    if (!_hasConfirmedNetwork) {
      _hasConfirmedNetwork = true;
    }

    if (!hadNetwork) {
      // Network just came back, check server immediately
      _checkServerHealth();
    }
  }

  void _scheduleNextCheck({
    Duration? delay,
    bool force = false,
    bool retainEarlierDeadline = false,
  }) {
    if (_statusController.isClosed || !_isAppForeground) {
      _stopPolling();
      return;
    }

    final interval = delay ?? _nextStaleProbeDelay();
    final deadline = DateTime.now().add(interval);
    final currentDeadline = _pollDeadline;
    if (retainEarlierDeadline &&
        (_pollTimer?.isActive ?? false) &&
        currentDeadline != null &&
        !currentDeadline.isAfter(deadline)) {
      // Preserve the earlier fixed-window deadline, but never lose stronger
      // semantics from a later coalesced event. In particular, a transport
      // failure must upgrade a resume/staleness timer to a forced probe.
      _pollForcesProbe = _pollForcesProbe || force;
      return;
    }

    _stopPolling();
    _pollDeadline = deadline;
    _pollForcesProbe = force;

    _pollTimer = Timer(interval, () {
      final forceProbe = _pollForcesProbe;
      _pollTimer = null;
      _pollDeadline = null;
      _pollForcesProbe = false;
      if (!_statusController.isClosed && _hasNetworkInterface) {
        unawaited(_checkServerHealth(force: forceProbe));
      }
    });
  }

  Duration _nextStaleProbeDelay() {
    if (_consecutiveFailures == 0) {
      return _withJitter(_healthyProbeInterval, fraction: 0.15);
    }
    final exponent = min(_consecutiveFailures - 1, 4);
    final milliseconds = min(
      const Duration(seconds: 30).inMilliseconds * pow(2, exponent),
      _maximumFailureBackoff.inMilliseconds,
    ).toInt();
    return _withJitter(Duration(milliseconds: milliseconds), fraction: 0.2);
  }

  Duration _withJitter(Duration duration, {required double fraction}) {
    final spread = (duration.inMilliseconds * fraction).round();
    if (spread <= 0) return duration;
    final offset = _random.nextInt(spread * 2 + 1) - spread;
    return Duration(milliseconds: max(1, duration.inMilliseconds + offset));
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollDeadline = null;
    _pollForcesProbe = false;
  }

  Future<void> _checkServerHealth({bool force = false}) {
    if (_statusController.isClosed || !_hasNetworkInterface) {
      return Future<void>.value();
    }
    final activeProbe = _healthCheckFuture;
    if (activeProbe != null) {
      if (!force || _activeHealthCheckSatisfiesForce) return activeProbe;
      // A non-forced probe may be only the recent-traffic fast path. Wait for
      // that state update to settle, then start or join one real forced probe.
      return activeProbe.then((_) => _checkServerHealth(force: true));
    }

    final baseUri = _getServerUri();
    final satisfiesForce =
        force ||
        _consecutiveFailures != 0 ||
        !_hasRecentSuccessfulTraffic(baseUri);

    late final Future<void> trackedProbe;
    trackedProbe = _runServerHealthCheck(force: force).whenComplete(() {
      if (identical(_healthCheckFuture, trackedProbe)) {
        _healthCheckFuture = null;
        _activeHealthCheckSatisfiesForce = false;
      }
    });
    _activeHealthCheckSatisfiesForce = satisfiesForce;
    _healthCheckFuture = trackedProbe;
    return trackedProbe;
  }

  Future<void> _runServerHealthCheck({required bool force}) async {
    final baseUri = _getServerUri();
    if (!force &&
        _consecutiveFailures == 0 &&
        _hasRecentSuccessfulTraffic(baseUri)) {
      _updateStatus(ConnectivityStatus.online);
      _scheduleNextCheck();
      return;
    }

    final isReachable = await _probeServer();
    // Closing the owned Dio during provider teardown resolves an in-flight
    // probe as a failure. Do not let that stale completion mutate state or
    // install a new backoff timer that retains the disposed service/ref.
    if (_statusController.isClosed) return;

    Duration? overrideDelay;

    if (isReachable) {
      _consecutiveFailures = 0;
      _updateStatus(ConnectivityStatus.online);
    } else {
      _consecutiveFailures++;
      // Require more consecutive failures to reduce false negatives.
      // Switch to offline only after >= 3 consecutive failures.
      if (_consecutiveFailures >= 3) {
        _updateStatus(ConnectivityStatus.offline);
      } else {
        // Confirm transient failures promptly before presenting offline UI.
        overrideDelay = _withJitter(const Duration(seconds: 3), fraction: 0.2);
      }
    }

    _scheduleNextCheck(delay: overrideDelay);
  }

  Future<bool> _probeServer() async {
    final baseUri = _getServerUri();
    if (baseUri == null) {
      // No server configured yet, assume online
      return true;
    }

    final configuredClientUri = _parseUri(_dio.options.baseUrl);
    final configuredClientOrigin = ConnectivityService._originKey(
      configuredClientUri,
    );
    final targetOrigin = ConnectivityService._originKey(baseUri);
    final hasOriginBoundHeaders = _dio.options.headers.keys.any(
      (name) => !ConduitUserAgent.isHeaderName(name),
    );
    if ((configuredClientOrigin != null &&
            configuredClientOrigin != targetOrigin) ||
        (configuredClientOrigin == null && hasOriginBoundHeaders)) {
      // This service belongs to the Dio created for one selected server. A
      // provider switch may publish the next server before disposal reaches an
      // already-scheduled probe. A credential-bearing client without a
      // provable base origin is equally unsafe: never send its headers to the
      // currently selected server by inference.
      _lastLatencyMs = -1;
      return false;
    }

    try {
      final start = DateTime.now();
      final healthUri = baseUri.resolve('/health');
      final cancelToken = CancelToken();
      final deadlineTimer = Timer(_probeDeadline, () {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('Connectivity probe deadline expired');
        }
      });

      final Response<dynamic> response;
      try {
        response = await _dio
            .getUri<dynamic>(
              healthUri,
              options: Options(
                sendTimeout: _probeConnectTimeout,
                receiveTimeout: _probeConnectTimeout,
                followRedirects: false,
                validateStatus: (status) => status != null && status < 500,
              ),
              cancelToken: cancelToken,
            )
            .timeout(
              _probeDeadline,
              onTimeout: () {
                if (!cancelToken.isCancelled) {
                  cancelToken.cancel('Connectivity probe deadline expired');
                }
                throw TimeoutException('Connectivity probe deadline expired');
              },
            );
      } finally {
        deadlineTimer.cancel();
      }

      final isHealthy = response.statusCode == 200;

      if (isHealthy) {
        _lastLatencyMs = DateTime.now().difference(start).inMilliseconds;
        noteSuccessfulTraffic(baseUri);
      } else {
        _lastLatencyMs = -1;
      }

      return isHealthy;
    } catch (_) {
      _lastLatencyMs = -1;
      return false;
    }
  }

  Uri? _getServerUri() {
    final api = _ref.read(apiServiceProvider);
    if (api != null) {
      return _parseUri(api.baseUrl);
    }

    final activeServer = _ref.read(activeServerProvider);
    return activeServer.maybeWhen(
      data: (server) => server != null ? _parseUri(server.url) : null,
      orElse: () => null,
    );
  }

  Uri? _parseUri(String url) {
    return ServerTlsHttpClientFactory.parseBaseUri(url);
  }

  void _updateStatus(ConnectivityStatus newStatus) {
    if (_currentStatus != newStatus && !_statusController.isClosed) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
    } else {
      _currentStatus = newStatus;
    }

    if (newStatus == ConnectivityStatus.online) {
      _offlineSuppressedUntil = null;
    }
  }

  void _cancelNoNetworkGrace() {
    _noNetworkGraceTimer?.cancel();
    _noNetworkGraceTimer = null;
  }

  bool get _isOfflineSuppressed {
    final until = _offlineSuppressedUntil;
    // Check process-wide suppression window (set by API layer on successes)
    final globalUntil = _globalOfflineSuppressedUntil;
    if (globalUntil != null && DateTime.now().isBefore(globalUntil)) {
      return true;
    }
    if (until == null) {
      return false;
    }
    if (DateTime.now().isBefore(until)) {
      return true;
    }
    _offlineSuppressedUntil = null;
    return false;
  }

  void _extendOfflineSuppression(Duration duration) {
    final base = DateTime.now();
    final proposed = base.add(duration);
    if (_offlineSuppressedUntil == null ||
        proposed.isAfter(_offlineSuppressedUntil!)) {
      _offlineSuppressedUntil = proposed;
    }
  }

  // ===== Global suppression signaling (from API layer) =====
  static DateTime? _globalOfflineSuppressedUntil;
  static final Map<String, DateTime> _lastSuccessfulTrafficByOrigin = {};
  static final StreamController<Uri> _successfulTraffic =
      StreamController<Uri>.broadcast(sync: true);
  static final StreamController<Uri> _transportFailures =
      StreamController<Uri>.broadcast(sync: true);

  static String? _originKey(Uri? uri) {
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}';
  }

  /// Records successful server traffic so the fallback health timer does not
  /// wake the radio merely to prove a connection that normal API work already
  /// proved. Entries are origin-scoped to avoid suppressing a newly-selected
  /// server with traffic from the previous one.
  static void noteSuccessfulTraffic(Uri? serverUri) {
    final key = _originKey(serverUri);
    if (key == null) return;
    if (!_lastSuccessfulTrafficByOrigin.containsKey(key) &&
        _lastSuccessfulTrafficByOrigin.length >= 16) {
      _lastSuccessfulTrafficByOrigin.remove(
        _lastSuccessfulTrafficByOrigin.keys.first,
      );
    }
    _lastSuccessfulTrafficByOrigin[key] = DateTime.now();
    if (!_successfulTraffic.isClosed) {
      _successfulTraffic.add(serverUri!);
    }
  }

  static void reportTransportFailure(Uri? serverUri) {
    if (serverUri != null && !_transportFailures.isClosed) {
      _transportFailures.add(serverUri);
    }
  }

  @visibleForTesting
  static bool debugHasRecentSuccessfulTraffic(Uri serverUri) {
    final key = _originKey(serverUri);
    final lastSuccess = key == null
        ? null
        : _lastSuccessfulTrafficByOrigin[key];
    return lastSuccess != null &&
        DateTime.now().difference(lastSuccess) < _recentTrafficWindow;
  }

  @visibleForTesting
  static void debugResetTrafficSignals() {
    _lastSuccessfulTrafficByOrigin.clear();
    _globalOfflineSuppressedUntil = null;
  }

  @visibleForTesting
  int get debugConsecutiveFailures => _consecutiveFailures;

  bool _hasRecentSuccessfulTraffic(Uri? serverUri) {
    final key = _originKey(serverUri);
    final lastSuccess = key == null
        ? null
        : _lastSuccessfulTrafficByOrigin[key];
    return lastSuccess != null &&
        DateTime.now().difference(lastSuccess) < _recentTrafficWindow;
  }

  /// Suppress offline transitions globally for a short window. Useful
  /// to avoid flicker after known-good API responses.
  static void suppressOfflineGlobally(Duration duration) {
    final proposed = DateTime.now().add(duration);
    if (_globalOfflineSuppressedUntil == null ||
        proposed.isAfter(_globalOfflineSuppressedUntil!)) {
      _globalOfflineSuppressedUntil = proposed;
    }
  }

  /// Manually trigger a connectivity check.
  Future<bool> checkNow() async {
    await _checkServerHealth(force: true);
    return _currentStatus == ConnectivityStatus.online;
  }

  void dispose() {
    _stopPolling();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _transportFailureSubscription?.cancel();
    _transportFailureSubscription = null;
    _successfulTrafficSubscription?.cancel();
    _successfulTrafficSubscription = null;
    _cancelNoNetworkGrace();
    WidgetsBinding.instance.removeObserver(this);

    if (_ownsDio) {
      _dio.close(force: true);
    }

    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _isAppForeground = true;
        _extendOfflineSuppression(const Duration(seconds: 4));
        // Give networking stack a short window to settle
        _scheduleNextCheck(delay: const Duration(milliseconds: 500));
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _isAppForeground = false;
        _extendOfflineSuppression(const Duration(seconds: 6));
        _stopPolling();
        break;
      case AppLifecycleState.detached:
        _isAppForeground = false;
        _stopPolling();
        break;
    }
  }
}

// Provider for the connectivity service
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final activeServer = ref.watch(activeServerProvider);

  return activeServer.maybeWhen(
    data: (server) {
      if (server == null) {
        final dio = Dio();
        final service = ConnectivityService(dio, ref, null, true);
        ref.onDispose(service.dispose);
        return service;
      }

      final dio = createConnectivityHealthClient(
        server,
        suppressCustomCookieHeader: () {
          try {
            return ref.read(incompleteLogoutFenceProvider) ||
                ref
                    .read(incompleteLogoutFenceProvider.notifier)
                    .desiredSuppressed;
          } catch (_) {
            // A request racing provider teardown cannot safely reattach a
            // configured proxy session cookie.
            return true;
          }
        },
      );

      final service = ConnectivityService(dio, ref, null, true);
      ref.onDispose(service.dispose);
      return service;
    },
    orElse: () {
      final dio = Dio();
      final service = ConnectivityService(dio, ref, null, true);
      ref.onDispose(service.dispose);
      return service;
    },
  );
});

/// Builds the origin-bound health client without automatic redirects.
///
/// Server custom headers may carry proxy credentials. Following a cross-origin
/// `/health` redirect would disclose them to an untrusted host, so redirects
/// are handled as an unhealthy probe instead.
@visibleForTesting
Dio createConnectivityHealthClient(
  ServerConfig server, {
  bool Function()? suppressCustomCookieHeader,
}) {
  final serverUri = ServerTlsHttpClientFactory.parseBaseUri(server.url);
  final customHeaderNames = server.customHeaders.keys
      .map((name) => name.toLowerCase())
      .toSet();
  final dio = Dio(
    BaseOptions(
      baseUrl: serverUri?.toString() ?? server.url,
      connectTimeout: ConnectivityService._probeConnectTimeout,
      receiveTimeout: ConnectivityService._probeConnectTimeout,
      followRedirects: false,
      maxRedirects: 0,
      validateStatus: (status) => status != null && status < 400,
      headers: ConduitUserAgent.mergeHeaders(server.customHeaders),
    ),
  );

  if (customHeaderNames.isNotEmpty || suppressCustomCookieHeader != null) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (ConnectivityService._originKey(options.uri) !=
              ConnectivityService._originKey(serverUri)) {
            options.headers.removeWhere(
              (name, _) => customHeaderNames.contains(name.toLowerCase()),
            );
          }

          if (suppressCustomCookieHeader != null) {
            var suppressed = true;
            try {
              suppressed = suppressCustomCookieHeader();
            } catch (_) {
              // Fail closed if the live logout fence cannot be resolved.
            }
            if (suppressed) {
              options.headers.removeWhere(
                (name, _) => name.toLowerCase() == 'cookie',
              );
            }
          }
          handler.next(options);
        },
      ),
    );
  }

  ServerTlsHttpClientFactory.configureDio(
    dio,
    server,
    userAgent: ConduitUserAgent.value,
  );
  return dio;
}

// Riverpod notifier for connectivity status
@Riverpod(keepAlive: true)
class ConnectivityStatusNotifier extends _$ConnectivityStatusNotifier {
  StreamSubscription<ConnectivityStatus>? _subscription;

  @override
  ConnectivityStatus build() {
    final service = ref.watch(connectivityServiceProvider);

    _subscription?.cancel();
    _subscription = service.statusStream.listen(
      (status) => state = status,
      onError: (_, _) {}, // Ignore errors, keep current state
    );

    ref.onDispose(() {
      _subscription?.cancel();
      _subscription = null;
    });

    // Return current status immediately (starts as online)
    return service.currentStatus;
  }
}

// Simple provider for checking if online
final isOnlineProvider = Provider<bool>((ref) {
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) return true;

  final status = ref.watch(connectivityStatusProvider);
  return status == ConnectivityStatus.online;
});
