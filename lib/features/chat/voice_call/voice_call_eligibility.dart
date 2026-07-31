import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../direct_connections/services/direct_model_registry.dart';
import '../../hermes/models/hermes_model.dart';
import '../../hermes/providers/hermes_providers.dart';

enum VoiceCallEligibilityReason {
  eligible,
  modelRequired,
  backendInitializing,
  authenticationRequired,
  backendUnavailable,
}

@immutable
class VoiceCallEligibility {
  const VoiceCallEligibility._({
    required this.reason,
    required this.model,
    this.errorMessage,
  });

  const VoiceCallEligibility.eligible(Model model)
    : this._(reason: VoiceCallEligibilityReason.eligible, model: model);

  const VoiceCallEligibility.blocked({
    required VoiceCallEligibilityReason reason,
    required String errorMessage,
    Model? model,
  }) : this._(reason: reason, model: model, errorMessage: errorMessage);

  final VoiceCallEligibilityReason reason;
  final Model? model;
  final String? errorMessage;

  bool get canStart => reason == VoiceCallEligibilityReason.eligible;
}

final class VoiceCallEligibilityResolutionCancelled implements Exception {
  const VoiceCallEligibilityResolutionCancelled();
}

/// Resolves voice eligibility from the selected model's trusted transport.
///
/// OpenWebUI models still require an authenticated session. Hermes and
/// device-owned Direct models use app-owned transports and are admitted from
/// their concrete runtime provenance instead of OpenWebUI navigation state.
final voiceCallEligibilityProvider = Provider<VoiceCallEligibility>((ref) {
  final model = ref.watch(selectedModelProvider);
  if (model == null) {
    return const VoiceCallEligibility.blocked(
      reason: VoiceCallEligibilityReason.modelRequired,
      errorMessage: 'Choose a model before starting a voice call.',
    );
  }

  if (ref.watch(reviewerModeProvider)) {
    return VoiceCallEligibility.eligible(model);
  }

  if (isHermesModel(model)) {
    if (ref.watch(hermesSecretsLoadingProvider)) {
      return VoiceCallEligibility.blocked(
        reason: VoiceCallEligibilityReason.backendInitializing,
        model: model,
        errorMessage: 'Hermes is still loading. Try again in a moment.',
      );
    }
    if (ref.watch(hermesConfigProvider).isUsable) {
      return VoiceCallEligibility.eligible(model);
    }
    return VoiceCallEligibility.blocked(
      reason: VoiceCallEligibilityReason.backendUnavailable,
      model: model,
      errorMessage: 'Hermes is unavailable. Check its server URL and API key.',
    );
  }

  if (isLocallyMintedDirectModel(model)) {
    // The registry mutates in place. Discovery is its reactive invalidation
    // signal when a profile is replaced, disabled, or removed.
    ref.watch(directModelDiscoveryProvider);
    final binding = ref.watch(directModelRegistryProvider).resolve(model);
    if (binding == null) {
      return VoiceCallEligibility.blocked(
        reason: VoiceCallEligibilityReason.backendUnavailable,
        model: model,
        errorMessage: 'The selected direct connection is unavailable.',
      );
    }
    if (binding.source == DirectModelSource.device) {
      return VoiceCallEligibility.eligible(model);
    }
  }

  if (ref.watch(authNavigationStateProvider) ==
      AuthNavigationState.authenticated) {
    return VoiceCallEligibility.eligible(model);
  }

  return VoiceCallEligibility.blocked(
    reason: VoiceCallEligibilityReason.authenticationRequired,
    model: model,
    errorMessage: 'Sign in to start a voice call.',
  );
});

/// Resolves transient startup state before returning the current admission
/// decision. Native entry points can arrive before secure storage, auth, or
/// default-model selection has finished hydrating.
Future<VoiceCallEligibility> resolveVoiceCallEligibility(
  Ref ref, {
  Duration readinessTimeout = const Duration(seconds: 3),
  Future<void>? cancellationSignal,
  bool Function()? cancellationRequested,
}) async {
  final deadline = DateTime.now().add(readinessTimeout);
  final cancellation = _VoiceCallEligibilityCancellation(
    signal: cancellationSignal,
    requested: cancellationRequested,
  );

  while (true) {
    cancellation.throwIfRequested();
    if (_voiceCallNeedsHermesHydration(ref)) {
      final changed = await _waitForHermesStateChange(
        ref,
        deadline,
        cancellation,
      );
      cancellation.throwIfRequested();
      if (!changed && _voiceCallNeedsHermesHydration(ref)) {
        return const VoiceCallEligibility.blocked(
          reason: VoiceCallEligibilityReason.backendInitializing,
          errorMessage: 'Hermes is still loading. Try again in a moment.',
        );
      }
      // Re-evaluate selection as well as hydration. The user may have changed
      // backends while native startup was waiting.
      continue;
    }

    final model = ref.read(selectedModelProvider);
    final preferredBackend = ref.read(preferredBackendProvider);
    if (model == null && preferredBackend == PreferredBackend.hermes) {
      if (!ref.read(hermesConfigProvider).isUsable) {
        return const VoiceCallEligibility.blocked(
          reason: VoiceCallEligibilityReason.backendUnavailable,
          errorMessage:
              'Hermes is unavailable. Check its server URL and API key.',
        );
      }
      if (_remainingReadinessTime(deadline) == Duration.zero) {
        return ref.read(voiceCallEligibilityProvider);
      }
      // Hermes selection is independent from optional OpenWebUI auth. Restore
      // it directly so a slow OWUI secure-storage read cannot block a valid
      // Hermes-only native launch.
      await cancellation.wait(Future<void>.delayed(Duration.zero));
      cancellation.throwIfRequested();
      if (_remainingReadinessTime(deadline) == Duration.zero) {
        return ref.read(voiceCallEligibilityProvider);
      }
      if (ref.read(selectedModelProvider) == null &&
          ref.read(preferredBackendProvider) == PreferredBackend.hermes &&
          ref.read(hermesConfigProvider).isUsable) {
        ref.read(isManualModelSelectionProvider.notifier).set(false);
        ref.read(selectedModelProvider.notifier).set(hermesSyntheticModel());
      }
      if (ref.read(selectedModelProvider) == null &&
          ref.read(preferredBackendProvider) == PreferredBackend.hermes &&
          ref.read(hermesConfigProvider).isUsable) {
        return ref.read(voiceCallEligibilityProvider);
      }
      continue;
    }
    if (model == null && preferredBackend == PreferredBackend.direct) {
      final restored = await _restorePreferredDeviceDirectModel(
        ref,
        deadline,
        cancellation,
      );
      cancellation.throwIfRequested();
      if (restored) continue;
    }

    if (ref.read(authNavigationStateProvider) == AuthNavigationState.loading &&
        !voiceCallCanResolveWithoutOpenWebUiAuth(ref)) {
      final changed = await _waitForOpenWebUiStateChange(
        ref,
        deadline,
        cancellation,
      );
      cancellation.throwIfRequested();
      if (changed) continue;
      return ref.read(voiceCallEligibilityProvider);
    }

    await _resolveDefaultModelIfNeeded(ref, deadline, cancellation);
    cancellation.throwIfRequested();
    final eligibility = ref.read(voiceCallEligibilityProvider);
    if (eligibility.canStart ||
        ref.read(authNavigationStateProvider) != AuthNavigationState.loading ||
        voiceCallCanResolveWithoutOpenWebUiAuth(ref)) {
      return eligibility;
    }

    final changed = await _waitForOpenWebUiStateChange(
      ref,
      deadline,
      cancellation,
    );
    cancellation.throwIfRequested();
    if (!changed) return ref.read(voiceCallEligibilityProvider);
  }
}

/// Whether the current voice launch can become ready without OpenWebUI auth.
///
/// This is also used by cold-start quick actions so accountless transports can
/// proceed while an unrelated OpenWebUI session is still hydrating.
bool voiceCallCanResolveWithoutOpenWebUiAuth(Ref ref) {
  if (ref.read(reviewerModeProvider)) return true;

  final model = ref.read(selectedModelProvider);
  if (model == null) {
    final preferredBackend = ref.read(preferredBackendProvider);
    if (preferredBackend == PreferredBackend.hermes) return true;
    if (preferredBackend != PreferredBackend.direct) return false;

    final discovery = ref.read(directModelDiscoveryProvider);
    if (discovery.isLoading && !discovery.hasValue) return true;
    final registry = ref.read(directModelRegistryProvider);
    return discovery.value?.models.any((candidate) {
          if (candidate.isHidden) return false;
          return registry.resolve(candidate)?.source ==
              DirectModelSource.device;
        }) ??
        false;
  }
  if (isHermesModel(model)) return true;
  if (!isLocallyMintedDirectModel(model)) return false;

  final binding = ref.read(directModelRegistryProvider).resolve(model);
  return binding?.source == DirectModelSource.device;
}

bool _voiceCallNeedsHermesHydration(Ref ref) {
  if (!ref.read(hermesSecretsLoadingProvider)) return false;
  final model = ref.read(selectedModelProvider);
  return model != null
      ? isHermesModel(model)
      : ref.read(preferredBackendProvider) == PreferredBackend.hermes;
}

Duration _remainingReadinessTime(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining.isNegative ? Duration.zero : remaining;
}

Future<void> _resolveDefaultModelIfNeeded(
  Ref ref,
  DateTime deadline,
  _VoiceCallEligibilityCancellation cancellation,
) async {
  cancellation.throwIfRequested();
  if (ref.read(selectedModelProvider) != null) return;
  final remaining = _remainingReadinessTime(deadline);
  if (remaining == Duration.zero) return;
  try {
    await cancellation.wait(
      ref
          .read(defaultModelProvider.future)
          .timeout(remaining, onTimeout: () => null),
    );
  } on VoiceCallEligibilityResolutionCancelled {
    rethrow;
  } catch (_) {
    // The eligibility result below provides the user-facing failure.
  }
}

Future<bool> _restorePreferredDeviceDirectModel(
  Ref ref,
  DateTime deadline,
  _VoiceCallEligibilityCancellation cancellation,
) async {
  cancellation.throwIfRequested();
  final remaining = _remainingReadinessTime(deadline);
  if (remaining == Duration.zero) return false;

  DirectModelDiscoveryState discovery;
  try {
    discovery = await cancellation.wait(
      ref.read(directModelDiscoveryProvider.future).timeout(remaining),
    );
  } on VoiceCallEligibilityResolutionCancelled {
    rethrow;
  } catch (_) {
    return false;
  }

  cancellation.throwIfRequested();
  final registry = ref.read(directModelRegistryProvider);
  final candidates = discovery.models
      .where((candidate) {
        if (candidate.isHidden) return false;
        return registry.resolve(candidate)?.source == DirectModelSource.device;
      })
      .toList(growable: false);
  if (candidates.isEmpty) return false;

  final configuredId = ref.read(appSettingsProvider).defaultModel;
  final selected = candidates.firstWhere(
    (candidate) => candidate.id == configuredId,
    orElse: () => candidates.first,
  );
  await cancellation.wait(Future<void>.delayed(Duration.zero));
  cancellation.throwIfRequested();
  if (ref.read(selectedModelProvider) != null ||
      ref.read(preferredBackendProvider) != PreferredBackend.direct ||
      ref.read(directModelRegistryProvider).resolve(selected)?.source !=
          DirectModelSource.device) {
    return false;
  }
  ref.read(isManualModelSelectionProvider.notifier).set(false);
  ref.read(selectedModelProvider.notifier).set(selected);
  return ref.read(selectedModelProvider)?.id == selected.id;
}

Future<bool> _waitForHermesStateChange(
  Ref ref,
  DateTime deadline,
  _VoiceCallEligibilityCancellation cancellation,
) async {
  cancellation.throwIfRequested();
  if (!_voiceCallNeedsHermesHydration(ref)) return true;

  final completer = Completer<bool>();
  void completeOnChange(Object? previous, Object? next) {
    if (!completer.isCompleted) completer.complete(true);
  }

  final subscriptions = <ProviderSubscription<Object?>>[
    ref.listen<bool>(hermesSecretsLoadingProvider, completeOnChange),
    ref.listen<Model?>(selectedModelProvider, completeOnChange),
    ref.listen<PreferredBackend>(preferredBackendProvider, completeOnChange),
  ];
  final timer = Timer(_remainingReadinessTime(deadline), () {
    if (!completer.isCompleted) completer.complete(false);
  });
  if (!_voiceCallNeedsHermesHydration(ref) && !completer.isCompleted) {
    completer.complete(true);
  }

  try {
    return await cancellation.wait(completer.future);
  } finally {
    timer.cancel();
    for (final subscription in subscriptions) {
      subscription.close();
    }
  }
}

Future<bool> _waitForOpenWebUiStateChange(
  Ref ref,
  DateTime deadline,
  _VoiceCallEligibilityCancellation cancellation,
) async {
  cancellation.throwIfRequested();
  if (ref.read(authNavigationStateProvider) != AuthNavigationState.loading ||
      voiceCallCanResolveWithoutOpenWebUiAuth(ref)) {
    return true;
  }

  final completer = Completer<bool>();
  void completeOnChange(Object? previous, Object? next) {
    if (!completer.isCompleted) completer.complete(true);
  }

  final subscriptions = <ProviderSubscription<Object?>>[
    ref.listen<AuthNavigationState>(
      authNavigationStateProvider,
      completeOnChange,
    ),
    ref.listen<Model?>(selectedModelProvider, completeOnChange),
    ref.listen<PreferredBackend>(preferredBackendProvider, completeOnChange),
  ];
  final timer = Timer(_remainingReadinessTime(deadline), () {
    if (!completer.isCompleted) completer.complete(false);
  });
  if ((ref.read(authNavigationStateProvider) != AuthNavigationState.loading ||
          voiceCallCanResolveWithoutOpenWebUiAuth(ref)) &&
      !completer.isCompleted) {
    completer.complete(true);
  }

  try {
    return await cancellation.wait(completer.future);
  } finally {
    timer.cancel();
    for (final subscription in subscriptions) {
      subscription.close();
    }
  }
}

final class _VoiceCallEligibilityCancellation {
  const _VoiceCallEligibilityCancellation({this.signal, this.requested});

  final Future<void>? signal;
  final bool Function()? requested;

  void throwIfRequested() {
    if (requested?.call() ?? false) {
      throw const VoiceCallEligibilityResolutionCancelled();
    }
  }

  Future<T> wait<T>(Future<T> operation) async {
    throwIfRequested();
    final cancellationSignal = signal;
    if (cancellationSignal == null) return operation;
    return Future.any<T>([
      operation,
      cancellationSignal.then<T>(
        (_) => throw const VoiceCallEligibilityResolutionCancelled(),
      ),
    ]);
  }
}
