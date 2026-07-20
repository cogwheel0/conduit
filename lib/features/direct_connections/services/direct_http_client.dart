import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../core/models/server_config.dart';
import '../../../core/services/server_tls_http_client_factory.dart';
import '../models/direct_connection_profile.dart';

typedef DirectDioFactory = Dio Function(DirectConnectionProfile profile);

/// Creates a credential-scoped Dio client for exactly one direct profile.
final class DirectHttpClientFactory {
  const DirectHttpClientFactory();

  Dio create(DirectConnectionProfile profile) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 60),
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    configure(dio, profile);

    return dio;
  }

  /// Applies the security boundary to an injected Dio instance as well as the
  /// default one. This keeps test/extension clients from accidentally enabling
  /// credential-bearing redirects or using a stale base URL.
  void configure(Dio dio, DirectConnectionProfile profile) {
    profile.validate();

    // An IO adapter caches its HttpClient after the first request. Reusing it
    // across profile edits could retain an earlier profile's trust policy or
    // client certificate even after createHttpClient is replaced. Rotate only
    // native Dio adapters; injected/mock adapters remain intact.
    final previousAdapter = dio.httpClientAdapter;
    if (previousAdapter is IOHttpClientAdapter) {
      previousAdapter.close(force: true);
      dio.httpClientAdapter = IOHttpClientAdapter();
    }

    dio.options.baseUrl = profile.requestBaseUri().toString();
    dio.options.followRedirects = false;
    dio.options.queryParameters.clear();
    if (profile.adapterKey == kOpenAiCompatibleAdapterKey &&
        (profile.apiVersion ?? '').trim().isNotEmpty) {
      dio.options.queryParameters['api-version'] = profile.apiVersion!.trim();
    }
    dio.options.headers.clear();
    dio.options.headers.addAll({
      'Accept': 'application/json',
      if ((profile.apiKey ?? '').trim().isNotEmpty)
        ...switch (profile.apiKeyAuthMode) {
          DirectApiKeyAuthMode.bearer => {
            'Authorization': 'Bearer ${profile.apiKey!.trim()}',
          },
          DirectApiKeyAuthMode.apiKeyHeader => {
            'api-key': profile.apiKey!.trim(),
          },
        },
      ...profile.customHeaders,
    });

    ServerTlsHttpClientFactory.configureDio(
      dio,
      ServerConfig(
        id: 'direct-${profile.id}',
        name: profile.name,
        url: profile.baseUrl,
        allowSelfSignedCertificates: profile.allowSelfSignedCertificates,
        mtlsCertificateChainPem: profile.mtlsCertificateChainPem,
        mtlsCertificateLabel: profile.mtlsCertificateLabel,
        mtlsPrivateKeyPem: profile.mtlsPrivateKeyPem,
        mtlsPrivateKeyLabel: profile.mtlsPrivateKeyLabel,
        mtlsPrivateKeyPassword: profile.mtlsPrivateKeyPassword,
      ),
    );
  }
}

/// A credential- and trust-policy-scoped native connection pool.
///
/// Profile edits retire the old entry immediately, but an in-flight stream
/// keeps its lease until settlement so changing settings cannot abort or
/// silently rebind an authorized request. No signature is ever logged.
final class DirectHttpClientPool {
  DirectHttpClientPool({
    DirectHttpClientFactory? factory,
    DirectDioFactory? dioFactory,
    this.idleTimeout = const Duration(minutes: 2),
    this.maxIdleEntries = 8,
  }) : _create =
           dioFactory ?? (factory ?? const DirectHttpClientFactory()).create {
    if (idleTimeout.isNegative) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout');
    }
    if (maxIdleEntries < 0) {
      throw RangeError.value(maxIdleEntries, 'maxIdleEntries');
    }
  }

  final DirectDioFactory _create;
  final Duration idleTimeout;
  final int maxIdleEntries;
  final Map<String, _PooledDirectHttpClient> _entries = {};
  final Set<_PooledDirectHttpClient> _allEntries = {};
  int _idleSequence = 0;
  bool _disposed = false;

  DirectHttpClientLease acquire(DirectConnectionProfile profile) {
    if (_disposed) throw StateError('DirectHttpClientPool is disposed');
    profile.validate();
    final signature = _profileTransportSignature(profile);

    for (final entry in _entries.values.toList(growable: false)) {
      if (entry.profileId == profile.id && entry.signature != signature) {
        _retire(entry);
      }
    }

    var entry = _entries[signature];
    if (entry == null) {
      entry = _PooledDirectHttpClient(
        profileId: profile.id,
        signature: signature,
        dio: _create(profile),
      );
      _entries[signature] = entry;
      _allEntries.add(entry);
    }
    final acquiredEntry = entry;
    acquiredEntry.idleTimer?.cancel();
    acquiredEntry.idleTimer = null;
    acquiredEntry.idleSequence = null;
    acquiredEntry.activeLeases++;
    return DirectHttpClientLease._(
      acquiredEntry.dio,
      () => _release(acquiredEntry),
    );
  }

  void _release(_PooledDirectHttpClient entry) {
    if (entry.activeLeases > 0) entry.activeLeases--;
    if (entry.retired) {
      _closeIfUnused(entry);
      return;
    }
    if (entry.activeLeases == 0) _scheduleIdleEviction(entry);
  }

  /// Retires every transport for [profileId] without interrupting requests
  /// that already hold a lease. A later acquisition always receives a fresh
  /// client, even if it presents an identical historical profile snapshot.
  void invalidateProfile(String profileId) {
    if (_disposed) return;
    for (final entry in _entries.values.toList(growable: false)) {
      if (entry.profileId == profileId) _retire(entry);
    }
  }

  /// Batch form used when a reload or ownership transition removes multiple
  /// profiles at once.
  void invalidateProfiles(Iterable<String> profileIds) {
    if (_disposed) return;
    final ids = profileIds.toSet();
    if (ids.isEmpty) return;
    for (final entry in _entries.values.toList(growable: false)) {
      if (ids.contains(entry.profileId)) _retire(entry);
    }
  }

  void _scheduleIdleEviction(_PooledDirectHttpClient entry) {
    entry.idleTimer?.cancel();
    entry.idleSequence = ++_idleSequence;
    if (idleTimeout == Duration.zero) {
      _retire(entry);
      return;
    }
    entry.idleTimer = Timer(idleTimeout, () {
      if (_disposed || entry.activeLeases != 0 || entry.retired) return;
      _retire(entry);
    });
    _enforceIdleCap();
  }

  void _enforceIdleCap() {
    final idleEntries =
        _entries.values
            .where((entry) => entry.activeLeases == 0 && !entry.retired)
            .toList(growable: false)
          ..sort(
            (left, right) =>
                (left.idleSequence ?? 0).compareTo(right.idleSequence ?? 0),
          );
    final excess = idleEntries.length - maxIdleEntries;
    for (var index = 0; index < excess; index++) {
      _retire(idleEntries[index]);
    }
  }

  void _retire(_PooledDirectHttpClient entry) {
    if (entry.retired) return;
    entry.retired = true;
    entry.idleTimer?.cancel();
    entry.idleTimer = null;
    entry.idleSequence = null;
    if (identical(_entries[entry.signature], entry)) {
      _entries.remove(entry.signature);
    }
    _closeIfUnused(entry);
  }

  void _closeIfUnused(_PooledDirectHttpClient entry) {
    if (!entry.retired || entry.activeLeases != 0 || entry.closed) return;
    entry.closed = true;
    _allEntries.remove(entry);
    entry.dio.close(force: true);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _allEntries) {
      entry.idleTimer?.cancel();
      entry.idleTimer = null;
      // A lease may outlive container teardown. Mark its entry retired so a
      // later release closes out bookkeeping instead of scheduling an idle
      // timer on this already-disposed pool.
      entry.retired = true;
      if (!entry.closed) {
        entry.closed = true;
        entry.dio.close(force: true);
      }
    }
    _entries.clear();
    _allEntries.clear();
  }
}

final class DirectHttpClientLease {
  DirectHttpClientLease._(this.dio, this._onRelease);

  final Dio dio;
  void Function()? _onRelease;

  void release() {
    final callback = _onRelease;
    if (callback == null) return;
    _onRelease = null;
    callback();
  }
}

final class _PooledDirectHttpClient {
  _PooledDirectHttpClient({
    required this.profileId,
    required this.signature,
    required this.dio,
  });

  final String profileId;
  final String signature;
  final Dio dio;
  int activeLeases = 0;
  bool retired = false;
  bool closed = false;
  int? idleSequence;
  Timer? idleTimer;
}

String _profileTransportSignature(DirectConnectionProfile profile) {
  final sortedHeaders = profile.customHeaders.entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  final canonical = jsonEncode(<String, Object?>{
    'profileId': profile.id,
    'adapter': profile.adapterKey,
    'baseUri': profile.requestBaseUri().toString(),
    'apiVersion': profile.apiVersion,
    'authMode': profile.apiKeyAuthMode.storageValue,
    'apiKey': profile.apiKey,
    'headers': <List<String>>[
      for (final header in sortedHeaders) <String>[header.key, header.value],
    ],
    'allowSelfSigned': profile.allowSelfSignedCertificates,
    'certificateChain': profile.mtlsCertificateChainPem,
    'certificateLabel': profile.mtlsCertificateLabel,
    'privateKey': profile.mtlsPrivateKeyPem,
    'privateKeyLabel': profile.mtlsPrivateKeyLabel,
    'privateKeyPassword': profile.mtlsPrivateKeyPassword,
  });
  // Keep credentials out of long-lived map keys while retaining a stable,
  // effectively collision-resistant identity for every transport setting.
  return sha256.convert(utf8.encode(canonical)).toString();
}
