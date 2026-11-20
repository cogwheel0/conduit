//! How the calendar writes its days and times. The daemon decides what a row
//! says (core's row-time rule) and sends wall clocks in the Mac's zone; this
//! only puts them in words, as the phone's `calendar_format.dart` does.

use conduit_protocol::{CalendarAgenda, CalendarItemDto, CalendarRowTimeDto, CalendarWallTime};
use gpui_kit::{Hsla, Rgba};

use crate::l10n::L10n;
use crate::shell::date_picker::{WallClock, seconds_of};
use crate::views::dates::{Form, format};

/// `wall` as the date picker holds it.
pub fn clock_of(wall: &CalendarWallTime) -> WallClock {
    WallClock {
        year: wall.year as i32,
        month: wall.month.clamp(1, 12) as u32,
        day: wall.day.clamp(1, 31) as u32,
        hour: wall.hour.clamp(0, 23) as u32,
        minute: wall.minute.clamp(0, 59) as u32,
    }
}

/// A picked clock as the protocol's wall time.
pub fn wall_of(clock: WallClock) -> CalendarWallTime {
    CalendarWallTime {
        year: clock.year.into(),
        month: clock.month.into(),
        day: clock.day.into(),
        hour: clock.hour.into(),
        minute: clock.minute.into(),
    }
}

/// The local instant `wall` names, in milliseconds.
pub fn wall_ms(wall: &CalendarWallTime) -> i64 {
    seconds_of(clock_of(wall)).unwrap_or_default() * 1000
}

/// `wall` in `form`.
pub fn wall_in(wall: &CalendarWallTime, form: Form, l: &L10n) -> String {
    format(wall_ms(wall), form, l.locale())
}

/// The time of day ("9:30 AM", "09:30").
pub fn time(wall: &CalendarWallTime, l: &L10n) -> String {
    wall_in(wall, Form::Time, l)
}

/// The day with its weekday ("Tue, Nov 11").
pub fn day(wall: &CalendarWallTime, l: &L10n) -> String {
    wall_in(wall, Form::WeekdayDayMonth, l)
}

/// The day with its weekday and year ("Tue, Nov 11, 2026"), for a date
/// field.
pub fn full_day(wall: &CalendarWallTime, l: &L10n) -> String {
    wall_in(wall, Form::WeekdayDayMonthYear, l)
}

pub fn same_day(a: &CalendarWallTime, b: &CalendarWallTime) -> bool {
    a.year == b.year && a.month == b.month && a.day == b.day
}

/// The day after `wall`, at the same clock.
pub fn next_day(wall: &CalendarWallTime) -> CalendarWallTime {
    let date =
        chrono::NaiveDate::from_ymd_opt(wall.year as i32, wall.month as u32, wall.day as u32)
            .and_then(|d| d.succ_opt());
    match date {
        Some(d) => {
            use chrono::Datelike as _;
            CalendarWallTime {
                year: d.year().into(),
                month: d.month().into(),
                day: d.day().into(),
                ..wall.clone()
            }
        }
        None => wall.clone(),
    }
}

/// A day's heading: "Today · Tue, Nov 11", "Tomorrow · …", or the day.
pub fn day_heading(wall: &CalendarWallTime, today: Option<&CalendarWallTime>, l: &L10n) -> String {
    let date = day(wall, l);
    match today {
        Some(t) if same_day(wall, t) => l.calendar_day_today(&date),
        Some(t) if same_day(wall, &next_day(t)) => l.calendar_day_tomorrow(&date),
        _ => date,
    }
}

/// The range a page covers ("Nov 11 – Nov 24"), with years when it is not
/// all this year.
pub fn range_label(agenda: &CalendarAgenda, l: &L10n) -> String {
    let (Some(first), Some(end)) = (&agenda.first_day, &agenda.end_day) else {
        return String::new();
    };
    // The end is the day after the last.
    let last_ms = wall_ms(end) - 12 * 3_600_000;
    let this_year = agenda.today.as_ref().map(|t| t.year);
    let last_year = {
        use chrono::{Datelike as _, TimeZone as _};
        chrono::Local
            .timestamp_millis_opt(last_ms)
            .earliest()
            .map(|t| i64::from(t.year()))
    };
    let with_year = Some(first.year) != this_year || last_year != this_year;
    let form = if with_year {
        Form::DayMonthYear
    } else {
        Form::DayMonth
    };
    l.calendar_range_label(&wall_in(first, form, l), &format(last_ms, form, l.locale()))
}

/// What a row says about its time on its day.
pub fn row_time(row: &CalendarRowTimeDto, l: &L10n) -> String {
    let clock = |w: &Option<CalendarWallTime>| w.as_ref().map(|w| time(w, l)).unwrap_or_default();
    match row.kind.as_str() {
        "at" => clock(&row.start),
        "range" => format!("{} – {}", clock(&row.start), clock(&row.end)),
        "startsAt" => l.calendar_starts_at(&clock(&row.start)),
        "endsAt" => l.calendar_ends_at(&clock(&row.end)),
        _ => l.calendar_all_day(),
    }
}

/// When an event that goes on past `day`, the day of the row that shows it,
/// ends, as the row is said ("Ends Fri, Nov 13 2:00 AM", or the last day for
/// one all day). None when it ends on `day`: the row's own time says so.
pub fn ends_after(item: &CalendarItemDto, day: &CalendarWallTime, l: &L10n) -> Option<String> {
    let date = |w: &CalendarWallTime| (w.year, w.month, w.day);
    if item.all_day {
        let last = item.last_day.as_ref()?;
        return (date(last) > date(day)).then(|| l.calendar_ends_at(&self::day(last, l)));
    }
    let end = item.end.as_ref()?;
    (date(end) > date(day))
        .then(|| l.calendar_ends_at(&format!("{} {}", self::day(end, l), time(end, l))))
}

/// When an event happens, in full, for its sheet.
pub fn when(item: &CalendarItemDto, l: &L10n) -> String {
    let first = day(&item.start, l);
    let last = item.last_day.as_ref().unwrap_or(&item.start);
    if item.all_day {
        return if same_day(&item.start, last) {
            format!("{first} · {}", l.calendar_all_day())
        } else {
            format!("{first} – {}", day(last, l))
        };
    }
    let start = time(&item.start, l);
    match &item.end {
        Some(end) if wall_ms(end) > wall_ms(&item.start) => {
            if same_day(&item.start, end) {
                format!("{first} · {start} – {}", time(end, l))
            } else {
                format!("{first} {start} – {} {}", day(end, l), time(end, l))
            }
        }
        _ => format!("{first} · {start}"),
    }
}

/// An invitation's answer, as the phone names it.
pub fn answer_label(answer: Option<&str>, l: &L10n) -> String {
    match answer {
        Some("accepted") => l.calendar_rsvp_accepted(),
        Some("tentative") => l.calendar_rsvp_tentative(),
        Some("declined") => l.calendar_rsvp_declined(),
        _ => l.calendar_rsvp_pending(),
    }
}

/// The repeat choices, in the editor's order.
pub const REPEATS: [&str; 6] = ["none", "daily", "weekdays", "weekly", "monthly", "yearly"];

pub fn repeat_label(repeat: &str, l: &L10n) -> String {
    match repeat {
        "daily" => l.calendar_repeat_daily(),
        "weekdays" => l.calendar_repeat_weekdays(),
        "weekly" => l.calendar_repeat_weekly(),
        "monthly" => l.calendar_repeat_monthly(),
        "yearly" => l.calendar_repeat_yearly(),
        "custom" => l.calendar_repeat_custom(),
        _ => l.calendar_repeat_none(),
    }
}

/// What a scheduled-task entry's row says it is.
pub fn scheduled_label(item: &CalendarItemDto, l: &L10n) -> String {
    match item.scheduled_state.as_deref() {
        Some("failed") => l.calendar_scheduled_run_failed(),
        Some("finished") => l.calendar_scheduled_run_finished(),
        _ => l.calendar_scheduled_upcoming(),
    }
}

/// A calendar's `#rrggbb` as a colour.
pub fn parse_color(hex: Option<&str>) -> Option<Hsla> {
    let value = hex?.trim().trim_start_matches('#');
    if value.len() != 6 || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let n = u32::from_str_radix(value, 16).ok()?;
    Some(
        Rgba {
            r: ((n >> 16) & 0xff) as f32 / 255.,
            g: ((n >> 8) & 0xff) as f32 / 255.,
            b: (n & 0xff) as f32 / 255.,
            a: 1.,
        }
        .into(),
    )
}

/// The colours a new calendar can take (the phone's), with the name each is
/// announced by.
pub const COLORS: [(&str, &str); 6] = [
    ("#3b82f6", "blue"),
    ("#22c55e", "green"),
    ("#f59e0b", "amber"),
    ("#ef4444", "red"),
    ("#8b5cf6", "purple"),
    ("#14b8a6", "teal"),
];

/// Why a calendar call was refused, in the phone's words; `fallback` when
/// it gave no reason.
pub fn failure_text(e: &conduit_protocol::RpcError, fallback: String, l: &L10n) -> String {
    match e.args.get("reason").map(String::as_str) {
        Some("accountChanged") => l.calendar_account_changed(),
        Some("unavailable") => l.calendar_unavailable(),
        Some("notWritable" | "destinationNotWritable") => l.calendar_write_denied(),
        Some("notInvited") => l.calendar_not_invited(),
        Some("notOwnCalendar") => l.calendar_make_default_failed(),
        Some("scheduledTaskEntry") => l.calendar_scheduled_entry_read_only(),
        Some("notFound") => l.calendar_not_found(),
        _ => e
            .args
            .get("detail")
            .filter(|d| !d.trim().is_empty())
            .cloned()
            .unwrap_or(fallback),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wall(y: i64, m: i64, d: i64, h: i64, min: i64) -> CalendarWallTime {
        CalendarWallTime {
            year: y,
            month: m,
            day: d,
            hour: h,
            minute: min,
        }
    }

    #[test]
    fn rows_say_what_the_daemon_decided() {
        let l = L10n::new("en");
        let row = |kind: &str| CalendarRowTimeDto {
            kind: kind.into(),
            start: Some(wall(2026, 11, 12, 9, 0)),
            end: Some(wall(2026, 11, 12, 10, 30)),
        };
        assert_eq!(row_time(&row("allDay"), &l), l.calendar_all_day());
        assert!(row_time(&row("range"), &l).contains(" – "));
        assert!(row_time(&row("startsAt"), &l).starts_with("Starts"));
        assert!(row_time(&row("endsAt"), &l).starts_with("Ends"));
    }

    #[test]
    fn today_and_tomorrow_head_their_days() {
        let l = L10n::new("en");
        let today = wall(2026, 12, 31, 0, 0);
        assert!(day_heading(&today, Some(&today), &l).starts_with("Today · "));
        assert!(day_heading(&wall(2027, 1, 1, 0, 0), Some(&today), &l).starts_with("Tomorrow · "));
        assert!(!day_heading(&wall(2027, 1, 2, 0, 0), Some(&today), &l).contains('·'));
    }

    #[test]
    fn colours_parse_only_as_six_hex_digits() {
        assert!(parse_color(Some("#22c55e")).is_some());
        assert!(parse_color(Some("22C55E")).is_some());
        assert!(parse_color(Some("#fff")).is_none());
        assert!(parse_color(None).is_none());
    }
}
