import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/calendar/calendar_draft.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import 'calendar_event_editor.dart';
import 'calendar_format.dart';
import 'calendar_sheet_frame.dart';

/// Shows [event], as the agenda listed it, for the account [owner] that opened
/// it.
///
/// The agenda's own copy is what is shown and what an invited person answers
/// from: it is complete, and an invitation to a calendar the account cannot
/// read is listed there even though the event's detail route would refuse it.
Future<void> showCalendarEventSheet(
  BuildContext context, {
  required CalendarEventModel event,
  required CalendarOwner owner,
}) {
  return ThemedSheets.showCustom<void>(
    context: context,
    builder: (_) => CalendarEventSheet(event: event, owner: owner),
  );
}

/// What reading the event's own record said.
enum _Detail {
  /// Not asked: the calendar is not one the account can read, so the record
  /// would be refused and the agenda copy is all there is.
  skipped,
  loading,
  fresh,

  /// The server refused the read: access to the calendar is gone.
  denied,

  /// The event no longer exists.
  gone,

  /// The read failed for another reason; the agenda copy stands.
  failed,
}

class CalendarEventSheet extends ConsumerStatefulWidget {
  const CalendarEventSheet({
    super.key,
    required this.event,
    required this.owner,
  });

  final CalendarEventModel event;
  final CalendarOwner owner;

  @override
  ConsumerState<CalendarEventSheet> createState() => _CalendarEventSheetState();
}

class _CalendarEventSheetState extends ConsumerState<CalendarEventSheet> {
  _Detail _detail = _Detail.skipped;
  CalendarEventModel? _fresh;
  CalendarRsvp? _answer;
  bool _busy = false;
  String? _error;

  CalendarAgenda get _notifier => ref.read(calendarAgendaProvider.notifier);
  CalendarEventModel get _event => widget.event;

  @override
  void initState() {
    super.initState();
    final data = ref.read(calendarAgendaProvider).asData?.value;
    final readable =
        data?.calendars.any((c) => c.id == _event.calendarId) ?? false;
    if (readable) {
      _detail = _Detail.loading;
      _loadDetail();
    }
  }

  /// Refreshes from the event's own record. A refusal keeps only what the agenda
  /// already authorized and turns editing off; the agenda is refreshed so what
  /// the account can see is up to date.
  Future<void> _loadDetail() async {
    try {
      final fetched = await _notifier.fetchEvent(
        _event.id,
        owner: widget.owner,
      );
      if (!mounted) return;
      setState(() {
        _fresh = fetched;
        _detail = _Detail.fresh;
      });
    } on DioException catch (error) {
      if (!mounted) return;
      final status = error.response?.statusCode;
      setState(
        () => _detail = switch (status) {
          403 => _Detail.denied,
          404 => _Detail.gone,
          _ => _Detail.failed,
        },
      );
      if (status == 403 || status == 404) _refreshAgenda();
    } catch (_) {
      // The account changed or the calendar became unavailable: nothing here
      // may be shown as fresh, and the actions refuse on their own.
      if (mounted) setState(() => _detail = _Detail.failed);
    }
  }

  void _refreshAgenda() {
    final owner = _notifier.captureOwner();
    if (owner != null) _notifier.refresh(owner: owner);
  }

  Future<void> _respond(CalendarRsvp status) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final stored = await _notifier.respond(
        _event,
        status,
        owner: widget.owner,
      );
      if (mounted) setState(() => _answer = stored);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = calendarErrorText(
            l10n,
            error,
            fallback: l10n.calendarRsvpFailed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    CalendarEventModel stored;
    try {
      // The stored event, never an occurrence: an occurrence's start is not the
      // series' start, and a series is edited as a whole.
      stored = await _notifier.fetchEvent(_event.id, owner: widget.owner);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = calendarErrorText(
            l10n,
            error,
            fallback: l10n.calendarEventLoadFailed,
          );
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final saved = await showCalendarEventEditor(
      context,
      owner: widget.owner,
      event: stored,
    );
    if (saved == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: _event.isRecurring
          ? l10n.calendarEventDeleteSeries
          : l10n.calendarEventDelete,
      message: _event.isRecurring
          ? l10n.calendarEventDeleteSeriesConfirm(_event.title)
          : l10n.calendarEventDeleteConfirm(_event.title),
      confirmText: _event.isRecurring
          ? l10n.calendarEventDeleteSeries
          : l10n.calendarEventDelete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _notifier.deleteEvent(_event, owner: widget.owner);
      if (mounted && _notifier.isCurrentOwner(widget.owner)) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = calendarErrorText(
            l10n,
            error,
            fallback: l10n.calendarEventDeleteFailed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final zone = ref.watch(calendarZoneProvider);
    final data = ref.watch(calendarAgendaProvider).asData?.value;
    final access = data?.access;
    final calendars = data?.calendars ?? const <CalendarModel>[];
    final calendar = calendars
        .where((c) => c.id == _event.calendarId)
        .firstOrNull;
    final shown = _fresh ?? _event;
    final canEdit =
        access != null &&
        access.canEdit(_event, calendars) &&
        _detail != _Detail.denied &&
        _detail != _Detail.gone &&
        _detail != _Detail.loading;
    final invited = access?.canRsvp(shown) ?? false;
    final answer = _answer ?? access?.ownAnswer(shown);
    final repeat = CalendarRepeat.fromRule(_event.rrule);

    return CalendarSheetFrame(
      title: l10n.calendarEventDetailTitle,
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            _event.title.isEmpty ? l10n.calendarUntitledEvent : _event.title,
            key: const Key('calendar-event-title'),
            style: theme.headingMedium,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            formatCalendarWhen(
              context,
              l10n,
              startNs: _event.startAtNs,
              endNs: _event.endAtNs,
              allDay: _event.allDay,
              zone: zone,
            ),
            key: const Key('calendar-event-when'),
            style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
          ),
          if (_event.location case final location?) ...[
            const SizedBox(height: Spacing.xs),
            Text(location, key: const Key('calendar-event-location')),
          ],
          if (_event.description case final description?) ...[
            const SizedBox(height: Spacing.md),
            Text(description, key: const Key('calendar-event-description')),
          ],
          const SizedBox(height: Spacing.md),
          if (calendar != null)
            Text(
              l10n.calendarEventCalendar(calendar.name),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (_event.organizerName case final organizer?)
            Text(
              l10n.calendarEventOrganizer(organizer),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (_event.isRecurring) ...[
            Text(
              repeat == CalendarRepeat.custom
                  ? l10n.calendarRepeatCustom
                  : repeatLabel(l10n, repeat),
              key: const Key('calendar-event-repeat'),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.calendarEventSeriesNote,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          if (shown.attendees.isNotEmpty)
            Text(
              l10n.calendarEventInvitedCount(shown.attendees.length),
              key: const Key('calendar-event-invited'),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (invited) ...[
            const SizedBox(height: Spacing.lg),
            Text(
              l10n.calendarRsvpPrompt,
              style: theme.label?.copyWith(color: theme.textSecondary),
            ),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final status in const [
                  CalendarRsvp.accepted,
                  CalendarRsvp.tentative,
                  CalendarRsvp.declined,
                ])
                  ConduitChip(
                    key: Key('calendar-rsvp-${status.wire}'),
                    label: rsvpLabel(l10n, status),
                    isSelected: answer == status,
                    onTap: _busy ? null : () => _respond(status),
                  ),
              ],
            ),
          ],
          if (_detail == _Detail.gone) ...[
            const SizedBox(height: Spacing.md),
            Text(
              l10n.calendarEventGone,
              key: const Key('calendar-event-gone'),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ] else if (!canEdit && _detail != _Detail.loading) ...[
            const SizedBox(height: Spacing.md),
            Text(
              l10n.calendarEventReadOnly,
              key: const Key('calendar-event-read-only'),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          if (_error case final message?) ...[
            const SizedBox(height: Spacing.md),
            Text(
              message,
              key: const Key('calendar-event-error'),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ],
          if (canEdit) ...[
            const SizedBox(height: Spacing.lg),
            Row(
              children: [
                Expanded(
                  child: ConduitButton(
                    key: const Key('calendar-event-delete'),
                    text: _event.isRecurring
                        ? l10n.calendarEventDeleteSeries
                        : l10n.calendarEventDelete,
                    isDestructive: true,
                    isSecondary: true,
                    onPressed: _busy ? null : _delete,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: ConduitButton(
                    key: const Key('calendar-event-edit'),
                    text: _event.isRecurring
                        ? l10n.calendarEventEditSeries
                        : l10n.calendarEventEdit,
                    isLoading: _busy,
                    onPressed: _busy ? null : _edit,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
