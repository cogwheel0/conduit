//! New Calendar, a sheet on the main window: a private calendar of the
//! account's own, with a name and one of the phone's colours.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::focus::{RadioGroupExt as _, radio_option_id};
use conduit_components::views::kit::Button;
use conduit_protocol::{CalendarCreate, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, Subscription,
    Toggled, WeakEntity, Window, div, px,
};

use super::{color_dot, format};
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 420.;

pub fn open(stores: Stores, window: &mut Window, cx: &mut App) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        NewCalendarSheet::new(stores, w, cx)
    });
}

pub struct NewCalendarSheet {
    stores: Stores,
    name: Entity<InputState>,
    /// One of [`format::COLORS`].
    pub color: &'static str,
    pub saving: bool,
    /// Create was pressed with no name.
    pub name_missing: bool,
    pub failure: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl NewCalendarSheet {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.calendar_new_calendar_hint(), false, window, cx);
        let mut subscriptions = vec![cx.subscribe_in(
            &name,
            window,
            |this, _, e: &InputEvent, window, cx| match e {
                InputEvent::Change => {
                    this.failure = None;
                    cx.notify();
                }
                InputEvent::PressEnter { .. } => this.create(window, cx),
                _ => {}
            },
        )];
        // Made for the account it opened under, never the next one's.
        subscriptions.push(sheet::close_with_account(&stores, cx));
        name.update(cx, |s, cx| s.focus(window, cx));
        Self {
            stores,
            name,
            color: format::COLORS[0].0,
            saving: false,
            name_missing: false,
            failure: None,
            _subscriptions: subscriptions,
        }
    }

    /// Types the name, as the user would.
    pub fn set_name(&mut self, name: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = name.to_string();
        self.name.update(cx, |s, cx| s.set_value(value, window, cx));
        cx.notify();
    }

    pub fn create(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        let name = forms::text(&self.name, cx);
        if name.trim().is_empty() {
            self.name_missing = true;
            forms::focus_invalid(&self.name, window, cx);
            cx.notify();
            return;
        }
        self.saving = true;
        self.failure = None;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::CalendarCreateCalendar>(&CalendarCreate {
            name: name.trim().to_string(),
            color: Some(self.color.to_string()),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.saving = false;
                match result {
                    Ok(_) => {
                        s.stores.calendar.update(cx, |c, cx| c.refresh(cx));
                        sheet::dismiss(cx);
                    }
                    Err(e) => {
                        log::warn!("calendar.createCalendar: {e}");
                        let l = cx.l10n().clone();
                        s.failure = Some(format::failure_text(&e, l.calendar_create_failed(), &l));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn set_color(&mut self, color: &'static str, cx: &mut Context<Self>) {
        self.color = color;
        cx.notify();
    }
}

impl SheetBody for NewCalendarSheet {
    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel_view = view.clone();
        Some(
            div()
                .w_full()
                .flex()
                .justify_end()
                .gap(px(8.))
                .child(
                    Button::new("calendar-new-cancel", l.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = cancel_view.update(cx, |s, cx| s.cancel(window, cx));
                        },
                    )),
                )
                .child(
                    Button::new("calendar-new-create", l.calendar_create_calendar())
                        .primary()
                        .disabled(self.saving)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = view.update(cx, |s, cx| s.create(window, cx));
                        })),
                )
                .into_any_element(),
        )
    }

    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if !self.saving {
            sheet::dismiss(cx);
        }
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().calendar_new_calendar().into()
    }
}

impl Render for NewCalendarSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let selected = format::COLORS
            .iter()
            .position(|(hex, _)| *hex == self.color)
            .unwrap_or(0);
        let swatches = format::COLORS.iter().enumerate().map(|(i, (hex, name))| {
            let on = i == selected;
            let color = format::parse_color(Some(hex)).unwrap_or(r.text_faint);
            let label = l.calendar_color_name(name);
            let view = view.clone();
            div()
                .id(radio_option_id("calendar-new-color", i, on))
                .role(Role::RadioButton)
                .aria_label(SharedString::from(label.clone()))
                .aria_toggled(if on { Toggled::True } else { Toggled::False })
                .size(px(26.))
                .flex()
                .flex_none()
                .items_center()
                .justify_center()
                .rounded_full()
                .cursor_pointer()
                .when(on, |d| d.border_2().border_color(r.text))
                .child(color_dot(color, 18.).when(on, |d| {
                    d.flex().items_center().justify_center().child(icon(
                        IconName::Check,
                        11.,
                        gpui_kit::white(),
                    ))
                }))
                .tip(label, None)
                .radio_option_outline(on, 13., cx)
                .on_click(move |_, _, cx| {
                    let _ = view.update(cx, |s, cx| s.set_color(format::COLORS[i].0, cx));
                })
        });
        let pick_view = view.clone();
        let group = div()
            .id("calendar-new-colors")
            .role(Role::RadioGroup)
            .aria_label(SharedString::from(l.desktop_calendar_color()))
            .flex()
            .gap(px(10.))
            .children(swatches)
            .radio_group(
                selected,
                format::COLORS.len(),
                Some(Rc::new(move |i, _, cx| {
                    let _ = pick_view.update(cx, |s, cx| s.set_color(format::COLORS[i].0, cx));
                })),
                cx,
            );
        let missing = self.name_missing && forms::text(&self.name, cx).trim().is_empty();
        let mut body: Vec<AnyElement> = vec![
            div()
                .id("sheet-title")
                .role(Role::Heading)
                .text_size(px(t.metrics.body + 2.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(SharedString::from(l.calendar_new_calendar()))
                .into_any_element(),
            forms::form_group(
                vec![
                    forms::field(
                        l.desktop_calendar_name(),
                        &self.name,
                        None,
                        missing.then(|| l.calendar_name_required().into()),
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::form_row(l.desktop_calendar_color(), group, cx).into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        ];
        if let Some(failure) = &self.failure {
            body.push(
                forms::form_error("calendar-new-error", failure.clone(), cx).into_any_element(),
            );
        }
        div()
            .id("calendar-new")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .children(body)
    }
}
