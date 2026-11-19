//! Controls the Settings panes share beyond Kit's: a native pop-up button
//! (an `NSMenu` of choices with the current one checked), a checkbox, a
//! value in the secondary colour, and a pane's lead paragraph.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::{ControlExt as _, Ring, pressed_fill};
use conduit_components::views::kit::ClickHandler;
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{App, Div, ElementId, SharedString, Stateful, Toggled, Window, div, px, relative};

use crate::actions::SettingsChoice;

/// One item of a [`popup`]: what it stores and what it says.
#[derive(Clone, Debug, PartialEq)]
pub struct Choice {
    pub value: String,
    pub label: String,
    /// A separator goes above it.
    pub separated: bool,
}

impl Choice {
    pub fn new(value: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            label: label.into(),
            separated: false,
        }
    }

    pub fn separated(mut self) -> Self {
        self.separated = true;
        self
    }
}

/// A macOS pop-up button: the chosen item's name and ⌃⌄; a click opens a
/// native menu of `choices` with `selected` checked, and picking one sends
/// [`SettingsChoice`] `{menu, value}` up from the window's focus.
pub fn popup(
    menu: &str,
    label: &str,
    choices: Vec<Choice>,
    selected: &str,
    disabled: bool,
    window: &mut Window,
    cx: &mut App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let shown = choices
        .iter()
        .find(|c| c.value == selected)
        .map(|c| c.label.clone())
        .unwrap_or_else(|| selected.to_string());
    let menu_id = menu.to_string();
    let chosen = selected.to_string();
    let el = div()
        .id(ElementId::Name(format!("popup-{menu}").into()))
        .role(gpui_kit::Role::ComboBox)
        .aria_label(SharedString::from(format!("{label}: {shown}")))
        .h(px(t.metrics.control_height - 2.))
        .max_w(px(280.))
        .pl(px(10.))
        .pr(px(6.))
        .flex()
        .flex_none()
        .items_center()
        .gap(px(6.))
        .rounded(t.control_radius())
        .border_1()
        .border_color(r.border_strong)
        .bg(conduit_components::views::kit::field_fill(&t))
        .shadow(conduit_components::views::kit::control_shadow(&t))
        .text_size(px(t.metrics.control))
        .text_color(r.text)
        .when(disabled, |d| d.opacity(0.45))
        .child(div().min_w_0().truncate().child(SharedString::from(shown)))
        .child(icon(IconName::ChevronsUpDown, 13., r.text_subtle));
    if disabled {
        return el;
    }
    el.cursor_pointer()
        .hover(|s| s.bg(conduit_components::views::kit::field_fill_hover(&t)))
        .on_click(move |_, window, cx| {
            let mut native = NativeMenu::new();
            for choice in &choices {
                if choice.separated {
                    native = native.separator();
                }
                native = native.menu_with_check(
                    choice.label.clone(),
                    choice.value == chosen,
                    Box::new(SettingsChoice {
                        menu: menu_id.clone(),
                        value: choice.value.clone(),
                    }),
                );
            }
            native.show(window.mouse_position(), window, cx);
        })
        .keyboard_control(Ring::Outset(f32::from(t.control_radius())), window, cx)
}

/// A checkbox (AppKit's): a rounded square, filled and checked when on.
pub fn checkbox(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    on: bool,
    on_click: ClickHandler,
    window: &mut Window,
    cx: &mut App,
) -> Stateful<Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let fill = if on {
        r.checked
    } else {
        conduit_components::views::kit::field_fill(&t)
    };
    div()
        .id(id)
        .role(gpui_kit::Role::CheckBox)
        .aria_label(label.into())
        .aria_toggled(if on { Toggled::True } else { Toggled::False })
        .size(px(16.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(4.))
        .bg(fill)
        .when(!on, |d| d.border_1().border_color(r.control_edge))
        .cursor_pointer()
        .active(|s| s.bg(pressed_fill(fill, &t)))
        .when(on, |d| {
            d.child(icon(IconName::Check, 11., r.checked_foreground))
        })
        .on_click(move |e, w, cx| on_click(e, w, cx))
        .keyboard_control(Ring::Outset(4.), window, cx)
}

/// A setting's value, in the secondary colour (an email, a version).
pub fn value(text: impl Into<SharedString>, cx: &App) -> Div {
    let t = cx.conduit();
    div()
        .max_w(px(360.))
        .truncate()
        .text_size(px(t.metrics.control))
        .text_color(t.roles.text_subtle)
        .child(text.into())
}

/// A paragraph above a pane's groups, in the footer's voice.
pub fn lead(text: impl Into<SharedString>, cx: &App) -> Div {
    let t = cx.conduit();
    div()
        .px(px(4.))
        .text_size(px(t.metrics.small + 0.5))
        .line_height(relative(1.4))
        .text_color(t.roles.text_subtle)
        .child(text.into())
}

/// A row of push buttons at a group's trailing edge.
pub fn buttons(children: Vec<gpui_kit::AnyElement>) -> Div {
    div()
        .w_full()
        .flex()
        .justify_end()
        .gap(px(8.))
        .children(children)
}

/// A handler that does nothing (a control drawn disabled).
pub fn noop() -> ClickHandler {
    Rc::new(|_, _, _| {})
}
