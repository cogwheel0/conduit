import '../features/direct_connections/models/direct_connection_profile.dart';
import '../features/direct_connections/services/direct_model_registry.dart';
import '../features/direct_connections/services/model_logo_catalog.dart';
import '../features/terminal/models/terminal_agent_model.dart';
import '../models/model.dart';

final RegExp _whitespace = RegExp(r'\s');

/// Whether [name] is only a model's raw id, rather than a name an admin or
/// provider chose.
///
/// A name is raw when it is empty, repeats one of [ids] (whole or after its
/// provider prefix, as `gpt-5-mini` for `openai/gpt-5-mini`), or is shaped
/// like a namespaced id itself (no spaces, and a `/`).
bool isRawModelIdName(String name, {Iterable<String?> ids = const []}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  for (final id in ids) {
    final candidate = id?.trim();
    if (candidate == null || candidate.isEmpty) continue;
    if (trimmed == candidate || trimmed == _lastSegment(candidate)) {
      return true;
    }
  }
  return !_whitespace.hasMatch(trimmed) && trimmed.contains('/');
}

/// The name to show for a model whose server name is [name] and id is [id].
///
/// - A name someone chose (`Research Assistant`, `GPT-5 mini (fast)`) is
///   returned unchanged, only trimmed.
/// - A raw id (`openai/gpt-5-mini`) becomes the models.dev display name
///   (`GPT-5 Mini`) when [catalog] knows it,
/// - else it loses its provider prefix (`gpt-5-mini`).
///
/// [alternateIds] are other ids the same model goes by, such as a Direct
/// model's remote id, so a name repeating one of them also counts as raw.
/// Returns an empty string only when both [name] and [id] are blank.
String modelDisplayName({
  required String name,
  String? id,
  Iterable<String?> alternateIds = const [],
  ModelLogoCatalog? catalog,
}) {
  var source = name.trim();
  if (source.isEmpty) source = id?.trim() ?? '';
  if (source.isEmpty) return '';
  if (!isRawModelIdName(source, ids: [id, ...alternateIds])) return source;

  final bare = _lastSegment(source);
  final catalogName = catalog?.modelNameFor(bare);
  return catalogName == null ? bare : _capitalizeLowercaseWords(catalogName);
}

/// models.dev writes some names with lowercase trailing words ("GPT-4.1
/// mini") and others in title case ("GPT-5 Mini"); side by side in one list
/// the mix reads as a typo. Capitalise words made only of lowercase letters,
/// and leave anything with digits or capitals ("o3", "4o", "GPT") as it is.
String _capitalizeLowercaseWords(String name) => name
    .split(' ')
    .map(
      (word) => _lowercaseWord.hasMatch(word)
          ? '${word[0].toUpperCase()}${word.substring(1)}'
          : word,
    )
    .join(' ');

final RegExp _lowercaseWord = RegExp(r'^[a-z]+$');

/// [modelDisplayName] for [model], using the models.dev catalog the app
/// installed at startup unless [catalog] is given.
String displayNameForModel(Model model, {ModelLogoCatalog? catalog}) {
  final remoteId = model.metadata?['remoteModelId'];
  return modelDisplayName(
    name: model.name,
    id: model.id,
    alternateIds: [if (remoteId is String) remoteId],
    catalog: catalog ?? installedModelLogoCatalog,
  );
}

/// What a model picker says under Apple's two Foundation Models, in the
/// app's language: where each one runs, in a few words.
typedef AppleModelPickerSubtitles = ({String onDevice, String privateCloud});

/// Whether [model] is Apple's Private Cloud Compute model rather than the
/// on-device one. False for any model not trusted as Apple's
/// ([isAppleFoundationModel]), whatever its id says.
bool isApplePrivateCloudComputeModel(Model model) =>
    isAppleFoundationModel(model) &&
    model.metadata?['remoteModelId'] == kApplePccRemoteModelId;

/// The secondary line under [model] in a model picker.
///
/// A model named after its id shows that full id (`openai/gpt-5-mini` under
/// `GPT-5 Mini`), so the friendly name never hides which model it is. A model
/// someone named shows its description, else its id. Returns `null` when the
/// line would only repeat the name.
///
/// Given [apple], Apple's Foundation Models show those words instead of the
/// framework's description, so they take one line like every other row.
String? modelPickerSubtitle(
  Model model, {
  ModelLogoCatalog? catalog,
  AppleModelPickerSubtitles? apple,
}) {
  if (apple != null && isAppleFoundationModel(model)) {
    return isApplePrivateCloudComputeModel(model)
        ? apple.privateCloud
        : apple.onDevice;
  }
  // A coding agent's id is an address, not a name; say where it runs.
  final agentSubtitle = terminalAgentPickerSubtitle(model);
  if (agentSubtitle != null) return agentSubtitle;
  final remoteId = model.metadata?['remoteModelId'];
  final fullId =
      (remoteId is String && remoteId.trim().isNotEmpty ? remoteId : model.id)
          .trim();
  final name = displayNameForModel(model, catalog: catalog);
  final description = model.description?.trim();
  final named = !isRawModelIdName(
    model.name,
    ids: [model.id, if (remoteId is String) remoteId],
  );
  if (named && description != null && description.isNotEmpty) {
    return description;
  }
  if (fullId.isNotEmpty && fullId != name) return fullId;
  return description == null || description.isEmpty ? null : description;
}

/// The id segment after the last `/` (`openai/gpt-5-mini` → `gpt-5-mini`),
/// or the whole value when that segment would be empty.
String _lastSegment(String value) {
  final slash = value.lastIndexOf('/');
  if (slash < 0) return value;
  final tail = value.substring(slash + 1).trim();
  return tail.isEmpty ? value : tail;
}
