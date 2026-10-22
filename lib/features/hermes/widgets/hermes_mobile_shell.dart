import '../../chat/voice_mode/chat_voice_mode_controller.dart';
import 'hermes_conversation_stage.dart';

import 'package:flutter/foundation.dart';

import 'hermes_keyboard_footer.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart'
    show MaterialLocalizations, Material, Divider, TextButton;

import '../../../core/services/haptic_service.dart';

import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/hermes_mobile_navigation.dart';
import '../providers/hermes_mobile_route_stack.dart';
import '../providers/hermes_file_browser.dart';
import '../providers/hermes_mobile_work.dart';
import 'hermes_file_explorer.dart';
import '../views/hermes_jobs_page.dart';
import '../views/hermes_settings_sections.dart';
import 'hermes_session_tile.dart';
import 'hermes_message_interactions.dart';
import 'hermes_messages_home.dart';
import 'hermes_message_icon.dart';
import '../providers/hermes_messages.dart';

/// Bottom navigation always opens a section's main screen.
void selectHermesWorkAreaRoot(WidgetRef ref, HermesWorkArea area) {
  FocusManager.instance.primaryFocus?.unfocus();
  ref.read(composerAutofocusEnabledProvider.notifier).set(false);
  ref.read(hermesMobileChatSwitcherProvider).dismiss();
  ref.read(hermesMobileModelPanelProvider).dismiss();
  ref.read(hermesMobileRouteStackProvider).dismissPanels();
  if (area == HermesWorkArea.chat) {
    ref.read(hermesMessagesNavigationProvider.notifier).closeSearch();
  }
  if (area == HermesWorkArea.files) {
    ref.read(hermesFileBrowserBackProvider).home();
  }
  ref.read(hermesMobileNavigationProvider.notifier).select(area);
}

Future<void> startHermesMobileConversation(
  WidgetRef ref, {
  bool task = false,
  String? prefill,
}) async {
  // A modal or source row may unmount while a new chat is being prepared.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final service = container.read(hermesApiServiceProvider);
  container.read(hermesSessionNavigationEpochProvider.notifier).bump();
  await startNewHermesChat(container, preserveBoundRuns: true);
  if (!identical(container.read(hermesApiServiceProvider), service)) return;
  if (prefill != null) {
    container.read(prefilledInputTextProvider.notifier).set(prefill);
  }
  container.read(composerAutofocusEnabledProvider.notifier).set(!task);
  container
      .read(hermesMobileNavigationProvider.notifier)
      .newConversation(task: task);
}

class HermesMobileShell extends ConsumerStatefulWidget {
  const HermesMobileShell({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<HermesMobileShell> createState() => _HermesMobileShellState();
}

class _HermesMobileShellState extends ConsumerState<HermesMobileShell> {
  bool _chatMounted = false;
  late final _compactModalOwner = ref
      .read(hermesMobileRouteStackProvider)
      .compactModalOwner;

  @override
  void dispose() {
    _compactModalOwner.dismiss();
    super.dispose();
  }

  Future<bool> _handleBack() async {
    if (ModalRoute.of(context)?.isCurrent == false) {
      return Navigator.of(context).maybePop();
    }
    final navigation = ref.read(hermesMobileNavigationProvider);
    final chatVisible =
        navigation.area == HermesWorkArea.chat && navigation.conversation;
    final call = ref.read(chatVoiceModeControllerProvider);
    if (chatVisible && call.isActive && !call.isCollapsed) {
      ref.read(chatVoiceModeControllerProvider.notifier).collapse();
      return true;
    }
    final routeStack = ref.read(hermesMobileRouteStackProvider);
    if (chatVisible && routeStack.hasPanels) {
      return routeStack.maybePopPanel();
    }
    if (navigation.area == HermesWorkArea.chat &&
        !navigation.conversation &&
        ref.read(hermesMessagesNavigationProvider).search) {
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(hermesMessagesNavigationProvider.notifier).closeSearch();
      return true;
    }
    if (navigation.area == HermesWorkArea.files &&
        ref.read(hermesFileBrowserBackProvider).back()) {
      return true;
    }
    if (ref.read(hermesMobileChatSwitcherProvider).dismiss()) return true;
    if (ref.read(hermesMobileModelPanelProvider).dismiss()) return true;
    if (chatVisible &&
        (ref.read(composerHasFocusProvider) ||
            MediaQuery.viewInsetsOf(context).bottom > 0)) {
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(composerAutofocusEnabledProvider.notifier).set(false);
      return true;
    }
    if (ref.read(hermesSessionOpeningProvider) != null) {
      ref.read(hermesSessionNavigationEpochProvider.notifier).bump();
      return true;
    }
    final controller = ref.read(hermesMobileNavigationProvider.notifier);
    if (!controller.canGoBack) return false;
    controller.back();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(hermesMobileWorkObserverProvider);
    final routeStack = ref.watch(hermesMobileRouteStackProvider);
    ref.listen(hermesMobileNavigationProvider, (_, _) {
      routeStack.dismissPanels();
    });
    ref.listen(
      activeConversationProvider.select(
        (value) => (value?.id, value?.metadata['hermesSessionId']),
      ),
      (_, _) => routeStack.dismissPanels(),
    );
    ref.listen(hermesApiServiceProvider, (_, _) => routeStack.dismissPanels());
    final navigation = ref.watch(hermesMobileNavigationProvider);
    final chatVisible =
        navigation.area == HermesWorkArea.chat && navigation.conversation;
    if (chatVisible) _chatMounted = true;
    final expandedCall =
        chatVisible &&
        ref.watch(
          chatVoiceModeControllerProvider.select(
            (s) => s.isActive && !s.isCollapsed,
          ),
        );
    final messages = ref.watch(hermesMessagesNavigationProvider);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final followsKeyboard = defaultTargetPlatform == TargetPlatform.android;
    final navigationHeight = expandedCall
        ? 0.0
        : HermesBottomNavigation.heightFor(context) +
              (chatVisible ? 2 : 8) +
              math.max(MediaQuery.viewPaddingOf(context).bottom, 8);
    final navigationInset = followsKeyboard
        ? math.max(0.0, navigationHeight - keyboardInset)
        : keyboardInset > 0
        ? 0.0
        : navigationHeight;
    final shell = CompactModalOwnerScope(
      owner: _compactModalOwner,
      child: PopScope(
        canPop:
            !expandedCall &&
            !ref.read(hermesMobileNavigationProvider.notifier).canGoBack &&
            ref.watch(hermesSessionOpeningProvider) == null &&
            !(navigation.area == HermesWorkArea.chat &&
                !chatVisible &&
                messages.search),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          unawaited(_handleBack());
        },
        child: AdaptiveScaffold(
          resizeToAvoidBottomInset: !chatVisible,
          body: Stack(
            fit: StackFit.expand,
            children: [
              HermesConversationStage(
                chatArea: navigation.area == HermesWorkArea.chat,
                logicalDetail: chatVisible,
                selectedId: ref.watch(
                  activeConversationProvider.select(
                    (value) => value?.metadata['hermesSessionId'] as String?,
                  ),
                ),
                history: Padding(
                  padding: EdgeInsets.only(bottom: navigationInset),
                  child: const SafeArea(
                    bottom: false,
                    child: HermesConversationHome(),
                  ),
                ),
                detail: _chatMounted
                    ? MediaQuery.removePadding(
                        context: context,
                        removeBottom: true,
                        child: HermesNavigationInset(
                          bottom: navigationInset,
                          child: widget.child,
                        ),
                      )
                    : null,
                other: !chatVisible && navigation.area != HermesWorkArea.chat
                    ? Padding(
                        padding: EdgeInsets.only(bottom: navigationInset),
                        child: SafeArea(
                          bottom: false,
                          child: switch (navigation.area) {
                            HermesWorkArea.chat => const SizedBox.shrink(),
                            HermesWorkArea.tasks => const _TasksArea(),
                            HermesWorkArea.files => const HermesFilesArea(),
                            HermesWorkArea.explore => const _ExploreArea(),
                          },
                        ),
                      )
                    : null,
              ),
              if (!expandedCall)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: HermesKeyboardFooter(
                    inset: keyboardInset,
                    followSystemGeometry: followsKeyboard,
                    child: SafeArea(
                      maintainBottomViewPadding: true,
                      top: false,
                      minimum: EdgeInsets.fromLTRB(
                        16,
                        chatVisible ? 2 : 8,
                        16,
                        8,
                      ),
                      child: HermesBottomNavigation(
                        selected: navigation.area,
                        onSelected: (area) =>
                            selectHermesWorkAreaRoot(ref, area),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // The shell owns logical work-area history, while its retained child
    // navigator owns pushed pages and sheets. Check that visible stack first;
    // it is not an ancestor of the shell's BuildContext.
    if (Router.maybeOf(context)?.backButtonDispatcher == null) return shell;
    return BackButtonListener(
      onBackButtonPressed: () async {
        if (!mounted) return false;
        return _handleBack();
      },
      child: shell,
    );
  }
}

class HermesBottomNavigation extends StatelessWidget {
  const HermesBottomNavigation({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  static const double height = 53;
  final HermesWorkArea selected;
  final ValueChanged<HermesWorkArea> onSelected;
  static List<String> _labels(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return [l.messagesHomeTitle, l.mobileTasks, l.mobileFiles, l.mobileSkills];
  }

  static double heightFor(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width - 32) / 4 - 12;
    var labelHeight = 0.0;
    for (final label in _labels(context)) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            fontSize: 11,
            height: 1.15,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 2,
      )..layout(maxWidth: math.max(1, width));
      labelHeight = math.max(labelHeight, painter.height);
      painter.dispose();
    }
    return math.max(height, 24 + 2 + labelHeight + 8);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final labels = _labels(context);
    final icons = [
      HermesMessageIcons.messages,
      HermesMessageIcons.tasks,
      HermesMessageIcons.folder,
      HermesMessageIcons.compass,
    ];
    return CompactNavigationSurface(
      color: theme.navigationBackground,
      child: SizedBox(
        height: heightFor(context),
        child: Row(
          children: [
            for (final entry in HermesWorkArea.values.indexed)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: TextButton(
                    key: ValueKey('hermes-nav-${entry.$2.name}'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      foregroundColor: selected == entry.$2
                          ? theme.navigationSelected
                          : theme.navigationUnselected,
                      backgroundColor: selected == entry.$2
                          ? theme.navigationSelectedBackground
                          : Colors.transparent,
                    ),
                    onPressed: () {
                      unawaited(ConduitHaptics.selectionClick());
                      onSelected(entry.$2);
                    },
                    child: Semantics(
                      key: ValueKey('hermes-nav-state-${entry.$2.name}'),
                      label: labels[entry.$1],
                      selected: selected == entry.$2,
                      excludeSemantics: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          entry.$2 == HermesWorkArea.explore
                              ? const HermesSkillsIcon()
                              : Icon(icons[entry.$1], size: 24),
                          const SizedBox(height: 2),
                          Text(
                            labels[entry.$1],
                            key: ValueKey('hermes-nav-label-${entry.$2.name}'),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  fontSize: 11,
                                  height: 1.15,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class HermesAreaHeader extends StatelessWidget {
  const HermesAreaHeader({
    super.key,
    required this.title,
    this.create,
    this.action,
    this.leading,
    this.showProfile = true,
    this.prominent = false,
  });
  final String title;
  final VoidCallback? create;
  final Widget? action, leading;
  final bool showProfile;
  final bool prominent;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
    child: Row(
      children: [
        ?leading,
        Expanded(
          child: Text(
            title,
            style:
                (prominent
                        ? Theme.of(context).textTheme.headlineSmall
                        : Theme.of(context).textTheme.titleLarge)
                    ?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: prominent ? 24 : null,
                    ),
          ),
        ),
        ?action,
        if (create != null)
          CompactIconAction(
            key: const ValueKey('hermes-create-task'),
            tooltip: AppLocalizations.of(context)!.mobileCreateTask,
            onPressed: create,
            icon: const Icon(Icons.add_rounded),
          ),
        if (showProfile) const HermesProfileButton(),
      ],
    ),
  );
}

class HermesProfileButton extends StatefulWidget {
  const HermesProfileButton({super.key});
  @override
  State<HermesProfileButton> createState() => _HermesProfileButtonState();
}

class _HermesProfileButtonState extends State<HermesProfileButton> {
  double _turns = 0;
  bool _opening = false;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Builder(
      builder: (anchor) => CompactIconAction(
        tooltip: l10n.mobileSettings,
        icon: AnimatedRotation(
          turns: _turns,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: const Icon(HermesMessageIcons.settings),
        ),
        onPressed: () async {
          if (_opening) return;
          _opening = true;
          unawaited(ConduitHaptics.selectionClick());
          final animate = !MediaQuery.disableAnimationsOf(context);
          setState(() => _turns += .25);
          if (animate) {
            await Future<void>.delayed(const Duration(milliseconds: 180));
          }
          if (!mounted || !anchor.mounted) return;
          try {
            final route = await showCompactMenuAtAnchor<String>(
              context,
              anchor,
              [
                CompactMenuChoice(
                  Routes.hermesSettings,
                  l10n.mobileHermesSettings,
                ),
                CompactMenuChoice(Routes.profile, l10n.mobileAppSettings),
              ],
            );
            if (route != null && mounted) NavigationService.pushTo(route);
          } finally {
            _opening = false;
          }
        },
      ),
    );
  }
}

class HermesConversationHome extends ConsumerStatefulWidget {
  const HermesConversationHome({super.key, this.switcher = false});
  final bool switcher;
  @override
  ConsumerState<HermesConversationHome> createState() =>
      _HermesConversationHomeState();
}

class _HermesConversationHomeState
    extends ConsumerState<HermesConversationHome> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    if (!widget.switcher) return const HermesMessagesHome();
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.watch(hermesSessionsProvider);
    return Column(
      children: [
        HermesAreaHeader(
          title: l10n.mobileRecentConversations,
          showProfile: !widget.switcher,
          prominent: widget.switcher,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(hermesSessionsProvider);
              await ref.read(hermesSessionsProvider.future);
            },
            child: sessions.when(
              loading: () => const Center(child: AdaptiveProgressIndicator()),
              error: (_, _) => HermesLoadError(
                onRetry: () => ref.invalidate(hermesSessionsProvider),
              ),
              data: (all) {
                final filtered = all
                    .where(
                      (session) =>
                          !session.isScheduledRun &&
                          '${session.title} ${session.preview ?? ''}'
                              .toLowerCase()
                              .contains(_search.toLowerCase()),
                    )
                    .toList();
                final groups = groupHermesConversations(
                  filtered,
                  DateTime.now(),
                  weekStart: MaterialLocalizations.of(context)
                      .firstDayOfWeekIndex,
                );
                final locale = Localizations.localeOf(context).toString();
                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (filtered.isEmpty)
                      _EmptyText(
                        _search.isEmpty
                            ? l10n.mobileNoConversations
                            : l10n.mobileNoSearchResults,
                      ),
                    for (final group in groups) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 16, 4),
                        child: Text(
                          switch (group.kind) {
                            HermesConversationPeriod.day => DateFormat.EEEE(
                              locale,
                            ).format(group.date!),
                            HermesConversationPeriod.lastWeek =>
                              l10n.mobileLastWeek,
                            HermesConversationPeriod.month =>
                              (group.date!.year == DateTime.now().year
                                      ? DateFormat.MMMM(locale)
                                      : DateFormat.yMMMM(locale))
                                  .format(group.date!),
                            HermesConversationPeriod.older =>
                              l10n.mobileOlderConversations,
                          },
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: context.conduitTheme.textSecondary,
                          ),
                        ),
                      ),
                      for (final session in group.sessions)
                        HermesSessionTile(
                          key: ValueKey(session.id),
                          session: session,
                          showActiveIndicator: true,
                          onOpened: widget.switcher
                              ? () => Navigator.of(context).pop()
                              : null,
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, widget.switcher ? 16 : 0),
          child: Row(
            children: [
              Expanded(
                child: CompactSearchField(
                  hint: l10n.mobileSearchConversations,
                  onChanged: (value) => setState(() => _search = value),
                ),
              ),
              const SizedBox(width: 8),
              CompactIconAction(
                key: const ValueKey('hermes-new-conversation'),
                tooltip: l10n.mobileNewConversation,
                backgroundColor: context.conduitTheme.surfaceContainerHighest,
                borderColor: context.conduitTheme.dividerColor,
                onPressed: () async {
                  await startHermesMobileConversation(ref);
                  if (widget.switcher && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(Icons.add_box_outlined),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> showHermesConversationSwitcher(BuildContext context) =>
    showCompactConversationSheet(
      context,
      const HermesConversationHome(switcher: true),
    );

class _TasksArea extends ConsumerWidget {
  const _TasksArea();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final messages = ref.watch(chatMessagesProvider);
    final pending = findPendingHermesComposerPrompt(messages);
    final running = ref.watch(isChatStreamingProvider);
    final tasks = ref.watch(hermesMobileActiveTasksProvider);
    final receipts = ref.watch(hermesTaskReceiptsProvider);
    bool hasNewerActiveRow(HermesTaskReceipt receipt) =>
        tasks.asData?.value.any(
          (row) =>
              (row['session_key'] ?? row['id']) == receipt.session.id &&
              (row['_conduitObservedAt'] is! int ||
                  row['_conduitObservedAt'] >
                      (receipt.session.updatedAt?.millisecondsSinceEpoch ?? 0)),
        ) ==
        true;
    final scheduledRuns = ref.watch(hermesSessionsProvider);
    final activeSession = ref.watch(hermesActiveSessionProvider);
    final jobs = ref.watch(hermesJobsProvider);
    final capabilities = ref.watch(hermesCapabilitiesProvider);
    final writable = capabilities.asData?.value.jobsAdmin == true;
    final available = capabilities.asData?.value.jobs == true;
    final conversation = ref.watch(activeConversationProvider);
    return Column(
      children: [
        HermesAreaHeader(
          title: l10n.mobileTasks,
          action: available
              ? HermesScheduleCreateAction(
                  writable: writable,
                  askLabel: l10n.mobileCreateTask,
                  onAsk: () =>
                      unawaited(startHermesMobileConversation(ref, task: true)),
                )
              : null,
          create: available
              ? null
              : () => unawaited(startHermesMobileConversation(ref, task: true)),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(hermesSessionsProvider);
              ref.invalidate(hermesMobileActiveTasksProvider);
              ref.invalidate(hermesCapabilitiesProvider);
              ref.invalidate(hermesJobsProvider);
              await ref.read(hermesJobsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (running || pending != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      pending != null
                          ? Icons.help_outline_rounded
                          : Icons.autorenew_rounded,
                    ),
                    title: Text(
                      conversation?.title ?? l10n.mobileNewConversation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      pending != null
                          ? l10n.mobileNeedsYou
                          : l10n.mobileRunning,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => ref
                        .read(hermesMobileNavigationProvider.notifier)
                        .showConversation(),
                  ),
                for (final receipt in receipts)
                  if ((!(running || pending != null) ||
                          receipt.session.id != activeSession) &&
                      !hasNewerActiveRow(receipt))
                    ListTile(
                      key: ValueKey('hermes-task-${receipt.session.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        switch (receipt.outcome) {
                          HermesChatOutcome.completed =>
                            HermesMessageIcons.check,
                          HermesChatOutcome.failed =>
                            Icons.error_outline_rounded,
                          HermesChatOutcome.stopped =>
                            Icons.stop_circle_outlined,
                        },
                        color: receipt.outcome == HermesChatOutcome.failed
                            ? context.conduitTheme.error
                            : null,
                      ),
                      title: Text(
                        receipt.session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(switch (receipt.outcome) {
                        HermesChatOutcome.completed => l10n.scheduleDone,
                        HermesChatOutcome.failed => l10n.error,
                        HermesChatOutcome.stopped => l10n.chatSwitcherCancelled,
                      }),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => unawaited(
                        openHermesSession(
                          context,
                          ref,
                          receipt.session,
                          bot: receipt.bot,
                          botAvatar: receipt.botAvatar,
                        ),
                      ),
                    ),
                tasks.when(
                  loading: () =>
                      const Center(child: AdaptiveProgressIndicator()),
                  error: (_, _) => HermesLoadError(
                    onRetry: () =>
                        ref.invalidate(hermesMobileActiveTasksProvider),
                  ),
                  data: (rows) => Column(
                    children: [
                      for (final row in rows)
                        if ((!(running || pending != null) ||
                                (row['session_key'] ?? row['id']) !=
                                    activeSession) &&
                            !receipts.any(
                              (receipt) =>
                                  receipt.session.id ==
                                      (row['session_key'] ?? row['id']) &&
                                  !hasNewerActiveRow(receipt),
                            ))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              row['status'] == 'waiting'
                                  ? Icons.help_outline_rounded
                                  : Icons.autorenew_rounded,
                            ),
                            title: Text(
                              row['title']?.toString() ??
                                  l10n.mobileNewConversation,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              row['status'] == 'waiting'
                                  ? l10n.mobileNeedsYou
                                  : l10n.mobileRunning,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              final id = (row['session_key'] ?? row['id'])
                                  ?.toString();
                              if (id == null || id.isEmpty) return;
                              if (id == activeSession) {
                                ref
                                    .read(
                                      hermesMobileNavigationProvider.notifier,
                                    )
                                    .showConversation();
                              } else {
                                unawaited(
                                  openHermesSession(
                                    context,
                                    ref,
                                    HermesSessionSummary(
                                      id: id,
                                      title:
                                          row['title']?.toString() ??
                                          l10n.mobileNewConversation,
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                    ],
                  ),
                ),
                if (scheduledRuns.asData?.value.any((s) => s.isScheduledRun) ==
                    true)
                  CompactContentRow(
                    title: Text(l10n.mobileRecentTaskRuns),
                    leading: const Icon(Icons.history_rounded),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => unawaited(
                      showCompactConversationSheet(
                        context,
                        Builder(
                          builder: (sheetContext) {
                            final navigator = Navigator.of(sheetContext);
                            final route = ModalRoute.of(sheetContext)!;
                            return Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    12,
                                  ),
                                  child: Text(
                                    l10n.mobileRecentTaskRuns,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                                Expanded(
                                  child: ListView(
                                    children: [
                                      for (final session
                                          in scheduledRuns.asData!.value.where(
                                            (s) => s.isScheduledRun,
                                          ))
                                        HermesSessionTile(
                                          key: ValueKey(session.id),
                                          session: session,
                                          onOpened: () {
                                            if (!navigator.mounted ||
                                                !route.isActive) {
                                              return;
                                            }
                                            if (route.isCurrent) {
                                              navigator.pop();
                                            } else {
                                              navigator.removeRoute(route);
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                _SectionTitle(l10n.mobileSchedules),
                if (capabilities.isLoading)
                  const Center(child: AdaptiveProgressIndicator())
                else if (capabilities.hasError)
                  HermesLoadError(
                    onRetry: () => ref.invalidate(hermesCapabilitiesProvider),
                  )
                else if (!available)
                  _EmptyText(l10n.hermesJobAdminDisabled)
                else
                  jobs.when(
                    loading: () =>
                        const Center(child: AdaptiveProgressIndicator()),
                    error: (_, _) => HermesLoadError(
                      onRetry: () => ref.invalidate(hermesJobsProvider),
                    ),
                    data: (items) => Material(
                      color: context.conduitTheme.cardBackground,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          if (items.isEmpty)
                            _EmptyText(l10n.hermesNoSchedulesYet),
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            HermesScheduleCard(
                              key: ValueKey(items[i].id),
                              job: items[i],
                              writable: writable,
                              grouped: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ExploreArea extends ConsumerStatefulWidget {
  const _ExploreArea();
  @override
  ConsumerState<_ExploreArea> createState() => _ExploreAreaState();
}

class _ExploreAreaState extends ConsumerState<_ExploreArea> {
  String _search = '';
  String _skillCategory = '';
  int _skillLimit = 16;

  String _skillTitle(String command) => command
      .replaceFirst('/', '')
      .replaceAll(RegExp(r'[-_]'), ' ')
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');

  String _categoryOf(Prompt skill) {
    final raw = skill.meta?['hermesSkillCategory'];
    return raw is String &&
            raw.trim().isNotEmpty &&
            raw.trim() != 'uncategorized'
        ? raw.trim()
        : 'general';
  }

  String _categoryLabel(String category, AppLocalizations l10n) =>
      switch (category) {
        'uncategorized' || 'general' => l10n.mobileGeneralSkillCategory,
        'mlops' => 'Machine Learning',
        'github' => 'GitHub',
        'devops' => 'DevOps',
        'mcp' => 'MCP',
        'autonomous-ai-agents' => 'Autonomous AI Agents',
        _ => _skillTitle(category),
      };

  Widget _skillDetails(Prompt skill, AppLocalizations l10n) =>
      CompactContentRow(
        key: ValueKey('hermes-skill-${skill.command}'),
        subtitle: skill.title.isEmpty
            ? null
            : Text(skill.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        title: Text(
          _skillTitle(skill.command),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, size: 20),
        onTap: () async {
          final start = await showCompactConfigurationSheet<bool>(
            context,
            (sheetContext) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _skillTitle(skill.command),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (skill.title.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(skill.title),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: CompactActionBubble(
                      label: l10n.newChat,
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                    ),
                  ),
                ],
              ),
            ),
          );
          if (start == true && mounted) {
            await startHermesMobileConversation(ref, prefill: skill.content);
          }
        },
      );

  Widget _skillGroups(List<Prompt> items, AppLocalizations l10n) {
    final query = _search.trim().toLowerCase();
    final filtered =
        items.where((skill) {
          final category = _categoryOf(skill);
          return (_skillCategory.isEmpty || _skillCategory == category) &&
              '${skill.command} ${skill.title} $category ${_categoryLabel(category, l10n)}'
                  .toLowerCase()
                  .contains(query);
        }).toList()..sort(
          (a, b) => _skillTitle(a.command).compareTo(_skillTitle(b.command)),
        );
    if (filtered.isEmpty) {
      return _EmptyText(
        query.isEmpty && _skillCategory.isEmpty
            ? l10n.mobileNoSkills
            : l10n.mobileNoSearchResults,
      );
    }
    return Column(
      children: [
        for (final skill in filtered.take(_skillLimit))
          _skillDetails(skill, l10n),
        if (filtered.length > _skillLimit)
          AdaptiveButton.child(
            key: const ValueKey('hermes-more-skills'),
            style: AdaptiveButtonStyle.plain,
            onPressed: () => setState(() => _skillLimit += 16),
            child: Text(l10n.mobileMoreSkills),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final skills = ref.watch(hermesMobileSkillsProvider);
    final categories =
        (skills.asData?.value ?? const <Prompt>[])
            .map(_categoryOf)
            .toSet()
            .toList()
          ..sort(
            (a, b) =>
                _categoryLabel(a, l10n).compareTo(_categoryLabel(b, l10n)),
          );
    final capabilities = ref.watch(hermesCapabilitiesProvider).asData?.value;
    return Column(
      children: [
        HermesAreaHeader(
          title: l10n.mobileSkills,
          action: ref.watch(hermesApiServiceProvider) is HermesDesktopApiService
              ? TextButton(
                  onPressed: () => NavigationService.pushTo(Routes.hermesMcp),
                  child: Text(l10n.mobileIntegrations),
                )
              : null,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              final service = ref.read(hermesApiServiceProvider);
              if (service is HermesDesktopApiService) {
                service.invalidateSkillCatalog();
              }
              ref.invalidate(hermesMobileSkillsProvider);
              ref.invalidate(hermesToolsetsProvider);
              await ref.read(hermesMobileSkillsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Row(
                        children: [
                          CompactPopupMenu<String>(
                            maxHeightFraction: .5,
                            key: const ValueKey('hermes-skill-category-filter'),
                            tooltip: l10n.mobileFilterSkillCategories,
                            icon: Icon(
                              Icons.filter_list_rounded,
                              color: _skillCategory.isEmpty
                                  ? null
                                  : context.conduitTheme.buttonPrimary,
                            ),
                            choices: [
                              CompactMenuChoice(
                                '',
                                l10n.mobileAllSkillCategories,
                                selected: _skillCategory.isEmpty,
                              ),
                              for (final category in categories)
                                CompactMenuChoice(
                                  category,
                                  _categoryLabel(category, l10n),
                                  selected: _skillCategory == category,
                                ),
                            ],
                            onSelected: (category) => setState(() {
                              _skillCategory = category;
                              _skillLimit = 16;
                            }),
                          ),
                          Expanded(
                            child: CompactSearchField(
                              hint: l10n.mobileSearchSkills,
                              onChanged: (value) => setState(() {
                                _search = value;
                                _skillLimit = 16;
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    skills.when(
                      loading: () =>
                          const Center(child: AdaptiveProgressIndicator()),
                      error: (_, _) => HermesLoadError(
                        onRetry: () =>
                            ref.invalidate(hermesMobileSkillsProvider),
                      ),
                      data: (items) => _skillGroups(items, l10n),
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      leading: const Icon(HermesMessageIcons.messages),
                      title: Text(l10n.mobileAskHermes),
                      onTap: () => unawaited(
                        startHermesMobileConversation(
                          ref,
                          prefill: l10n.mobileManageSkillsPrompt,
                        ),
                      ),
                    ),
                  ],
                ),
                if (capabilities?.toolsets == true)
                  CompactDisclosureSection(
                    title: l10n.mobileTools,
                    icon: Icons.build_outlined,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: HermesToolsetsSection(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class HermesTaskStarter extends ConsumerWidget {
  const HermesTaskStarter({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 96, 24, 96),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.mobileTaskPrompt,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(l10n.mobileTaskHelp),
            const SizedBox(height: 20),
            for (final example in [
              l10n.mobileTaskExampleOne,
              l10n.mobileTaskExampleTwo,
              l10n.mobileTaskExampleThree,
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AdaptiveButton.child(
                  style: AdaptiveButtonStyle.plain,
                  onPressed: () {
                    ref.read(prefilledInputTextProvider.notifier).set(example);
                    ref.read(inputFocusTriggerProvider.notifier).increment();
                  },
                  child: Text(example, textAlign: TextAlign.start),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class HermesLoadError extends StatelessWidget {
  const HermesLoadError({super.key, required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppLocalizations.of(context)!.mobileLoadFailed,
            textAlign: TextAlign.center,
          ),
          AdaptiveButton.child(
            style: AdaptiveButtonStyle.plain,
            onPressed: onRetry,
            child: Text(AppLocalizations.of(context)!.mobileRetry),
          ),
        ],
      ),
    ),
  );
}

class _EmptyText extends StatelessWidget {
  const _EmptyText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 24),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: context.conduitTheme.textSecondary),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

enum HermesConversationPeriod { day, lastWeek, month, older }

class HermesConversationGroup {
  HermesConversationGroup(this.kind, this.date);
  final HermesConversationPeriod kind;
  final DateTime? date;
  final List<HermesSessionSummary> sessions = [];
}

/// Calendar boundaries avoid DST-dependent 24-hour assumptions.
List<HermesConversationGroup> groupHermesConversations(
  List<HermesSessionSummary> sessions,
  DateTime now, {
  int weekStart = 0,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final start = DateTime(
    today.year,
    today.month,
    today.day - (today.weekday % 7 - weekStart + 7) % 7,
  );
  final previous = DateTime(start.year, start.month, start.day - 7);
  final sorted = sessions.indexed.toList()
    ..sort((a, b) {
      final x = a.$2.updatedAt, y = b.$2.updatedAt;
      if (x == null || y == null) {
        return x == y
            ? a.$1.compareTo(b.$1)
            : x == null
            ? 1
            : -1;
      }
      final order = y.compareTo(x);
      return order == 0 ? a.$1.compareTo(b.$1) : order;
    });
  final groups = <String, HermesConversationGroup>{};
  for (final entry in sorted) {
    final session = entry.$2;
    final date = session.updatedAt?.toLocal();
    final kind = date == null
        ? HermesConversationPeriod.older
        : !date.isBefore(start)
        ? HermesConversationPeriod.day
        : !date.isBefore(previous)
        ? HermesConversationPeriod.lastWeek
        : HermesConversationPeriod.month;
    final key = switch (kind) {
      HermesConversationPeriod.day => '${date!.year}-${date.month}-${date.day}',
      HermesConversationPeriod.month => '${date!.year}-${date.month}',
      _ => kind.name,
    };
    (groups[key] ??= HermesConversationGroup(kind, date)).sessions.add(session);
  }
  return groups.values.toList();
}
