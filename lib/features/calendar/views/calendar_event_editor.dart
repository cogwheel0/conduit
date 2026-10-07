import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../workspace/widgets/workspace_access_grants.dart';
import 'calendar_calendars_sheet.dart';
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
  late final CalendarZone _zone;
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _location = TextEditingController();

  /// Names for people picked in this editor; the server returns none.
  final _names = <String, String>{};
  bool _saving = false;
  String? _error;

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

  void _update(CalendarEventDraft draft) => setState(() {
    _draft = draft;
    _error = null;
  });

  void _requireOwner() {
    if (!mounted || !_notifier.isCurrentOwner(widget.owner)) {
      throw CalendarOwnerChangedException();
    }
  }

  Future<void> _pickDate({required bool end}) async {
    final current = (end ? _draft.end : _draft.start) ?? _draft.start;
    final picked = await showDatePicker(
      context: context,
      initialDate: current.fields,
      firstDate: DateTime.utc(2000),
      lastDate: DateTime.utc(2100),
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
    final current = (end ? _draft.end : _draft.start) ?? _draft.start;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
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
    final issues = draft.issues;
    if (issues.isNotEmpty) {
      setState(() => _error = draftIssueText(l10n, issues.first));
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
    final changed = draft.isChanged(zone: _zone);
    final recurring = draft.original?.isRecurring ?? false;

    String day(CalendarWallTime wall) => formatCalendarDay(context, wall);
    String clock(CalendarWallTime wall) => formatCalendarClock(context, wall);

    return CalendarSheetFrame(
      title: draft.isNew
          ? l10n.calendarNewEventTitle
          : recurring
          ? l10n.calendarEditSeriesTitle
          : l10n.calendarEditEventTitle,
      child: ListView(
        shrinkWrap: true,
        children: [
          ConduitInput(
            key: const Key('calendar-editor-title'),
            controller: _title,
            label: l10n.calendarFieldTitle,
            enabled: !_saving,
            onChanged: (value) => _update(draft.copyWith(title: value)),
          ),
          const SizedBox(height: Spacing.md),
          ConduitInput(
            key: const Key('calendar-editor-description'),
            controller: _description,
            label: l10n.calendarFieldDescription,
            minLines: 2,
            maxLines: 6,
            enabled: !_saving,
            onChanged: (value) => _update(draft.copyWith(description: value)),
          ),
          const SizedBox(height: Spacing.md),
          ConduitInput(
            key: const Key('calendar-editor-location'),
            controller: _location,
            label: l10n.calendarFieldLocation,
            enabled: !_saving,
            onChanged: (value) => _update(draft.copyWith(location: value)),
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
                      : (value) => _update(draft.copyWith(allDay: value)),
                ),
                preserveTrailingSemantics: true,
              ),
              UtilityRow(
                key: const Key('calendar-editor-start-date'),
                title: l10n.calendarFieldStarts,
                subtitle: day(start),
                showChevron: true,
                onTap: _saving ? null : () => _pickDate(end: false),
              ),
              if (!draft.allDay)
                UtilityRow(
                  key: const Key('calendar-editor-start-time'),
                  title: l10n.calendarFieldStartTime,
                  subtitle: clock(start),
                  showChevron: true,
                  onTap: _saving ? null : () => _pickTime(end: false),
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
                      : () => _update(draft.copyWith(end: start)),
                )
              else ...[
                UtilityRow(
                  key: const Key('calendar-editor-end-date'),
                  title: l10n.calendarFieldEnds,
                  subtitle: day(end),
                  showChevron: true,
                  onTap: _saving ? null : () => _pickDate(end: true),
                ),
                if (!draft.allDay)
                  UtilityRow(
                    key: const Key('calendar-editor-end-time'),
                    title: l10n.calendarFieldEndTime,
                    subtitle: clock(end),
                    showChevron: true,
                    onTap: _saving ? null : () => _pickTime(end: true),
                  ),
                UtilityRow(
                  key: const Key('calendar-editor-remove-end'),
                  title: l10n.clear,
                  leading: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.minus_circled,
                      android: Icons.remove_circle_outline,
                    ),
                  ),
                  onTap: _saving
                      ? null
                      : () => _update(draft.copyWith(clearEnd: true)),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.md),
          Text(
            l10n.calendarFieldRepeat,
            style: theme.label?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final repeat in CalendarRepeat.values)
                if (repeat != CalendarRepeat.custom)
                  ConduitChip(
                    key: Key('calendar-editor-repeat-${repeat.name}'),
                    label: repeatLabel(l10n, repeat),
                    isSelected: draft.repeat == repeat,
                    onTap: _saving
                        ? null
                        : () => _update(draft.copyWith(repeat: repeat)),
                  ),
            ],
          ),
          if (draft.repeat == CalendarRepeat.custom) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              '${l10n.calendarRepeatCustom}: ${draft.original?.rrule ?? ''}',
              key: const Key('calendar-editor-custom-rule'),
              style: theme.bodySmall?.copyWith(color: theme.textPrimary),
            ),
            Text(
              l10n.calendarRepeatKept,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          if (draft.repeat != CalendarRepeat.none) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.calendarRecurrenceTimezoneNote,
              key: const Key('calendar-editor-recurrence-note'),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          const SizedBox(height: Spacing.md),
          InsetGroupedList(
            children: [
              UtilityRow(
                key: const Key('calendar-editor-calendar'),
                title: l10n.calendarFieldCalendar,
                subtitle:
                    calendar?.name ??
                    (draft.calendarId.isEmpty
                        ? l10n.calendarChooseCalendar
                        : draft.calendarId),
                showChevron: true,
                onTap: _saving ? null : _pickCalendar,
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Text(
            l10n.calendarFieldAttendees,
            style: theme.label?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final person in draft.attendees)
                _PersonChip(
                  key: Key('calendar-editor-person-${person.userId}'),
                  label:
                      person.name ??
                      _names[person.userId] ??
                      l10n.calendarInvitedPerson,
                  removeLabel: l10n.calendarRemovePerson(
                    person.name ??
                        _names[person.userId] ??
                        l10n.calendarInvitedPerson,
                  ),
                  onRemove: _saving ? null : () => _removePerson(person),
                ),
              ConduitChip(
                key: const Key('calendar-editor-add-people'),
                label: l10n.calendarAddPeople,
                icon: Icons.person_add_alt_1_outlined,
                onTap: _saving ? null : _addPeople,
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            l10n.calendarAttendeesNote,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          if (data != null &&
              data.writableCalendars.isEmpty &&
              draft.isNew) ...[
            const SizedBox(height: Spacing.md),
            Text(
              l10n.calendarNoWritableCalendar,
              key: const Key('calendar-editor-no-calendar'),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          if (_error case final message?) ...[
            const SizedBox(height: Spacing.md),
            Text(
              message,
              key: const Key('calendar-editor-error'),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ],
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: ConduitButton(
                  text: l10n.cancel,
                  isSecondary: true,
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: ConduitButton(
                  key: const Key('calendar-editor-save'),
                  text: l10n.save,
                  isLoading: _saving,
                  onPressed: _saving || !changed ? null : _save,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({
    super.key,
    required this.label,
    required this.removeLabel,
    required this.onRemove,
  });

  final String label;
  final String removeLabel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Container(
      padding: const EdgeInsets.only(left: Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: removeLabel,
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
