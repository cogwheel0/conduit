import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
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
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../navigation/providers/conversation_selection_provider.dart';
import 'calendar_calendars_sheet.dart';
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

  CalendarAgenda get _notifier => ref.read(calendarAgendaProvider.notifier);

  /// The account is captured here, on the action, before anything is awaited.
  Future<void> _refresh({CalendarRange? range, Set<String>? filter}) async {
    final owner = _notifier.captureOwner();
    if (owner == null) return;
    await _notifier.refresh(owner: owner, range: range, filter: filter);
  }

  Future<void> _shift(CalendarRange range, int days) => _refresh(
    range: range.shifted(days, zone: ref.read(calendarZoneProvider)),
  );

  Future<void> _today() {
    final zone = ref.read(calendarZoneProvider);
    final now = ref.read(calendarClockProvider)().toUtc();
    final today = wallTimeAt(now.microsecondsSinceEpoch * 1000, zone);
    return _refresh(
      range: CalendarRange.days(today, calendarAgendaDays, zone: zone),
    );
  }

  Future<void> _toggleCalendar(CalendarAgendaData data, String id) {
    final next = {...data.filter};
    if (!next.remove(id)) next.add(id);
    return _refresh(filter: next);
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
    final theme = context.conduitTheme;
    final zone = ref.watch(calendarZoneProvider);
    final state = ref.watch(calendarAgendaProvider);
    final data = state.asData?.value;

    return UtilityPageScaffold.settings(
      title: l10n.calendarTitle,
      children: [
        Text(
          l10n.calendarDescription,
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.md),
        if (data != null) ...[
          _RangeBar(
            data: data,
            onEarlier: () => _shift(data.range, -calendarAgendaDays),
            onLater: () => _shift(data.range, calendarAgendaDays),
            onToday: _today,
          ),
          const SizedBox(height: Spacing.sm),
          if (data.calendars.length > 1) ...[
            _CalendarFilter(
              data: data,
              onToggle: (id) => _toggleCalendar(data, id),
              onClear: () => _refresh(filter: const <String>{}),
            ),
            const SizedBox(height: Spacing.md),
          ],
        ],
        InsetGroupedList(
          children: [
            if (data == null && state.isLoading)
              const Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: Center(child: ConduitLoadingIndicator(isCompact: true)),
              )
            else if (data == null)
              UtilityRow(
                key: const Key('calendar-retry'),
                title: l10n.calendarLoadFailed,
                subtitle: l10n.retry,
                onTap: _refresh,
              )
            else if (data.items.isEmpty)
              UtilityRow(
                key: const Key('calendar-empty'),
                title: l10n.calendarEmpty,
                enabled: false,
              ),
            if (data?.stale ?? false)
              UtilityRow(
                key: const Key('calendar-stale'),
                title: l10n.calendarStale,
                subtitle: l10n.retry,
                onTap: _refresh,
              ),
          ],
        ),
        if (data != null && data.items.isNotEmpty)
          ..._days(context, l10n, data, zone),
        const SizedBox(height: Spacing.md),
        InsetGroupedList(
          children: [
            UtilityRow(
              key: const Key('calendar-add-event'),
              title: l10n.calendarAddEvent,
              leading: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.add_circled,
                  android: Icons.add_circle_outline,
                ),
              ),
              onTap: data == null ? null : () => _add(data),
            ),
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
        const SizedBox(height: Spacing.sm),
        Text(
          l10n.calendarTimezoneNote,
          key: const Key('calendar-timezone-note'),
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
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
  ) {
    final theme = context.conduitTheme;
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
    return [
      for (final day in days) ...[
        Padding(
          padding: const EdgeInsets.only(top: Spacing.sm, bottom: Spacing.xs),
          child: Text(
            formatCalendarDay(context, day),
            key: Key('calendar-day-${day.dateOnly}'),
            style: theme.label?.copyWith(color: theme.textSecondary),
          ),
        ),
        InsetGroupedList(
          children: [
            for (final item in byDay[day]!)
              _ItemRow(
                key: Key('calendar-item-${item.key}'),
                item: item,
                day: day,
                zone: zone,
                access: data.access,
                color: switch (item) {
                  CalendarEventModel() =>
                    parseCalendarColor(item.color) ??
                        parseCalendarColor(
                          calendarsById[item.calendarId]?.color,
                        ),
                  ScheduledTaskCalendarEntry() => parseCalendarColor(
                    data.calendars.where((c) => c.isVirtual).firstOrNull?.color,
                  ),
                },
                onTap: () => _open(item),
              ),
          ],
        ),
      ],
    ];
  }
}

class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.data,
    required this.onEarlier,
    required this.onLater,
    required this.onToday,
  });

  final CalendarAgendaData data;
  final VoidCallback onEarlier;
  final VoidCallback onLater;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final locale = Localizations.localeOf(context).toString();
    final format = DateFormat.MMMd(locale);
    final last = data.range.endDay.addDays(-1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.calendarRangeLabel(
            format.format(data.range.firstDay.fields),
            format.format(last.fields),
          ),
          key: const Key('calendar-range'),
          style: theme.headingSmall,
        ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            ConduitChip(
              key: const Key('calendar-earlier'),
              label: l10n.calendarEarlier,
              onTap: onEarlier,
            ),
            ConduitChip(
              key: const Key('calendar-today'),
              label: l10n.calendarToday,
              onTap: onToday,
            ),
            ConduitChip(
              key: const Key('calendar-later'),
              label: l10n.calendarLater,
              onTap: onLater,
            ),
          ],
        ),
      ],
    );
  }
}

class _CalendarFilter extends StatelessWidget {
  const _CalendarFilter({
    required this.data,
    required this.onToggle,
    required this.onClear,
  });

  final CalendarAgendaData data;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        ConduitChip(
          key: const Key('calendar-filter-all'),
          label: l10n.calendarAllCalendars,
          isSelected: data.filter.isEmpty,
          onTap: onClear,
        ),
        for (final calendar in data.calendars)
          ConduitChip(
            key: Key('calendar-filter-${calendar.id}'),
            label: calendar.name,
            isSelected: data.filter.contains(calendar.id),
            onTap: () => onToggle(calendar.id),
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
    required this.color,
    required this.onTap,
  });

  final CalendarAgendaItem item;
  final CalendarWallTime day;
  final CalendarZone zone;
  final CalendarAccess? access;
  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final dot = Padding(
      padding: const EdgeInsets.only(right: Spacing.xs),
      child: Icon(Icons.circle, size: 12, color: color ?? theme.textSecondary),
    );
    switch (item) {
      case final CalendarEventModel event:
        // An all-day or multi-day event reads as all day on the days between
        // its first and last, where a clock time would be wrong.
        final span = daySpan(
          startNs: event.startAtNs,
          endNs: event.endAtNs,
          zone: zone,
        );
        final spansDays = !span.first.sameDate(span.last);
        final time = formatCalendarRowTime(
          context,
          l10n,
          startNs: event.startAtNs,
          endNs: event.endAtNs,
          allDay: event.allDay || (spansDays && !day.sameDate(span.first)),
          zone: zone,
        );
        final answer = access?.ownAnswer(event);
        final invited = access?.canRsvp(event) == true;
        final subtitle = [
          time,
          if (event.location != null) event.location!,
          if (event.isRecurring) l10n.calendarRepeatsMarker,
        ].join(' · ');
        return UtilityRow(
          title: event.title.isEmpty ? l10n.calendarUntitledEvent : event.title,
          subtitle: subtitle,
          subtitleMaxLines: 2,
          leading: dot,
          status: invited
              ? Text(
                  rsvpLabel(l10n, answer),
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                )
              : null,
          semanticLabel: '${event.title}. $subtitle',
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
        );
        return UtilityRow(
          title: entry.title,
          subtitle: '$time · $label',
          subtitleMaxLines: 2,
          leading: dot,
          semanticLabel: '${entry.title}. $time. $label',
          showChevron: entry.automationId != null,
          onTap: entry.automationId == null ? null : onTap,
        );
    }
  }
}
