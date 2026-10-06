import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit/shared/widgets/user_avatar.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_members_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/utils/user_avatar_utils.dart';

/// Searchable, paged list of a channel's members, with Add and Remove for
/// accounts that may manage a group channel.
///
/// The sheet belongs to the [ChannelMembersOwner] that opened it and closes
/// itself when that owner stops being current or the channel on screen
/// changes. Reading and searching are always available; the management
/// controls follow [channelMemberManagementProvider].
class ChannelMembersSheet extends ConsumerStatefulWidget {
  const ChannelMembersSheet({
    super.key,
    required this.owner,
    this.onMembersChanged,
  });

  final ChannelMembersOwner owner;

  /// Called after the server accepted an add or remove, whether or not this
  /// sheet is still open, so the screen behind it can refresh its own copy.
  final VoidCallback? onMembersChanged;

  /// Opens the list for [owner], captured by the caller before any await.
  static Future<void> show(
    BuildContext context, {
    required ChannelMembersOwner owner,
    VoidCallback? onMembersChanged,
  }) {
    return ThemedSheets.showCustom<void>(
      context: context,
      builder: (_) =>
          ChannelMembersSheet(owner: owner, onMembersChanged: onMembersChanged),
    );
  }

  @override
  ConsumerState<ChannelMembersSheet> createState() =>
      _ChannelMembersSheetState();
}

class _ChannelMembersSheetState extends ConsumerState<ChannelMembersSheet> {
  static const _searchDebounce = Duration(milliseconds: 300);

  final _searchController = TextEditingController();
  Timer? _debounce;
  bool _closing = false;
  String? _actionError;

  ChannelMembersOwner get _owner => widget.owner;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  ChannelMembersController get _controller =>
      ref.read(channelMembersControllerProvider(_owner).notifier);

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      setState(() => _actionError = null);
      unawaited(_controller.setQuery(value));
    });
  }

  String _failureMessage(
    AppLocalizations l10n,
    ChannelMemberMutationResult result,
  ) => switch (result) {
    ChannelMemberMutationResult.denied => l10n.channelMembersChangeDenied,
    ChannelMemberMutationResult.notPermitted =>
      l10n.channelMembersChangeNotPermitted,
    _ => l10n.channelMembersChangeFailed,
  };

  Future<void> _remove(ChannelMember member) async {
    setState(() => _actionError = null);
    final result = await _controller.removeMember(member.id);
    if (result == ChannelMemberMutationResult.done) {
      widget.onMembersChanged?.call();
    }
    if (!mounted ||
        result == ChannelMemberMutationResult.done ||
        result == ChannelMemberMutationResult.ownerChanged) {
      return;
    }
    setState(
      () =>
          _actionError = _failureMessage(AppLocalizations.of(context)!, result),
    );
  }

  Future<void> _add() async {
    await ThemedSheets.showCustom<void>(
      context: context,
      builder: (_) => ChannelAddMembersSheet(
        owner: _owner,
        onMembersChanged: widget.onMembersChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final state = ref.watch(channelMembersControllerProvider(_owner));
    final management = ref.watch(channelMemberManagementProvider(_owner));
    final channel = ref.watch(activeChannelProvider);

    ref.listen(channelMembersControllerProvider(_owner), (_, next) {
      if (next.phase == ChannelMembersPhase.ownerChanged) _close();
    });
    ref.listen(activeChannelProvider, (_, next) {
      if (next == null || next.id != _owner.channelId) _close();
    });

    final count = state.total ?? channel?.userCount ?? state.members.length;
    return _KeyboardAwareSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.channelMembersTitle(count),
                  style: theme.headingSmall,
                ),
              ),
              if (management.canManage)
                IconButton(
                  key: const Key('channel-members-add'),
                  tooltip: l10n.channelMembersAdd,
                  icon: Icon(
                    Icons.person_add_alt_1_outlined,
                    color: theme.iconSecondary,
                  ),
                  onPressed: state.mutating ? null : _add,
                ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          // The server returns every member of a direct message in one go and
          // the web client offers no search there.
          if (channel?.isDm != true) ...[
            const SizedBox(height: Spacing.sm),
            ConduitGlassSearchField(
              controller: _searchController,
              hintText: l10n.channelMembersSearchHint,
              query: _searchController.text,
              onChanged: _onQueryChanged,
              onClear: () {
                _searchController.clear();
                _onQueryChanged('');
              },
            ),
          ],
          if (_actionError != null)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text(
                _actionError!,
                key: const Key('channel-members-error'),
                style: theme.bodySmall?.copyWith(color: theme.error),
              ),
            ),
          const SizedBox(height: Spacing.sm),
          Flexible(child: _body(context, l10n, state, management)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    ChannelMembersState state,
    ChannelMemberManagement management,
  ) {
    final theme = context.conduitTheme;
    switch (state.phase) {
      case ChannelMembersPhase.loading:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: ConduitLoading.inline(context: context),
          ),
        );
      case ChannelMembersPhase.ownerChanged:
        return const SizedBox.shrink();
      case ChannelMembersPhase.failed:
        return Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.channelMembersLoadFailed,
                key: const Key('channel-members-load-failed'),
                textAlign: TextAlign.center,
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                key: const Key('channel-members-retry'),
                text: l10n.retry,
                isSecondary: true,
                onPressed: () => unawaited(_controller.reload()),
              ),
            ],
          ),
        );
      case ChannelMembersPhase.ready:
        if (state.members.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Text(
              l10n.channelMembersEmpty,
              key: const Key('channel-members-empty'),
              textAlign: TextAlign.center,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          );
        }
    }

    final showFooter = state.hasMore || state.loadMoreFailed;
    final currentUserId = ref.watch(currentUserProvider2.select((u) => u?.id));
    return ListView.builder(
      key: const Key('channel-members-list'),
      shrinkWrap: true,
      // The search keyboard covers the lower rows and Load more; scrolling
      // the list is how the person gets them back.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: state.members.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == state.members.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: state.loadingMore
                ? Center(child: ConduitLoading.inline(context: context))
                : ConduitButton(
                    key: const Key('channel-members-load-more'),
                    text: state.loadMoreFailed
                        ? l10n.channelMembersLoadMoreFailed
                        : l10n.channelMembersLoadMore,
                    isSecondary: true,
                    isFullWidth: true,
                    onPressed: () => unawaited(_controller.loadMore()),
                  ),
          );
        }
        return _memberTile(
          context,
          l10n,
          state.members[index],
          canRemove: management.canManage,
          isSelf: state.members[index].id == currentUserId,
          busy: state.mutating,
        );
      },
    );
  }

  Widget _memberTile(
    BuildContext context,
    AppLocalizations l10n,
    ChannelMember member, {
    required bool canRemove,
    required bool isSelf,
    required bool busy,
  }) {
    final theme = context.conduitTheme;
    final name = member.name.isEmpty ? l10n.channelUnknownMember : member.name;
    return Material(
      color: Colors.transparent,
      child: AdaptiveListTile(
        key: Key('channel-member-${member.id}'),
        leading: UserAvatar(
          size: 32,
          imageUrl: resolveUserProfileImageUrl(
            _owner.api,
            member.profileImageUrl,
          ),
          fallbackText: String.fromCharCode(name.runes.first).toUpperCase(),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: member.role == null
            ? null
            : Text(
                member.role!,
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
        trailing: canRemove
            ? IconButton(
                key: Key('channel-member-remove-${member.id}'),
                tooltip: l10n.channelMembersRemoveMember(name),
                icon: Icon(Icons.close, color: theme.iconSecondary),
                // The web client disables removing yourself.
                onPressed: isSelf || busy ? null : () => _remove(member),
              )
            : null,
      ),
    );
  }
}

/// Collects people and groups to add to a channel and sends them in one
/// request.
///
/// What may be picked follows the account's sharing policy; whether the sheet
/// opens at all follows management authority. The two are independent. Picks
/// survive a refusal or a failure so the request can be retried.
class ChannelAddMembersSheet extends ConsumerStatefulWidget {
  const ChannelAddMembersSheet({
    super.key,
    required this.owner,
    this.onMembersChanged,
  });

  final ChannelMembersOwner owner;
  final VoidCallback? onMembersChanged;

  @override
  ConsumerState<ChannelAddMembersSheet> createState() =>
      _ChannelAddMembersSheetState();
}

class _ChannelAddMembersSheetState
    extends ConsumerState<ChannelAddMembersSheet> {
  final List<WorkspacePrincipalPreview> _selected = [];
  bool _submitting = false;
  bool _closing = false;
  String? _error;

  ChannelMembersOwner get _owner => widget.owner;

  void _close([Object? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _pick(ChannelMemberManagement management) async {
    final picked = await WorkspacePrincipalPicker.show(
      context,
      directory: WorkspacePrincipalDirectory.fromApi(_owner.api),
      allowUsers: management.allowUsers,
      allowGroups: management.allowGroups,
    );
    // A pick made for an account that has since changed is not kept.
    if (picked == null || !mounted || !_owner.isCurrent(ref.read)) return;
    final alreadyPicked = _selected.any(
      (p) => p.type == picked.type && p.id == picked.id,
    );
    if (alreadyPicked) return;
    setState(() {
      _selected.add(picked);
      _error = null;
    });
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final userIds = [
      for (final p in _selected)
        if (p.type == WorkspacePrincipalType.user) p.id,
    ];
    final groupIds = [
      for (final p in _selected)
        if (p.type == WorkspacePrincipalType.group) p.id,
    ];
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await ref
        .read(channelMembersControllerProvider(_owner).notifier)
        .addMembers(userIds: userIds, groupIds: groupIds);
    if (result == ChannelMemberMutationResult.done) {
      widget.onMembersChanged?.call();
    }
    if (!mounted) return;
    switch (result) {
      case ChannelMemberMutationResult.done:
      case ChannelMemberMutationResult.ownerChanged:
        _close();
      case ChannelMemberMutationResult.denied:
      case ChannelMemberMutationResult.notPermitted:
      case ChannelMemberMutationResult.failed:
      case ChannelMemberMutationResult.busy:
        setState(() {
          _submitting = false;
          _error = switch (result) {
            ChannelMemberMutationResult.denied =>
              l10n.channelMembersChangeDenied,
            ChannelMemberMutationResult.notPermitted =>
              l10n.channelMembersChangeNotPermitted,
            _ => l10n.channelMembersChangeFailed,
          };
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final management = ref.watch(channelMemberManagementProvider(_owner));

    ref.listen(channelMembersControllerProvider(_owner), (_, next) {
      if (next.phase == ChannelMembersPhase.ownerChanged) _close();
    });
    // Management ended (Advanced turned off, permission withdrawn): keep the
    // picks on screen but stop offering to send them.
    final canPickAny = management.allowUsers || management.allowGroups;

    // The native iOS presenter gives its content no Material ancestor, which
    // the selected-principal chips need.
    return _KeyboardAwareSheet(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.channelMembersAdd,
                    style: theme.headingSmall,
                  ),
                ),
                SheetCloseButton(
                  tooltip: l10n.close,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            if (_selected.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: Spacing.xs,
                    runSpacing: Spacing.xs,
                    children: [
                      for (final principal in _selected)
                        InputChip(
                          key: Key(
                            'channel-add-selected-${principal.type.name}-'
                            '${principal.id}',
                          ),
                          avatar: Icon(
                            principal.type == WorkspacePrincipalType.group
                                ? Icons.groups_outlined
                                : Icons.person_outline,
                            size: IconSize.small,
                          ),
                          label: Text(
                            principal.name.isEmpty
                                ? principal.id
                                : principal.name,
                          ),
                          onDeleted: _submitting
                              ? null
                              : () =>
                                    setState(() => _selected.remove(principal)),
                        ),
                    ],
                  ),
                ),
              ),
            if (!canPickAny)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: Text(
                  l10n.workspaceAccessGrantsDisabled,
                  key: const Key('channel-add-members-picking-disabled'),
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: ConduitButton(
                  key: const Key('channel-add-members-pick'),
                  text: switch ((
                    management.allowUsers,
                    management.allowGroups,
                  )) {
                    (true, true) => l10n.workspaceAccessAddPeople,
                    (true, false) => l10n.workspaceAccessAddUsers,
                    _ => l10n.workspaceAccessAddGroups,
                  },
                  icon: Icons.person_add_alt_1_outlined,
                  isSecondary: true,
                  isFullWidth: true,
                  onPressed: _submitting ? null : () => _pick(management),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: Text(
                  _error!,
                  key: const Key('channel-add-members-error'),
                  style: theme.bodySmall?.copyWith(color: theme.error),
                ),
              ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              key: const Key('channel-add-members-confirm'),
              text: l10n.channelMembersAddConfirm,
              isFullWidth: true,
              isLoading: _submitting,
              onPressed:
                  _selected.isEmpty || _submitting || !management.canManage
                  ? null
                  : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// The sheet surface for both member sheets.
///
/// The modal route does not move for the keyboard, so the surface is lifted by
/// the keyboard inset the way [ThemedSheets.showSurface] does it. The surface
/// also lays its child out with unbounded height, so a list that has to scroll
/// needs its own bound: three quarters of the screen, or whatever the keyboard
/// leaves below the status bar once the handle and padding are paid for.
class _KeyboardAwareSheet extends StatelessWidget {
  const _KeyboardAwareSheet({required this.child});

  final Widget child;

  // The handle's margins and bar, plus the surface's top and bottom padding.
  static const _surfaceChrome =
      Spacing.sm + 4 + Spacing.md + Spacing.sm + Spacing.modalPadding;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    // A modal route without useSafeArea strips the top padding from its
    // MediaQuery, so the status bar has to come from the view itself.
    final view = View.of(context);
    final statusBar = view.padding.top / view.devicePixelRatio;
    final remaining =
        height -
        keyboard -
        statusBar -
        bottomSafe -
        _surfaceChrome -
        Spacing.sm;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConduitModalSheetSurface(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(0, math.min(height * 0.75, remaining)),
          ),
          child: child,
        ),
      ),
    );
  }
}
