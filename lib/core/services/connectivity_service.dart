import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';

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
  ConnectivityService(this._dio, this._ref, [Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity() {
    _initialize();
  }

  final Dio _dio;
  final Ref _ref;
  final Connectivity _connectivity;

  final _statusController = StreamController<ConnectivityStatus>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _pollTimer;
  Timer? _noNetworkGraceTimer;
  DateTime? _offlineSuppressedUntil;
  bool _isAppForeground = true;

  // Start optimistically as online to prevent flash
  ConnectivityStatus _currentStatus = ConnectivityStatus.online;
  bool _hasNetworkInterface = false;
  bool _hasConfirmedNetwork = false;
  int _consecutiveFailures = 0;
  int _lastLatencyMs = -1;

  Stream<ConnectivityStatus> get statusStream => _statusController.stream;
  ConnectivityStatus get currentStatus => _currentStatus;
  int get lastLatencyMs => _lastLatencyMs;
  bool get isOnline => _currentStatus == ConnectivityStatus.online;
  bool get isAppForeground => _isAppForeground;
  bool get isOfflineSuppressed => _isOfflineSuppressed;

  void _initialize() {
    // Listen to network interface changes
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      _handleNetworkChange,
      onError: (_) {}, // Ignore connectivity errors
    );

    // Check initial network state immediately
    _connectivity.checkConnectivity().then(_handleNetworkChange);

    // Start periodic health checks
    _scheduleNextCheck();

    WidgetsBinding.instance.addObserver(this);
    _extendOfflineSuppression(const Duration(seconds: 3));
  }

  void _handleNetworkChange(List<ConnectivityResult> results) {
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

  void _scheduleNextCheck({Duration? delay}) {
    _stopPolling();

    if (!_isAppForeground) {
      return;
    }

    // Adaptive polling based on failure count
    final interval =
        delay ??
        (_consecutiveFailures >= 3
            ? const Duration(seconds: 30)
            : _consecutiveFailures >= 1
            ? const Duration(seconds: 20)
            : const Duration(seconds: 15));

    _pollTimer = Timer(interval, () {
      if (_hasNetworkInterface) {
        _checkServerHealth();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkServerHealth() async {
    if (_statusController.isClosed || !_hasNetworkInterface) {
      return;
    }

    final isReachable = await _probeServer();

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
        // Shorter retry when still below threshold.
        overrideDelay = const Duration(seconds: 3);
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

    try {
      final start = DateTime.now();
      final healthUri = baseUri.resolve('/health');

      final response = await _dio
          .getUri(
            healthUri,
            options: Options(
              sendTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
              followRedirects: false,
              validateStatus: (status) => status != null && status < 500,
            ),
          )
          .timeout(const Duration(seconds: 6));

      final isHealthy = response.statusCode == 200;

      if (isHealthy) {
        _lastLatencyMs = DateTime.now().difference(start).inMilliseconds;
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
    if (url.isEmpty) return null;

    Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null) return null;

    if (!parsed.hasScheme) {
      parsed = Uri.tryParse('https://$url') ?? Uri.tryParse('http://$url');
    }

    return parsed;
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
    await _checkServerHealth();
    return _currentStatus == ConnectivityStatus.online;
  }

  void dispose() {
    _stopPolling();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _cancelNoNetworkGrace();
    WidgetsBinding.instance.removeObserver(this);

    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }

  /// Configures the Dio instance to accept self-signed certificates.
  ///
  /// This method sets up a [badCertificateCallback] that trusts certificates
  /// from the specified server's host and port for health check requests.
  ///
  /// Security considerations:
  /// - Only certificates from the exact host/port are trusted
  /// - If no port is specified in the URL, all ports on the host are trusted
  /// - Web platforms ignore this (browsers handle TLS validation)
  ///
  /// This is called per-Dio-instance rather than using global HttpOverrides.
  static void configureSelfSignedCerts(Dio dio, String serverUrl) {
    if (kIsWeb) return;

    final uri = _parseStaticUri(serverUrl);
    if (uri == null) return;

    final adapter = dio.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) return;

    adapter.createHttpClient = () {
      final client = HttpClient();
      final host = uri.host.toLowerCase();
      final port = uri.hasPort ? uri.port : null;

      client.badCertificateCallback =
          (X509Certificate cert, String requestHost, int requestPort) {
            // Only trust certificates from our configured server
            if (requestHost.toLowerCase() != host) return false;
            // If no specific port configured, trust any port on this host
            if (port == null) return true;
            // Otherwise, port must match exactly
            return requestPort == port;
          };

      return client;
    };
  }

  static Uri? _parseStaticUri(String url) {
    if (url.trim().isEmpty) return null;

    Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null) return null;

    if (!parsed.hasScheme) {
      parsed =
          Uri.tryParse('https://${url.trim()}') ??
          Uri.tryParse('http://${url.trim()}');
    }

    return parsed;
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
        final service = ConnectivityService(dio, ref);
        ref.onDispose(service.dispose);
        return service;
      }

      final dio = Dio(
        BaseOptions(
          baseUrl: server.url,
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (status) => status != null && status < 400,
          headers: server.customHeaders.isNotEmpty
              ? Map<String, String>.from(server.customHeaders)
              : null,
        ),
      );

      if (server.allowSelfSignedCertificates) {
        ConnectivityService.configureSelfSignedCerts(dio, server.url);
      }

      final service = ConnectivityService(dio, ref);
      ref.onDispose(service.dispose);
      return service;
    },
    orElse: () {
      final dio = Dio();
      final service = ConnectivityService(dio, ref);
      ref.onDispose(service.dispose);
      return service;
    },
  );
});

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
