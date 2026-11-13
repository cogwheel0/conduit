//! A shortcut field, as System Settings › Keyboard Shortcuts draws one: the
//! chord in a small field; a click (or Space with it focused) starts
//! listening, the field showing "Type Shortcut" in its ring until keys are
//! pressed or Esc cancels.

use gpui_kit::prelude::*;
use gpui_kit::{App, ElementId, FontWeight, Role, SharedString, Window, div, px};

use crate::theme::{ActiveConduitTheme, with_alpha};
use crate::views::focus::{ControlExt as _, Ring, pressed_fill, ring_overlay};
use crate::views::kit::{ClickHandler, on_click_or_noop};

/// The field's width: room for a four-modifier chord.
pub const SHORTCUT_FIELD_WIDTH: f32 = 104.;

/// How much of an editable keycap's fill and edge a fixed one keeps.
pub const FIXED_ALPHA: f32 = 0.5;

#[derive(IntoElement)]
pub struct ShortcutField {
    id: ElementId,
    keys: SharedString,
    label: SharedString,
    placeholder: SharedString,
    recording: bool,
    disabled: bool,
    fixed: bool,
    on_click: Option<ClickHandler>,
}

impl ShortcutField {
    /// `keys` as menus write them (`⌃⌘S`); `label` is what VoiceOver reads
    /// ("Change the shortcut for New Chat"); `placeholder` shows while it
    /// listens.
    pub fn new(
        id: impl Into<ElementId>,
        keys: impl Into<SharedString>,
        label: impl Into<SharedString>,
        placeholder: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            keys: keys.into(),
            label: label.into(),
            placeholder: placeholder.into(),
            recording: false,
            disabled: false,
            fixed: false,
            on_click: None,
        }
    }
    pub fn recording(mut self, recording: bool) -> Self {
        self.recording = recording;
        self
    }
    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
    /// A chord that can't be changed (a menu's standard one): the same
    /// keycap, dimmed, with nothing to click, so every shortcut in the list
    /// reads as one kind of thing and the fixed ones as set.
    pub fn fixed(mut self, fixed: bool) -> Self {
        self.fixed = fixed;
        self
    }
    pub fn on_click(mut self, handler: ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
}

impl RenderOnce for ShortcutField {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let radius = f32::from(t.control_radius());
        // A step above the group it sits in (the dark ramp's step 2).
        let bg = crate::views::kit::field_fill(&t);
        if self.fixed {
            return div()
                .id(self.id)
                .role(Role::Label)
                .aria_label(self.label)
                .aria_description(self.keys.clone())
                .w(px(SHORTCUT_FIELD_WIDTH))
                .h(px(t.metrics.control_height))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(radius))
                .bg(with_alpha(bg, FIXED_ALPHA))
                .border_1()
                .border_color(with_alpha(r.border_strong, FIXED_ALPHA))
                .text_size(px(t.metrics.control))
                .font_weight(FontWeight::MEDIUM)
                .text_color(r.text_subtle)
                .child(self.keys);
        }
        let el = div()
            .id(self.id)
            .role(Role::Button)
            .aria_label(self.label)
            .aria_description(if self.recording {
                self.placeholder.clone()
            } else {
                self.keys.clone()
            })
            .aria_toggled(if self.recording {
                gpui_kit::Toggled::True
            } else {
                gpui_kit::Toggled::False
            })
            .w(px(SHORTCUT_FIELD_WIDTH))
            .h(px(t.metrics.control_height))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(radius))
            .bg(bg)
            .border_1()
            .border_color(if self.recording {
                with_alpha(r.text, 0.55)
            } else {
                r.border_strong
            })
            .relative()
            // Listening: the field wears the ring, as AppKit's does.
            .when(self.recording, |d| {
                d.child(ring_overlay(Ring::Outset(radius), &t))
            })
            .text_size(px(t.metrics.control))
            .when(self.recording, |d| {
                d.text_color(r.text_subtle).child(self.placeholder)
            })
            .when(!self.recording, |d| {
                d.font_weight(FontWeight::MEDIUM)
                    .text_color(r.text)
                    .child(self.keys)
            })
            .when(self.disabled, |d| d.opacity(0.45));
        if self.disabled {
            return el;
        }
        let hover = crate::theme::mix(bg, r.text, if t.dark { 0.06 } else { 0.03 });
        el.cursor_pointer()
            .hover(|s| s.bg(hover))
            .active(|s| s.bg(pressed_fill(hover, &t)))
            .on_click(on_click_or_noop(self.on_click))
            .keyboard_control(Ring::Outset(radius), window, cx)
    }
}
