import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import 'calendar_color_dot.dart';
import 'calendar_format.dart';
import 'calendar_sheet_frame.dart';

/// Lists the account's calendars, chooses which of them the agenda shows and
/// which is the default, and creates a personal calendar. [owner] is the
/// account the sheet was opened for.
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

/// The few colours a new calendar can take, with the name each is announced
/// by.
const _calendarColors = <({String hex, String name})>[
  (hex: '#3b82f6', name: 'blue'),
  (hex: '#22c55e', name: 'green'),
  (hex: '#f59e0b', name: 'amber'),
  (hex: '#ef4444', name: 'red'),
  (hex: '#8b5cf6', name: 'purple'),
  (hex: '#14b8a6', name: 'teal'),
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
  String _color = _calendarColors.first.hex;
  bool _busy = false;
  String? _error;

  /// Whether the new-calendar form is open.
  bool _creating = false;
  bool _nameMissing = false;

  /// The agenda filter as last chosen here, shown at once while the agenda
  /// reloads for it.
  Set<String>? _filter;

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
      setState(() => _nameMissing = true);
      return Future.value();
    }
    return _run(() async {
      final created = await _notifier.createCalendar(
        CalendarForm(name: name, color: _color),
        owner: widget.owner,
      );
      if (!mounted) return;
      ConduitHaptics.success();
      _name.clear();
      setState(() => _creating = false);
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

  /// The calendars the agenda shows: all of them when the filter is empty.
  Set<String> _visible(CalendarAgendaData data) {
    final all = {for (final c in data.calendars) c.id};
    final chosen = (_filter ?? data.filter).intersection(all);
    return chosen.isEmpty ? all : chosen;
  }

  /// Shows or hides [id]'s events. At least one calendar stays shown, and
  /// showing every one clears the filter, so calendars added later show too.
  Future<void> _toggleVisible(CalendarAgendaData data, String id) async {
    final all = {for (final c in data.calendars) c.id};
    final next = {..._visible(data)};
    if (!next.remove(id)) next.add(id);
    if (next.isEmpty) return;
    final filter = next.containsAll(all) ? <String>{} : next;
    setState(() => _filter = filter);
    await _notifier.refresh(owner: widget.owner, filter: filter);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final data = ref.watch(calendarAgendaProvider).asData?.value;
    final access = data?.access;
    final calendars = [
      for (final calendar in data?.calendars ?? const <CalendarModel>[])
        if (widget.picking
            ? !calendar.isVirtual && (access?.canWrite(calendar) ?? false)
            : !calendar.isVirtual || data!.calendars.length > 1)
          calendar,
    ];
    final filterable = !widget.picking && (data?.calendars.length ?? 0) > 1;
    final visible = data == null ? const <String>{} : _visible(data);
    final creating = _creating || calendars.isEmpty;

    return CalendarSheetFrame(
      title: widget.picking
          ? l10n.calendarPickTitle
          : l10n.calendarCalendarsTitle,
      footer: _error == null
          ? null
          : Text(
              _error!,
              key: const Key('calendar-calendars-error'),
              style: theme.bodySmall?.copyWith(color: theme.error),
              // The footer stays pinned, so a long message must not crowd out
              // the actions; the whole text is still read out.
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
      child: ListView(
        shrinkWrap: true,
        children: [
          if (calendars.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              child: Text(
                widget.picking
                    ? l10n.calendarNoWritableCalendar
                    : l10n.calendarEmptyCalendars,
                key: const Key('calendar-none-writable'),
                style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
              ),
            )
          else
            InsetGroupedList(
              footer: filterable ? l10n.calendarVisibilityFooter : null,
              children: [
                for (final calendar in calendars)
                  widget.picking
                      ? _pickRow(l10n, calendar, data!)
                      : _manageRow(
                          l10n,
                          theme,
                          calendar,
                          data!,
                          filterable: filterable,
                          shown: visible.contains(calendar.id),
                          onlyShown:
                              visible.length == 1 &&
                              visible.contains(calendar.id),
                        ),
              ],
            ),
          const SizedBox(height: Spacing.lg),
          if (creating)
            _newCalendarForm(l10n, theme, canCancel: calendars.isNotEmpty)
          else
            InsetGroupedList(
              children: [
                UtilityRow(
                  key: const Key('calendar-new-calendar'),
                  title: l10n.calendarNewCalendar,
                  leading: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.add_circled,
                      android: Icons.add_circle_outline,
                    ),
                  ),
                  onTap: _busy ? null : () => setState(() => _creating = true),
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<String> _badges(
    AppLocalizations l10n,
    CalendarModel calendar,
    CalendarAgendaData data,
  ) {
    final access = data.access;
    if (access == null || calendar.isVirtual) return const [];
    final owned = access.owns(calendar);
    return [
      if (owned && calendar.isDefault) l10n.calendarDefaultBadge,
      if (!owned) l10n.calendarSharedBadge,
      if (!access.canWrite(calendar)) l10n.calendarReadOnlyBadge,
    ];
  }

  Widget _pickRow(
    AppLocalizations l10n,
    CalendarModel calendar,
    CalendarAgendaData data,
  ) {
    final badges = _badges(l10n, calendar, data);
    return UtilitySelectionRow(
      key: Key('calendar-pick-${calendar.id}'),
      leading: CalendarColorDot(color: parseCalendarColor(calendar.color)),
      title: calendar.name,
      subtitle: badges.isEmpty ? null : badges.join(' · '),
      selected: calendar.id == widget.selectedId,
      onTap: () => Navigator.of(context).pop(calendar.id),
    );
  }

  /// A calendar with its badges. Tapping it shows or hides its events when
  /// the agenda has more than one calendar to choose from; the account's own
  /// calendars can also be made its default here.
  Widget _manageRow(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    CalendarModel calendar,
    CalendarAgendaData data, {
    required bool filterable,
    required bool shown,
    required bool onlyShown,
  }) {
    final access = data.access;
    final badges = _badges(l10n, calendar, data);
    // Only the account's own calendars can be its default; another owner's
    // default flag is theirs.
    final canMakeDefault =
        access != null &&
        !calendar.isVirtual &&
        access.canMakeDefault(calendar) &&
        !calendar.isDefault;
    final check = filterable
        ? AnimatedSwitcher(
            duration: context.motionDuration(
              AnimationDuration.microInteraction,
            ),
            child: shown
                ? Icon(
                    context.usesCupertinoChrome
                        ? CupertinoIcons.check_mark_circled_solid
                        : Icons.check_circle,
                    key: const ValueKey<String>('shown'),
                    color: theme.buttonPrimary,
                    size: IconSize.medium,
                  )
                : Icon(
                    context.usesCupertinoChrome
                        ? CupertinoIcons.circle
                        : Icons.radio_button_unchecked,
                    key: const ValueKey<String>('hidden'),
                    color: theme.iconSecondary,
                    size: IconSize.medium,
                  ),
          )
        : null;
    return UtilityRow(
      key: Key('calendar-row-${calendar.id}'),
      title: calendar.name,
      subtitle: badges.isEmpty ? null : badges.join(' · '),
      leading: CalendarColorDot(color: parseCalendarColor(calendar.color)),
      selected: filterable && shown,
      onTap: filterable && !onlyShown
          ? () => _toggleVisible(data, calendar.id)
          : null,
      trailing: canMakeDefault || check != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canMakeDefault)
                  ConduitButton(
                    key: Key('calendar-make-default-${calendar.id}'),
                    text: l10n.calendarMakeDefault,
                    isCompact: true,
                    isSecondary: true,
                    onPressed: _busy ? null : () => _makeDefault(calendar),
                  ),
                if (canMakeDefault && check != null)
                  const SizedBox(width: Spacing.sm),
                ?check,
              ],
            )
          : null,
      preserveTrailingSemantics: canMakeDefault,
    );
  }

  Widget _newCalendarForm(
    AppLocalizations l10n,
    ConduitThemeExtension theme, {
    required bool canCancel,
  }) {
    final hasName = _name.text.trim().isNotEmpty;
    return InsetGroupedSection(
      title: l10n.calendarNewCalendar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConduitInput(
            key: const Key('calendar-new-name'),
            controller: _name,
            hint: l10n.calendarNewCalendarHint,
            semanticLabel: l10n.calendarNewCalendarHint,
            enabled: !_busy,
            autofocus: canCancel,
            errorText: _nameMissing && !hasName
                ? l10n.calendarNameRequired
                : null,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            children: [
              for (final color in _calendarColors)
                _ColorSwatch(
                  key: Key('calendar-new-color-${color.hex}'),
                  color: parseCalendarColor(color.hex)!,
                  label: l10n.calendarColorName(color.name),
                  selected: _color == color.hex,
                  onTap: _busy
                      ? null
                      : () => setState(() => _color = color.hex),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (canCancel) ...[
                ConduitButton(
                  key: const Key('calendar-new-cancel'),
                  text: l10n.cancel,
                  isSecondary: true,
                  isCompact: true,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _creating = false;
                          _nameMissing = false;
                          _name.clear();
                        }),
                ),
                const SizedBox(width: Spacing.sm),
              ],
              ConduitButton(
                key: const Key('calendar-create-calendar'),
                text: l10n.calendarCreateCalendar,
                isCompact: true,
                isLoading: _busy,
                onPressed: _busy || !hasName ? null : _create,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A colour a new calendar can take, as a round swatch with a
/// [TouchTarget.minimum] hit area. The chosen one is ringed and checked, so it
/// does not rely on colour alone.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    super.key,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null
            ? null
            : () {
                ConduitHaptics.selectionClick();
                onTap!();
              },
        child: SizedBox.square(
          dimension: TouchTarget.minimum,
          child: Center(
            child: Container(
              width: IconSize.xl,
              height: IconSize.xl,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? theme.textPrimary : Colors.transparent,
                  width: BorderWidth.thick,
                ),
              ),
              child: selected
                  ? Icon(
                      UiUtils.platformIcon(
                        ios: CupertinoIcons.checkmark,
                        android: Icons.check,
                      ),
                      size: IconSize.sm,
                      color: Colors.white,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
