//! A native date or time picker, as Calendar's editor asks for one: an
//! `NSAlert` sheet on the window whose accessory is an `NSDatePicker` (a
//! month calendar for a day, a stepper field for a time of day).
//!
//! [`pick`] resolves with the chosen wall clock, or `None` when cancelled.
//! As with [`crate::shell::sheet`], the alert is begun from a foreground task
//! outside any GPUI borrow, because AppKit calls back into the window's
//! delegate while a sheet begins.
//!
//! On Windows and Linux (a window with no NSWindow) the picker is the app's
//! own prompt ([`crate::shell::app_prompt`]) with a [`PickerField`] in it: a
//! month grid whose arrow keys move the day (Page Up and Page Down the
//! month, Home and End its ends), or an hour and a minute that Up and Down
//! step and digits type, Left and Right moving between them
//! ([`PickerState`]).

use std::cell::Cell;
use std::rc::Rc;

use chrono::{Datelike as _, NaiveDate};
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::theme::with_alpha;
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Context, FocusHandle, KeyBinding, KeyDownEvent, PromptButton, PromptLevel, Role,
    SharedString, Task, Window, actions, div, px,
};

use crate::views::dates::{self, Form};

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
    if let Some(ns_window) = conduit_components::window::macos::ns_window(window) {
        return cx.spawn(async move |_| match macos::begin(&ns_window, &spec) {
            Some(rx) => rx.await.ok().flatten(),
            None => None,
        });
    }
    // The Mac draws no picker of its own in a window (its pickers are
    // NSDatePicker sheets).
    if !crate::shell::app_prompt::installed(cx) {
        return Task::ready(None);
    }
    pick_in_window(window.window_handle(), spec, cx)
}

/// [`pick`] through the app's own prompt, with a [`PickerField`] in it.
fn pick_in_window(
    window: gpui_kit::AnyWindowHandle,
    spec: PickerSpec,
    cx: &mut App,
) -> Task<Option<WallClock>> {
    cx.spawn(async move |cx| {
        let chosen = Rc::new(Cell::new(spec.value));
        let shown = window
            .update(cx, |_, window, cx| {
                let locale = {
                    use crate::l10n::ActiveL10n as _;
                    cx.l10n().locale().to_string()
                };
                let field = cx.new(|cx| {
                    PickerField::new(
                        PickerState::new(spec.mode, spec.value),
                        spec.title.clone(),
                        locale,
                        chosen.clone(),
                        cx,
                    )
                });
                let stops = vec![field.read(cx).focus.clone()];
                crate::shell::app_prompt::show_next_with(
                    crate::shell::app_prompt::Accessory {
                        view: field.into(),
                        stops,
                    },
                    cx,
                );
                window.prompt(
                    PromptLevel::Info,
                    &spec.title,
                    None,
                    &[
                        PromptButton::ok(spec.ok.clone()),
                        PromptButton::cancel(spec.cancel.clone()),
                    ],
                    cx,
                )
            })
            .ok()?;
        (shown.await == Ok(0)).then(|| chosen.get())
    })
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

/// Which part of a time of day the keys change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Segment {
    Hour,
    Minute,
}

/// A picker's value as the keys move it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PickerState {
    pub mode: PickerMode,
    pub value: WallClock,
    /// A time's part the keys change.
    pub segment: Segment,
    /// A digit typed into the segment, waiting for its second.
    typed: Option<u32>,
}

impl PickerState {
    pub fn new(mode: PickerMode, value: WallClock) -> Self {
        Self {
            mode,
            value,
            segment: Segment::Hour,
            typed: None,
        }
    }

    fn day(&self) -> Option<NaiveDate> {
        NaiveDate::from_ymd_opt(self.value.year, self.value.month, self.value.day)
    }

    fn set_day(&mut self, d: NaiveDate) {
        self.value.year = d.year();
        self.value.month = d.month();
        self.value.day = d.day();
    }

    /// Picks a day (a click on the grid).
    pub fn pick_day(&mut self, day: NaiveDate) {
        self.set_day(day);
    }

    /// Moves the value for `key` (`left`, `pagedown`, `7`…): true when the
    /// picker took the key.
    pub fn key(&mut self, key: &str) -> bool {
        match self.mode {
            PickerMode::Date => self.date_key(key),
            PickerMode::Time => self.time_key(key),
        }
    }

    fn date_key(&mut self, key: &str) -> bool {
        let Some(day) = self.day() else {
            return false;
        };
        let moved = match key {
            "left" => day.pred_opt(),
            "right" => day.succ_opt(),
            "up" => day.checked_sub_days(chrono::Days::new(7)),
            "down" => day.checked_add_days(chrono::Days::new(7)),
            "pageup" => day.checked_sub_months(chrono::Months::new(1)),
            "pagedown" => day.checked_add_months(chrono::Months::new(1)),
            "home" => day.with_day(1),
            "end" => day
                .with_day(1)
                .and_then(|d| d.checked_add_months(chrono::Months::new(1)))
                .and_then(|d| d.pred_opt()),
            _ => return false,
        };
        if let Some(d) = moved {
            self.set_day(d);
        }
        true
    }

    /// Picks which part of a time the keys change (a click on it).
    pub fn select(&mut self, segment: Segment) {
        self.segment = segment;
        self.typed = None;
    }

    /// Steps `segment` by one, up or down (its arrows), wrapping as the keys
    /// do.
    pub fn step(&mut self, segment: Segment, by: i32) {
        self.select(segment);
        self.time_key(if by > 0 { "up" } else { "down" });
    }

    fn time_key(&mut self, key: &str) -> bool {
        let modulus = match self.segment {
            Segment::Hour => 24,
            Segment::Minute => 60,
        };
        let current = match self.segment {
            Segment::Hour => self.value.hour,
            Segment::Minute => self.value.minute,
        };
        match key {
            "up" => self.set_segment((current + 1) % modulus),
            "down" => self.set_segment((current + modulus - 1) % modulus),
            "left" | "right" => {
                self.segment = match self.segment {
                    Segment::Hour => Segment::Minute,
                    Segment::Minute => Segment::Hour,
                };
                self.typed = None;
            }
            digit if digit.len() == 1 && digit.as_bytes()[0].is_ascii_digit() => {
                let d = u32::from(digit.as_bytes()[0] - b'0');
                match self.typed.take() {
                    Some(first) if first * 10 + d < modulus => {
                        self.set_segment(first * 10 + d);
                        self.next_segment();
                    }
                    _ => {
                        self.set_segment(d);
                        // A digit no second one can follow is the value.
                        if d * 10 >= modulus {
                            self.next_segment();
                        } else {
                            self.typed = Some(d);
                        }
                    }
                }
                return true;
            }
            _ => return false,
        }
        self.typed = None;
        true
    }

    fn set_segment(&mut self, n: u32) {
        match self.segment {
            Segment::Hour => self.value.hour = n,
            Segment::Minute => self.value.minute = n,
        }
    }

    /// After an hour is typed, the minute.
    fn next_segment(&mut self) {
        if self.segment == Segment::Hour {
            self.segment = Segment::Minute;
        }
    }
}

actions!(
    date_picker,
    [Left, Right, Up, Down, PageUp, PageDown, Home, End]
);

/// The key context of a [`PickerField`].
pub const PICKER_CONTEXT: &str = "ConduitPicker";

/// The picker's keys, deeper than the prompt's (whose Left and Right move
/// between its buttons). Esc is the prompt's Cancel here too: the app's Esc
/// (Stop Generating, with no context) ranks as deep as the focus, so the
/// prompt's own binding loses to it while the picker has focus.
pub fn bindings() -> Vec<KeyBinding> {
    let c = Some(PICKER_CONTEXT);
    vec![
        KeyBinding::new("escape", crate::shell::app_prompt::Cancel, c),
        KeyBinding::new("left", Left, c),
        KeyBinding::new("right", Right, c),
        KeyBinding::new("up", Up, c),
        KeyBinding::new("down", Down, c),
        KeyBinding::new("pageup", PageUp, c),
        KeyBinding::new("pagedown", PageDown, c),
        KeyBinding::new("home", Home, c),
        KeyBinding::new("end", End, c),
    ]
}

/// The picker in the app's prompt: a month grid, or an hour and a minute.
pub struct PickerField {
    state: PickerState,
    title: String,
    locale: String,
    /// What the prompt's OK answers with.
    chosen: Rc<Cell<WallClock>>,
    pub focus: FocusHandle,
}

impl PickerField {
    fn new(
        state: PickerState,
        title: String,
        locale: String,
        chosen: Rc<Cell<WallClock>>,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            state,
            title,
            locale,
            chosen,
            focus: cx.focus_handle(),
        }
    }

    fn key(&mut self, key: &str, cx: &mut Context<Self>) {
        if self.state.key(key) {
            self.chosen.set(self.state.value);
            cx.notify();
        }
    }

    fn ms(wall: WallClock) -> i64 {
        seconds_of(wall).unwrap_or(0) * 1000
    }

    /// A time of day as an instant on a day every time exists on, so its
    /// label shows the fields' hour even in a clock change's gap (02:30 on
    /// the morning clocks skip it stays 02:30).
    fn time_ms(wall: WallClock) -> i64 {
        Self::ms(WallClock {
            year: 2000,
            month: 1,
            day: 1,
            ..wall
        })
    }

    fn render_month(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let t = cx.conduit().clone();
        let r = &t.roles;
        let value = self.state.value;
        let Some(selected) = self.state.day() else {
            return div().into_any_element();
        };
        let first = selected.with_day(1).unwrap_or(selected);
        // The grid starts on the day the region's weeks do.
        let week_start = dates::first_weekday(&self.locale);
        let lead =
            (first.weekday().num_days_from_monday() + 7 - week_start.num_days_from_monday()) % 7;
        let start = first - chrono::Days::new(u64::from(lead));
        let today = wall_of(chrono::Local::now().timestamp())
            .and_then(|w| NaiveDate::from_ymd_opt(w.year, w.month, w.day));
        let at = |d: NaiveDate| WallClock {
            year: d.year(),
            month: d.month(),
            day: d.day(),
            ..value
        };
        let title = dates::format(Self::ms(at(first)), Form::MonthYear, &self.locale);
        let header = (0..7).map(|i| {
            let d = start + chrono::Days::new(i);
            div()
                .w(px(32.))
                .flex()
                .justify_center()
                .text_size(px(t.metrics.small))
                .text_color(r.text_subtle)
                .child(dates::format(Self::ms(at(d)), Form::Weekday, &self.locale))
        });
        let rows = (0..6).map(|row| {
            div().flex().flex_row().children((0..7).map(|col| {
                let d = start + chrono::Days::new(row * 7 + col);
                let is_selected = d == selected;
                let in_month = d.month() == first.month();
                let label = dates::format(Self::ms(at(d)), Form::LongDate, &self.locale);
                div()
                    .id(("day", (row * 7 + col) as usize))
                    .role(Role::GridCell)
                    .aria_label(SharedString::from(label))
                    .aria_selected(is_selected)
                    .when(is_selected, |d| d.aria_active_descendant())
                    .w(px(32.))
                    .h(px(28.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(6.))
                    .text_size(px(t.metrics.control))
                    .text_color(if is_selected {
                        r.primary_foreground
                    } else if in_month {
                        r.text
                    } else {
                        r.text_faint
                    })
                    .when(is_selected, |d| d.bg(r.primary))
                    .when(!is_selected && Some(d) == today, |d| {
                        d.border_1().border_color(r.primary)
                    })
                    .when(!is_selected, |d| d.hover(|s| s.bg(r.hover)))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.state.pick_day(d);
                        this.chosen.set(this.state.value);
                        cx.notify();
                    }))
                    .child(d.day().to_string())
            }))
        });
        // The months either side, for the pointer (Page Up and Page Down
        // for the keys); each is named by the month it shows.
        let step = |id: &'static str, months: i32, icon: IconName| {
            let target = if months < 0 {
                selected.checked_sub_months(chrono::Months::new(1))
            } else {
                selected.checked_add_months(chrono::Months::new(1))
            };
            let label = target
                .map(|d| dates::format(Self::ms(at(d)), Form::MonthYear, &self.locale))
                .unwrap_or_default();
            div()
                .id(id)
                .role(Role::Button)
                .aria_label(SharedString::from(label))
                .size(px(24.))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(6.))
                .cursor_pointer()
                .hover(|s| s.bg(r.hover))
                .child(conduit_components::assets::icon(icon, 13., r.text_subtle))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.key(if months < 0 { "pageup" } else { "pagedown" }, cx)
                }))
        };
        div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(step("previous-month", -1, IconName::ChevronLeft))
                    .child(
                        div()
                            .text_size(px(t.metrics.control))
                            .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(title.clone()),
                    )
                    .child(step("next-month", 1, IconName::ChevronRight)),
            )
            .child(div().flex().flex_row().children(header))
            .child(
                div()
                    .id("month")
                    .role(Role::Grid)
                    .aria_label(SharedString::from(title))
                    .flex()
                    .flex_col()
                    .children(rows),
            )
            .into_any_element()
    }

    fn render_time(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let t = cx.conduit().clone();
        let r = &t.roles;
        let value = self.state.value;
        let focus = self.focus.clone();
        // A part of the time: a click picks it (the keys then change it),
        // and the arrows above and below step it, for the pointer. The
        // field as a whole is what screen readers and the keys reach.
        let (hour_name, minute_name) = {
            use crate::l10n::ActiveL10n as _;
            let l = cx.l10n();
            (
                SharedString::from(l.desktop_picker_hour()),
                SharedString::from(l.desktop_picker_minute()),
            )
        };
        let view = cx.entity().downgrade();
        let mut segment_for = |segment: Segment, n: u32, name: &'static str| {
            let active = self.state.segment == segment;
            let stepper = |id: &'static str, by: i32, icon: IconName, cx: &mut Context<Self>| {
                div()
                    .id(id)
                    .debug_selector(move || id.into())
                    .w(px(40.))
                    .h(px(16.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(4.))
                    .cursor_pointer()
                    .hover(|s| s.bg(r.hover))
                    .child(conduit_components::assets::icon(icon, 11., r.text_subtle))
                    .map(|d| {
                        let focus = focus.clone();
                        d.on_click(cx.listener(move |this, _, window, cx| {
                            window.focus(&focus, cx);
                            this.state.step(segment, by);
                            this.chosen.set(this.state.value);
                            cx.notify();
                        }))
                    })
            };
            let up = stepper(
                if name == "hour" {
                    "hour-up"
                } else {
                    "minute-up"
                },
                1,
                IconName::ChevronUp,
                cx,
            );
            let down = stepper(
                if name == "hour" {
                    "hour-down"
                } else {
                    "minute-down"
                },
                -1,
                IconName::ChevronDown,
                cx,
            );
            // Each part is its own spin button, the focused field's active
            // descendant while the keys change it, so moving between them
            // is heard.
            let field = div()
                .id(name)
                .debug_selector(move || name.into())
                .role(Role::SpinButton)
                .aria_label(match segment {
                    Segment::Hour => hour_name.clone(),
                    Segment::Minute => minute_name.clone(),
                })
                .aria_numeric_value(f64::from(n))
                .aria_min_numeric_value(0.)
                .aria_max_numeric_value(if segment == Segment::Hour { 23. } else { 59. })
                .when(active, |d| d.aria_active_descendant())
                // A screen reader's own increment and decrement, so the
                // arrows above and below (no role, so not in the tree) are
                // the pointer's alone.
                .on_a11y_action(gpui_kit::AccessibleAction::Increment, {
                    let view = view.clone();
                    move |_, _, cx| step_part(&view, segment, 1, cx)
                })
                .on_a11y_action(gpui_kit::AccessibleAction::Decrement, {
                    let view = view.clone();
                    move |_, _, cx| step_part(&view, segment, -1, cx)
                })
                .w(px(40.))
                .h(px(t.metrics.control_height))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(6.))
                .border_1()
                .border_color(if active { r.primary } else { r.border_strong })
                .bg(if active {
                    with_alpha(r.primary, 0.12)
                } else {
                    r.raised
                })
                .text_color(r.text)
                .text_size(px(t.metrics.control + 1.))
                .cursor_pointer()
                .map(|d| {
                    let focus = focus.clone();
                    d.on_click(cx.listener(move |this, _, window, cx| {
                        window.focus(&focus, cx);
                        this.state.select(segment);
                        cx.notify();
                    }))
                })
                .child(format!("{n:02}"));
            div()
                .flex()
                .flex_col()
                .items_center()
                .gap(px(2.))
                .child(up)
                .child(field)
                .child(down)
        };
        let hour = segment_for(Segment::Hour, value.hour, "hour");
        let minute = segment_for(Segment::Minute, value.minute, "minute");
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.))
            .child(hour)
            .child(div().text_color(r.text).child(":"))
            .child(minute)
            .child(
                div()
                    .pl(px(8.))
                    .text_size(px(t.metrics.control))
                    .text_color(r.text_subtle)
                    .child(dates::format(
                        Self::time_ms(value),
                        Form::Time,
                        &self.locale,
                    )),
            )
            .into_any_element()
    }
}

/// Steps a part of the picker's time (a screen reader's increment or
/// decrement on it).
fn step_part(view: &gpui_kit::WeakEntity<PickerField>, segment: Segment, by: i32, cx: &mut App) {
    let _ = view.update(cx, |this, cx| {
        this.state.step(segment, by);
        this.chosen.set(this.state.value);
        cx.notify();
    });
}

impl Render for PickerField {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let focused = self.focus.is_focused(window);
        let value = self.state.value;
        let body = match self.state.mode {
            PickerMode::Date => self.render_month(cx),
            PickerMode::Time => self.render_time(cx),
        };
        let spoken = match self.state.mode {
            PickerMode::Date => dates::format(Self::ms(value), Form::LongDate, &self.locale),
            PickerMode::Time => dates::format(Self::time_ms(value), Form::Time, &self.locale),
        };
        div()
            .id("picker")
            .key_context(PICKER_CONTEXT)
            .track_focus(&self.focus)
            .role(Role::Group)
            .aria_label(SharedString::from(self.title.clone()))
            .aria_value(SharedString::from(spoken))
            .p(px(6.))
            .rounded(px(8.))
            .border_2()
            .border_color(if focused {
                with_alpha(t.roles.text, 0.55)
            } else {
                with_alpha(t.roles.text, 0.)
            })
            .on_action(cx.listener(|this, _: &Left, _, cx| this.key("left", cx)))
            .on_action(cx.listener(|this, _: &Right, _, cx| this.key("right", cx)))
            .on_action(cx.listener(|this, _: &Up, _, cx| this.key("up", cx)))
            .on_action(cx.listener(|this, _: &Down, _, cx| this.key("down", cx)))
            .on_action(cx.listener(|this, _: &PageUp, _, cx| this.key("pageup", cx)))
            .on_action(cx.listener(|this, _: &PageDown, _, cx| this.key("pagedown", cx)))
            .on_action(cx.listener(|this, _: &Home, _, cx| this.key("home", cx)))
            .on_action(cx.listener(|this, _: &End, _, cx| this.key("end", cx)))
            .on_key_down(cx.listener(|this, e: &KeyDownEvent, _, cx| {
                let k = &e.keystroke;
                if !k.modifiers.modified() && k.key.len() == 1 {
                    this.key(&k.key, cx);
                }
            }))
            .child(body)
    }
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

    fn wall(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> WallClock {
        WallClock {
            year,
            month,
            day,
            hour,
            minute,
        }
    }

    #[test]
    fn the_date_keys_move_the_day() {
        let mut p = PickerState::new(PickerMode::Date, wall(2026, 1, 31, 9, 30));
        let mut step = |key: &str| {
            assert!(p.key(key), "{key}");
            (p.value.year, p.value.month, p.value.day)
        };
        assert_eq!(step("right"), (2026, 2, 1));
        assert_eq!(step("pageup"), (2026, 1, 1));
        assert_eq!(step("end"), (2026, 1, 31));
        // A month on, the day is the last that month has.
        assert_eq!(step("pagedown"), (2026, 2, 28));
        assert_eq!(step("up"), (2026, 2, 21));
        assert_eq!(step("down"), (2026, 2, 28));
        assert_eq!(step("home"), (2026, 2, 1));
        assert_eq!(step("left"), (2026, 1, 31));
        assert_eq!((p.value.hour, p.value.minute), (9, 30), "the time stays");
        assert!(!p.key("x"));
    }

    #[test]
    fn the_time_keys_step_and_type() {
        let mut p = PickerState::new(PickerMode::Time, wall(2026, 11, 12, 9, 30));
        let mut step = |key: &str| {
            assert!(p.key(key), "{key}");
            (p.value.hour, p.value.minute)
        };
        assert_eq!(step("up"), (10, 30));
        assert_eq!(step("down"), (9, 30));
        assert_eq!(step("right"), (9, 30));
        assert_eq!(step("down"), (9, 29));
        assert_eq!(step("left"), (9, 29));
        // Midnight wraps.
        for _ in 0..9 {
            step("down");
        }
        assert_eq!(step("down"), (23, 29));
        // Typed: an hour's two digits, then the minute's.
        assert_eq!(step("1"), (1, 29));
        assert_eq!(step("4"), (14, 29));
        assert_eq!(step("0"), (14, 0));
        assert_eq!(step("5"), (14, 5));
        assert_eq!((p.value.year, p.value.month, p.value.day), (2026, 11, 12));
        // A first digit no second can follow is the hour at once.
        let mut p = PickerState::new(PickerMode::Time, wall(2026, 11, 12, 9, 30));
        assert!(p.key("7"));
        assert_eq!((p.value.hour, p.segment), (7, Segment::Minute));
    }

    /// The app's prompt with the picker's keys, as `menus::bind_keys`
    /// binds them off the Mac.
    fn app_pickers(cx: &mut gpui_kit::TestAppContext) {
        cx.update(crate::views::test_globals);
        cx.update(|cx| {
            crate::shell::app_prompt::install(cx);
            cx.bind_keys(crate::shell::app_prompt::bindings());
            cx.bind_keys(bindings());
        });
    }

    struct Blank;

    impl Render for Blank {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    fn ask(
        vcx: &mut gpui_kit::VisualTestContext,
        mode: PickerMode,
        value: WallClock,
    ) -> Rc<Cell<Option<Option<WallClock>>>> {
        let answer = Rc::new(Cell::new(None));
        let seen = answer.clone();
        vcx.update(|window, cx| {
            let spec = PickerSpec {
                title: "Starts".into(),
                mode,
                value,
                ok: "OK".into(),
                cancel: "Cancel".into(),
            };
            let task = pick(window, spec, cx);
            cx.spawn(async move |_| seen.set(Some(task.await))).detach();
        });
        vcx.run_until_parked();
        answer
    }

    /// While the picker is up, the app's chords act on nothing behind it:
    /// Ctrl+Shift+Enter allows no tool request the picker covers, with the
    /// picker's own field focused (off the Mac).
    #[gpui_kit::test]
    fn a_picker_keeps_the_apps_chords_from_what_it_covers(cx: &mut gpui_kit::TestAppContext) {
        app_pickers(cx);
        let allowed = Rc::new(Cell::new(0));
        let seen = allowed.clone();
        cx.update(|cx| {
            use crate::keymap::{KeyOs, Keymap, app_chords};
            // As `menus::bind_keys` binds them off the Mac.
            cx.bind_keys([gpui_kit::KeyBinding::new(
                "ctrl-shift-enter",
                crate::actions::AllowRequest,
                None,
            )]);
            cx.on_action(move |_: &crate::actions::AllowRequest, _| seen.set(seen.get() + 1));
            let chords = app_chords(&Keymap::default(), None, KeyOs::Linux);
            let guard = crate::shell::app_prompt::guard_bindings(&chords, KeyOs::Linux, cx);
            cx.bind_keys(guard);
        });
        let (_, vcx) = cx.add_window_view(|_, _| Blank);
        let answer = ask(vcx, PickerMode::Date, wall(2026, 1, 31, 9, 30));
        vcx.simulate_keystrokes("ctrl-shift-enter");
        vcx.run_until_parked();
        assert_eq!(allowed.get(), 0, "allowed the request behind the picker");
        // The picker still answers.
        vcx.simulate_keystrokes("right enter");
        vcx.run_until_parked();
        assert_eq!(answer.get(), Some(Some(wall(2026, 2, 1, 9, 30))));
    }

    /// Esc cancels with the hour or the minute focused, as from the
    /// buttons: the app's Esc (Stop Generating, bound with no context and
    /// answered app-wide) ranks as deep as the picker's focus, deeper than
    /// the prompt's own Esc.
    #[gpui_kit::test]
    fn esc_cancels_with_the_hour_or_minute_focused(cx: &mut gpui_kit::TestAppContext) {
        cx.update(crate::views::test_globals);
        let stops = Rc::new(Cell::new(0));
        let seen = stops.clone();
        cx.update(|cx| {
            // As `menus::bind_keys` binds them: the app's first, then the
            // prompt's and the picker's.
            cx.bind_keys([gpui_kit::KeyBinding::new(
                "escape",
                crate::actions::StopGenerating,
                None,
            )]);
            cx.on_action(move |_: &crate::actions::StopGenerating, _| seen.set(seen.get() + 1));
            crate::shell::app_prompt::install(cx);
            cx.bind_keys(crate::shell::app_prompt::bindings());
            cx.bind_keys(bindings());
        });
        let (_, vcx) = cx.add_window_view(|_, _| Blank);
        for keys in ["escape", "right escape"] {
            let answer = ask(vcx, PickerMode::Time, wall(2026, 1, 31, 9, 30));
            vcx.simulate_keystrokes(keys);
            vcx.run_until_parked();
            assert_eq!(answer.get(), Some(None), "{keys}: the picker stayed up");
            assert!(!vcx.update(|window, _| window.has_active_prompt()));
        }
        assert_eq!(
            stops.get(),
            0,
            "Esc reached Stop Generating behind the picker"
        );
    }

    /// Without the app's prompt (the Mac, in a window with no NSWindow)
    /// there is no picker to show: it answers as cancelled, showing nothing.
    #[gpui_kit::test]
    fn without_the_apps_prompt_no_picker_is_shown(cx: &mut gpui_kit::TestAppContext) {
        cx.update(crate::views::test_globals);
        let (_, vcx) = cx.add_window_view(|_, _| Blank);
        let answer = ask(vcx, PickerMode::Date, wall(2026, 1, 31, 9, 30));
        assert_eq!(answer.get(), Some(None));
        assert!(!vcx.has_pending_prompt());
    }

    /// The time can be set with the pointer: a click picks the hour or the
    /// minute (the keys then change it) and their arrows step them.
    #[gpui_kit::test]
    fn a_time_is_picked_with_the_pointer(cx: &mut gpui_kit::TestAppContext) {
        app_pickers(cx);
        let (_, vcx) = cx.add_window_view(|_, _| Blank);
        let answer = ask(vcx, PickerMode::Time, wall(2026, 1, 31, 9, 30));
        let click = |vcx: &mut gpui_kit::VisualTestContext, selector: &'static str| {
            let bounds = vcx
                .debug_bounds(selector)
                .unwrap_or_else(|| panic!("{selector} not drawn"));
            vcx.simulate_click(bounds.center(), gpui_kit::Modifiers::none());
            vcx.run_until_parked();
        };
        click(vcx, "minute");
        vcx.simulate_keystrokes("up");
        vcx.run_until_parked();
        click(vcx, "hour-up");
        click(vcx, "hour-up");
        click(vcx, "minute-down");
        vcx.simulate_keystrokes("enter");
        vcx.run_until_parked();
        assert_eq!(answer.get(), Some(Some(wall(2026, 1, 31, 11, 30))));
    }

    /// Off the Mac the picker is the app's prompt: it has the keyboard as
    /// it opens, its keys move the value, Return chooses it, Esc cancels,
    /// and Tab goes on to the buttons and back.
    #[gpui_kit::test]
    fn a_day_and_a_time_are_picked_from_the_keyboard(cx: &mut gpui_kit::TestAppContext) {
        app_pickers(cx);
        let (_, vcx) = cx.add_window_view(|_, _| Blank);
        let start = wall(2026, 1, 31, 9, 30);
        for (mode, keys, chosen) in [
            (
                PickerMode::Date,
                "right pagedown enter",
                Some(wall(2026, 3, 1, 9, 30)),
            ),
            (PickerMode::Date, "right escape", None),
            (
                PickerMode::Time,
                "up right down enter",
                Some(wall(2026, 1, 31, 10, 29)),
            ),
            (
                PickerMode::Time,
                "1 4 0 5 enter",
                Some(wall(2026, 1, 31, 14, 5)),
            ),
            // Tab goes on to the buttons, Shift-Tab back round to the last:
            // OK stands first on Windows and the Mac, last on Linux
            // (GNOME's order). Space presses the one with focus.
            (
                PickerMode::Date,
                "left tab space",
                (!cfg!(target_os = "linux")).then_some(wall(2026, 1, 30, 9, 30)),
            ),
            (
                PickerMode::Date,
                "left shift-tab space",
                cfg!(target_os = "linux").then_some(wall(2026, 1, 30, 9, 30)),
            ),
        ] {
            let answer = ask(vcx, mode, start);
            assert!(
                vcx.update(|window, _| window.has_active_prompt()),
                "{keys}: not drawn"
            );
            vcx.simulate_keystrokes(keys);
            vcx.run_until_parked();
            assert_eq!(answer.get(), Some(chosen), "{mode:?} {keys}");
            assert!(!vcx.update(|window, _| window.has_active_prompt()));
        }
    }

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
