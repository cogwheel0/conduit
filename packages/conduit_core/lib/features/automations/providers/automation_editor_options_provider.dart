import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/automation_destinations.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/providers/automation_terminal_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// What a scheduled task's editor offers the account right now: the models a
/// task may name, the channels it may post to and the folders it may file its
/// chats in. A list that has not loaded (or failed to) is null, and a draft is
/// then checked against it by the server instead of being refused on a guess.
@immutable
final class AutomationEditorOptions {
  const AutomationEditorOptions({
    this.models,
    this.channels,
    this.access = const <String, AutomationChannelAccess>{},
    this.folders,
    this.terminals,
    this.agentsLoading = false,
    this.agentsUnknown = false,
  });

  /// Server models the picker shows ([automationModelSelectable]), then the
  /// coding agents of the draft's terminal once [withTerminalAgents] added
  /// them.
  final List<Model>? models;

  /// The server's terminals a task may run with
  /// ([automationTerminalsProvider]); null when they could not be read.
  final List<TerminalServerInfo>? terminals;

  /// The draft runs a coding agent, and its terminal's agents are still
  /// being read.
  final bool agentsLoading;

  /// The draft runs a coding agent, and its terminal could not be asked
  /// for its agents: whether that agent is still offered is unknown, so the
  /// draft is not refused for it.
  final bool agentsUnknown;

  /// Channels the server would accept, Direct messages left out.
  final List<Channel>? channels;

  /// What the channel list alone says about posting to each listed channel.
  final Map<String, AutomationChannelAccess> access;

  /// The account's own folders ([automationFolderOptions]).
  final List<({String id, String name})>? folders;

  /// What stops [draft] from being saved against these options.
  List<AutomationDraftIssue> issuesFor(AutomationDraft draft) => draft.issues(
    modelIds: models == null || agentsUnknown
        ? null
        : {for (final m in models!) m.id},
    folderIds: folders == null ? null : {for (final f in folders!) f.id},
    channelIds: channels == null ? null : {for (final c in channels!) c.id},
  );

  /// Whether posting to [channelId] has to be confirmed by reading the
  /// channel back before the task is saved.
  bool needsWriteReadBack(String channelId) =>
      access[channelId] == AutomationChannelAccess.needsWriteReadBack;

  /// These options for [draft] with its terminal: the server's [terminals]
  /// (null while they load or when they failed), and the coding [agents]
  /// its terminal offers ([automationAgentModelsProvider] for
  /// [automationAgentQueryFor]), which follow the server's models.
  ///
  /// A task with no terminal runs no agent. One posting to a channel, or one
  /// whose terminals are not known, cannot tell whether its agent is
  /// offered; a terminal the server lists without this one offers none.
  AutomationEditorOptions withTerminalAgents({
    required AutomationDraft? draft,
    required AsyncValue<List<TerminalServerInfo>?> terminals,
    required AsyncValue<List<Model>?>? agents,
  }) {
    final servers = terminals.asData?.value;
    final terminalId = draft?.terminalId;
    final terminal = servers
        ?.where((server) => server.selectionId == terminalId)
        .firstOrNull;
    final channel = draft?.target.isChannel ?? false;
    final List<Model>? offered;
    if (terminalId == null) {
      offered = const <Model>[];
    } else if (channel || servers == null) {
      offered = null;
    } else if (terminal == null) {
      // The server lists its terminals and this one is not among them.
      offered = const <Model>[];
    } else {
      // Null while loading, and when the terminal could not be asked.
      offered = agents?.asData?.value;
    }
    final runsAgent = draft?.runsAgent ?? false;
    final serverModels = models;
    return AutomationEditorOptions(
      models: serverModels == null ? null : [...serverModels, ...?offered],
      channels: channels,
      access: access,
      folders: folders,
      terminals: servers,
      agentsLoading:
          runsAgent && (terminals.isLoading || (agents?.isLoading ?? false)),
      agentsUnknown: runsAgent && offered == null,
    );
  }
}

/// What [draft]'s editor asks its terminal for coding agents with, or null
/// when it asks none: a coding agent posts only to a chat, so a task posting
/// to a channel asks none, and neither does one whose terminal is not among
/// [terminals]. [cwd] is the working folder as typed.
AutomationAgentQuery? automationAgentQueryFor(
  AutomationDraft? draft,
  List<TerminalServerInfo>? terminals, {
  String? cwd,
}) {
  final terminalId = draft?.terminalId;
  final terminal = terminals
      ?.where((server) => server.selectionId == terminalId)
      .firstOrNull;
  final channel = draft?.target.isChannel ?? false;
  if (terminal == null || channel) return null;
  return (
    terminalId: terminal.selectionId,
    terminalName: terminal.displayName,
    cwd: cwd,
    automationId: draft?.original?.id,
  );
}

/// The options a scheduled task's editor offers, from the providers the
/// phone's editor and the desktop daemon both read, so they offer the same
/// models, channels and folders. It lives only while an editor watches it.
final automationEditorOptionsProvider =
    Provider.autoDispose<AutomationEditorOptions>((ref) {
      final models = ref
          .watch(modelsProvider)
          .asData
          ?.value
          .where(automationModelSelectable)
          .toList();
      final channelList = ref.watch(channelsListProvider).asData?.value;
      final user = ref.watch(currentUserProvider2);
      final permissions =
          ref.watch(userPermissionsProvider).asData?.value ??
          const <String, dynamic>{};
      final enabled = ref.watch(channelsFeatureEnabledProvider);
      final access = {
        for (final channel in channelList ?? const <Channel>[])
          channel.id: automationChannelAccess(
            channel,
            user: user,
            channelsEnabled: enabled,
            permissions: permissions,
          ),
      };
      final folders = ref.watch(foldersProvider).asData?.value;
      return AutomationEditorOptions(
        models: models,
        channels: channelList
            ?.where((c) => access[c.id] != AutomationChannelAccess.unavailable)
            .toList(),
        access: access,
        folders: folders == null
            ? null
            : [
                for (final f in automationFolderOptions(folders))
                  (id: f.id, name: f.name),
              ],
      );
    });
