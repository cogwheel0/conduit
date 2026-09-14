import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../models/deepseek_config.dart';
import '../models/deepseek_probe.dart';
import '../services/deepseek_probe_service.dart';

/// Owns the DeepSeek harness config. Every field is non-secret, so state
/// hydrates synchronously from shared preferences and each mutation persists
/// before updating state. (No secure-storage hydration: DSH uses a host
/// allowlist instead of an API key.)
class DeepSeekConfigController extends Notifier<DeepSeekConfig> {
  Future<void> _mutationQueue = Future<void>.value();

  @override
  DeepSeekConfig build() {
    final enabled =
        PreferencesStore.getBool(PreferenceKeys.deepseekEnabled) ?? false;
    final baseUrl =
        PreferencesStore.getString(PreferenceKeys.deepseekBaseUrl) ?? '';
    final trustedHost =
        PreferencesStore.getString(PreferenceKeys.deepseekTrustedHost);
    final allowSelfSignedCertificates =
        PreferencesStore.getBool(
          PreferenceKeys.deepseekAllowSelfSignedCertificates,
        ) ??
        false;
    return DeepSeekConfig(
      enabled: enabled,
      baseUrl: baseUrl,
      trustedHost: (trustedHost?.trim().isNotEmpty ?? false)
          ? trustedHost!.trim()
          : null,
      allowSelfSignedCertificates: allowSelfSignedCertificates,
    );
  }

  Future<void> setEnabled(bool value) =>
      _commit(state.copyWith(enabled: value));

  Future<void> setBaseUrl(String value) =>
      _commit(state.copyWith(baseUrl: value.trim()));

  Future<void> setTrustedHost(String? value) {
    final trimmed = value?.trim();
    return _commit(
      state.copyWith(
        trustedHost: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      ),
    );
  }

  Future<void> setAllowSelfSignedCertificates(bool value) => _commit(
        state.copyWith(allowSelfSignedCertificates: value),
      );

  /// Persists the full config, then updates state. Mutations are queued so
  /// fast successive writes keep their order. A failed write rethrows to the
  /// caller and leaves state unchanged; the queue itself keeps going.
  Future<void> _commit(DeepSeekConfig next) {
    final mutation = _mutationQueue.then((_) async {
      await PreferencesStore.putChecked(
        PreferenceKeys.deepseekEnabled,
        next.enabled,
      );
      await PreferencesStore.putChecked(
        PreferenceKeys.deepseekBaseUrl,
        next.baseUrl.isEmpty ? null : next.baseUrl,
      );
      await PreferencesStore.putChecked(
        PreferenceKeys.deepseekTrustedHost,
        next.trustedHost,
      );
      await PreferencesStore.putChecked(
        PreferenceKeys.deepseekAllowSelfSignedCertificates,
        next.allowSelfSignedCertificates,
      );
      state = next;
    });
    _mutationQueue = mutation.catchError((Object _) {});
    return mutation;
  }
}

final deepseekConfigProvider =
    NotifierProvider<DeepSeekConfigController, DeepSeekConfig>(
      DeepSeekConfigController.new,
    );

/// Runs the liveness probe against the configured `dsh web` server root.
///
/// [build] watches the config: when the connection identity (scheme/host/
/// port) changes to a usable origin, a debounced auto-probe runs. The
/// settings page can also call [runProbe] directly (the Connect button) for
/// an immediate check.
class DeepSeekProbeController extends Notifier<DeepSeekProbeState> {
  static const Duration _autoProbeDebounce = Duration(milliseconds: 600);

  final DeepSeekProbeService _service = const DeepSeekProbeService();
  Timer? _autoProbeTimer;
  String? _probedOrigin;
  int _probeGeneration = 0;

  @override
  DeepSeekProbeState build() {
    ref.onDispose(() => _autoProbeTimer?.cancel());
    final config = ref.watch(deepseekConfigProvider);
    final origin = config.isUsable
        ? DeepSeekConfig.connectionOrigin(config.baseUrl)
        : null;
    _scheduleAutoProbe(origin);
    return const DeepSeekProbeState();
  }

  void _scheduleAutoProbe(String? origin) {
    _autoProbeTimer?.cancel();
    if (origin == null) {
      if (_probedOrigin != null) {
        _probedOrigin = null;
        state = const DeepSeekProbeState();
      }
      return;
    }
    if (origin == _probedOrigin) return;
    _autoProbeTimer = Timer(_autoProbeDebounce, () => unawaited(runProbe()));
  }

  /// Runs a probe against the current config right away and resolves with
  /// the settled result (null when the config is not usable). Concurrent
  /// runs are coordinated by generation so a stale result can never update
  /// state.
  Future<DeepSeekProbeResult?> runProbe() {
    _autoProbeTimer?.cancel();
    final config = ref.read(deepseekConfigProvider);
    final origin = config.isUsable
        ? DeepSeekConfig.connectionOrigin(config.baseUrl)
        : null;
    if (origin == null) {
      state = const DeepSeekProbeState();
      return Future<DeepSeekProbeResult?>.value();
    }
    final generation = ++_probeGeneration;
    state = const DeepSeekProbeState(status: DeepSeekProbeStatus.probing);
    return _service.probe(config).then((result) {
      if (generation != _probeGeneration) return result;
      _probedOrigin = origin;
      state =
          DeepSeekProbeState(status: result.status, lastResult: result);
      return result;
    });
  }
}

final deepseekProbeProvider =
    NotifierProvider<DeepSeekProbeController, DeepSeekProbeState>(
      DeepSeekProbeController.new,
    );
