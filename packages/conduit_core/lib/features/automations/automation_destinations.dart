import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart'
    show isLocallyMintedDirectModel;
import 'package:conduit_core/features/hermes/models/hermes_model.dart'
    show isHermesModel;
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/user.dart';

/// Folders a task may file its chats in: the account's own.
///
/// Open WebUI refuses any other folder, a shared one with a write grant
/// included, so offering one would only fail on save.
List<Folder> automationFolderOptions(Iterable<Folder> folders) => [
  for (final folder in folders)
    if (!folder.shared) folder,
];

/// Models a task may name: server models the picker shows. A Direct or Hermes
/// model lives on this device and cannot be reached from the server's
/// scheduler.
bool automationModelSelectable(Model model) =>
    !model.isHidden &&
    !isLocallyMintedDirectModel(model) &&
    !isHermesModel(model);

/// What Conduit can tell, from the channel list alone, about whether a task
/// may post to a channel.
enum AutomationChannelAccess {
  /// The list already proves the account may post.
  allowed,

  /// A standard channel: the list does not say whether the account has a write
  /// grant, so it has to be read back from the channel itself.
  needsWriteReadBack,

  /// The server would refuse this destination.
  unavailable,
}

/// Open WebUI's channel-destination rule, as far as the channel list shows it.
///
/// Channels must be enabled and exist. An admin may use any channel. Others
/// need the `features.channels` permission and, for a group, to be a member (a
/// channel in their list is one they belong to), or for any other type a write
/// grant. Direct messages are not offered, as in Open WebUI's own picker.
AutomationChannelAccess automationChannelAccess(
  Channel channel, {
  required User? user,
  required bool channelsEnabled,
  required Map<String, dynamic> permissions,
}) {
  if (!channelsEnabled || channel.id.isEmpty || channel.isDm) {
    return AutomationChannelAccess.unavailable;
  }
  if (user?.role == 'admin') return AutomationChannelAccess.allowed;
  final features = permissions['features'];
  if (features is! Map || features['channels'] != true) {
    return AutomationChannelAccess.unavailable;
  }
  if (channel.type == 'group') return AutomationChannelAccess.allowed;
  return AutomationChannelAccess.needsWriteReadBack;
}
