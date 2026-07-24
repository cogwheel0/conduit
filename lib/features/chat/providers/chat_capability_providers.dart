part of 'chat_providers.dart';

// Available tools provider
final availableToolsProvider =
    NotifierProvider<AvailableToolsNotifier, List<String>>(
      AvailableToolsNotifier.new,
    );

// Web search enabled state for API-based web search
final webSearchEnabledProvider =
    NotifierProvider<WebSearchEnabledNotifier, bool>(
      WebSearchEnabledNotifier.new,
    );

// Image generation enabled state - behaves like web search
final imageGenerationEnabledProvider =
    NotifierProvider<ImageGenerationEnabledNotifier, bool>(
      ImageGenerationEnabledNotifier.new,
    );

// Vision capable models provider
final visionCapableModelsProvider =
    NotifierProvider<VisionCapableModelsNotifier, List<String>>(
      VisionCapableModelsNotifier.new,
    );

// File upload capable models provider
final fileUploadCapableModelsProvider =
    NotifierProvider<FileUploadCapableModelsNotifier, List<String>>(
      FileUploadCapableModelsNotifier.new,
    );

class AvailableToolsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => [];

  void set(List<String> tools) => state = List<String>.from(tools);
}

class WebSearchEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(_chatFeatureDefaultsProvider).webSearchEnabled;

  void set(bool value) {
    state = value;
    unawaited(
      ref.read(appSettingsProvider.notifier).setChatWebSearchEnabled(value),
    );
  }
}

class ImageGenerationEnabledNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(_chatFeatureDefaultsProvider).imageGenerationEnabled;

  void set(bool value) {
    state = value;
    unawaited(
      ref
          .read(appSettingsProvider.notifier)
          .setChatImageGenerationEnabled(value),
    );
  }
}

bool? _explicitModelCapability(Model model, String capability) {
  bool? readCapability(Object? rawCapabilities) {
    if (rawCapabilities is! Map) return null;
    final value = rawCapabilities[capability];
    return value is bool ? value : null;
  }

  final metadata = model.metadata;
  final info = metadata?['info'];
  final infoMeta = info is Map ? info['meta'] : null;
  final meta = metadata?['meta'];

  return readCapability(infoMeta is Map ? infoMeta['capabilities'] : null) ??
      readCapability(meta is Map ? meta['capabilities'] : null) ??
      readCapability(metadata?['capabilities']) ??
      readCapability(model.capabilities);
}

class VisionCapableModelsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final selectedModel = ref.watch(selectedModelProvider);
    if (selectedModel == null) {
      return [];
    }

    final directIdentity =
        isLocallyMintedDirectModel(selectedModel) ||
        hasReservedDirectIdentity(selectedModel);
    if (directIdentity) {
      // DirectModelRegistry is mutable and its Provider retains object
      // identity. Discovery is the reactive mutation signal for model
      // replacement/removal, so watching the registry provider alone cannot
      // invalidate this capability result.
      ref.watch(directModelDiscoveryProvider);
      final directBinding = ref
          .read(directModelRegistryProvider)
          .resolve(selectedModel);
      if (directBinding == null || selectedModel.isMultimodal != true) {
        return [];
      }
      return [selectedModel.id];
    }

    // Match OpenWebUI: omitted capability metadata is permissive for
    // compatibility, but an explicit false must disable image input.
    if (_explicitModelCapability(selectedModel, 'vision') == false) {
      return [];
    }
    return [selectedModel.id];
  }
}

class FileUploadCapableModelsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final selectedModel = ref.watch(selectedModelProvider);
    if (selectedModel == null) {
      return [];
    }

    if (isHermesModel(selectedModel)) {
      return [selectedModel.id];
    }

    final directIdentity =
        isLocallyMintedDirectModel(selectedModel) ||
        hasReservedDirectIdentity(selectedModel);
    if (directIdentity) {
      ref.watch(directModelDiscoveryProvider);
      final directBinding = ref
          .read(directModelRegistryProvider)
          .resolve(selectedModel);
      // Direct documents are extracted locally into bounded text and do not
      // depend on the remote model's image-input capability.
      return directBinding == null ? [] : [selectedModel.id];
    }

    // Match OpenWebUI's missing-is-allowed policy while honoring an explicit
    // per-model file-upload denial.
    if (_explicitModelCapability(selectedModel, 'file_upload') == false) {
      return [];
    }
    return [selectedModel.id];
  }
}
