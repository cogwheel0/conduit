import 'hermes_model.dart';

/// Selects recommendations from the gateway's catalog without adding models or
/// claiming that catalog presence verifies account access. The caller keeps its
/// selected model visible separately, including an older selected model.
///
/// A provider's live recommended default or explicit catalog hints take
/// precedence over the small documented fallback below. No match returns an
/// empty list so the picker can show all models without an endorsement.
List<HermesDesktopModelOption> hermesRecommendedModels(
  Iterable<HermesDesktopModelOption> options, {
  Map<String, String> providerRecommendedDefaults = const {},
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final catalog = options.toList(growable: false);
  final providersWithHints = <String>{
    for (final option in catalog)
      if (option.recommended != null ||
          option.isDefault == true ||
          option.popular == true ||
          option.recommendationRank != null)
        option.provider,
  };
  final indices = {for (var i = 0; i < catalog.length; i++) catalog[i]: i};
  final selected = catalog.where((option) {
    if (option.recommended == false ||
        option.deprecated == true ||
        option.isRetiredAt(clock) ||
        option.shutdownAt != null) {
      return false;
    }
    final preferred = providerRecommendedDefaults[option.provider];
    if (preferred != null && preferred.trim().isNotEmpty) {
      return option.id == preferred;
    }
    if (providersWithHints.contains(option.provider)) {
      return option.recommended == true ||
          option.isDefault == true ||
          option.popular == true ||
          option.recommendationRank != null;
    }
    return _isCuratedRecommendation(option);
  }).toList();
  selected.sort((a, b) {
    final rank = (a.recommendationRank ?? double.infinity).compareTo(
      b.recommendationRank ?? double.infinity,
    );
    if (rank != 0) return rank;
    final defaults = (b.isDefault == true ? 1 : 0).compareTo(
      a.isDefault == true ? 1 : 0,
    );
    return defaults != 0 ? defaults : indices[a]!.compareTo(indices[b]!);
  });
  return selected;
}

// Recommendation policy, not catalog inventory. Verified 2026-10-11 against:
// https://developers.openai.com/api/docs/guides/model-selection
// https://platform.claude.com/docs/en/models/overview
// https://ai.google.dev/gemini-api/docs/models
// Only exact IDs returned by a configured gateway can match this policy.
const _currentOpenAiModels = {'gpt-6.1-sol', 'gpt-6-astra', 'gpt-6-luna'};
const _currentClaudeModels = {
  'claude-fable-5-1',
  'claude-opus-5-5',
  'claude-sonnet-5-5',
  'claude-haiku-5-5',
};
const _currentGeminiModels = {'gemini-3.8-flash', 'gemini-3.5-flash-lite'};

bool _isCuratedRecommendation(HermesDesktopModelOption option) {
  final provider = option.provider.toLowerCase();
  final id = option.id.toLowerCase();
  return switch (provider) {
    'openai' ||
    'openai-codex' ||
    'codex' ||
    'copilot' ||
    'github-copilot' ||
    'azure' ||
    'azure-foundry' => _currentOpenAiModels.contains(id),
    'anthropic' || 'claude' => _currentClaudeModels.contains(id),
    'google' || 'gemini' || 'google-gemini' => _currentGeminiModels.contains(
      id.startsWith('models/') ? id.substring('models/'.length) : id,
    ),
    'openrouter' =>
      (id.startsWith('openai/') &&
              _currentOpenAiModels.contains(id.substring('openai/'.length))) ||
          (id.startsWith('anthropic/') &&
              _currentClaudeModels.contains(
                id.substring('anthropic/'.length),
              )) ||
          (id.startsWith('google/') &&
              _currentGeminiModels.contains(id.substring('google/'.length))),
    _ => false,
  };
}
