import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../navigation/utils/chat_list_back.dart';
import '../../navigation/widgets/sidebar_page_leading_button.dart';
import '../widgets/hermes_room_avatars.dart';
import '../widgets/hermes_room_composer.dart';
import '../widgets/hermes_room_info_sheet.dart';
import '../widgets/hermes_room_timeline.dart';

/// A Hermes Group Chat, opened like a chat: the bots' messages with their
/// names and faces, the user's own bubbles, live bot status by the title,
/// approvals as cards, and Continue when a discussion paused. Reads the
/// room every two seconds while it is on screen and the app is in front.
class HermesRoomPage extends ConsumerStatefulWidget {
  const HermesRoomPage({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<HermesRoomPage> createState() => _HermesRoomPageState();
}

class _HermesRoomPageState extends ConsumerState<HermesRoomPage>
    with WidgetsBindingObserver {
  late final HermesOpenRoomNotifier _openRoom;
  Timer? _poll;
  Timer? _tick;
  bool _acting = false;

  /// Whether the page is in view: the router keeps it mounted out of sight,
  /// with its tickers muted, while another sidebar destination is open.
  bool _inView = true;
  bool _foreground = true;

  List<HermesRoomEvent>? _projectedEvents;
  String? _projectedShape;
  List<HermesRoomTimelineItem> _items = const [];

  HermesRoomController get _room =>
      ref.read(hermesRoomProvider(widget.roomId).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openRoom = ref.read(hermesOpenRoomProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openRoom.set(widget.roomId);
    });
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _tick?.cancel();
    final openRoom = _openRoom;
    final roomId = widget.roomId;
    // Providers may not change while the tree is being torn down.
    Future.microtask(() => openRoom.clear(roomId));
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inView = TickerMode.valuesOf(context).enabled;
    if (inView == _inView) return;
    _inView = inView;
    if (!inView) {
      _stopTimers();
    } else {
      // Providers may not change while the tree builds.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _inView && _foreground) _startPolling();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _inView) {
      _startPolling();
      // The ticker comes back with the next build.
      setState(() {});
    } else {
      _stopTimers();
    }
  }

  void _stopTimers() {
    _poll?.cancel();
    _poll = null;
    _tick?.cancel();
    _tick = null;
  }

  void _startPolling() {
    _poll?.cancel();
    unawaited(_room.refresh());
    _poll = Timer.periodic(
      kHermesRoomPollInterval,
      (_) => unawaited(_room.refresh()),
    );
  }

  /// Ticks once a second while a bot works and the page is seen, so its
  /// elapsed time moves.
  void _syncTicker(bool working) {
    if (working && _inView && _foreground && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!working || !_inView || !_foreground) {
      _tick?.cancel();
      _tick = null;
    }
  }

  List<HermesRoomTimelineItem> _timeline(HermesRoomView view) {
    final room = view.room;
    if (room == null) return const [];
    final shape = [
      view.driver?.maxContinues,
      for (final member in room.members) '${member.memberId}=${member.name}',
    ].join('|');
    if (!identical(view.events, _projectedEvents) || shape != _projectedShape) {
      _projectedEvents = view.events;
      _projectedShape = shape;
      _items = projectHermesRoomTimeline(
        view.events,
        room,
        maxContinues: view.driver?.maxContinues,
      );
    }
    return _items;
  }

  void _showError(Object error) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final detail = hermesRoomRefusalDetail(error);
    UiUtils.showMessage(
      context,
      detail == null
          ? l10n.hermesRoomActionFailed
          : l10n.hermesRoomRefused(detail),
      isError: true,
    );
  }

  Future<bool> _send(String text) async {
    try {
      await _room.send(text);
      return true;
    } catch (error) {
      // An unclear answer keeps the words and says so above the composer;
      // a refusal gives them back with Hermes' reason.
      if (hermesRoomSendAdmittedNothing(error) ||
          hermesRoomRefusalDetail(error) != null) {
        _showError(error);
      }
      return false;
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await action();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _stop() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final stopped = await _room.stop();
      if (mounted) {
        UiUtils.showMessage(context, l10n.hermesRoomStoppedCount(stopped));
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _openInfo() async {
    final action = await showHermesRoomInfoSheet(
      context,
      roomId: widget.roomId,
    );
    if (!mounted) return;
    switch (action) {
      case HermesRoomInfoAction.stop:
        await _stop();
      case HermesRoomInfoAction.disband:
        try {
          await _room.disband();
          if (mounted) {
            NavigationService.returnToPreviousPage(
              fallback: Routes.hermesSessions,
            );
          }
        } catch (error) {
          _showError(error);
        }
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final view = ref.watch(hermesRoomProvider(widget.roomId));
    final room = view.room;
    final driver = view.driver;
    final statuses = room == null
        ? const <String, HermesRoomMemberStatus>{}
        : hermesRoomMemberStatuses(
            view.events,
            room.members,
            driver?.memberActivity ?? const [],
            DateTime.now(),
          );
    final working =
        (driver?.working ?? false) ||
        (driver?.memberActivity.isNotEmpty ?? false);
    _syncTicker(statuses.values.any((status) => status.busy));
    final canStop = driver != null && working && !view.gone;
    final items = _timeline(view);
    final topInset =
        MediaQuery.viewPaddingOf(context).top +
        conduitAdaptiveToolbarHeightOf(context);

    final actions = buildConduitAdaptiveToolbarActionWidgets([
      if (canStop)
        ConduitAdaptiveAppBarIconButton(
          key: const ValueKey<String>('hermes-room-toolbar-stop'),
          icon: Icons.stop_circle_outlined,
          iosSymbol: 'stop.circle',
          iconColor: theme.textPrimary,
          semanticLabel: l10n.hermesRoomStopWork,
          onPressed: _stop,
        ),
      if (room != null)
        ConduitAdaptiveAppBarIconButton(
          key: const ValueKey<String>('hermes-room-toolbar-info'),
          icon: Icons.info_outline,
          iosSymbol: 'info.circle',
          iconColor: theme.textPrimary,
          semanticLabel: l10n.hermesRoomInfoTitle,
          onPressed: _openInfo,
        ),
    ]);

    return ChatListBackScope(
      fallback: Routes.hermesSessions,
      child: AdaptiveRouteShell(
        backgroundColor: theme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: buildConduitCenteredAdaptiveAppBar(
          context: context,
          tintColor: theme.textPrimary,
          leading: SidebarPageLeadingButton(
            fallback: Routes.hermesSessions,
            iconColor: theme.textPrimary,
          ),
          title: _RoomTitle(
            room: room,
            status: _statusLine(l10n, room, driver, statuses),
            onTap: room == null ? null : _openInfo,
          ),
          actions: actions,
          cupertinoTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: actions,
          ),
          centerTitle: false,
        ),
        body: Column(
          children: [
            Expanded(
              child: _body(
                view,
                items,
                topInset: topInset,
                canStop: canStop,
              ),
            ),
            ..._banners(l10n, view),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  Spacing.xs,
                  Spacing.md,
                  Spacing.sm,
                ),
                child: HermesRoomComposer(
                  members: room?.members ?? const [],
                  enabled: room != null && driver != null && !view.gone,
                  sending: view.sending,
                  unsentText: view.unsentText,
                  onSend: _send,
                  onStop: canStop ? _stop : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    HermesRoomView view,
    List<HermesRoomTimelineItem> items, {
    required double topInset,
    required bool canStop,
  }) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final room = view.room;
    if (room == null) {
      if (!view.loaded) {
        return const Center(child: AdaptiveProgressIndicator());
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                view.gone ? l10n.hermesRoomGone : l10n.hermesRoomLoadFailed,
                textAlign: TextAlign.center,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
              if (!view.gone) ...[
                const SizedBox(height: Spacing.md),
                ConduitButton(
                  text: l10n.retry,
                  isCompact: true,
                  onPressed: () => unawaited(_room.refresh()),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final pending = view.driver?.pendingActions ?? const [];
    final rows = <Widget>[
      if (items.isEmpty)
        _RoomIntro(
          key: const ValueKey<String>('hermes-room-intro'),
          room: room,
          purpose: view.context?.purpose,
        ),
      for (var index = 0; index < items.length; index++)
        HermesRoomTimelineRow(
          key: ValueKey<String>(items[index].key),
          item: items[index],
          roomId: room.id,
          previous: index == 0 ? null : items[index - 1],
          busy: _acting,
          onContinue: view.gone || view.driver == null
              ? null
              : (id) => _act(() => _room.continueDiscussion(id)),
          // A paused discussion runs no turn, and still ends from its card.
          onStop: view.gone || view.driver == null ? null : _stop,
        ),
      for (final action in pending)
        HermesRoomDecisionCard(
          key: ValueKey<String>(
            'hermes-room-action-${action.kind}-${action.taskId}-'
            '${action.executionGeneration}',
          ),
          action: action,
          room: room,
          busy: _acting,
          onAnswer: (action, choice) =>
              _act(() => _room.answer(action, choice: choice)),
        ),
    ];
    return ListView.builder(
      key: const ValueKey<String>('hermes-room-timeline'),
      reverse: true,
      padding: EdgeInsets.only(top: topInset + Spacing.sm, bottom: Spacing.sm),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[rows.length - 1 - index],
    );
  }

  List<Widget> _banners(AppLocalizations l10n, HermesRoomView view) {
    final notes = [
      if (view.gone && view.room != null) l10n.hermesRoomGone,
      if (!view.gone && view.loaded && view.room != null && view.driver == null)
        l10n.hermesRoomNotRunning,
      if (!view.gone && view.room != null && view.readError != null)
        l10n.hermesRoomRefreshFailed,
      if (view.unsentText != null && !view.sending) l10n.hermesRoomSendUnclear,
    ];
    final theme = context.conduitTheme;
    return [
      for (final note in notes)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.xxs,
            Spacing.lg,
            0,
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: IconSize.small,
                color: theme.textSecondary,
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  note,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// The compact line under the title: who works and in what, else who
  /// waits, else how many bots the room has.
  String? _statusLine(
    AppLocalizations l10n,
    HermesRoom? room,
    HermesRoomDriverStatus? driver,
    Map<String, HermesRoomMemberStatus> statuses,
  ) {
    if (room == null) return null;
    if (driver?.pendingActions.any((action) => action.isApproval) ?? false) {
      return l10n.hermesRoomNeedsYou;
    }
    String describe(HermesRoomMember member) {
      final status = statuses[member.memberId]!;
      final elapsed = status.elapsed;
      return [
        member.name,
        if (status.kind == HermesRoomMemberStatusKind.stalled)
          l10n.hermesRoomQuiet(
            formatHermesRoomElapsed(elapsed ?? Duration.zero),
          )
        else ...[
          ?status.tool,
          if (elapsed != null) formatHermesRoomElapsed(elapsed),
        ],
      ].join(' · ');
    }

    final busy = [
      for (final member in room.members)
        if (statuses[member.memberId]?.busy ?? false) member,
    ];
    if (busy.isNotEmpty) {
      final more = busy.length - 1;
      return more > 0 ? '${describe(busy.first)} +$more' : describe(busy.first);
    }
    for (final member in room.members) {
      final kind = statuses[member.memberId]?.kind;
      if (kind == HermesRoomMemberStatusKind.queued) {
        return '${member.name} · ${l10n.hermesRoomWaiting}';
      }
    }
    return l10n.hermesRoomBotCount(room.members.length);
  }
}

class _RoomTitle extends StatelessWidget {
  const _RoomTitle({required this.room, this.status, this.onTap});

  final HermesRoom? room;
  final String? status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final room = this.room;
    if (room == null) return const SizedBox.shrink();
    final status = this.status;
    return Semantics(
      button: onTap != null,
      header: true,
      label: [room.name, ?status].join(', '),
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey<String>('hermes-room-title'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.62,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HermesRoomAvatarStack(members: room.members, size: 28),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.name,
                      key: const ValueKey<String>('hermes-room-title-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: conduitAdaptiveToolbarLeadingTitleTextStyle(
                        context,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (status != null)
                      Text(
                        status,
                        key: const ValueKey<String>('hermes-room-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelSmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What an empty room shows: its bots and purpose.
class _RoomIntro extends StatelessWidget {
  const _RoomIntro({super.key, required this.room, this.purpose});

  final HermesRoom room;
  final String? purpose;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final purpose = this.purpose?.trim();
    return Padding(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Column(
        children: [
          HermesRoomAvatarStack(members: room.members, size: 56),
          const SizedBox(height: Spacing.sm),
          Text(
            room.name,
            textAlign: TextAlign.center,
            style: AppTypography.titleMediumStyle.copyWith(
              color: theme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            purpose == null || purpose.isEmpty
                ? room.members.map((member) => member.name).join(', ')
                : purpose,
            textAlign: TextAlign.center,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: Spacing.xxs),
          Text(
            l10n.hermesRoomMessageHint,
            textAlign: TextAlign.center,
            style: AppTypography.labelSmallStyle.copyWith(
              color: theme.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
