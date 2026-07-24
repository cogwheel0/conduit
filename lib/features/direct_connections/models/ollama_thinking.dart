enum OllamaThinkingSetting {
  disabled('disabled'),
  low('low'),
  medium('medium'),
  high('high');

  const OllamaThinkingSetting(this.storageValue);

  final String storageValue;

  Object get apiValue => this == disabled ? false : storageValue;

  static OllamaThinkingSetting fromStorage(String value) {
    final normalized = value.trim().toLowerCase();
    return values.firstWhere(
      (candidate) => candidate.storageValue == normalized,
      orElse: () =>
          throw const FormatException('Ollama thinking setting is invalid.'),
    );
  }
}

Map<String, String> normalizeOllamaThinkingByModel(Map<String, String> values) {
  if (values.length > 1000) {
    throw const FormatException('Too many Ollama thinking settings.');
  }
  final normalized = <String, String>{};
  for (final entry in values.entries) {
    final modelId = entry.key.trim();
    if (modelId.isEmpty ||
        modelId.length > 512 ||
        modelId.contains('\r') ||
        modelId.contains('\n') ||
        modelId.contains('\u0000')) {
      throw const FormatException('Ollama model id is invalid.');
    }
    normalized[modelId] = OllamaThinkingSetting.fromStorage(
      entry.value,
    ).storageValue;
  }
  return normalized;
}
