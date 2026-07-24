import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/model.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../direct_connections/models/direct_connection_profile.dart';
import '../../direct_connections/models/ollama_thinking.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../hermes/models/hermes_model.dart';

part 'reasoning_effort_provider.g.dart';

const String kAutomaticReasoningEffort = 'automatic';
const List<String> kStandardReasoningEfforts = <String>[
  'low',
  'medium',
  'high',
];
const List<String> kReasoningEffortOptions = <String>[
  kAutomaticReasoningEffort,
  ...kStandardReasoningEfforts,
];

String normalizeReasoningEffort(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty || normalized.length > 64) {
    throw const FormatException('Reasoning effort must be 1 to 64 characters.');
  }
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(normalized)) {
    throw const FormatException(
      'Reasoning effort may contain letters, numbers, hyphens, and underscores.',
    );
  }
  return normalized;
}

@Riverpod(keepAlive: true)
class LocalReasoningEfforts extends _$LocalReasoningEfforts {
  @override
  Map<String, String> build() {
    final raw = PreferencesStore.getString(
      PreferenceKeys.reasoningEffortByModel,
    );
    if (raw == null || raw.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty || entry.value is! String) continue;
        try {
          result[key] = normalizeReasoningEffort(entry.value as String);
        } catch (_) {
          // Preserve other per-model preferences when one entry is corrupt.
        }
      }
      return Map<String, String>.unmodifiable(result);
    } catch (_) {
      return const <String, String>{};
    }
  }

  Future<void> set(String key, String? effort) async {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) return;
    final updated = Map<String, String>.of(state);
    if (effort == null) {
      updated.remove(normalizedKey);
    } else {
      updated[normalizedKey] = normalizeReasoningEffort(effort);
    }
    state = Map.unmodifiable(updated);
    await PreferencesStore.put(
      PreferenceKeys.reasoningEffortByModel,
      jsonEncode(updated),
    );
  }
}

String? _localEffortKey(Ref ref) {
  final model = ref.watch(selectedModelProvider);
  if (model == null) return null;
  if (isHermesModel(model)) return 'hermes:${model.id}';
  final binding = ref.watch(directModelRegistryProvider).resolve(model);
  if (binding != null) {
    return 'direct:${binding.profileId}:${binding.remoteModelId}';
  }
  return null;
}

final configuredReasoningEffortProvider = Provider<String?>((ref) {
  final model = ref.watch(selectedModelProvider);
  if (model == null) return null;
  final binding = ref.watch(directModelRegistryProvider).resolve(model);
  if (binding != null) {
    if (binding.adapterKey == kOllamaAdapterKey) {
      final profiles = ref.watch(directConnectionProfilesProvider);
      if (!profiles.hasValue) return null;
      final profile = profiles.requireValue
          .where((candidate) => candidate.id == binding.profileId)
          .firstOrNull;
      return profile?.ollamaThinkingFor(binding.remoteModelId)?.storageValue;
    }
  }

  final localKey = _localEffortKey(ref);
  if (localKey != null) {
    return ref.watch(localReasoningEffortsProvider)[localKey];
  }

  if (ref.watch(apiServiceProvider) != null) {
    return ref
        .watch(personalizationSettingsProvider)
        .asData
        ?.value
        .reasoningEffort;
  }
  return null;
});

final reasoningEffortProvider = Provider<String>(
  (ref) =>
      ref.watch(configuredReasoningEffortProvider) ?? kAutomaticReasoningEffort,
);

final reasoningEffortAllowsCustomProvider = Provider<bool>((ref) {
  final model = ref.watch(selectedModelProvider);
  if (model == null) return true;
  final binding = ref.watch(directModelRegistryProvider).resolve(model);
  if (binding == null) return true;
  return binding.adapterKey != kOllamaAdapterKey;
});

typedef ReasoningEffortReader = T Function<T>(ProviderListenable<T> provider);

String reasoningEffortForModel(ReasoningEffortReader read, Model? model) {
  if (model == null) return kAutomaticReasoningEffort;
  final binding = read(directModelRegistryProvider).resolve(model);
  if (binding != null) {
    if (binding.adapterKey == kOllamaAdapterKey) {
      final profile = _readDirectProfile(read, binding.profileId);
      return profile?.ollamaThinkingFor(binding.remoteModelId)?.storageValue ??
          kAutomaticReasoningEffort;
    }
    return read(
          localReasoningEffortsProvider,
        )['direct:${binding.profileId}:${binding.remoteModelId}'] ??
        kAutomaticReasoningEffort;
  }
  if (isHermesModel(model)) {
    return read(localReasoningEffortsProvider)['hermes:${model.id}'] ??
        kAutomaticReasoningEffort;
  }
  if (read(apiServiceProvider) != null) {
    return read(
          personalizationSettingsProvider,
        ).asData?.value.reasoningEffort ??
        kAutomaticReasoningEffort;
  }
  return kAutomaticReasoningEffort;
}

bool reasoningEffortAllowsCustomForModel(
  ReasoningEffortReader read,
  Model? model,
) {
  if (model == null) return true;
  final binding = read(directModelRegistryProvider).resolve(model);
  if (binding == null) return true;
  return binding.adapterKey != kOllamaAdapterKey;
}

Future<void> setReasoningEffort(
  ReasoningEffortReader read,
  String effort,
) async {
  final model = read(selectedModelProvider);
  if (model == null) return;
  await setReasoningEffortForModel(read, model, effort);
}

Future<void> setReasoningEffortForModel(
  ReasoningEffortReader read,
  Model model,
  String effort,
) async {
  final normalized = normalizeReasoningEffort(effort);
  final configured = normalized == kAutomaticReasoningEffort
      ? null
      : normalized;
  final binding = read(directModelRegistryProvider).resolve(model);
  if (binding != null) {
    if (binding.adapterKey == kOllamaAdapterKey) {
      late final List<DirectConnectionProfile> profiles;
      try {
        profiles = await read(directConnectionProfilesProvider.future);
      } catch (_) {
        return;
      }
      final profile = profiles
          .where(
            (candidate) =>
                candidate.id == binding.profileId &&
                candidate.enabled &&
                candidate.adapterKey == kOllamaAdapterKey,
          )
          .firstOrNull;
      if (profile == null) return;
      await read(directConnectionProfilesProvider.notifier).setOllamaThinking(
        binding.profileId,
        binding.remoteModelId,
        configured == null
            ? null
            : OllamaThinkingSetting.fromStorage(configured),
      );
      return;
    }
    await read(
      localReasoningEffortsProvider.notifier,
    ).set('direct:${binding.profileId}:${binding.remoteModelId}', configured);
    return;
  }
  if (isHermesModel(model)) {
    await read(
      localReasoningEffortsProvider.notifier,
    ).set('hermes:${model.id}', configured);
    return;
  }
  if (read(apiServiceProvider) != null) {
    await read(
      personalizationSettingsProvider.notifier,
    ).setReasoningEffort(configured);
  }
}

DirectConnectionProfile? _readDirectProfile(
  ReasoningEffortReader read,
  String profileId,
) {
  final profiles =
      read(directConnectionProfilesProvider).value ??
      const <DirectConnectionProfile>[];
  for (final profile in profiles) {
    if (profile.id == profileId) return profile;
  }
  return null;
}
