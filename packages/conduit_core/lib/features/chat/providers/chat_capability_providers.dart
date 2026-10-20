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

// Code interpreter selection. Unlike web search and image generation it is
// never a saved preference: running code is chosen for the conversation at
// hand, so it starts off, ends with the conversation, ends when the account,
// sign-in session or server changes, and ends when a terminal is selected (the
// two are exclusive in Open WebUI). The Advanced setting does not end it.
final codeInterpreterEnabledProvider =
    NotifierProvider<CodeInterpreterEnabledNotifier, bool>(
      CodeInterpreterEnabledNotifier.new,
    );

/// Whether the interpreter may run for the selected model right now, or why
/// not. Null means it may.
final codeInterpreterBlockProvider = Provider<CodeInterpreterBlock?>((ref) {
  final api = ref.watch(apiServiceProvider);
  final model = ref.watch(selectedModelProvider);
  if (api == null ||
      model == null ||
      !ref.watch(isAuthenticatedProvider2) ||
      isHermesModel(model) ||
      hasReservedDirectIdentity(model)) {
    return CodeInterpreterBlock.notOpenWebUi;
  }
  return _evaluateCodeInterpreterSupport(
    config: ref.watch(backendConfigProvider).asData?.value,
    serverId: api.serverConfig.id,
    user: ref.watch(currentUserProvider2),
    permissions: ref.watch(userPermissionsProvider).asData?.value,
    model: model,
    terminalId: ref.watch(selectedTerminalIdProvider),
  );
});

/// What the composer shows for the interpreter, or null for nothing.
///
/// The action is offered whenever the interpreter is usable. With Advanced on
/// it also appears, disabled, to explain that a server runs Python in the
/// browser. A selection already made stays visible so the user can turn it
/// off, and [block] says why it will not run, if it will not. Turns that never
/// reach an Open WebUI server get no offer.
typedef CodeInterpreterOffer = ({bool selected, CodeInterpreterBlock? block});

final codeInterpreterOfferProvider = Provider<CodeInterpreterOffer?>((ref) {
  final selected = ref.watch(codeInterpreterEnabledProvider);
  final block = ref.watch(codeInterpreterBlockProvider);
  if (block == CodeInterpreterBlock.notOpenWebUi) return null;
  if (selected || block == null) return (selected: selected, block: block);
  if (block != CodeInterpreterBlock.unsupportedEngine) return null;
  final advanced = ref.watch(
    appSettingsProvider.select((settings) => settings.advancedFeaturesEnabled),
  );
  return advanced ? (selected: false, block: block) : null;
});

/// Why Open WebUI's code interpreter cannot run a turn.
enum CodeInterpreterBlock {
  /// The turn does not go through an Open WebUI server's chat completion.
  notOpenWebUi,

  /// The server has not said, for this server and account, that it runs the
  /// interpreter. Nothing is assumed in its place.
  unverified,

  /// The server's administrator has turned the interpreter off.
  serverDisabled,

  /// The server asks the client to run the code (its Pyodide engine). Only the
  /// server's own Jupyter engine is supported.
  unsupportedEngine,

  /// The signed-in account is not allowed to use the interpreter.
  noPermission,

  /// The model's own settings turn the interpreter off.
  modelUnsupported,

  /// A terminal is selected for the turn, and it replaces the interpreter.
  terminalActive,
}

/// Open WebUI's own rule for offering the interpreter, from the same inputs:
/// the server's flag and engine, the account's permission, the model's
/// capability and the selected terminal.
///
/// Anything the server has not reported stays unsupported, except a listed
/// model with no capability entry, which Open WebUI treats as capable. A null
/// [model] is one the server has not vouched for. [config] counts only when it
/// was fetched from [serverId].
CodeInterpreterBlock? _evaluateCodeInterpreterSupport({
  required BackendConfig? config,
  required String serverId,
  required User? user,
  required Map<String, dynamic>? permissions,
  required Model? model,
  required String? terminalId,
}) {
  if (config == null ||
      config.serverId != serverId ||
      config.enableCodeInterpreter == null) {
    return CodeInterpreterBlock.unverified;
  }
  if (config.enableCodeInterpreter != true) {
    return CodeInterpreterBlock.serverDisabled;
  }
  final engine = config.codeInterpreterEngine;
  if (engine == null) return CodeInterpreterBlock.unverified;
  if (engine != 'jupyter') return CodeInterpreterBlock.unsupportedEngine;

  if (user?.role != 'admin') {
    if (permissions == null) return CodeInterpreterBlock.unverified;
    final features = permissions['features'];
    if (features is! Map || features['code_interpreter'] != true) {
      return CodeInterpreterBlock.noPermission;
    }
  }

  if (model == null) return CodeInterpreterBlock.unverified;
  if (_explicitModelCapability(model, 'code_interpreter') == false) {
    return CodeInterpreterBlock.modelUnsupported;
  }
  if (_resolveTerminalIdForRequest(selectedTerminalId: terminalId) != null &&
      modelSupportsTerminal(model)) {
    return CodeInterpreterBlock.terminalActive;
  }
  return null;
}

/// Whether a request built now may carry the interpreter flag: it is selected,
/// and the server, the account, the model and the terminal selection allow it.
bool _admitCodeInterpreter(dynamic ref) =>
    ref.read(codeInterpreterEnabledProvider) &&
    ref.read(codeInterpreterBlockProvider) == null;

/// Raised for a queued turn that asked for the interpreter after the server,
/// the account, or the model stopped allowing it. The turn is not sent without
/// the interpreter, since that would answer with a different workflow.
class CodeInterpreterUnavailableException implements Exception {
  const CodeInterpreterUnavailableException(this.reason);

  final CodeInterpreterBlock reason;

  String get message => switch (reason) {
    CodeInterpreterBlock.serverDisabled =>
      'The server no longer allows the code interpreter.',
    CodeInterpreterBlock.unsupportedEngine =>
      'This server runs code in the browser, which Conduit cannot do.',
    CodeInterpreterBlock.noPermission =>
      'Your account can no longer use the code interpreter.',
    CodeInterpreterBlock.modelUnsupported =>
      'This model no longer supports the code interpreter.',
    CodeInterpreterBlock.terminalActive =>
      'A terminal was selected, which replaces the code interpreter.',
    CodeInterpreterBlock.unverified || CodeInterpreterBlock.notOpenWebUi =>
      'The server did not confirm that it can run the code interpreter.',
  };

  @override
  String toString() => 'CodeInterpreterUnavailableException: $message';
}

/// A queued turn's interpreter support could not be read from the server. It is
/// an ordinary failure, so the outbox's backoff and retry limit apply.
class CodeInterpreterRecheckFailed implements Exception {
  const CodeInterpreterRecheckFailed(this.cause);

  final Object cause;

  @override
  String toString() => 'CodeInterpreterRecheckFailed: $cause';
}

/// Rechecks a queued turn that was admitted with the interpreter, against the
/// server and the account that own it, right before it is sent. Null means the
/// server still runs it.
///
/// This reads the server's answers, not the composer, because the selection,
/// terminal and model on screen now belong to whatever the user is doing. The
/// turn's model is looked up in the server's own model list, so a model that
/// list does not carry is unverified rather than borrowing another's answer.
///
/// Every read is made with the auth snapshot taken before the first one, and
/// [requireCurrentOwner] runs after each, so a session that changes mid-way
/// stops the turn before it reads anything as the next account. A server that
/// cannot be reached throws [CodeInterpreterRecheckFailed], which the outbox
/// retries. An unreadable answer is neither permission nor refusal.
Future<CodeInterpreterBlock?> _recheckCodeInterpreterForCompletion(
  dynamic ref, {
  required ApiService api,
  required void Function() requireCurrentOwner,
  required String modelId,
  required String? terminalId,
}) async {
  requireCurrentOwner();
  final auth = api.captureAuthSnapshot();
  final user = ref.read(currentUserProvider2) as User?;
  final BackendConfig? config;
  Map<String, dynamic>? permissions;
  final List<Model> models;
  try {
    config = await api.getBackendConfig(authSnapshot: auth);
    requireCurrentOwner();
    if (user?.role != 'admin') {
      permissions = await api.getUserPermissions(authSnapshot: auth);
      requireCurrentOwner();
    }
    models = await api.getModels(includeHidden: true, authSnapshot: auth);
    requireCurrentOwner();
  } on OutboxDeferralException {
    rethrow;
  } catch (error) {
    // A read the session refused because it changed is a deferral, not a
    // server that failed to answer.
    requireCurrentOwner();
    throw CodeInterpreterRecheckFailed(error);
  }
  final serverId = api.serverConfig.id;
  return _evaluateCodeInterpreterSupport(
    config: config?.copyWith(serverId: serverId),
    serverId: serverId,
    user: user,
    permissions: permissions,
    model: models.where((model) => model.id == modelId).firstOrNull,
    terminalId: terminalId,
  );
}

/// Settles a queued turn whose interpreter support is gone. The placeholder
/// shows the reason and [SyncTerminalException] parks the op with the same
/// words, so the message is never sent without the interpreter it asked for.
///
/// Nothing was sent, so the placeholder is marked refused rather than
/// submitted: a retry of the same op runs this recheck again and sends the
/// turn, with the interpreter it asked for, once the server supports it.
Future<Never> _rejectUnsupportedCodeInterpreter(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
  required CodeInterpreterBlock reason,
  required bool live,
}) async {
  final error = CodeInterpreterUnavailableException(reason);
  if (live) {
    (ref.read(chatMessagesProvider.notifier) as ChatMessagesNotifier)
        .failLastStreamingAssistant(
          error,
          assistantMessageId: assistantMessageId,
        );
  }
  try {
    // Under the chat lock, queued behind the live failure's own echo write, so
    // that echo cannot replace the marker.
    final locks = ref.read(chatLocksProvider) as ChatLocks;
    await locks.runExclusive(owner.chatId, () async {
      await owner.database?.messagesDao.markAssistantCompletionRefused(
        chatId: owner.chatId,
        messageId: assistantMessageId,
        error: chatErrorContentForException(error),
      );
    });
  } catch (cause, stackTrace) {
    DebugLogger.error(
      'code-interpreter-rejection-marker-failed',
      scope: 'chat/completion',
      error: cause,
      stackTrace: stackTrace,
    );
  }
  throw SyncTerminalException(message: error.toString());
}

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

class CodeInterpreterEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    // The choice belongs to the account and server it was made under, so it
    // ends with them: the next account chooses code execution for itself. The
    // session epoch also covers the same account signing back in on the same
    // API. The model and permissions are checked when a turn is admitted.
    ref
      ..watch(openWebUiAuthSessionEpochProvider)
      ..watch(currentUserProvider2.select((user) => user?.id))
      ..watch(apiServiceProvider);
    // A selected terminal replaces the interpreter, as in Open WebUI's own
    // composer.
    ref.listen<String?>(selectedTerminalIdProvider, (_, terminalId) {
      if (state &&
          _resolveTerminalIdForRequest(selectedTerminalId: terminalId) !=
              null &&
          modelSupportsTerminal(ref.read(selectedModelProvider))) {
        state = false;
      }
    });
    return false;
  }

  /// Chooses the interpreter, unless the server, the account, the model or a
  /// selected terminal does not allow it. Turning it off is always allowed.
  void set(bool value) {
    if (value && ref.read(codeInterpreterBlockProvider) != null) return;
    state = value;
  }

  void clear() => state = false;
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
