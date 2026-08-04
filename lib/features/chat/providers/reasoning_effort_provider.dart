import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/models/model.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../direct_connections/models/direct_connection_profile.dart';
import '../../direct_connections/models/ollama_thinking.dart';
import '../../direct_connections/models/openrouter_reasoning.dart';
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

final class ReasoningEffortPolicy {
  const ReasoningEffortPolicy({
    required this.visible,
    required this.options,
    required this.allowsCustom,
    this.restrictsValues = false,
  });

  static const generic = ReasoningEffortPolicy(
    visible: true,
    options: kReasoningEffortOptions,
    allowsCustom: true,
  );

  static const unsupported = ReasoningEffortPolicy(
    visible: false,
    options: <String>[],
    allowsCustom: false,
    restrictsValues: true,
  );

  final bool visible;
  final List<String> options;
  final bool allowsCustom;
  final bool restrictsValues;

  String? effectiveConfiguredEffort(String? configured) {
    if (configured == null || configured == kAutomaticReasoningEffort) {
      return null;
    }
    if (!restrictsValues) return configured;
    return options.contains(configured) ? configured : null;
  }

  bool accepts(String effort) =>
      effort == kAutomaticReasoningEffort ||
      !restrictsValues ||
      options.contains(effort);
}

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

String? modelConfiguredReasoningEffort(Model? model) {
  final metadata = model?.metadata;
  if (metadata == null) return null;

  final info = metadata['info'];
  return _reasoningEffortFromParams(<Object?>[
    if (info is Map) info['params'],
    metadata['params'],
  ]);
}

String? _reasoningEffortFromParams(Iterable<Object?> candidates) {
  for (final candidate in candidates) {
    if (candidate is! Map) continue;
    final rawEffort = candidate['reasoning_effort'];
    if (rawEffort is! String) continue;
    try {
      return normalizeReasoningEffort(rawEffort);
    } on FormatException {
      // Ignore malformed server metadata and continue to the user preference.
    }
  }
  return null;
}

bool _isOpenWebUiWorkspaceModel(Model model) {
  final info = model.metadata?['info'];
  if (info is! Map) return false;
  return info['id']?.toString() == model.id &&
      (info.containsKey('user_id') || info.containsKey('base_model_id'));
}

/// Loads private workspace-model parameters that OpenWebUI intentionally omits
/// from `/api/models`. The detail route returns them only to callers with write
/// access; read-only callers receive an empty params map.
@riverpod
Future<String?> serverModelReasoningEffort(Ref ref, Model model) async {
  if (!_isOpenWebUiWorkspaceModel(model)) return null;
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;
  final details = await api.getModelDetails(model.id);
  return _reasoningEffortFromParams(<Object?>[details?['params']]);
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
    return ref
        .watch(reasoningEffortPolicyProvider)
        .effectiveConfiguredEffort(
          ref.watch(localReasoningEffortsProvider)[localKey],
        );
  }

  String? detailedModelEffort;
  if (_isOpenWebUiWorkspaceModel(model)) {
    final detailedEffort = ref.watch(serverModelReasoningEffortProvider(model));
    // Until OpenWebUI returns the private workspace params, do not let a
    // user-level fallback override the model's server-side configuration.
    if (detailedEffort.isLoading) return null;
    detailedModelEffort = detailedEffort.asData?.value;
  }
  final modelEffort =
      detailedModelEffort ?? modelConfiguredReasoningEffort(model);
  if (modelEffort != null) {
    return reasoningEffortPolicyForModel(
      ref.watch,
      model,
    ).effectiveConfiguredEffort(modelEffort);
  }

  if (ref.watch(apiServiceProvider) != null) {
    final configured = ref
        .watch(personalizationSettingsProvider)
        .asData
        ?.value
        .reasoningEffort;
    return reasoningEffortPolicyForModel(
      ref.watch,
      model,
    ).effectiveConfiguredEffort(configured);
  }
  return null;
});

final reasoningEffortProvider = Provider<String>(
  (ref) =>
      ref.watch(configuredReasoningEffortProvider) ?? kAutomaticReasoningEffort,
);

final reasoningEffortPolicyProvider = Provider<ReasoningEffortPolicy>((ref) {
  final model = ref.watch(selectedModelProvider);
  return reasoningEffortPolicyForModel(ref.watch, model);
});

final reasoningEffortAllowsCustomProvider = Provider<bool>((ref) {
  return ref.watch(reasoningEffortPolicyProvider).allowsCustom;
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
    final configured = read(
      localReasoningEffortsProvider,
    )['direct:${binding.profileId}:${binding.remoteModelId}'];
    return reasoningEffortPolicyForModel(
          read,
          model,
        ).effectiveConfiguredEffort(configured) ??
        kAutomaticReasoningEffort;
  }
  if (isHermesModel(model)) {
    return read(localReasoningEffortsProvider)['hermes:${model.id}'] ??
        kAutomaticReasoningEffort;
  }
  String? detailedModelEffort;
  if (_isOpenWebUiWorkspaceModel(model)) {
    final detailedEffort = read(serverModelReasoningEffortProvider(model));
    if (detailedEffort.isLoading) return kAutomaticReasoningEffort;
    detailedModelEffort = detailedEffort.asData?.value;
  }
  final modelEffort =
      detailedModelEffort ?? modelConfiguredReasoningEffort(model);
  final policy = reasoningEffortPolicyForModel(read, model);
  if (modelEffort != null) {
    return policy.effectiveConfiguredEffort(modelEffort) ??
        kAutomaticReasoningEffort;
  }
  if (read(apiServiceProvider) != null) {
    final configured = read(
      personalizationSettingsProvider,
    ).asData?.value.reasoningEffort;
    return policy.effectiveConfiguredEffort(configured) ??
        kAutomaticReasoningEffort;
  }
  return kAutomaticReasoningEffort;
}

bool reasoningEffortAllowsCustomForModel(
  ReasoningEffortReader read,
  Model? model,
) => reasoningEffortPolicyForModel(read, model).allowsCustom;

ReasoningEffortPolicy reasoningEffortPolicyForModel(
  ReasoningEffortReader read,
  Model? model,
) {
  if (model == null) {
    return const ReasoningEffortPolicy(
      visible: false,
      options: <String>[],
      allowsCustom: false,
    );
  }
  if (isHermesModel(model)) return ReasoningEffortPolicy.generic;
  final binding = read(directModelRegistryProvider).resolve(model);
  if (binding == null) {
    final detailedModelEffort = _isOpenWebUiWorkspaceModel(model)
        ? read(serverModelReasoningEffortProvider(model)).asData?.value
        : null;
    return model.supportsReasoningEffort || detailedModelEffort != null
        ? ReasoningEffortPolicy.generic
        : ReasoningEffortPolicy.unsupported;
  }
  if (binding.adapterKey == kOllamaAdapterKey) {
    return const ReasoningEffortPolicy(
      visible: true,
      options: kReasoningEffortOptions,
      allowsCustom: false,
      restrictsValues: true,
    );
  }
  if (model.capabilities?['openrouter'] != true) {
    return ReasoningEffortPolicy.generic;
  }
  final support = OpenRouterReasoningSupport.tryParseCatalog(
    model.capabilities?['reasoning'],
  );
  final efforts = support?.selectableEfforts ?? const <String>[];
  return ReasoningEffortPolicy(
    visible: efforts.isNotEmpty,
    options: List<String>.unmodifiable(<String>[
      if (efforts.isNotEmpty) kAutomaticReasoningEffort,
      ...efforts,
    ]),
    allowsCustom: false,
    restrictsValues: true,
  );
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
  final policy = reasoningEffortPolicyForModel(read, model);
  if (!policy.accepts(normalized)) {
    throw const FormatException(
      'This model does not support that reasoning effort.',
    );
  }
  final configured = normalized == kAutomaticReasoningEffort
      ? null
      : normalized;
  final binding = read(directModelRegistryProvider).resolve(model);
  if (binding != null) {
    if (binding.adapterKey == kOllamaAdapterKey) {
      final profiles = await read(directConnectionProfilesProvider.future);
      final profile = profiles
          .where(
            (candidate) =>
                candidate.id == binding.profileId &&
                candidate.enabled &&
                candidate.adapterKey == kOllamaAdapterKey,
          )
          .firstOrNull;
      if (profile == null) {
        throw StateError('Ollama connection is unavailable.');
      }
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
