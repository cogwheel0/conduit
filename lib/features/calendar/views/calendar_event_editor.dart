import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_date_time_picker.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/discard_changes.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../workspace/widgets/workspace_access_grants.dart';
import 'calendar_calendars_sheet.dart';
import 'calendar_color_dot.dart';
import 'calendar_format.dart';
import 'calendar_sheet_frame.dart';

/// Creates an event, or edits [event], for the account [owner] that opened it.
///
/// [event] must be the stored event, which for a recurring one is its series.
/// Returns true once the server accepted the change. A refused save, including
/// one for an account that has since changed, leaves every field as typed.
Future<bool?> showCalendarEventEditor(
  BuildContext context, {
  required CalendarOwner owner,
  CalendarEventModel? event,
  CalendarWallTime? initialDay,
}) {
  return ThemedSheets.showCustom<bool>(
    context: context,
    builder: (_) =>
        CalendarEventEditor(owner: owner, event: event, initialDay: initialDay),
  );
}

class CalendarEventEditor extends ConsumerStatefulWidget {
  const CalendarEventEditor({
    super.key,
    required this.owner,
    this.event,
    this.initialDay,
  });

  final CalendarOwner owner;
  final CalendarEventModel? event;
  final CalendarWallTime? initialDay;

  @override
  ConsumerState<CalendarEventEditor> createState() =>
      _CalendarEventEditorState();
}

class _CalendarEventEditorState extends ConsumerState<CalendarEventEditor> {
  late CalendarEventDraft _draft;

  /// The draft as the editor opened, which a new event is compared with to
  /// tell whether anything was changed.
  late final CalendarEventDraft _opened;
  late final CalendarZone _zone;
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _location = TextEditingController();

  /// Names for people picked in this editor; the server returns none.
  final _names = <String, String>{};
  bool _saving = false;
  String? _error;

  /// Whether the user typed in the title, so a missing one is pointed out.
  /// Moving on without typing, as to a date picker, does not count.
  bool _titleTouched = false;
  bool _saveAttempted = false;

  CalendarAgenda get _notifier => ref.read(calendarAgendaProvider.notifier);

  @override
  void initState() {
    super.initState();
    _zone = ref.read(calendarZoneProvider);
    final event = widget.event;
    if (event != null) {
      _draft = CalendarEventDraft.edit(event, zone: _zone);
    } else {
      _draft = CalendarEventDraft.create(
        calendarId: _defaultCalendarId() ?? '',
        start: _defaultStart(),
      );
    }
    _opened = _draft;
    _title.text = _draft.title;
    _description.text = _draft.description;
    _location.text = _draft.location;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _location.dispose();
    super.dispose();
  }

  /// The account's own default calendar when it can take events, otherwise the
  /// first calendar that can.
  String? _defaultCalendarId() {
    final data = ref.read(calendarAgendaProvider).asData?.value;
    final access = data?.access;
    if (data == null || access == null) return null;
    final writable = data.writableCalendars;
    final preferred = access.defaultCalendar(writable);
    return (preferred ?? writable.firstOrNull)?.id;
  }

  /// The next whole hour when the agenda starts today, else 09:00 on its first
  /// day.
  CalendarWallTime _defaultStart() {
    final day = widget.initialDay;
    final now = ref.read(calendarClockProvider)().toUtc();
    final today = wallTimeAt(now.microsecondsSinceEpoch * 1000, _zone);
    if (day == null || day.sameDate(today)) {
      return CalendarWallTime.fromFields(
        DateTime.utc(today.year, today.month, today.day, today.hour + 1),
      );
    }
    return CalendarWallTime(day.year, day.month, day.day, 9);
  }

  /// Whether closing now would lose something the user changed. An edit counts
  /// what would be sent; a new event counts any field moved from where it
  /// started.
  bool get _dirty {
    final draft = _draft;
    if (!draft.isNew) return draft.isChanged(zone: _zone);
    final opened = _opened;
    return draft.title != opened.title ||
        draft.description != opened.description ||
        draft.location != opened.location ||
        draft.calendarId != opened.calendarId ||
        draft.allDay != opened.allDay ||
        draft.start != opened.start ||
        draft.end != opened.end ||
        draft.repeat != opened.repeat ||
        draft.attendees.length != opened.attendees.length ||
        !draft.attendees.every(opened.attendees.contains);
  }

  void _update(CalendarEventDraft draft) => setState(() {
    _draft = draft;
    _error = null;
  });

  void _requireOwner() {
    if (!mounted || !_notifier.isCurrentOwner(widget.owner)) {
      throw CalendarOwnerChangedException();
    }
  }

  /// Closes the editor, asking first when that would throw edits away.
  Future<void> _close() async {
    // A save on its way can't be called back, and its result closes the
    // editor; a discard question asked meanwhile would be answered by it.
    if (_saving) return;
    if (_dirty && !await confirmDiscardChanges(context)) return;
    if (mounted && !_saving) Navigator.of(context).pop();
  }

  Future<void> _pickDate({required bool end}) async {
    final l10n = AppLocalizations.of(context)!;
    final current = (end ? _draft.end : _draft.start) ?? _draft.start;
    final picked = await showAdaptiveDatePicker(
      context,
      initial: DateTime(current.year, current.month, current.day),
      first: DateTime(2000),
      last: DateTime(2100),
      title: end ? l10n.calendarFieldEnds : l10n.calendarFieldStarts,
    );
    if (picked == null || !mounted) return;
    final wall = CalendarWallTime(
      picked.year,
      picked.month,
      picked.day,
      current.hour,
      current.minute,
    );
    _setBoundary(wall, end: end);
  }

  Future<void> _pickTime({required bool end}) async {
    final l10n = AppLocalizations.of(context)!;
    final current = (end ? _draft.end : _draft.start) ?? _draft.start;
    final picked = await showAdaptiveTimePicker(
      context,
      initial: TimeOfDay(hour: current.hour, minute: current.minute),
      title: end ? l10n.calendarFieldEndTime : l10n.calendarFieldStartTime,
    );
    if (picked == null || !mounted) return;
    _setBoundary(
      CalendarWallTime(
        current.year,
        current.month,
        current.day,
        picked.hour,
        picked.minute,
      ),
      end: end,
    );
  }

  /// Sets the start or the end. An end that would fall before the start is
  /// moved to keep the event's length, as Open WebUI's own editor does, so
  /// moving the start never leaves an impossible span.
  void _setBoundary(CalendarWallTime wall, {required bool end}) {
    if (end) {
      _update(_draft.copyWith(end: wall));
      return;
    }
    var next = _draft.copyWith(start: wall);
    final currentEnd = _draft.end;
    if (currentEnd != null) {
      final before = _draft.allDay
          ? currentEnd.dateOnly.compareTo(wall.dateOnly) < 0
          : currentEnd.compareTo(wall) < 0;
      if (before) {
        final length = _draft.allDay
            ? Duration.zero
            : _draft.end!.fields.difference(_draft.start.fields).abs();
        next = next.copyWith(
          end: _draft.allDay
              ? wall.dateOnly
              : CalendarWallTime.fromFields(wall.fields.add(length)),
        );
      }
    }
    _update(next);
  }

  Future<void> _pickRepeat() async {
    final l10n = AppLocalizations.of(context)!;
    final current = _draft.repeat;
    // A rule the editor cannot write stays on offer while it is the event's.
    final choices = [
      for (final repeat in CalendarRepeat.values)
        if (repeat != CalendarRepeat.custom || current == CalendarRepeat.custom)
          repeat,
    ];
    final picked = await showAdaptiveSelectionSheet<CalendarRepeat>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: l10n.calendarFieldRepeat,
        itemCount: choices.length,
        initialChildSize: 0.5,
        minChildSize: 0.32,
        maxChildSize: 0.75,
        itemBuilder: (context, index) {
          final repeat = choices[index];
          return AdaptiveSelectionTile(
            key: Key('calendar-editor-repeat-${repeat.name}'),
            title: repeatLabel(l10n, repeat),
            selected: repeat == current,
            onTap: () => Navigator.of(sheetContext).pop(repeat),
          );
        },
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    _update(_draft.copyWith(repeat: picked));
  }

  Future<void> _pickCalendar() async {
    final picked = await showCalendarPickerSheet(
      context,
      owner: widget.owner,
      selectedId: _draft.calendarId,
    );
    if (picked == null || !mounted || !_notifier.isCurrentOwner(widget.owner)) {
      return;
    }
    _update(_draft.copyWith(calendarId: picked));
  }

  Future<void> _addPeople() async {
    final directory = ref.read(workspacePrincipalDirectoryProvider);
    if (directory == null) return;
    final picked = await WorkspacePrincipalPicker.show(
      context,
      directory: directory,
      allowUsers: true,
      allowGroups: false,
    );
    // A pick made for an account that has since changed is not kept.
    if (picked == null ||
        picked.type != WorkspacePrincipalType.user ||
        !mounted ||
        !_notifier.isCurrentOwner(widget.owner)) {
      return;
    }
    if (_draft.attendees.any((a) => a.userId == picked.id)) return;
    _names[picked.id] = picked.name;
    _update(
      _draft.copyWith(
        attendees: [
          ..._draft.attendees,
          CalendarDraftAttendee(userId: picked.id, name: picked.name),
        ],
      ),
    );
  }

  void _removePerson(CalendarDraftAttendee person) => _update(
    _draft.copyWith(
      attendees: [
        for (final a in _draft.attendees)
          if (a.userId != person.userId) a,
      ],
    ),
  );

  Future<void> _save() async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context)!;
    final draft = _draft;
    if (draft.issues.isNotEmpty) {
      setState(() => _saveAttempted = true);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final stored = draft.original;
      if (stored == null) {
        await _notifier.createEvent(
          draft.toCreateForm(zone: _zone),
          owner: widget.owner,
        );
      } else {
        await _notifier.updateEvent(
          stored,
          draft.toUpdate(zone: _zone),
          owner: widget.owner,
        );
      }
      // A save accepted for the previous account stays accepted, but it must
      // not close this editor as though it were for the signed-in one.
      _requireOwner();
      ConduitHaptics.success();
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      // The form keeps everything that was typed, whatever the reason.
      if (mounted) {
        setState(
          () => _error = calendarErrorText(
            l10n,
            error,
            fallback: l10n.calendarSaveFailed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _personName(AppLocalizations l10n, CalendarDraftAttendee person) =>
      person.name ?? _names[person.userId] ?? l10n.calendarInvitedPerson;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final data = ref.watch(calendarAgendaProvider).asData?.value;
    final draft = _draft;
    final calendar = data?.calendars
        .where((c) => c.id == draft.calendarId)
        .firstOrNull;
    final start = draft.start;
    final end = draft.end;
    final issues = draft.issues;
    final dirty = _dirty;
    final changed = draft.isNew || dirty;
    final recurring = draft.original?.isRecurring ?? false;
    final titleError =
        (_titleTouched || _saveAttempted) &&
            issues.contains(CalendarDraftIssue.titleRequired)
        ? l10n.calendarTitleRequired
        : null;
    final endBeforeStart = issues.contains(CalendarDraftIssue.endBeforeStart);
    // With no calendar to write to, the note says how to get one; otherwise
    // the missing choice is pointed out, since Save waits for it.
    final noWritableCalendar =
        data != null && data.writableCalendars.isEmpty && draft.isNew;
    final calendarMissing =
        !noWritableCalendar &&
        issues.contains(CalendarDraftIssue.calendarRequired);
    final canSave = !_saving && changed && issues.isEmpty;
    final whenNotes = [
      if (draft.repeat == CalendarRepeat.custom) l10n.calendarRepeatKept,
      if (draft.repeat != CalendarRepeat.none)
        l10n.calendarRecurrenceTimezoneNote,
    ];

    return DiscardChangesScope(
      dirty: dirty,
      busy: _saving,
      child: CalendarSheetFrame(
        title: draft.isNew
            ? l10n.calendarNewEventTitle
            : recurring
            ? l10n.calendarEditSeriesTitle
            : l10n.calendarEditEventTitle,
        onClose: _close,
        holdDismiss: dirty || _saving,
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error case final message?) ...[
              Text(
                message,
                key: const Key('calendar-editor-error'),
                style: theme.bodySmall?.copyWith(color: theme.error),
                // The footer stays pinned, so a long message must not crowd out
                // the actions; the whole text is still read out.
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.sm),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ConduitButton(
                  key: const Key('calendar-editor-cancel'),
                  text: l10n.cancel,
                  isSecondary: true,
                  isCompact: true,
                  onPressed: _saving ? null : _close,
                ),
                const SizedBox(width: Spacing.sm),
                ConduitButton(
                  key: const Key('calendar-editor-save'),
                  text: l10n.save,
                  isCompact: true,
                  isLoading: _saving,
                  onPressed: canSave ? _save : null,
                ),
              ],
            ),
          ],
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ConduitInput(
              key: const Key('calendar-editor-title'),
              controller: _title,
              label: l10n.calendarFieldTitle,
              enabled: !_saving,
              autofocus: draft.isNew,
              textInputAction: TextInputAction.next,
              errorText: titleError,
              onChanged: (value) {
                _titleTouched = true;
                _update(_draft.copyWith(title: value));
              },
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              key: const Key('calendar-editor-location'),
              controller: _location,
              label: l10n.calendarFieldLocation,
              enabled: !_saving,
              textInputAction: TextInputAction.next,
              onChanged: (value) => _update(_draft.copyWith(location: value)),
            ),
            const SizedBox(height: Spacing.md),
            InsetGroupedList(
              children: [
                UtilityRow(
                  title: l10n.calendarFieldAllDay,
                  trailing: AdaptiveSwitch(
                    key: const Key('calendar-editor-all-day'),
                    value: draft.allDay,
                    semanticLabel: l10n.calendarFieldAllDay,
                    onChanged: _saving
                        ? null
                        : (value) => _update(_draft.copyWith(allDay: value)),
                  ),
                  preserveTrailingSemantics: true,
                ),
                _BoundaryRow(
                  label: l10n.calendarFieldStarts,
                  timeLabel: l10n.calendarFieldStartTime,
                  dateKey: const Key('calendar-editor-start-date'),
                  timeKey: const Key('calendar-editor-start-time'),
                  wall: start,
                  allDay: draft.allDay,
                  onPickDate: _saving ? null : () => _pickDate(end: false),
                  onPickTime: _saving ? null : () => _pickTime(end: false),
                ),
                if (end == null)
                  UtilityRow(
                    key: const Key('calendar-editor-add-end'),
                    title: l10n.calendarAddEnd,
                    leading: Icon(
                      UiUtils.platformIcon(
                        ios: CupertinoIcons.add_circled,
                        android: Icons.add_circle_outline,
                      ),
                    ),
                    onTap: _saving
                        ? null
                        : () => _update(_draft.copyWith(end: _draft.start)),
                  )
                else ...[
                  _BoundaryRow(
                    label: l10n.calendarFieldEnds,
                    timeLabel: l10n.calendarFieldEndTime,
                    dateKey: const Key('calendar-editor-end-date'),
                    timeKey: const Key('calendar-editor-end-time'),
                    wall: end,
                    allDay: draft.allDay,
                    invalid: endBeforeStart,
                    onPickDate: _saving ? null : () => _pickDate(end: true),
                    onPickTime: _saving ? null : () => _pickTime(end: true),
                  ),
                  UtilityRow(
                    key: const Key('calendar-editor-remove-end'),
                    title: l10n.calendarRemoveEnd,
                    leading: Icon(
                      UiUtils.platformIcon(
                        ios: CupertinoIcons.minus_circled,
                        android: Icons.remove_circle_outline,
                      ),
                    ),
                    onTap: _saving
                        ? null
                        : () => _update(_draft.copyWith(clearEnd: true)),
                  ),
                ],
                UtilityRow(
                  key: const Key('calendar-editor-repeat'),
                  title: l10n.calendarFieldRepeat,
                  status: Text(
                    repeatLabel(l10n, draft.repeat),
                    key: const Key('calendar-editor-repeat-value'),
                    style: theme.bodyMedium?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  showChevron: true,
                  onTap: _saving ? null : _pickRepeat,
                ),
              ],
            ),
            if (endBeforeStart)
              _GroupNote(
                l10n.calendarEndBeforeStart,
                key: const Key('calendar-editor-end-error'),
                color: theme.error,
              ),
            if (whenNotes.isNotEmpty)
              _GroupNote(
                whenNotes.join(' '),
                key: const Key('calendar-editor-recurrence-note'),
              ),
            const SizedBox(height: Spacing.md),
            InsetGroupedList(
              children: [
                UtilityRow(
                  key: const Key('calendar-editor-calendar'),
                  title: l10n.calendarFieldCalendar,
                  status: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (calendar != null) ...[
                        CalendarColorDot(
                          color: parseCalendarColor(calendar.color),
                        ),
                        const SizedBox(width: Spacing.xs),
                      ],
                      Flexible(
                        child: Text(
                          calendar?.name ??
                              (draft.calendarId.isEmpty
                                  ? l10n.calendarChooseCalendar
                                  : draft.calendarId),
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodyMedium?.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  semanticLabel: [
                    l10n.calendarFieldCalendar,
                    calendar?.name ?? l10n.calendarChooseCalendar,
                  ].join('. '),
                  showChevron: true,
                  onTap: _saving ? null : _pickCalendar,
                ),
              ],
            ),
            if (noWritableCalendar)
              _GroupNote(
                l10n.calendarNoWritableCalendar,
                key: const Key('calendar-editor-no-calendar'),
              )
            else if (calendarMissing)
              _GroupNote(
                l10n.calendarCalendarRequired,
                key: const Key('calendar-editor-calendar-error'),
                color: theme.error,
              ),
            const SizedBox(height: Spacing.md),
            InsetGroupedList(
              title: l10n.calendarFieldAttendees,
              footer: l10n.calendarAttendeesNote,
              children: [
                for (final person in draft.attendees)
                  UtilityRow(
                    key: Key('calendar-editor-person-${person.userId}'),
                    title: _personName(l10n, person),
                    leading: Icon(
                      UiUtils.platformIcon(
                        ios: CupertinoIcons.person,
                        android: Icons.person_outline,
                      ),
                      color: theme.iconSecondary,
                    ),
                    trailing: ConduitIconButton(
                      key: Key('calendar-editor-remove-${person.userId}'),
                      icon: UiUtils.platformIcon(
                        ios: CupertinoIcons.minus_circle,
                        android: Icons.remove_circle_outline,
                      ),
                      iconColor: theme.error,
                      tooltip: l10n.calendarRemovePerson(
                        _personName(l10n, person),
                      ),
                      isCompact: true,
                      onPressed: _saving ? null : () => _removePerson(person),
                    ),
                    preserveTrailingSemantics: true,
                  ),
                UtilityRow(
                  key: const Key('calendar-editor-add-people'),
                  title: l10n.calendarAddPeople,
                  leading: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.person_add,
                      android: Icons.person_add_alt_1_outlined,
                    ),
                  ),
                  onTap: _saving ? null : _addPeople,
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            ConduitInput(
              key: const Key('calendar-editor-description'),
              controller: _description,
              label: l10n.calendarFieldDescription,
              minLines: 3,
              maxLines: 6,
              enabled: !_saving,
              onChanged: (value) =>
                  _update(_draft.copyWith(description: value)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line under a grouped list, set like the group's own footer.
class _GroupNote extends StatelessWidget {
  const _GroupNote(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.xs, Spacing.xs, Spacing.xs, 0),
      child: Text(
        text,
        style: AppTypography.bodySmallStyle.copyWith(
          color: color ?? theme.textTertiary,
        ),
      ),
    );
  }
}

/// "Starts" or "Ends" with its day and, unless the event is all day, its time,
/// each a button that opens its picker.
class _BoundaryRow extends StatelessWidget {
  const _BoundaryRow({
    required this.label,
    required this.timeLabel,
    required this.dateKey,
    required this.timeKey,
    required this.wall,
    required this.allDay,
    required this.onPickDate,
    required this.onPickTime,
    this.invalid = false,
  });

  final String label;
  final String timeLabel;
  final Key dateKey;
  final Key timeKey;
  final CalendarWallTime wall;
  final bool allDay;
  final bool invalid;
  final VoidCallback? onPickDate;
  final VoidCallback? onPickTime;

  @override
  Widget build(BuildContext context) {
    final day = formatCalendarDay(context, wall);
    final clock = formatCalendarClock(context, wall);
    return UtilityRow(
      title: label,
      semanticLabel: label,
      titleFlex: 2,
      statusFlex: 5,
      preserveTrailingSemantics: true,
      status: Wrap(
        alignment: WrapAlignment.end,
        spacing: Spacing.xs,
        children: [
          _PickerButton(
            key: dateKey,
            text: day,
            semanticLabel: '$label, $day',
            invalid: invalid,
            onTap: onPickDate,
          ),
          if (!allDay)
            _PickerButton(
              key: timeKey,
              text: clock,
              semanticLabel: '$timeLabel, $clock',
              invalid: invalid,
              onTap: onPickTime,
            ),
        ],
      ),
    );
  }
}

/// A filled value that opens a picker, as the date and time in a calendar
/// event's rows. Its hit area is at least [TouchTarget.minimum] tall.
class _PickerButton extends StatefulWidget {
  const _PickerButton({
    super.key,
    required this.text,
    required this.semanticLabel,
    required this.onTap,
    this.invalid = false,
  });

  final String text;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool invalid;

  @override
  State<_PickerButton> createState() => _PickerButtonState();
}

class _PickerButtonState extends State<_PickerButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || widget.onTap == null) return;
    setState(() => _pressed = value);
  }

  void _handleTap() {
    final onTap = widget.onTap;
    if (onTap == null) return;
    ConduitHaptics.selectionClick();
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final enabled = widget.onTap != null;
    final foreground = widget.invalid
        ? theme.error
        : enabled
        ? theme.textPrimary
        : theme.textSecondary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: enabled ? _handleTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: enabled ? _handleTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: AnimatedOpacity(
              opacity: _pressed ? Alpha.strong : 1,
              duration: context.motionDuration(AnimationDuration.buttonPress),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.invalid
                      ? theme.error.withValues(alpha: Alpha.highlight)
                      : theme.textSecondary.withValues(alpha: Alpha.highlight),
                  borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xs,
                  ),
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    style: theme.bodyMedium?.copyWith(color: foreground),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
