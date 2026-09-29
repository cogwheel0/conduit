import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/web_search/services/on_device_web_tools.dart';
import 'package:conduit_core/models/model.dart';

/// How a Direct model searches the web when the user turns web search on.
enum DirectWebSearchMode {
  /// The model can't call tools, so there is nothing to offer.
  unavailable,

  /// The provider runs the search (Ollama Cloud's `web_search`, OpenRouter's
  /// server tool). Conduit only asks for it.
  providerHosted,

  /// Conduit runs `web_search`/`web_fetch` on the device through the model's
  /// tool calls.
  onDevice,
}

/// Resolves the web search mode for a Direct [model] bound by [binding].
///
/// Provider-hosted search is trusted only for connections the user added on
/// this device: an Open WebUI server controls the capabilities of the models
/// it relays, so it must not be able to claim a provider-side tool.
DirectWebSearchMode directWebSearchModeFor({
  required DirectModelBinding binding,
  required Model model,
}) {
  final capabilities = model.capabilities;
  final isDeviceOwned = binding.source == DirectModelSource.device;
  final isOllamaCloud =
      binding.adapterKey == kOllamaAdapterKey &&
      capabilities?['ollama_cloud'] == true;
  final isOpenRouter =
      binding.adapterKey == kOpenAiCompatibleAdapterKey &&
      capabilities?['openrouter'] == true;
  if (isDeviceOwned &&
      (isOllamaCloud || isOpenRouter) &&
      capabilities?['web_search'] == true) {
    return DirectWebSearchMode.providerHosted;
  }
  // Apple's Foundation Models always take tools; their advertised parameter
  // list covers sampling controls only.
  if (binding.adapterKey == kApplePccAdapterKey) {
    return DirectWebSearchMode.onDevice;
  }
  return directModelMaySupportTools(model)
      ? DirectWebSearchMode.onDevice
      : DirectWebSearchMode.unavailable;
}

/// False only when the provider says [model] can't call tools. Generic
/// OpenAI-compatible servers usually say nothing, so silence means "try";
/// a provider that then rejects the tools fails the turn with
/// `DirectProviderFailureReason.toolsUnsupported`.
bool directModelMaySupportTools(Model model) {
  final supportedParameters = model.supportedParameters;
  if (supportedParameters != null && supportedParameters.isNotEmpty) {
    return supportedParameters.contains('tools');
  }
  // Ollama reports `completion`, `tools`, `vision`, `thinking`, ...
  final ollamaCapabilities = model.capabilities?['capabilities'];
  if (ollamaCapabilities is List && ollamaCapabilities.isNotEmpty) {
    return ollamaCapabilities.contains('tools');
  }
  return true;
}

/// Context windows at or below this many tokens get [WebToolBudget.compact].
const int kCompactWebToolContextTokens = 8192;

/// Tool results land in the model's context, so small windows (Apple's
/// Foundation Models, small local models) get a tighter budget.
///
/// [knownContextLength] is the advertised or user-set window, `null` when
/// unknown. Unknown is not the same as small: most hosted models don't
/// advertise their window.
WebToolBudget webToolBudgetFor({
  required String adapterKey,
  required int? knownContextLength,
}) {
  if (adapterKey == kApplePccAdapterKey ||
      (knownContextLength != null &&
          knownContextLength <= kCompactWebToolContextTokens)) {
    return WebToolBudget.compact;
  }
  return WebToolBudget.standard;
}

/// Whether a stored Direct error says the model rejected tool definitions.
///
/// Generic OpenAI-compatible servers don't say up front whether a model can
/// call tools, so the first turn with web search on is how Conduit finds
/// out. Matches the wording of Ollama, llama.cpp, vLLM, LM Studio and
/// OpenAI-style gateways, and only for rejected (4xx) requests.
bool isDirectToolsUnsupportedError(String? message) {
  if (message == null || !_rejectedRequest.hasMatch(message)) return false;
  return _toolsUnsupported.hasMatch(message);
}

final RegExp _rejectedRequest = RegExp(r'\bHTTP 4\d\d\b');

final RegExp _toolsUnsupported = RegExp(
  r"(does not|doesn't|do not) support (tools|tool calling|tool use|function"
  r'|functions)'
  r'|(tools?|tool calling|tool use|function calling) (is |are )?not supported'
  r'|unrecognized request argument supplied: tools'
  r'|tools param requires'
  r'|tool choice requires',
  caseSensitive: false,
);
