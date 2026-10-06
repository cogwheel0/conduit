import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import 'calendar_format.dart';
import 'calendar_sheet_frame.dart';

/// Lists the account's calendars, lets it choose its default, and creates a
/// personal calendar. [owner] is the account the sheet was opened for.
Future<void> showCalendarsSheet(
  BuildContext context, {
  required CalendarOwner owner,
}) {
  return ThemedSheets.showCustom<void>(
    context: context,
    builder: (_) => CalendarsSheet(owner: owner),
  );
}

/// Asks which calendar an event goes in. Only calendars the account can write
/// to are offered, since the server refuses an event anywhere else. The sheet
/// can also create a personal calendar, so an account with none can still
/// create an event. Returns the chosen calendar's id.
Future<String?> showCalendarPickerSheet(
  BuildContext context, {
  required CalendarOwner owner,
  String? selectedId,
}) {
  return ThemedSheets.showCustom<String>(
    context: context,
    builder: (_) =>
        CalendarsSheet(owner: owner, picking: true, selectedId: selectedId),
  );
}

/// The few colours a new calendar can take.
const _calendarColors = <String>[
  '#3b82f6',
  '#22c55e',
  '#f59e0b',
  '#ef4444',
  '#8b5cf6',
  '#14b8a6',
];

class CalendarsSheet extends ConsumerStatefulWidget {
  const CalendarsSheet({
    super.key,
    required this.owner,
    this.picking = false,
    this.selectedId,
  });

  final CalendarOwner owner;

  /// Whether choosing a row returns it, instead of listing every calendar.
  final bool picking;
  final String? selectedId;

  @override
  ConsumerState<CalendarsSheet> createState() => _CalendarsSheetState();
}

class _CalendarsSheetState extends ConsumerState<CalendarsSheet> {
  final _name = TextEditingController();
  String _color = _calendarColors.first;
  bool _busy = false;
  String? _error;

  CalendarAgenda get _notifier => ref.read(calendarAgendaProvider.notifier);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    required String fallback,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = calendarErrorText(l10n, error, fallback: fallback),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() {
    final l10n = AppLocalizations.of(context)!;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.calendarNameRequired);
      return Future.value();
    }
    return _run(() async {
      final created = await _notifier.createCalendar(
        CalendarForm(name: name, color: _color),
        owner: widget.owner,
      );
      if (!mounted) return;
      _name.clear();
      // A calendar made while picking is the one the user wanted.
      if (widget.picking && _notifier.isCurrentOwner(widget.owner)) {
        Navigator.of(context).pop(created.id);
      }
    }, fallback: l10n.calendarCreateFailed);
  }

  Future<void> _makeDefault(CalendarModel calendar) {
    final l10n = AppLocalizations.of(context)!;
    return _run(
      () => _notifier.makeDefault(calendar, owner: widget.owner),
      fallback: l10n.calendarMakeDefaultFailed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final data = ref.watch(calendarAgendaProvider).asData?.value;
    final access = data?.access;
    final calendars = [
      for (final calendar in data?.calendars ?? const <CalendarModel>[])
        if (!calendar.isVirtual &&
            (!widget.picking || (access?.canWrite(calendar) ?? false)))
          calendar,
    ];

    return CalendarSheetFrame(
      title: widget.picking
          ? l10n.calendarPickTitle
          : l10n.calendarCalendarsTitle,
      child: ListView(
        shrinkWrap: true,
        children: [
          InsetGroupedList(
            children: [
              if (calendars.isEmpty)
                UtilityRow(
                  key: const Key('calendar-none-writable'),
                  title: widget.picking
                      ? l10n.calendarNoWritableCalendar
                      : l10n.calendarEmptyCalendars,
                  enabled: false,
                ),
              for (final calendar in calendars)
                _calendarRow(l10n, theme, calendar, data!),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            l10n.calendarNewCalendar,
            style: theme.label?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.xs),
          ConduitInput(
            key: const Key('calendar-new-name'),
            controller: _name,
            hint: l10n.calendarNewCalendarHint,
            semanticLabel: l10n.calendarNewCalendarHint,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final color in _calendarColors)
                GestureDetector(
                  key: Key('calendar-new-color-$color'),
                  onTap: _busy ? null : () => setState(() => _color = color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: parseCalendarColor(color),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == color
                            ? theme.textPrimary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_error case final message?) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              message,
              key: const Key('calendar-calendars-error'),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ],
          const SizedBox(height: Spacing.md),
          ConduitButton(
            key: const Key('calendar-create-calendar'),
            text: l10n.calendarCreateCalendar,
            isLoading: _busy,
            onPressed: _busy ? null : _create,
          ),
        ],
      ),
    );
  }

  Widget _calendarRow(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    CalendarModel calendar,
    CalendarAgendaData data,
  ) {
    final access = data.access!;
    final owned = access.owns(calendar);
    final writable = access.canWrite(calendar);
    final mine = owned && calendar.isDefault;
    final badges = [
      if (mine) l10n.calendarDefaultBadge,
      if (!owned) l10n.calendarSharedBadge,
      if (!writable) l10n.calendarReadOnlyBadge,
    ];
    final dot = Padding(
      padding: const EdgeInsets.only(right: Spacing.xs),
      child: Icon(
        Icons.circle,
        size: 12,
        color: parseCalendarColor(calendar.color) ?? theme.textSecondary,
      ),
    );
    if (widget.picking) {
      return UtilityRow(
        key: Key('calendar-pick-${calendar.id}'),
        title: calendar.name,
        subtitle: badges.isEmpty ? null : badges.join(' · '),
        leading: dot,
        selected: calendar.id == widget.selectedId,
        onTap: () => Navigator.of(context).pop(calendar.id),
      );
    }
    return UtilityRow(
      key: Key('calendar-row-${calendar.id}'),
      title: calendar.name,
      subtitle: badges.isEmpty ? null : badges.join(' · '),
      leading: dot,
      // Only the account's own calendars can be its default; another owner's
      // default flag is theirs.
      trailing: access.canMakeDefault(calendar) && !calendar.isDefault
          ? ConduitButton(
              key: Key('calendar-make-default-${calendar.id}'),
              text: l10n.calendarMakeDefault,
              isCompact: true,
              isSecondary: true,
              onPressed: _busy ? null : () => _makeDefault(calendar),
            )
          : null,
      preserveTrailingSemantics: true,
    );
  }
}
