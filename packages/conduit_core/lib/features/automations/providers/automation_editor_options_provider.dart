import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/automation_destinations.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
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
  });

  /// Server models the picker shows ([automationModelSelectable]).
  final List<Model>? models;

  /// Channels the server would accept, Direct messages left out.
  final List<Channel>? channels;

  /// What the channel list alone says about posting to each listed channel.
  final Map<String, AutomationChannelAccess> access;

  /// The account's own folders ([automationFolderOptions]).
  final List<({String id, String name})>? folders;

  /// What stops [draft] from being saved against these options.
  List<AutomationDraftIssue> issuesFor(AutomationDraft draft) => draft.issues(
    modelIds: models == null ? null : {for (final m in models!) m.id},
    folderIds: folders == null ? null : {for (final f in folders!) f.id},
    channelIds: channels == null ? null : {for (final c in channels!) c.id},
  );

  /// Whether posting to [channelId] has to be confirmed by reading the
  /// channel back before the task is saved.
  bool needsWriteReadBack(String channelId) =>
      access[channelId] == AutomationChannelAccess.needsWriteReadBack;
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
