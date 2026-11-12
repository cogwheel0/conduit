import '../../../core/services/native_sheet_bridge.dart';

/// The calendar's month page: Settings's Calendar row opens it. In the native
/// iOS sheet it is the system's month grid over the chosen day's agenda;
/// where Flutter draws Settings, the same row opens the Flutter calendar.
const calendarMonthPageId = NativeSheetRoutes.calendar;

/// The month grid's id: paging sends `calendar.grid:month`, choosing a day
/// `calendar.grid:day`.
const calendarGridId = 'calendar.grid';

/// Rows of the calendar's pages act under ids starting with this.
const calendarRowPrefix = 'calendar.';

/// Moves the month page to today.
const calendarTodayRowId = 'calendar.today';

/// Reads the month again after a failed read.
const calendarRetryRowId = 'calendar.retry';

/// The page of an agenda item; the URI-encoded item key follows.
const calendarEventPagePrefix = 'calendar-event:';

/// The event editor; `new` or the URI-encoded event id follows.
const calendarEditorPagePrefix = 'calendar-event-edit:';

/// The page that adds people to an editor's event; the editor key follows.
const calendarPeoplePagePrefix = 'calendar-event-people:';

/// The list of calendars, which ones show, and the default.
const calendarCalendarsPageId = 'calendar-calendars';

/// The form making a new calendar.
const calendarNewCalendarPageId = 'calendar-new-calendar';

/// The editor key of a new event.
const calendarNewEventKey = 'new';

String calendarEventPageId(String itemKey) =>
    '$calendarEventPagePrefix${Uri.encodeComponent(itemKey)}';

/// [eventId] null for a new event.
String calendarEditorKey(String? eventId) =>
    eventId == null ? calendarNewEventKey : Uri.encodeComponent(eventId);

String calendarEditorPageId(String editorKey) =>
    '$calendarEditorPagePrefix$editorKey';

String calendarPeoplePageId(String editorKey) =>
    '$calendarPeoplePagePrefix$editorKey';

/// A row of an event page: `calendar.event.<action>:<item key>`.
String calendarEventRowId(String action, String itemKey) =>
    'calendar.event.$action:${Uri.encodeComponent(itemKey)}';

/// A field of an editor: `calendar.editor.<field>:<editor key>`.
String calendarEditorRowId(String field, String editorKey) =>
    'calendar.editor.$field:$editorKey';

/// Removes person [userId] from an editor's event.
String calendarEditorPersonRemoveId(String editorKey, String userId) =>
    'calendar.editor.person-remove:$editorKey:${Uri.encodeComponent(userId)}';

/// The people page's search field.
String calendarPeopleSearchId(String editorKey) =>
    'calendar.people.search:$editorKey';

/// Adds person [userId], found on the people page, to an editor's event.
String calendarPeopleAddId(String editorKey, String userId) =>
    'calendar.people.add:$editorKey:${Uri.encodeComponent(userId)}';

/// A scheduled task's entry on the agenda, which opens what its run made.
String calendarScheduledRowId(String itemKey) =>
    'calendar.scheduled:${Uri.encodeComponent(itemKey)}';

/// Shows or hides calendar [calendarId]'s events.
String calendarToggleRowId(String calendarId) =>
    'calendar.calendars.toggle:${Uri.encodeComponent(calendarId)}';

/// Makes calendar [calendarId] the default.
String calendarMakeDefaultId(String calendarId) =>
    'calendar.calendars.default:${Uri.encodeComponent(calendarId)}';

/// The new calendar form's fields and Create.
const calendarNewNameRowId = 'calendar.new.name';
const calendarNewColorRowId = 'calendar.new.color';
const calendarNewCreateId = 'calendar.new.create';
