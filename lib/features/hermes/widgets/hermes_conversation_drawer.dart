import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_mobile_navigation.dart';
import '../views/hermes_bot_workspace_page.dart';
import '../views/hermes_bot_setup_page.dart';
import '../views/hermes_group_setup_page.dart';
import '../views/hermes_group_chat_page.dart';
import '../views/hermes_group_workspace_page.dart';
import 'hermes_bot_avatar.dart';
import 'hermes_message_icon.dart';
import 'hermes_messages_home.dart';
import 'hermes_session_tile.dart' show openHermesSession;
import 'hermes_mobile_shell.dart'
    show HermesProfileButton, startHermesMobileConversation;

HermesBot? activeHermesWorkspaceBot(WidgetRef ref) {
  final conversation = ref.watch(activeConversationProvider);
  if (conversation?.metadata['hermesBotTitle'] == null) return null;
  final profile = conversation?.metadata['hermesBotProfile'];
  final id = conversation?.metadata['hermesSessionId'];
  return ref
      .watch(hermesMessagesBotsProvider)
      .asData
      ?.value
      .where(
        (bot) =>
            profile == bot.name || profile == null && bot.chatSessionId == id,
      )
      .firstOrNull;
}

class HermesWorkspaceBadge extends ConsumerWidget {
  const HermesWorkspaceBadge({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bot = activeHermesWorkspaceBot(ref);
    if (bot == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: '${bot.title}, open bot',
      child: InkWell(
        onTap: () => openHermesBotWorkspace(context, bot),
        borderRadius: BorderRadius.circular(18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: context.conduitTheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HermesBotAvatar(
                    size: 22,
                    label: bot.title,
                    shape: bot.avatarShape,
                    color: bot.avatarColor,
                    icon: bot.icon,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      bot.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_arrow_down, size: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showHermesConversationDrawer(
  BuildContext context,
  WidgetRef ref, {
  bool bots = false,
  HermesBotGroup? group,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context)!.close,
    barrierColor: Colors.black.withValues(alpha: .32),
    transitionDuration: context.motionDuration(
      const Duration(milliseconds: 180),
    ),
    transitionBuilder: (context, animation, secondary, child) =>
        SlideTransition(
          position: animation.drive(
            Tween(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic)),
          ),
          child: child,
        ),
    pageBuilder: (dialogContext, _, _) => SafeArea(
      left: false,
      right: false,
      minimum: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Dismissible(
          key: const ValueKey('hermes-conversation-drawer-swipe'),
          direction: DismissDirection.endToStart,
          resizeDuration: null,
          movementDuration: context.motionDuration(
            const Duration(milliseconds: 180),
          ),
          onDismissed: (_) => Navigator.of(dialogContext).pop(),
          child: Drawer(
            key: const ValueKey('hermes-conversation-drawer'),
            width: math.min(360, MediaQuery.sizeOf(context).width - 56),
            elevation: 4,
            backgroundColor: context.conduitTheme.surfaceChrome,
            surfaceTintColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadiusDirectional.horizontal(
                end: Radius.circular(24),
              ),
            ),
            child: _ConversationDrawer(
              parentContext: context,
              parentRef: ref,
              initialBots: bots,
              group: group,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ConversationDrawer extends ConsumerStatefulWidget {
  const _ConversationDrawer({
    required this.parentContext,
    required this.parentRef,
    required this.initialBots,
    this.group,
  });
  final BuildContext parentContext;
  final WidgetRef parentRef;
  final bool initialBots;
  final HermesBotGroup? group;
  @override
  ConsumerState<_ConversationDrawer> createState() => _DrawerState();
}

class _DrawerState extends ConsumerState<_ConversationDrawer> {
  late final bool _bots = widget.initialBots;
  void _close() => Navigator.of(context).pop();
  void _leaveGroup() {
    if (widget.group != null &&
        widget.parentContext.mounted &&
        ModalRoute.of(widget.parentContext)?.isCurrent == true) {
      Navigator.of(widget.parentContext).pop();
    }
  }

  Future<void> _create(String kind) async {
    final parent = widget.parentContext, parentRef = widget.parentRef;
    _close();
    if (!parent.mounted) return;
    if (kind == 'chat') {
      await startHermesMobileConversation(parentRef);
      _leaveGroup();
      return;
    }
    if (kind == 'bot') {
      final bot = await Navigator.of(parent).push<HermesBot>(
        MaterialPageRoute(builder: (_) => const HermesBotSetupPage()),
      );
      if (parent.mounted && bot != null) {
        await openHermesBotConversation(
          parent,
          parentRef,
          HermesBotConversation(bot: bot),
        );
      }
    } else {
      final group = await Navigator.of(
        parent,
      ).push(MaterialPageRoute(builder: (_) => const HermesGroupSetupPage()));
      if (parent.mounted && group != null) {
        await Navigator.of(parent).push(
          MaterialPageRoute(builder: (_) => HermesGroupChatPage(group: group)),
        );
      }
    }
  }

  void _messages() {
    final parentRef = widget.parentRef;
    _close();
    parentRef
        .read(hermesMessagesNavigationProvider.notifier)
        .select(_bots ? HermesMessagesTab.bots : HermesMessagesTab.chats);
    parentRef.read(hermesMobileNavigationProvider.notifier).showConversations();
    _leaveGroup();
  }

  void _search() {
    final parentRef = widget.parentRef;
    _close();
    parentRef.read(hermesMobileNavigationProvider.notifier).showConversations();
    parentRef
        .read(hermesMessagesNavigationProvider.notifier)
        .select(_bots ? HermesMessagesTab.bots : HermesMessagesTab.chats);
    parentRef.read(hermesMessagesNavigationProvider.notifier).search();
    _leaveGroup();
  }

  Widget _selectedRow({required bool selected, required Widget child}) =>
      Semantics(
        selected: selected,
        child: Material(
          color: selected
              ? context.conduitTheme.surfaceContainerHighest
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final bots =
        ref.watch(hermesMessagesBotsProvider).asData?.value ??
        const <HermesBot>[];
    final current = widget.group == null ? activeHermesWorkspaceBot(ref) : null;
    final rows = ref.watch(hermesBotConversationsProvider);
    final groups = ref.watch(hermesBotGroupsProvider);
    final history = ref.watch(hermesSessionsProvider);
    final active = ref.watch(hermesActiveSessionProvider);
    final sessions =
        hermesRegularConversations(
          history.asData?.value ?? const [],
          bots,
          profile:
              ref.watch(hermesApiServiceProvider)?.config.desktopProfile ??
              'default',
        ).where((s) => !s.archived).toList()..sort(
          (a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(
            a.updatedAt ?? DateTime(1970),
          ),
        );
    final visibleBots = (rows.asData?.value.rows ?? <HermesBotConversation>[])
        .where((row) => !row.bot.hidden)
        .toList();
    final visibleGroups = groups.asData?.value ?? [];
    final loading = _bots
        ? rows.isLoading || groups.isLoading
        : history.isLoading;
    final failed = _bots ? rows.hasError || groups.hasError : history.hasError;
    final empty = _bots
        ? visibleBots.isEmpty && visibleGroups.isEmpty
        : sessions.isEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _bots ? l10n.hermesBotsTitle : l10n.messagesChats,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              CompactIconAction(
                tooltip: l10n.close,
                icon: const Icon(HermesMessageIcons.close),
                onPressed: _close,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: _bots
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: CompactPopupMenu<String>(
                          tooltip: 'Create',
                          icon: const Icon(HermesMessageIcons.add),
                          choices: [
                            CompactMenuChoice('bot', l10n.messagesNewBot),
                            CompactMenuChoice('group', l10n.messagesNewGroup),
                          ],
                          onSelected: _create,
                        ),
                      )
                    : Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: () => _create('chat'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            foregroundColor: theme.textPrimary,
                          ),
                          icon: const Icon(HermesMessageIcons.add, size: 20),
                          label: Text(l10n.newChat),
                        ),
                      ),
              ),
              CompactIconAction(
                tooltip: _bots ? 'Search bots' : 'Search chats',
                icon: const HermesSearchIcon(),
                onPressed: _search,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: ValueKey('drawer-list-$_bots'),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: AdaptiveProgressIndicator()),
                ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text('Could not load conversations.'),
                      TextButton(
                        onPressed: () {
                          if (_bots) {
                            ref.invalidate(hermesBotConversationsProvider);
                            ref.invalidate(hermesBotGroupsProvider);
                          } else {
                            ref.invalidate(hermesSessionsProvider);
                          }
                        },
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              if (!loading && !failed && empty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _bots ? l10n.messagesNoBots : l10n.noConversationsYet,
                    style: TextStyle(color: theme.textSecondary),
                  ),
                ),
              if (_bots) ...[
                for (final row in visibleBots)
                  _selectedRow(
                    selected: current?.name == row.bot.name,
                    child: HermesMessageRow(
                      title: row.bot.title,
                      preview: row.bot.preview,
                      leading: HermesBotAvatar(
                        size: 40,
                        label: row.bot.title,
                        shape: row.bot.avatarShape,
                        color: row.bot.avatarColor,
                        icon: row.bot.icon,
                      ),
                      trailing: current?.name == row.bot.name
                          ? const Icon(HermesMessageIcons.check, size: 18)
                          : null,
                      onOpen: () async {
                        _close();
                        if (widget.parentContext.mounted) {
                          await openHermesBotConversation(
                            widget.parentContext,
                            widget.parentRef,
                            row,
                          );
                          _leaveGroup();
                        }
                      },
                    ),
                  ),
                for (final group in visibleGroups)
                  _selectedRow(
                    selected: widget.group?.key == group.key,
                    child: HermesMessageRow(
                      title: group.name,
                      leading: const Icon(HermesMessageIcons.groups, size: 36),
                      trailing: widget.group?.key == group.key
                          ? const Icon(HermesMessageIcons.check, size: 18)
                          : null,
                      onOpen: () async {
                        _close();
                        if (widget.parentContext.mounted) {
                          await Navigator.of(widget.parentContext).push(
                            MaterialPageRoute(
                              builder: (_) => HermesGroupChatPage(group: group),
                            ),
                          );
                        }
                      },
                    ),
                  ),
              ] else ...[
                for (final session in sessions)
                  _selectedRow(
                    selected: widget.group == null && active == session.id,
                    child: HermesMessageRow(
                      title: session.title,
                      preview: session.preview,
                      trailing: widget.group == null && active == session.id
                          ? const Icon(HermesMessageIcons.check, size: 18)
                          : null,
                      onOpen: () async {
                        _close();
                        if (widget.parentContext.mounted) {
                          await openHermesSession(
                            widget.parentContext,
                            widget.parentRef,
                            session,
                          );
                          _leaveGroup();
                        }
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _messages,
                  icon: const Icon(HermesMessageIcons.messages, size: 20),
                  label: Text(l10n.messagesHomeTitle),
                ),
              ),
              if (_bots && (widget.group != null || current != null))
                CompactIconAction(
                  tooltip: widget.group != null ? 'Open group' : 'Open bot',
                  icon: const Icon(HermesMessageIcons.edit, size: 20),
                  onPressed: () {
                    _close();
                    if (!widget.parentContext.mounted) return;
                    if (widget.group != null) {
                      Navigator.of(widget.parentContext).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              HermesGroupWorkspacePage(group: widget.group!),
                        ),
                      );
                    } else {
                      openHermesBotWorkspace(widget.parentContext, current!);
                    }
                  },
                ),
              const HermesProfileButton(),
            ],
          ),
        ),
      ],
    );
  }
}
