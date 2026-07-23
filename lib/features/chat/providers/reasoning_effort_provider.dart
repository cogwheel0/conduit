import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../direct_connections/models/direct_connection_profile.dart';
import '../../direct_connections/models/ollama_thinking.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../hermes/models/hermes_model.dart';

const String kDefaultReasoningEffort = 'medium';
const List<String> kStandardReasoningEfforts = <String>[
  'low',
  'medium',
  'high',
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

class LocalReasoningEffortsController extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    final raw = PreferencesStore.getString(
      PreferenceKeys.reasoningEffortByModel,
    );
    if (raw == null || raw.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      return Map<String, String>.unmodifiable({
        for (final entry in decoded.entries)
          if (entry.key.toString().trim().isNotEmpty && entry.value is String)
            entry.key.toString(): normalizeReasoningEffort(
              entry.value as String,
            ),
      });
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

final localReasoningEffortsProvider =
    NotifierProvider<LocalReasoningEffortsController, Map<String, String>>(
      LocalReasoningEffortsController.new,
    );

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
    final profiles =
        ref.watch(directConnectionProfilesProvider).value ??
        const <DirectConnectionProfile>[];
    final profile = profiles
        .where((candidate) => candidate.id == binding.profileId)
        .firstOrNull;
    if (profile?.adapterKey == kOllamaAdapterKey) {
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
      ref.watch(configuredReasoningEffortProvider) ?? kDefaultReasoningEffort,
);

final reasoningEffortAllowsCustomProvider = Provider<bool>((ref) {
  final model = ref.watch(selectedModelProvider);
  if (model == null) return true;
  final binding = ref.watch(directModelRegistryProvider).resolve(model);
  if (binding == null) return true;
  final profiles =
      ref.watch(directConnectionProfilesProvider).value ??
      const <DirectConnectionProfile>[];
  final profile = profiles
      .where((candidate) => candidate.id == binding.profileId)
      .firstOrNull;
  return profile?.adapterKey != kOllamaAdapterKey;
});

Future<void> setReasoningEffort(dynamic ref, String effort) async {
  final normalized = normalizeReasoningEffort(effort);
  final model = ref.read(selectedModelProvider);
  if (model == null) return;
  final binding = ref.read(directModelRegistryProvider).resolve(model);
  if (binding != null) {
    final profiles =
        ref.read(directConnectionProfilesProvider).value ??
        const <DirectConnectionProfile>[];
    final profile = profiles
        .where((candidate) => candidate.id == binding.profileId)
        .firstOrNull;
    if (profile?.adapterKey == kOllamaAdapterKey) {
      await ref
          .read(directConnectionProfilesProvider.notifier)
          .setOllamaThinking(
            binding.profileId,
            binding.remoteModelId,
            OllamaThinkingSetting.fromStorage(normalized),
          );
      return;
    }
    await ref
        .read(localReasoningEffortsProvider.notifier)
        .set(
          'direct:${binding.profileId}:${binding.remoteModelId}',
          normalized,
        );
    return;
  }
  if (isHermesModel(model)) {
    await ref
        .read(localReasoningEffortsProvider.notifier)
        .set('hermes:${model.id}', normalized);
    return;
  }
  if (ref.read(apiServiceProvider) != null) {
    await ref
        .read(personalizationSettingsProvider.notifier)
        .setReasoningEffort(normalized);
  }
}
