// What the chat composer offers for the selected model: the attachment kinds
// of its + panel, the `$` and `#` triggers, and a Hermes Desktop Gateway's
// busy-turn messages. The rules mobile's composer
// (lib/features/chat/widgets/modern_chat_input.dart) and the desktop daemon's
// `composer.options` share.
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart'
    show isLibreChatModel;
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// Reads a provider: `ref.watch` or `ref.read` in a widget, a container's
/// `read` in the daemon.
typedef ComposerAvailabilityRead = T Function<T>(
  ProviderListenable<T> provider,
);

/// What the + panel may attach for [model], before a host counts the pickers
/// it has.
///
/// * LibreChat: files and images.
/// * Hermes: files (documents are read on the device and sent as text,
///   whatever the server reads), images only when the server reports
///   `inputImages`.
/// * Open WebUI and Direct: files and images by the model's capabilities;
///   the server's own files and a web page only on Open WebUI; a Direct MCP
///   server's content only for a Direct model with one enabled.
typedef ComposerAttachmentKinds = ({
  bool file,
  bool serverFile,
  bool image,
  bool web,
  bool mcpContent,
});

ComposerAttachmentKinds composerAttachmentKinds(
  ComposerAvailabilityRead read,
  Model? model,
) {
  if (model != null && isLibreChatModel(model)) {
    return (
      file: true,
      serverFile: false,
      image: true,
      web: false,
      mcpContent: false,
    );
  }
  if (model != null && isHermesModel(model)) {
    final inputImages =
        read(hermesCapabilitiesProvider).asData?.value.inputImages == true;
    return (
      file: true,
      serverFile: false,
      image: inputImages,
      web: false,
      mcpContent: false,
    );
  }
  final directMode = model != null && hasReservedDirectIdentity(model);
  final imageInput =
      model != null && read(visionCapableModelsProvider).contains(model.id);
  final fileInput =
      model != null && read(fileUploadCapableModelsProvider).contains(model.id);
  final mcpContent =
      directMode &&
      read(directMcpServersProvider).maybeWhen(
        data: (servers) => servers.any((server) => server.enabled),
        orElse: () => false,
      );
  return (
    file: fileInput,
    serverFile: !directMode && fileInput,
    image: imageInput,
    web: !directMode,
    mcpContent: mcpContent,
  );
}

/// Whether `$` lists Open WebUI skills for [model]: an Open WebUI account,
/// and a model that is not Hermes, LibreChat or minted on the device.
bool composerSkillsAvailable(ComposerAvailabilityRead read, Model? model) {
  if (!read(openWebUiAccountAvailableProvider)) return false;
  return model == null ||
      (!isHermesModel(model) &&
          !isLibreChatModel(model) &&
          !isLocallyMintedDirectModel(model));
}

/// Whether `#` lists context for [model]: Open WebUI notes, knowledge and
/// files, which a Hermes or LibreChat turn cannot resolve.
bool composerContextAvailable(Model? model) =>
    model == null || (!isHermesModel(model) && !isLibreChatModel(model));

/// Whether [model] sends to a Hermes Desktop Gateway, which takes a busy
/// turn's messages itself: to steer it, or as the next message.
bool isHermesDesktopComposer(ComposerAvailabilityRead read, Model? model) =>
    model != null &&
    isHermesModel(model) &&
    read(hermesConfigProvider).mode == HermesBackendMode.desktopGateway;
