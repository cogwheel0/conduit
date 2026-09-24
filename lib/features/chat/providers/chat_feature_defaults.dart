part of 'chat_providers.dart';

typedef _ChatFeatureDefaults = ({
  bool webSearchEnabled,
  bool imageGenerationEnabled,
});

Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

Iterable<String> _stringList(dynamic value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.map((item) => item.toString());
}

bool _isAlwaysOnChatFeatureSetting(
  Map<String, dynamic>? userSettings, {
  required String uiKey,
  required String legacyKey,
}) {
  final uiMap = _asStringDynamicMap(userSettings?['ui']);
  final raw = uiMap?[uiKey] ?? userSettings?[legacyKey];

  if (raw is bool) {
    return raw;
  }
  if (raw is num) {
    return raw != 0;
  }
  if (raw is String) {
    switch (raw.toLowerCase()) {
      case 'always':
      case 'enabled':
      case 'on':
      case 'true':
      case '1':
        return true;
      default:
        return false;
    }
  }
  return false;
}

Set<String> _extractModelDefaultFeatureIds(Model? model) {
  final metadata = model?.metadata;
  final rootMeta = _asStringDynamicMap(metadata?['meta']);
  final infoMeta = _asStringDynamicMap(
    _asStringDynamicMap(metadata?['info'])?['meta'],
  );
  final defaultFeatureIds = <String>{};

  for (final candidate in <dynamic>[
    metadata?['defaultFeatureIds'],
    metadata?['default_feature_ids'],
    rootMeta?['defaultFeatureIds'],
    rootMeta?['default_feature_ids'],
    infoMeta?['defaultFeatureIds'],
    infoMeta?['default_feature_ids'],
  ]) {
    defaultFeatureIds.addAll(_stringList(candidate));
  }

  return defaultFeatureIds;
}

_ChatFeatureDefaults _resolveChatFeatureDefaults({
  required AppSettings appSettings,
  required Map<String, dynamic>? userSettings,
  required Model? model,
}) {
  final defaultFeatureIds = _extractModelDefaultFeatureIds(model);
  final webSearchDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'webSearch',
        legacyKey: 'webSearchEnabled',
      ) ||
      defaultFeatureIds.contains('web_search');
  final imageGenerationDefault =
      _isAlwaysOnChatFeatureSetting(
        userSettings,
        uiKey: 'imageGeneration',
        legacyKey: 'imageGenerationEnabled',
      ) ||
      defaultFeatureIds.contains('image_generation');

  return (
    webSearchEnabled: appSettings.chatWebSearchEnabled ?? webSearchDefault,
    imageGenerationEnabled:
        appSettings.chatImageGenerationEnabled ?? imageGenerationDefault,
  );
}

@visibleForTesting
({bool webSearchEnabled, bool imageGenerationEnabled})
resolveChatFeatureDefaultsForTest({
  required AppSettings appSettings,
  Map<String, dynamic>? userSettings,
  Model? model,
}) {
  return _resolveChatFeatureDefaults(
    appSettings: appSettings,
    userSettings: userSettings,
    model: model,
  );
}

final _chatFeatureDefaultsProvider = Provider<_ChatFeatureDefaults>((ref) {
  final appSettings = ref.watch(appSettingsProvider);
  final selectedModel = ref.watch(selectedModelProvider);
  final directBinding = selectedModel == null
      ? null
      : ref.watch(directModelRegistryProvider).resolve(selectedModel);
  // Device-owned direct models have no OpenWebUI user settings. Their
  // feature defaults come only from local app preferences and model metadata.
  final userSettings = directBinding?.source == DirectModelSource.device
      ? null
      : ref.watch(rawUserSettingsProvider).asData?.value;
  return _resolveChatFeatureDefaults(
    appSettings: appSettings,
    userSettings: userSettings,
    model: selectedModel,
  );
});
