//! Dates as the system writes them, for row stamps and section headers.
//!
//! On macOS these go through `NSDateFormatter`, so a time of day follows the
//! user's 12- or 24-hour choice and every form follows the app's language,
//! as Mail's list does. Elsewhere (the CI `cargo check` platforms) a plain
//! numeric fallback stands in.
//!
//! [`stamp`] is the one way a chat is dated, wherever it is listed: the
//! sidebar's rows (under any heading), its search results and the ⌘K
//! palette.

use chrono::{DateTime, Local, TimeZone};

use super::sidebar_model::{Stamp, stamp_for};
use crate::l10n::L10n;

/// What else dates a row, besides its own stamp.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dated {
    /// A date heading above it (Previous 30 Days, or a month that names
    /// its year when it isn't this one): the day and month say the rest.
    ByHeading,
    /// Nothing (pinned, in a folder, a search hit, the palette).
    Alone,
}

/// `ms` as a chat's date, by Mail's rules (and Notes', under the same
/// date headings): the time today, "Yesterday", the weekday within the
/// last week, then the day and month ("4 Jul", in the app's language), or
/// the system's short date for a year before this one on a row no heading
/// dates. The second string is what VoiceOver reads (the long date).
pub fn stamp(ms: i64, now: &DateTime<Local>, l: &L10n) -> (String, String) {
    stamp_in(ms, now, Dated::Alone, l)
}

/// [`stamp`] for a row that `dated` says more about.
pub fn stamp_in(ms: i64, now: &DateTime<Local>, dated: Dated, l: &L10n) -> (String, String) {
    let locale = l.locale();
    match stamp_for(ms, now) {
        Stamp::Time => {
            let time = format(ms, Form::Time, locale);
            (time.clone(), time)
        }
        Stamp::Yesterday => (l.yesterday(), l.yesterday()),
        Stamp::Weekday(w) => {
            let day = l.desktop_weekday_long(&w.number_from_monday().to_string());
            (day.clone(), day)
        }
        Stamp::Date => {
            let form = if day_month_reads(ms, now, dated) {
                Form::DayMonth
            } else {
                Form::ShortDate
            };
            (format(ms, form, locale), format(ms, Form::LongDate, locale))
        }
    }
}

/// Whether a date older than a week reads as its day and month alone:
/// under a date heading, or in this calendar year.
fn day_month_reads(ms: i64, now: &DateTime<Local>, dated: Dated) -> bool {
    use chrono::Datelike as _;
    dated == Dated::ByHeading
        || Local
            .timestamp_millis_opt(ms)
            .earliest()
            .is_some_and(|t| t.year() == now.year())
}

/// What to write.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Form {
    /// The time of day, short ("2:02 PM", "14:02").
    Time,
    /// A short numeric date ("7/18/26").
    ShortDate,
    /// The day and the month's short name, in the locale's order ("4 Jul",
    /// "Jul 4", "4. Juli").
    DayMonth,
    /// A long date, for VoiceOver ("July 18, 2026").
    LongDate,
    /// A month on its own ("October").
    Month,
    /// A month and its year ("October 2025").
    MonthYear,
    /// The weekday, day and month ("Tue, Nov 11"), as an agenda heads a day.
    WeekdayDayMonth,
    /// The same with the year ("Tue, Nov 11, 2026").
    WeekdayDayMonthYear,
    /// The day, month and year ("Nov 11, 2026").
    DayMonthYear,
    /// The weekday's short name ("Tue").
    Weekday,
    /// A day, month and year with the time ("Nov 11, 2026 at 9:30 AM").
    DateTime,
}

/// `ms` (milliseconds since the epoch) written in `form` for `locale` (an
/// app locale such as `en` or `zh_Hant`).
pub fn format(ms: i64, form: Form, locale: &str) -> String {
    #[cfg(target_os = "macos")]
    {
        if let Some(s) = mac::format(ms, form, locale) {
            return s;
        }
    }
    fallback(ms, form, locale)
}

/// A month section's title: the month alone in the current year, with its
/// year before that, as the phone heads them.
pub fn month_title(year: i32, month: u32, now: &DateTime<Local>, locale: &str) -> String {
    let Some(first) = Local.with_ymd_and_hms(year, month, 15, 12, 0, 0).earliest() else {
        return format!("{year}-{month:02}");
    };
    use chrono::Datelike as _;
    let form = if year == now.year() {
        Form::Month
    } else {
        Form::MonthYear
    };
    format(first.timestamp_millis(), form, locale)
}

fn fallback(ms: i64, form: Form, _locale: &str) -> String {
    let Some(t) = Local.timestamp_millis_opt(ms).earliest() else {
        return String::new();
    };
    match form {
        Form::Time => t.format("%H:%M").to_string(),
        Form::ShortDate => t.format("%Y-%m-%d").to_string(),
        Form::DayMonth => t.format("%-d %b").to_string(),
        Form::LongDate => t.format("%-d %B %Y").to_string(),
        Form::Month => t.format("%B").to_string(),
        Form::MonthYear => t.format("%B %Y").to_string(),
        Form::WeekdayDayMonth => t.format("%a, %-d %b").to_string(),
        Form::WeekdayDayMonthYear => t.format("%a, %-d %b %Y").to_string(),
        Form::DayMonthYear => t.format("%-d %b %Y").to_string(),
        Form::Weekday => t.format("%a").to_string(),
        Form::DateTime => t.format("%-d %b %Y %H:%M").to_string(),
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::cell::RefCell;
    use std::collections::HashMap;

    use objc2::rc::Retained;
    use objc2_foundation::{NSDate, NSDateFormatter, NSDateFormatterStyle, NSLocale, NSString};

    use super::Form;

    thread_local! {
        /// Formatters are slow to make and rows are drawn every frame while
        /// the list scrolls, so each (locale, form) keeps one.
        static FORMATTERS: RefCell<HashMap<(String, Form), Retained<NSDateFormatter>>> =
            RefCell::new(HashMap::new());
    }

    /// The system's own locale when it speaks the app's language (so the
    /// user's region and 12/24-hour choice apply), else the app's language.
    fn locale_for(app: &str) -> Retained<NSLocale> {
        let current = NSLocale::autoupdatingCurrentLocale();
        let language = app.split(['_', '-']).next().unwrap_or(app);
        let system = current.localeIdentifier().to_string();
        let system_language = system.split(['_', '-']).next().unwrap_or("");
        // zh_Hant and zh (Hans) share a language code but not a script.
        let same_script = !app.starts_with("zh")
            || (app.contains("Hant")
                == (system.contains("Hant") || system.contains("TW") || system.contains("HK")));
        if system_language == language && same_script {
            current
        } else {
            NSLocale::localeWithLocaleIdentifier(&NSString::from_str(&app.replace('_', "-")))
        }
    }

    fn make(form: Form, locale: &str) -> Retained<NSDateFormatter> {
        let f = NSDateFormatter::new();
        f.setLocale(Some(&locale_for(locale)));
        match form {
            Form::Time => {
                f.setDateStyle(NSDateFormatterStyle::NoStyle);
                f.setTimeStyle(NSDateFormatterStyle::ShortStyle);
            }
            Form::ShortDate => {
                f.setDateStyle(NSDateFormatterStyle::ShortStyle);
                f.setTimeStyle(NSDateFormatterStyle::NoStyle);
            }
            Form::LongDate => {
                f.setDateStyle(NSDateFormatterStyle::LongStyle);
                f.setTimeStyle(NSDateFormatterStyle::NoStyle);
            }
            // Stand-alone month names ("LLLL"), as headings use them.
            Form::DayMonth => f.setLocalizedDateFormatFromTemplate(&NSString::from_str("dMMM")),
            Form::Month => f.setLocalizedDateFormatFromTemplate(&NSString::from_str("LLLL")),
            Form::MonthYear => f.setLocalizedDateFormatFromTemplate(&NSString::from_str("yMMMM")),
            Form::WeekdayDayMonth => {
                f.setLocalizedDateFormatFromTemplate(&NSString::from_str("MMMEd"))
            }
            Form::WeekdayDayMonthYear => {
                f.setLocalizedDateFormatFromTemplate(&NSString::from_str("yMMMEd"))
            }
            Form::DayMonthYear => {
                f.setLocalizedDateFormatFromTemplate(&NSString::from_str("yMMMd"))
            }
            Form::Weekday => f.setLocalizedDateFormatFromTemplate(&NSString::from_str("EEE")),
            Form::DateTime => {
                f.setDateStyle(NSDateFormatterStyle::MediumStyle);
                f.setTimeStyle(NSDateFormatterStyle::ShortStyle);
            }
        }
        f
    }

    pub fn format(ms: i64, form: Form, locale: &str) -> Option<String> {
        let date = NSDate::dateWithTimeIntervalSince1970(ms as f64 / 1000.);
        FORMATTERS.with(|cell| {
            let mut map = cell.borrow_mut();
            let f = map
                .entry((locale.to_string(), form))
                .or_insert_with(|| make(form, locale));
            Some(f.stringFromDate(&date).to_string())
        })
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn forms_read_as_the_system_writes_them() {
        let t = Local
            .with_ymd_and_hms(2026, 7, 18, 9, 5, 0)
            .unwrap()
            .timestamp_millis();
        // A language the test machine is unlikely to run in, so the
        // explicit locale is used whatever the system's settings are.
        assert_eq!(format(t, Form::LongDate, "de"), "18. Juli 2026");
        assert_eq!(format(t, Form::ShortDate, "de"), "18.07.26");
        assert_eq!(format(t, Form::Time, "de"), "09:05");
        assert_eq!(format(t, Form::Month, "de"), "Juli");
        assert_eq!(format(t, Form::MonthYear, "de"), "Juli 2026");
    }

    #[test]
    fn a_chat_is_dated_by_mails_rules() {
        // German, which the test machine is unlikely to run in, so the app's
        // language decides every form.
        let l = L10n::new("de");
        let now = Local.with_ymd_and_hms(2026, 9, 22, 14, 0, 0).unwrap();
        let at = |d: chrono::Duration| (now - d).timestamp_millis();
        assert_eq!(
            stamp(at(chrono::Duration::hours(4)), &now, &l),
            ("10:00".into(), "10:00".into())
        );
        assert_eq!(
            stamp(at(chrono::Duration::days(1)), &now, &l).0,
            l.yesterday()
        );
        assert_eq!(
            stamp(at(chrono::Duration::days(4)), &now, &l),
            ("Freitag".into(), "Freitag".into())
        );
        // Seven days back the weekday would read as today's: the date, its
        // day and month this year.
        assert_eq!(
            stamp(at(chrono::Duration::days(7)), &now, &l).0,
            "15. Sept."
        );
        let march = Local.with_ymd_and_hms(2026, 3, 2, 9, 0, 0).unwrap();
        assert_eq!(
            stamp(march.timestamp_millis(), &now, &l),
            ("2. März".into(), "2. März 2026".into())
        );
        // A year before this one: the short date, unless a heading (which
        // names the year) is over the row.
        let last_year = Local.with_ymd_and_hms(2025, 7, 4, 9, 0, 0).unwrap();
        assert_eq!(
            stamp(last_year.timestamp_millis(), &now, &l),
            ("04.07.25".into(), "4. Juli 2025".into())
        );
        assert_eq!(
            stamp_in(last_year.timestamp_millis(), &now, Dated::ByHeading, &l).0,
            "4. Juli"
        );
    }

    #[test]
    fn day_and_month_follow_the_language() {
        let t = Local
            .with_ymd_and_hms(2026, 7, 4, 9, 5, 0)
            .unwrap()
            .timestamp_millis();
        assert_eq!(format(t, Form::DayMonth, "de"), "4. Juli");
        assert_eq!(format(t, Form::DayMonth, "fr"), "4 juil.");
        assert_eq!(format(t, Form::DayMonth, "ja"), "7月4日");
    }

    #[test]
    fn a_month_of_this_year_drops_the_year() {
        let now = Local.with_ymd_and_hms(2026, 11, 9, 12, 0, 0).unwrap();
        assert_eq!(month_title(2026, 7, &now, "de"), "Juli");
        assert_eq!(month_title(2025, 10, &now, "de"), "Oktober 2025");
    }
}
