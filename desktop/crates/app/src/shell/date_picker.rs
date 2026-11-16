//! A native date or time picker, as Calendar's editor asks for one: an
//! `NSAlert` sheet on the window whose accessory is an `NSDatePicker` (a
//! month calendar for a day, a stepper field for a time of day).
//!
//! [`pick`] resolves with the chosen wall clock, or `None` when cancelled.
//! As with [`crate::shell::sheet`], the alert is begun from a foreground task
//! outside any GPUI borrow, because AppKit calls back into the window's
//! delegate while a sheet begins.

use gpui_kit::{App, Task, Window};

/// What the picker chooses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PickerMode {
    /// A calendar day.
    Date,
    /// A time of day.
    Time,
}

/// A wall clock in the Mac's time zone, to the minute.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct WallClock {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
}

/// What the picker sheet says and starts on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PickerSpec {
    pub title: String,
    pub mode: PickerMode,
    pub value: WallClock,
    pub ok: String,
    pub cancel: String,
}

/// Test hook: when set, a picker answers at once with this instead of
/// showing (E2E sets the editor's fields directly). As the sheet does, a
/// Date picker keeps the time it started on and a Time picker its day.
#[derive(Clone, Copy, Debug, Default)]
pub struct AutoPick(pub Option<Option<WallClock>>);

impl gpui_kit::Global for AutoPick {}

/// Shows the picker as a sheet on `window`.
pub fn pick(window: &Window, spec: PickerSpec, cx: &mut App) -> Task<Option<WallClock>> {
    if let Some(answer) = cx.try_global::<AutoPick>().and_then(|a| a.0) {
        let start = spec.value;
        return Task::ready(answer.map(|picked| match spec.mode {
            PickerMode::Date => WallClock {
                hour: start.hour,
                minute: start.minute,
                ..picked
            },
            PickerMode::Time => WallClock {
                year: start.year,
                month: start.month,
                day: start.day,
                ..picked
            },
        }));
    }
    #[cfg(target_os = "macos")]
    {
        let Some(ns_window) = conduit_components::window::macos::ns_window(window) else {
            return Task::ready(None);
        };
        cx.spawn(async move |_| match macos::begin(&ns_window, &spec) {
            Some(rx) => rx.await.ok().flatten(),
            None => None,
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, spec);
        Task::ready(None)
    }
}

/// The local instant `wall` names, in seconds since the epoch (the first one
/// when a clock change makes it twice, the hour after when it skips it).
pub fn seconds_of(wall: WallClock) -> Option<i64> {
    use chrono::TimeZone as _;
    let local = chrono::Local;
    let naive = chrono::NaiveDate::from_ymd_opt(wall.year, wall.month, wall.day)?.and_hms_opt(
        wall.hour,
        wall.minute,
        0,
    )?;
    local
        .from_local_datetime(&naive)
        .earliest()
        .or_else(|| {
            local
                .from_local_datetime(&(naive + chrono::Duration::hours(1)))
                .earliest()
        })
        .map(|t| t.timestamp())
}

/// The wall clock at `seconds` since the epoch, in the Mac's zone.
pub fn wall_of(seconds: i64) -> Option<WallClock> {
    use chrono::{Datelike as _, TimeZone as _, Timelike as _};
    let t = chrono::Local.timestamp_opt(seconds, 0).earliest()?;
    Some(WallClock {
        year: t.year(),
        month: t.month(),
        day: t.day(),
        hour: t.hour(),
        minute: t.minute(),
    })
}

#[cfg(target_os = "macos")]
mod macos {
    use std::cell::RefCell;

    use block2::RcBlock;
    use futures::channel::oneshot;
    use objc2::MainThreadMarker;
    use objc2::rc::Retained;
    use objc2_app_kit::{
        NSAlert, NSAlertFirstButtonReturn, NSAlertStyle, NSDatePicker, NSDatePickerElementFlags,
        NSDatePickerStyle, NSModalResponse, NSWindow,
    };
    use objc2_foundation::{NSDate, NSString};

    use super::{PickerMode, PickerSpec, WallClock, seconds_of, wall_of};

    /// Starts the sheet; the receiver gets the chosen clock.
    pub fn begin(
        window: &Retained<NSWindow>,
        spec: &PickerSpec,
    ) -> Option<oneshot::Receiver<Option<WallClock>>> {
        let mtm = MainThreadMarker::new()?;
        let alert = NSAlert::new(mtm);
        alert.setMessageText(&NSString::from_str(&spec.title));
        alert.setAlertStyle(NSAlertStyle::Informational);
        alert.addButtonWithTitle(&NSString::from_str(&spec.ok));
        let cancel = alert.addButtonWithTitle(&NSString::from_str(&spec.cancel));
        cancel.setKeyEquivalent(&NSString::from_str("\u{1b}"));

        let picker = NSDatePicker::new(mtm);
        match spec.mode {
            PickerMode::Date => {
                picker.setDatePickerStyle(NSDatePickerStyle::ClockAndCalendar);
                picker.setDatePickerElements(NSDatePickerElementFlags::YearMonthDay);
            }
            PickerMode::Time => {
                picker.setDatePickerStyle(NSDatePickerStyle::TextFieldAndStepper);
                picker.setDatePickerElements(NSDatePickerElementFlags::HourMinute);
            }
        }
        picker.setBezeled(true);
        if let Some(seconds) = seconds_of(spec.value) {
            picker.setDateValue(&NSDate::dateWithTimeIntervalSince1970(seconds as f64));
        }
        picker.sizeToFit();
        alert.setAccessoryView(Some(&picker));
        alert.layout();
        // The picker takes the keyboard, so the arrow keys move its value.
        alert.window().setInitialFirstResponder(Some(&picker));

        let (tx, rx) = oneshot::channel::<Option<WallClock>>();
        let tx = RefCell::new(Some(tx));
        let start = spec.value;
        let mode = spec.mode;
        // The block keeps the alert and picker alive until it is answered.
        let keep = (alert.clone(), picker.clone());
        let handler = RcBlock::new(move |response: NSModalResponse| {
            let (_, picker) = &keep;
            let chosen = (response == NSAlertFirstButtonReturn)
                .then(|| wall_of(picker.dateValue().timeIntervalSince1970() as i64))
                .flatten()
                .map(|picked| match mode {
                    // Only the part this picker chooses changes.
                    PickerMode::Date => WallClock {
                        hour: start.hour,
                        minute: start.minute,
                        ..picked
                    },
                    PickerMode::Time => WallClock {
                        year: start.year,
                        month: start.month,
                        day: start.day,
                        ..picked
                    },
                });
            if let Some(tx) = tx.borrow_mut().take() {
                let _ = tx.send(chosen);
            }
        });
        alert.beginSheetModalForWindow_completionHandler(window, Some(&handler));
        Some(rx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wall_clock_round_trips_through_the_local_zone() {
        let wall = WallClock {
            year: 2026,
            month: 11,
            day: 12,
            hour: 9,
            minute: 30,
        };
        assert_eq!(seconds_of(wall).and_then(wall_of), Some(wall));
        assert_eq!(
            seconds_of(WallClock {
                month: 2,
                day: 30,
                ..wall
            }),
            None,
            "a day that does not exist"
        );
    }
}
