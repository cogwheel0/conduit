import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show automationsAvailableProvider;
import 'package:conduit_core/features/calendar/calendar_access.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/models/conversation.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../navigation/providers/conversation_selection_provider.dart';
import 'calendar_calendars_sheet.dart';
import 'calendar_color_dot.dart';
import 'calendar_event_editor.dart';
import 'calendar_event_sheet.dart';
import 'calendar_format.dart';

/// Wraps a calendar screen with the rule every entry point shares: the server
/// and account allow the calendar.
class CalendarGate extends ConsumerWidget {
  const CalendarGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (!ref.watch(calendarAvailableProvider)) {
      return UtilityPageScaffold.settings(
        key: const Key('calendar-unavailable'),
        title: l10n.calendarTitle,
        children: [Text(l10n.calendarUnavailable)],
      );
    }
    return child;
  }
}

/// The account's Open WebUI calendar as a compact agenda over a bounded stretch
/// of days. The server owns every event and expands recurring ones; this page
/// only reads them and sends the user's changes.
class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const CalendarGate(child: _CalendarAgenda());
}

class _CalendarAgenda extends ConsumerStatefulWidget {
  const _CalendarAgenda();

  @override
  ConsumerState<_CalendarAgenda> createState() => _CalendarAgendaState();
}

class _CalendarAgendaState extends ConsumerState<_CalendarAgenda> {
  @override
  void initState() {
    super.initState();
    // Reopening shows what the server holds now. A first open has no agenda
    // yet, and reading the provider below is what loads it, so only a provider
    // that already existed is refreshed.
    if (ref.exists(calendarAgendaProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(calendarAgendaProvider).isLoading) return;
        _refresh();
      });
    }
  }

  /// The range last asked for, so the range bar stays when moving to it
  /// failed and there is no agenda to read it from.
  CalendarRange? _requested;

  /// Whether a move to another range is loading.
  bool _paging = false;

  /// Counts moves to another range, so only the latest one clears [_paging].
  int _pageRequests = 0;

  CalendarAgenda get _notifier => ref.read(calendarAgendaProvider.notifier);

  /// The account is captured here, on the action, before anything is awaited.
  Future<void> _refresh({CalendarRange? range}) async {
    final owner = _notifier.captureOwner();
    if (owner == null) return;
    await _notifier.refresh(owner: owner, range: range);
  }

  /// Moves the agenda to [range], showing progress in the range bar.
  Future<void> _page(CalendarRange range) async {
    final request = ++_pageRequests;
    setState(() {
      _requested = range;
      _paging = true;
    });
    try {
      await _refresh(range: range);
    } finally {
      // An earlier move that ends while a later one loads leaves the
      // progress showing.
      if (mounted && request == _pageRequests) {
        setState(() => _paging = false);
      }
    }
  }

  Future<void> _shift(CalendarRange range, int days) =>
      _page(range.shifted(days, zone: ref.read(calendarZoneProvider)));

  CalendarWallTime _todayIn(CalendarZone zone) {
    final now = ref.read(calendarClockProvider)().toUtc();
    return wallTimeAt(now.microsecondsSinceEpoch * 1000, zone).dateOnly;
  }

  Future<void> _today() {
    final zone = ref.read(calendarZoneProvider);
    return _page(
      CalendarRange.days(_todayIn(zone), calendarAgendaDays, zone: zone),
    );
  }

  Future<void> _add(CalendarAgendaData data) async {
    final owner = _notifier.captureOwner();
    if (owner == null) return;
    await showCalendarEventEditor(
      context,
      owner: owner,
      initialDay: data.range.firstDay,
    );
  }

  Future<void> _open(CalendarAgendaItem item) async {
    switch (item) {
      case CalendarEventModel():
        final owner = _notifier.captureOwner();
        if (owner == null) return;
        await showCalendarEventSheet(context, event: item, owner: owner);
      case ScheduledTaskCalendarEntry():
        await _openScheduled(item);
    }
  }

  /// Opens the task a scheduled entry belongs to, or what a past run produced.
  ///
  /// An entry is the server's projection, not a stored event, so it never
  /// reaches an event route; it leads to the automation, or to the chat or
  /// channel message the run made. A result in a channel goes to the shell that
  /// is already mounted under this page, as the scheduled task page does, since
  /// pushing it again would reserve that shell's page key twice.
  Future<void> _openScheduled(ScheduledTaskCalendarEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final owner = _notifier.captureOwner();
    final automationId = entry.automationId;
    if (owner == null ||
        automationId == null ||
        !ref.read(automationsAvailableProvider)) {
      return;
    }
    final channelId = entry.resultChannelId;
    if (channelId != null) {
      context.goNamed(RouteNames.channel, pathParameters: {'id': channelId});
      return;
    }
    final chatId = entry.resultChatId;
    if (chatId == null) {
      context.pushNamed(
        RouteNames.scheduledTaskDetail,
        pathParameters: {'id': automationId},
      );
      return;
    }

    final originRoute = NavigationService.currentRoute;
    final originRevision = NavigationService.currentRouteRevision;
    final when = DateTime.fromMicrosecondsSinceEpoch(entry.startAtNs ~/ 1000);
    final result = await ref
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: chatId,
            title: entry.title,
            createdAt: when,
            updatedAt: when,
          ),
        );
    if (!mounted ||
        !_notifier.isCurrentOwner(owner) ||
        NavigationService.currentRoute != originRoute ||
        NavigationService.currentRouteRevision != originRevision) {
      return;
    }
    switch (result.disposition) {
      case ConversationSelectionDisposition.committed:
        context.go(Routes.chat);
      case ConversationSelectionDisposition.canceled:
        break;
      case ConversationSelectionDisposition.failed:
        UiUtils.showMessage(
          context,
          l10n.scheduledTaskOpenResultFailed,
          isError: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zone = ref.watch(calendarZoneProvider);
    ref.watch(calendarClockProvider);
    final state = ref.watch(calendarAgendaProvider);
    final data = state.asData?.value;
    final range = data?.range ?? _requested;
    final today = _todayIn(zone);

    return UtilityPageScaffold.settings(
      title: l10n.calendarTitle,
      trailing: AdaptiveTooltip(
        message: l10n.calendarAddEvent,
        child: ConduitAdaptiveAppBarIconButton(
          key: const Key('calendar-add-event'),
          icon: context.usesCupertinoChrome ? CupertinoIcons.add : Icons.add,
          semanticLabel: l10n.calendarAddEvent,
          onPressed: data == null ? null : () => _add(data),
        ),
      ),
      children: [
        if (range != null) ...[
          _RangeBar(
            range: range,
            today: today,
            paging: _paging,
            onEarlier: () => _shift(range, -calendarAgendaDays),
            onLater: () => _shift(range, calendarAgendaDays),
            onToday: range.firstDay.sameDate(today) ? null : _today,
          ),
          const SizedBox(height: Spacing.md),
        ],
        if (data == null && state.isLoading)
          const Padding(
            padding: EdgeInsets.all(Spacing.md),
            child: Center(child: ConduitLoadingIndicator(isCompact: true)),
          )
        else if (data == null)
          InsetGroupedList(
            children: [
              _NoticeRow(
                key: const Key('calendar-retry'),
                title: l10n.calendarLoadFailed,
                action: l10n.retry,
                onTap: _refresh,
              ),
            ],
          )
        else ...[
          if (data.stale) ...[
            InsetGroupedList(
              children: [
                _NoticeRow(
                  key: const Key('calendar-stale'),
                  title: l10n.calendarStale,
                  action: l10n.retry,
                  onTap: _refresh,
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
          ],
          if (data.items.isEmpty)
            InsetGroupedSection(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: () => _add(data),
                child: ConduitEmptyState(
                  key: const Key('calendar-empty'),
                  isCompact: true,
                  icon: UiUtils.platformIcon(
                    ios: CupertinoIcons.calendar,
                    android: Icons.event_available_outlined,
                  ),
                  title: l10n.calendarEmpty,
                  message: '',
                  action: ConduitButton(
                    key: const Key('calendar-empty-add'),
                    text: l10n.calendarAddEvent,
                    isCompact: true,
                    isSecondary: true,
                    onPressed: () => _add(data),
                  ),
                ),
              ),
            )
          else
            ..._days(context, l10n, data, zone, today),
        ],
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          footer: l10n.calendarTimezoneNote,
          children: [
            UtilityRow(
              key: const Key('calendar-manage-calendars'),
              title: l10n.calendarManageCalendars,
              leading: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.calendar,
                  android: Icons.calendar_month_outlined,
                ),
              ),
              showChevron: true,
              onTap: data == null
                  ? null
                  : () {
                      final owner = _notifier.captureOwner();
                      if (owner == null) return;
                      showCalendarsSheet(context, owner: owner);
                    },
            ),
          ],
        ),
      ],
    );
  }

  /// One grouped list per day that has something on it, in order.
  List<Widget> _days(
    BuildContext context,
    AppLocalizations l10n,
    CalendarAgendaData data,
    CalendarZone zone,
    CalendarWallTime today,
  ) {
    final byDay = <CalendarWallTime, List<CalendarAgendaItem>>{};
    for (final item in data.items) {
      final span = switch (item) {
        CalendarEventModel() => daySpan(
          startNs: item.startAtNs,
          endNs: item.endAtNs,
          zone: zone,
        ),
        ScheduledTaskCalendarEntry() => daySpan(
          startNs: item.startAtNs,
          zone: zone,
        ),
      };
      for (final day in daysInRange(span, data.range)) {
        byDay.putIfAbsent(day, () => []).add(item);
      }
    }
    final days = byDay.keys.toList()..sort();
    final calendarsById = {for (final c in data.calendars) c.id: c};
    final scheduledCalendar = data.calendars
        .where((c) => c.isVirtual)
        .firstOrNull;
    return [
      for (final (index, day) in days.indexed) ...[
        if (index > 0) const SizedBox(height: Spacing.md),
        _DayHeader(
          key: Key('calendar-day-${day.dateOnly}'),
          label: formatCalendarDayHeading(
            context,
            l10n,
            day: day,
            today: today,
          ),
          isToday: day.sameDate(today),
        ),
        const SizedBox(height: Spacing.sm),
        InsetGroupedList(
          children: [
            for (final item in byDay[day]!)
              _ItemRow(
                key: Key('calendar-item-${item.key}'),
                item: item,
                day: day,
                zone: zone,
                access: data.access,
                calendar: switch (item) {
                  CalendarEventModel() => calendarsById[item.calendarId],
                  ScheduledTaskCalendarEntry() => scheduledCalendar,
                },
                onTap: () => _open(item),
              ),
          ],
        ),
      ],
    ];
  }
}

/// The heading over one day's events, set like an inset group's title. Today's
/// stands out in the accent colour.
class _DayHeader extends StatelessWidget {
  const _DayHeader({super.key, required this.label, required this.isToday});

  final String label;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final native = context.usesCupertinoChrome;
    final base = native
        ? AppTypography.bodySmallStyle
        : AppTypography.labelMediumStyle;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: base.copyWith(
            color: isToday ? theme.buttonPrimary : theme.textSecondary,
            fontWeight: isToday || !native ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// A row that says something went wrong and offers to try again.
class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    super.key,
    required this.title,
    required this.action,
    required this.onTap,
  });

  final String title;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return UtilityRow(
      title: title,
      semanticLabel: '$title. $action',
      leading: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.exclamationmark_circle,
          android: Icons.error_outline,
        ),
        color: theme.warning,
      ),
      status: Text(
        action,
        style: theme.bodyMedium?.copyWith(
          color: theme.buttonPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: onTap,
    );
  }
}

/// The agenda's days, with chevrons to move a page back or forward and a way
/// back to today.
class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.range,
    required this.today,
    required this.paging,
    required this.onEarlier,
    required this.onLater,
    required this.onToday,
  });

  final CalendarRange range;
  final CalendarWallTime today;
  final bool paging;
  final VoidCallback onEarlier;
  final VoidCallback onLater;

  /// Null when the agenda already starts today.
  final VoidCallback? onToday;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Row(
      children: [
        ConduitIconButton(
          key: const Key('calendar-earlier'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.chevron_left,
            android: Icons.chevron_left,
          ),
          tooltip: l10n.calendarPreviousDays(range.dayCount),
          iconColor: theme.buttonPrimary,
          isCompact: true,
          onPressed: onEarlier,
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Semantics(
                  header: true,
                  liveRegion: true,
                  child: Text(
                    formatCalendarRange(
                      context,
                      l10n,
                      range: range,
                      today: today,
                    ),
                    key: const Key('calendar-range'),
                    style: theme.headingSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              if (paging) ...[
                const SizedBox(width: Spacing.sm),
                const ConduitLoadingIndicator(
                  key: Key('calendar-paging'),
                  size: IconSize.sm,
                  isCompact: true,
                ),
              ],
            ],
          ),
        ),
        ConduitIconButton(
          key: const Key('calendar-later'),
          icon: UiUtils.platformIcon(
            ios: CupertinoIcons.chevron_right,
            android: Icons.chevron_right,
          ),
          tooltip: l10n.calendarNextDays(range.dayCount),
          iconColor: theme.buttonPrimary,
          isCompact: true,
          onPressed: onLater,
        ),
        ConduitTextButton(
          key: const Key('calendar-today'),
          text: l10n.calendarToday,
          isPrimary: true,
          onPressed: onToday,
        ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.day,
    required this.zone,
    required this.access,
    required this.calendar,
    required this.onTap,
  });

  final CalendarAgendaItem item;
  final CalendarWallTime day;
  final CalendarZone zone;
  final CalendarAccess? access;

  /// The calendar the item is in, when the account can see it.
  final CalendarModel? calendar;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    switch (item) {
      case final CalendarEventModel event:
        final dot = CalendarColorDot(
          color:
              parseCalendarColor(event.color) ??
              parseCalendarColor(calendar?.color),
        );
        final title = event.title.isEmpty
            ? l10n.calendarUntitledEvent
            : event.title;
        final time = formatCalendarRowTime(
          context,
          l10n,
          startNs: event.startAtNs,
          endNs: event.endAtNs,
          allDay: event.allDay,
          zone: zone,
          day: day,
        );
        final answer = access?.ownAnswer(event);
        final invited = access?.canRsvp(event) == true;
        final subtitle = [
          time,
          if (event.location != null) event.location!,
          if (event.isRecurring) l10n.calendarRepeatsMarker,
        ].join(' · ');
        return UtilityRow(
          title: title,
          subtitle: subtitle,
          subtitleMaxLines: 2,
          leading: dot,
          status: invited
              ? Text(
                  rsvpLabel(l10n, answer),
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                )
              : null,
          semanticLabel: [
            title,
            time,
            ?event.location,
            ?calendar?.name,
            if (event.isRecurring) l10n.calendarRepeatsMarker,
            if (invited) rsvpLabel(l10n, answer),
          ].join('. '),
          showChevron: true,
          onTap: onTap,
        );
      case final ScheduledTaskCalendarEntry entry:
        final label = !entry.isRun
            ? l10n.calendarScheduledUpcoming
            : entry.failed
            ? l10n.calendarScheduledRunFailed
            : l10n.calendarScheduledRunFinished;
        final time = formatCalendarRowTime(
          context,
          l10n,
          startNs: entry.startAtNs,
          endNs: null,
          allDay: false,
          zone: zone,
          day: day,
        );
        return UtilityRow(
          title: entry.title,
          subtitle: '$time · $label',
          subtitleMaxLines: 2,
          leading: CalendarColorDot(color: parseCalendarColor(calendar?.color)),
          semanticLabel: [entry.title, time, label, ?calendar?.name].join('. '),
          showChevron: entry.automationId != null,
          onTap: entry.automationId == null ? null : onTap,
        );
    }
  }
}
