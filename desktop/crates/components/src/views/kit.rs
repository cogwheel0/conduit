//! Primitives drawn the macOS way on Conduit's palette: buttons, icon
//! buttons, switches, segmented controls, radios, avatars, badges, field
//! frames, section headers.
//!
//! Each interactive primitive carries an AccessKit role and a label, and
//! always registers a click handler so VoiceOver's press action reaches it.

use std::rc::Rc;

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, BoxShadow, ClickEvent, Div, ElementId, FontWeight, Hsla, Role, SharedString,
    Stateful, Toggled, Window, div, point, px, relative,
};

use crate::assets::{IconName, icon};
use crate::theme::{ActiveConduitTheme, ConduitTheme, with_alpha};
use crate::views::focus::{
    ControlExt as _, Ring, control_focus_handle, full_keyboard_access, pressed_fill, radio_keys,
    ring_overlay, ring_shadow,
};

/// A click callback a view model can hand to a view.
pub type ClickHandler = Rc<dyn Fn(&ClickEvent, &mut Window, &mut App) + 'static>;

/// Wraps an optional handler into one GPUI accepts (a no-op when absent).
pub fn on_click_or_noop(
    handler: Option<ClickHandler>,
) -> impl Fn(&ClickEvent, &mut Window, &mut App) + 'static {
    move |ev, window, cx| {
        if let Some(h) = &handler {
            h(ev, window, cx)
        }
    }
}

/// A soft drop shadow for raised controls.
pub fn control_shadow(t: &ConduitTheme) -> Vec<BoxShadow> {
    vec![BoxShadow {
        color: with_alpha(gpui_kit::black(), if t.dark { 0.35 } else { 0.08 }),
        offset: point(px(0.), px(0.5)),
        blur_radius: px(1.5),
        spread_radius: px(0.),
        inset: false,
    }]
}

/// The shadow under menus, the palette and floating cards.
pub fn overlay_shadow(t: &ConduitTheme) -> Vec<BoxShadow> {
    vec![
        BoxShadow {
            color: with_alpha(gpui_kit::black(), if t.dark { 0.5 } else { 0.12 }),
            offset: point(px(0.), px(12.)),
            blur_radius: px(32.),
            spread_radius: px(0.),
            inset: false,
        },
        BoxShadow {
            color: with_alpha(gpui_kit::black(), if t.dark { 0.4 } else { 0.08 }),
            offset: point(px(0.), px(1.)),
            blur_radius: px(3.),
            spread_radius: px(0.),
            inset: false,
        },
    ]
}

/// The one fill of what floats on the chat column (the composer, a docked
/// card, toasts, the toolbar's capsules, status pills, file chips): the
/// column itself in light, and in dark the raised tone code blocks and
/// tables share (#181818 on the #000 column), so the main window has one
/// raised tone, not several.
pub fn raised_fill(t: &ConduitTheme) -> Hsla {
    if t.dark {
        t.roles.raised
    } else {
        t.surfaces.panel
    }
}

/// A chip or box drawn on a raised surface (an attachment in the
/// composer): the column's tone in light, one step above the raised tone
/// in dark, so it never reads as a hole in it.
pub fn on_raised_fill(t: &ConduitTheme) -> Hsla {
    if t.dark {
        t.roles.raised_hover
    } else {
        t.surfaces.panel
    }
}

/// The small shadow under a status pill or toast-like capsule that sits on
/// the content (0/2/8, as the toolbar's capsules): with its hairline it
/// lifts the pill without the halo of [`overlay_shadow`].
pub fn pill_shadow(t: &ConduitTheme) -> Vec<BoxShadow> {
    vec![BoxShadow {
        color: with_alpha(gpui_kit::black(), if t.dark { 0.35 } else { 0.08 }),
        offset: point(px(0.), px(2.)),
        blur_radius: px(8.),
        spread_radius: px(0.),
        inset: false,
    }]
}

/// A focus ring drawn outside an element (macOS draws ~3 pt): the label
/// colour at 55%, as every control's ring ([`crate::views::focus`]).
pub fn focus_ring(t: &ConduitTheme) -> Vec<BoxShadow> {
    ring_shadow(t)
}

/// Text in the UI font at `size` with `color`.
pub fn text(content: impl Into<SharedString>, size: f32, color: Hsla) -> Div {
    div()
        .text_size(px(size))
        .text_color(color)
        .child(content.into())
}

/// A heading VoiceOver can find (`Role::Heading`).
pub fn heading(
    id: impl Into<ElementId>,
    content: impl Into<SharedString>,
    level: usize,
    size: f32,
    weight: FontWeight,
    color: Hsla,
) -> Stateful<Div> {
    let content = content.into();
    div()
        .id(id)
        .role(Role::Heading)
        .aria_level(level)
        .aria_label(content.clone())
        .text_size(px(size))
        .font_weight(weight)
        .text_color(color)
        .child(content)
}

/// Section header in a list or sidebar: 11 pt semibold, secondary colour.
pub fn section_label(content: impl Into<SharedString>, cx: &App) -> Div {
    let t = cx.conduit();
    div()
        .text_size(px(t.metrics.caption))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(t.roles.text_subtle)
        .child(content.into())
}

/// A keyboard shortcut written the way macOS menus write it (`⌘K`).
pub fn shortcut(keys: impl Into<SharedString>, color: Hsla, size: f32) -> Div {
    div()
        .flex_none()
        .text_size(px(size))
        .text_color(color)
        .child(keys.into())
}

/// What the Esc key's cap says in a footer hint: the word printed on the
/// key, as Raycast writes it (the ⎋ glyph reads as refresh or undo at
/// caption size).
pub const ESC_KEYCAP: &str = "esc";

/// A footer hint's key cap ("↩", "↑↓", "esc"): the keys in a hairline
/// box, as Spotlight's and Raycast's footers teach theirs.
pub fn keycap(keys: impl Into<SharedString>, t: &ConduitTheme) -> Div {
    let r = t.roles;
    div()
        .flex_none()
        .px(px(5.))
        .h(px(18.))
        .flex()
        .items_center()
        .rounded(px(4.))
        .border_1()
        .border_color(r.border)
        .text_size(px(t.metrics.caption))
        .text_color(r.text_subtle)
        .child(keys.into())
}

/// A 1-pt hairline.
pub fn divider(color: Hsla) -> Div {
    div().h(px(1.)).w_full().flex_none().bg(color)
}

/// Button styles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ButtonKind {
    /// The strong colour (black on Conduit light): one per view.
    Primary,
    /// A raised push button.
    Secondary,
    /// No chrome until hovered.
    Ghost,
    /// A destructive action, red text on a red tint.
    Danger,
}

/// A labelled push button.
#[derive(IntoElement)]
pub struct Button {
    id: ElementId,
    label: SharedString,
    kind: ButtonKind,
    leading: Option<IconName>,
    trailing_shortcut: Option<SharedString>,
    full_width: bool,
    large: bool,
    disabled: bool,
    on_click: Option<ClickHandler>,
}

impl Button {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            kind: ButtonKind::Secondary,
            leading: None,
            trailing_shortcut: None,
            full_width: false,
            large: false,
            disabled: false,
            on_click: None,
        }
    }
    pub fn kind(mut self, kind: ButtonKind) -> Self {
        self.kind = kind;
        self
    }
    pub fn primary(self) -> Self {
        self.kind(ButtonKind::Primary)
    }
    pub fn ghost(self) -> Self {
        self.kind(ButtonKind::Ghost)
    }
    pub fn danger(self) -> Self {
        self.kind(ButtonKind::Danger)
    }
    pub fn icon(mut self, icon: IconName) -> Self {
        self.leading = Some(icon);
        self
    }
    /// A shortcut shown after the label, e.g. `⌥⌘↩`.
    pub fn shortcut(mut self, keys: impl Into<SharedString>) -> Self {
        self.trailing_shortcut = Some(keys.into());
        self
    }
    pub fn full_width(mut self) -> Self {
        self.full_width = true;
        self
    }
    /// The taller onboarding size.
    pub fn large(mut self) -> Self {
        self.large = true;
        self
    }
    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
    pub fn on_click(mut self, handler: ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
}

impl RenderOnce for Button {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = &t.roles;
        let (bg, fg, border, hover_bg) = match self.kind {
            ButtonKind::Primary => (
                r.primary,
                r.primary_foreground,
                None,
                crate::theme::mix(r.primary, r.text, if t.dark { 0.12 } else { 0.18 }),
            ),
            // On the dark ramp a push button is a step above the group or
            // card it sits on.
            ButtonKind::Secondary => (
                field_fill(&t),
                r.text,
                Some(r.border_strong),
                field_fill_hover(&t),
            ),
            ButtonKind::Ghost => (with_alpha(r.text, 0.), r.text, None, r.hover),
            ButtonKind::Danger => (
                with_alpha(r.danger, 0.10),
                r.danger,
                None,
                with_alpha(r.danger, 0.16),
            ),
        };
        let height = if self.large {
            t.metrics.control_height + 8.
        } else {
            t.metrics.control_height
        };
        let size = if self.large {
            t.metrics.control + 1.
        } else {
            t.metrics.control
        };
        let shortcut_color = with_alpha(fg, 0.6);
        let pressed_bg = match self.kind {
            ButtonKind::Primary => {
                crate::theme::mix(r.primary, r.text, if t.dark { 0.24 } else { 0.32 })
            }
            _ => pressed_fill(hover_bg, &t),
        };
        let ring = if self.large {
            height / 2.
        } else {
            f32::from(t.control_radius())
        };
        let disabled = self.disabled;
        let el = div()
            .id(self.id)
            .role(Role::Button)
            .aria_label(self.label.clone())
            .when_some(self.trailing_shortcut.clone(), |d, k| {
                d.aria_keyshortcuts(k)
            })
            .h(px(height))
            .px(px(if self.large { 16. } else { 12. }))
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .gap(px(6.))
            // A large button is the phone's capsule call to action.
            .when(self.large, |d| d.rounded_full())
            .when(!self.large, |d| d.rounded(t.control_radius()))
            .bg(bg)
            .when_some(border, |d, b| d.border_1().border_color(b))
            .when(self.kind == ButtonKind::Secondary, |d| {
                d.shadow(control_shadow(&t))
            })
            .when(self.full_width, |d| d.w_full())
            .when(self.disabled, |d| d.opacity(0.45))
            .when(!self.disabled, |d| {
                d.cursor_pointer()
                    .hover(|s| s.bg(hover_bg))
                    .active(|s| s.bg(pressed_bg))
            })
            .text_size(px(size))
            .font_weight(if self.kind == ButtonKind::Primary {
                FontWeight::SEMIBOLD
            } else {
                FontWeight::MEDIUM
            })
            .text_color(fg)
            .when_some(self.leading, |d, i| d.child(icon(i, 15., fg)))
            .child(self.label)
            .when_some(self.trailing_shortcut, |d, k| {
                d.child(shortcut(k, shortcut_color, size - 1.))
            });
        // A disabled button runs nothing, whether clicked or pressed by
        // VoiceOver, and is no Tab stop.
        if disabled {
            el
        } else {
            el.on_click(on_click_or_noop(self.on_click))
                .keyboard_control(Ring::Outset(ring), window, cx)
        }
    }
}

/// A square, icon-only toolbar button. Its label is the tooltip and what
/// VoiceOver reads.
#[derive(IntoElement)]
pub struct IconButton {
    id: ElementId,
    icon: IconName,
    label: SharedString,
    size: f32,
    icon_size: f32,
    active: bool,
    color: Option<Hsla>,
    filled: Option<(Hsla, Hsla)>,
    round: bool,
    shortcut: Option<SharedString>,
    tooltip: Option<SharedString>,
    disabled: bool,
    on_click: Option<ClickHandler>,
}

impl IconButton {
    pub fn new(id: impl Into<ElementId>, icon: IconName, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            icon,
            label: label.into(),
            size: 28.,
            icon_size: 16.,
            active: false,
            color: None,
            filled: None,
            round: false,
            shortcut: None,
            tooltip: None,
            disabled: false,
            on_click: None,
        }
    }
    /// The chord that does the same, shown in the tooltip (`⌘N`).
    pub fn shortcut(mut self, keys: Option<SharedString>) -> Self {
        self.shortcut = keys.filter(|k| !k.is_empty());
        self
    }
    /// A shorter tooltip than the label VoiceOver reads ("Pin" for
    /// "Pin “Groceries”").
    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }
    /// Drawn dimmed (a filled one in the colours it is given); it neither
    /// clicks nor takes focus, so Tab passes it by.
    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
    pub fn size(mut self, size: f32, icon_size: f32) -> Self {
        self.size = size;
        self.icon_size = icon_size;
        self
    }
    /// Pressed/toggled on.
    pub fn active(mut self, active: bool) -> Self {
        self.active = active;
        self
    }
    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }
    /// A filled circle (send/stop): background and icon colour.
    pub fn filled(mut self, bg: Hsla, fg: Hsla) -> Self {
        self.filled = Some((bg, fg));
        self
    }
    /// Hover, pressed and toggled fills (and the focus ring) are circles,
    /// for a button in a round toolbar capsule.
    pub fn round(mut self) -> Self {
        self.round = true;
        self
    }
    pub fn on_click(mut self, handler: ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
}

impl RenderOnce for IconButton {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let radius = t.control_radius();
        let (bg, fg) = match self.filled {
            Some((bg, fg)) => (bg, fg),
            None if self.active => (r.selected, self.color.unwrap_or(r.text)),
            None => (with_alpha(r.text, 0.), self.color.unwrap_or(r.text_subtle)),
        };
        let filled = self.filled.is_some();
        // Ghost: the row hover, then darker while pressed. Filled (send,
        // stop): the disc eases toward the page, further while pressed.
        let (hover_bg, pressed_bg) = if filled {
            (
                crate::theme::mix(bg, r.content, 0.12),
                crate::theme::mix(bg, r.content, 0.26),
            )
        } else if self.active {
            (pressed_fill(bg, &t), pressed_fill(pressed_fill(bg, &t), &t))
        } else {
            (r.hover, pressed_fill(r.hover, &t))
        };
        let circle = filled || self.round;
        let ring = if circle {
            self.size / 2.
        } else {
            f32::from(radius)
        };
        let tip = self.tooltip.clone().unwrap_or_else(|| self.label.clone());
        let disabled = self.disabled;
        let el = div()
            .id(self.id)
            .role(Role::Button)
            .aria_label(self.label)
            .when_some(self.shortcut.clone(), |d, k| d.aria_keyshortcuts(k))
            .when(self.active, |d| d.aria_toggled(Toggled::True))
            .size(px(self.size))
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .bg(bg)
            .when(circle, |d| d.rounded_full())
            .when(!circle, |d| d.rounded(radius))
            // A filled one (Send) draws its unavailable state in the
            // colours it is given; a ghost one dims.
            .when(disabled && !filled, |d| d.opacity(0.4))
            .when(!disabled, |d| {
                d.cursor_pointer()
                    .hover(|s| s.bg(hover_bg))
                    .active(|s| s.bg(pressed_bg))
            })
            .child(icon(self.icon, self.icon_size, fg))
            .tip(tip, self.shortcut);
        if disabled {
            el
        } else {
            el.on_click(on_click_or_noop(self.on_click))
                .keyboard_control(Ring::Outset(ring), window, cx)
        }
    }
}

/// A macOS switch.
#[derive(IntoElement)]
pub struct Switch {
    id: ElementId,
    label: SharedString,
    on: bool,
    disabled: bool,
    on_click: Option<ClickHandler>,
}

impl Switch {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>, on: bool) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            on,
            disabled: false,
            on_click: None,
        }
    }
    pub fn on_click(mut self, handler: ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
    /// Shown dimmed and not switchable (what it controls is unavailable).
    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
}

impl RenderOnce for Switch {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let track = switch_track(self.on, &t);
        let knob = if self.on {
            r.checked_foreground
        } else {
            gpui_kit::white()
        };
        let disabled = self.disabled;
        let el = div()
            .id(self.id)
            .role(Role::Switch)
            .aria_label(self.label)
            .aria_toggled(if self.on {
                Toggled::True
            } else {
                Toggled::False
            })
            .w(px(32.))
            .h(px(18.))
            .flex_none()
            .rounded_full()
            .bg(track)
            .active(|s| s.bg(pressed_fill(track, &t)))
            .p(px(2.))
            .flex()
            .when(self.on, |d| d.justify_end())
            .when(self.disabled, |d| d.opacity(0.45))
            .when(!self.disabled, |d| d.cursor_pointer())
            .child(
                div()
                    .size(px(14.))
                    .rounded_full()
                    .bg(knob)
                    .shadow(knob_shadow(&t)),
            );
        // As a disabled button: no action and no Tab stop.
        if disabled {
            el
        } else {
            el.on_click(on_click_or_noop(self.on_click))
                .keyboard_control(Ring::Outset(9.), window, cx)
        }
    }
}

/// A switch's track: the checked colour when on; off, a grey a white knob
/// stands out on (light #D1D1D1, about System Settings' off track, where
/// the old 12% wash left the knob at 1.3:1 to the card around it).
pub fn switch_track(on: bool, t: &ConduitTheme) -> Hsla {
    let r = t.roles;
    if on {
        r.checked
    } else if t.dark {
        with_alpha(r.text, 0.22)
    } else {
        with_alpha(r.text, 0.19)
    }
}

/// The knob's edge and shadow, as AppKit draws its switch: a half-point
/// ring (so a white knob keeps its edge on a white card) and a soft 1 pt
/// drop shadow.
fn knob_shadow(t: &ConduitTheme) -> Vec<BoxShadow> {
    vec![
        BoxShadow {
            color: with_alpha(gpui_kit::black(), if t.dark { 0.30 } else { 0.16 }),
            offset: point(px(0.), px(0.)),
            blur_radius: px(0.),
            spread_radius: px(0.5),
            inset: false,
        },
        BoxShadow {
            color: with_alpha(gpui_kit::black(), if t.dark { 0.35 } else { 0.14 }),
            offset: point(px(0.), px(1.)),
            blur_radius: px(1.5),
            spread_radius: px(0.),
            inset: false,
        },
    ]
}

/// A settings row whose subtitle is a warning: the glyph in the warning
/// tone, then the message (why the control beside it is unavailable).
pub fn warning_row(
    title: impl Into<SharedString>,
    message: impl Into<SharedString>,
    control: impl IntoElement,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    let tone = crate::theme::legible_text(r.warning, r.text, grouped_tones(t).1, 3.0);
    div()
        .w_full()
        .min_h(px(t.metrics.row_height + 16.))
        .px(px(12.))
        .py(px(8.))
        .flex()
        .items_center()
        .gap(px(12.))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text)
                        .child(title.into()),
                )
                .child(
                    div()
                        .flex()
                        .items_start()
                        .gap(px(5.))
                        .child(div().pt(px(1.)).flex_none().child(crate::assets::icon(
                            IconName::CircleAlert,
                            12.,
                            tone,
                        )))
                        .child(
                            div()
                                .min_w_0()
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(message.into()),
                        ),
                ),
        )
        .child(control)
}

/// One option of a [`Segmented`] control.
pub struct Segment {
    pub label: SharedString,
    pub icon: Option<IconName>,
}

impl Segment {
    pub fn new(label: impl Into<SharedString>) -> Self {
        Self {
            label: label.into(),
            icon: None,
        }
    }
    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(icon);
        self
    }
}

/// Called with the index of the segment the user picked.
pub type SelectHandler = Rc<dyn Fn(usize, &mut Window, &mut App) + 'static>;

/// A macOS segmented control (the chosen segment is a raised pill).
#[derive(IntoElement)]
pub struct Segmented {
    id: SharedString,
    label: SharedString,
    segments: Vec<Segment>,
    selected: usize,
    on_select: Option<SelectHandler>,
}

impl Segmented {
    pub fn new(
        id: impl Into<SharedString>,
        label: impl Into<SharedString>,
        segments: Vec<Segment>,
        selected: usize,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            segments,
            selected,
            on_select: None,
        }
    }
    pub fn on_select(mut self, handler: SelectHandler) -> Self {
        self.on_select = Some(handler);
        self
    }
}

impl RenderOnce for Segmented {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let pill = if t.dark {
            crate::theme::mix(t.surfaces.panel, r.text, 0.22)
        } else {
            gpui_kit::white()
        };
        let count = self.segments.len();
        let (seg_hover, seg_pressed) = (
            with_alpha(r.text, if t.dark { 0.06 } else { 0.04 }),
            with_alpha(r.text, if t.dark { 0.14 } else { 0.10 }),
        );
        // One key-view stop for the whole control (AppKit's): Tab reaches
        // it, the arrows choose, and the chosen segment shows the ring.
        let group_id = ElementId::Name(self.id.clone());
        let focus = (full_keyboard_access(cx))
            .then(|| control_focus_handle(&group_id, window, cx).tab_stop(true));
        let focused = focus.as_ref().is_some_and(|f| f.is_focused(window));
        let segments: Vec<_> = self
            .segments
            .into_iter()
            .enumerate()
            .map(|(i, seg)| {
                let on = i == self.selected;
                div()
                    .id(ElementId::NamedInteger(self.id.clone(), i as u64))
                    .role(Role::RadioButton)
                    .aria_label(seg.label.clone())
                    .aria_selected(on)
                    .aria_position_in_set(i + 1)
                    .aria_size_of_set(count)
                    // VoiceOver hears the chosen segment while the control
                    // has focus (only then: a focused window would lend it
                    // focus too).
                    .when(on && focused, |d| d.aria_active_descendant())
                    .relative()
                    .h_full()
                    .px(px(12.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .gap(px(5.))
                    .rounded(px(5.))
                    .text_size(px(t.metrics.control - 0.5))
                    .font_weight(if on {
                        FontWeight::MEDIUM
                    } else {
                        FontWeight::NORMAL
                    })
                    .text_color(if on { r.text } else { r.text_subtle })
                    .when(on, |d| d.bg(pill).shadow(control_shadow(&t)))
                    .when(!on, |d| {
                        d.hover(|s| s.bg(seg_hover)).active(|s| s.bg(seg_pressed))
                    })
                    .cursor_pointer()
                    .when_some(seg.icon, |d, ic| {
                        d.child(icon(ic, 14., if on { r.text } else { r.text_subtle }))
                    })
                    .child(seg.label)
                    .when(on && focused, |d| {
                        d.child(ring_overlay(Ring::Outset(5.), &t))
                    })
                    // A click chooses without taking focus, as AppKit's.
                    .on_any_mouse_down(|_, window, _| window.prevent_default())
                    .on_click({
                        let handler = self.on_select.clone();
                        move |_, window, cx| {
                            if let Some(h) = &handler {
                                h(i, window, cx)
                            }
                        }
                    })
            })
            .collect();
        let selected = self.selected;
        let on_select = self.on_select.clone();
        div()
            .id(group_id)
            .role(Role::RadioGroup)
            .aria_label(self.label)
            .when_some(focus, |d, focus| {
                d.track_focus(&focus)
                    .on_any_mouse_down(|_, window, _| window.prevent_default())
                    .on_key_down(radio_keys(selected, count, on_select))
            })
            .h(px(t.metrics.control_height))
            .p(px(2.))
            .flex()
            .flex_none()
            .gap(px(2.))
            .rounded(px(7.))
            .bg(with_alpha(r.text, if t.dark { 0.10 } else { 0.06 }))
            .children(segments)
    }
}

/// A radio dot, as drawn inside list rows (the row carries the role).
pub fn radio_dot(on: bool, t: &ConduitTheme) -> Div {
    let r = t.roles;
    div()
        .size(px(16.))
        .flex_none()
        .rounded_full()
        .flex()
        .items_center()
        .justify_center()
        .when(on, |d| d.bg(r.checked))
        // Off: a field-toned disc with a 3:1 edge (a black disc with a
        // 1.5:1 ring vanished on the dark approval card).
        .when(!on, |d| {
            d.border_1().border_color(r.control_edge).bg(field_fill(t))
        })
        .when(on, |d| {
            d.child(div().size(px(6.)).rounded_full().bg(r.checked_foreground))
        })
}

/// A circular avatar with initials (or an icon).
pub fn avatar(initials: &str, size: f32, bg: Hsla, fg: Hsla) -> Div {
    div()
        .size(px(size))
        .flex_none()
        .rounded_full()
        .bg(bg)
        .flex()
        .items_center()
        .justify_center()
        .text_size(px((size * 0.38).round()))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(fg)
        .child(SharedString::from(initials.to_string()))
}

/// An icon on a rounded-square tile, for model avatars and option cards.
pub fn icon_tile(name: IconName, size: f32, bg: Hsla, fg: Hsla, radius: f32) -> Div {
    div()
        .size(px(size))
        .flex_none()
        .rounded(px(radius))
        .bg(bg)
        .flex()
        .items_center()
        .justify_center()
        .child(icon(name, (size * 0.55).round(), fg))
}

/// A small pill label.
pub fn badge(content: impl Into<SharedString>, bg: Hsla, fg: Hsla, cx: &App) -> Div {
    let t = cx.conduit();
    div()
        .flex_none()
        .h(px(18.))
        .px(px(7.))
        .rounded_full()
        .bg(bg)
        .flex()
        .items_center()
        .text_size(px(t.metrics.caption))
        .font_weight(FontWeight::MEDIUM)
        .text_color(fg)
        .child(content.into())
}

/// A Kit `Input` without its own chrome or padding, for a [`field_frame`].
pub fn bare_input(
    state: &gpui_kit::Entity<gpui_kit::component::input::InputState>,
    label: impl Into<SharedString>,
    size: f32,
) -> gpui_kit::component::input::Input {
    gpui_kit::component::input::Input::new(state)
        .appearance(false)
        .bordered(false)
        .px_0()
        .text_size(px(size))
        .aria_label(label)
}

/// The frame of a text field: a Kit `Input` with `appearance(false)` goes
/// inside. Draws the focus ring itself so it follows the accent policy.
pub fn field_frame(focused: bool, height: f32, cx: &App) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .h(px(height))
        .w_full()
        .px(px(10.))
        .flex()
        .items_center()
        .gap(px(7.))
        .rounded(t.control_radius())
        .bg(field_fill(t))
        .border_1()
        .border_color(if focused { r.focus } else { r.border_strong })
        .when(focused, |d| d.shadow(focus_ring(t)))
        .text_size(px(t.metrics.control + 1.))
        .text_color(r.text)
}

/// A field's inner row, without a frame of its own, for a [`form_field`].
pub fn inline_field(cx: &App) -> Div {
    let t = cx.conduit();
    div()
        .w_full()
        .flex()
        .items_center()
        .gap(px(7.))
        .text_size(px(t.metrics.control + 1.))
        .text_color(t.roles.text)
}

/// A labelled field as the phone's grouped forms draw one: a lifted row
/// with the label at its leading edge and the control after it, then the
/// help as the row's footer.
pub fn form_field(
    label: impl Into<SharedString>,
    control: impl IntoElement,
    help: Option<SharedString>,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    let (_, card) = grouped_tones(t);
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .w_full()
        .child(
            div()
                .w_full()
                .min_h(px(t.metrics.control_height + 14.))
                .px(px(12.))
                .flex()
                .items_center()
                .gap(px(12.))
                .rounded(px(12.))
                .bg(card)
                .child(
                    div()
                        .flex_none()
                        .min_w(px(96.))
                        .text_size(px(t.metrics.control + 1.))
                        .text_color(r.text)
                        .child(label.into()),
                )
                .child(div().flex_1().min_w_0().child(control)),
        )
        .when_some(help, |d, h| {
            d.child(
                div()
                    .px(px(12.))
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .line_height(relative(1.35))
                    .child(h),
            )
        })
}

/// The page and card tones of a grouped list, as the phone resolves them:
/// the darker of the palette's page and card colours is the page, so cards
/// always read as lifted. Dark mode takes them from the one dark ramp: the
/// page is the content tone (step 0, the chat column's #000) and a group
/// is raised (step 1, the composer's #181818), as the phone's grouped
/// lists are #000 under their cards.
pub fn grouped_tones(t: &ConduitTheme) -> (Hsla, Hsla) {
    if t.dark {
        return (t.surfaces.panel, t.roles.raised);
    }
    let c = &t.colors;
    let (page, card) = if crate::theme::contrast::relative_luminance(c.background)
        <= crate::theme::contrast::relative_luminance(c.card)
    {
        (c.background, c.card)
    } else {
        (c.card, c.background)
    };
    if page == card {
        (page, c.popover)
    } else {
        (page, card)
    }
}

/// The fill of a text field, a shortcut field, a secondary button or an
/// off radio: in dark the ramp's step 2, one step up from the raised
/// surface (a group, the approval card) it usually sits on, so it never
/// reads as a hole in it; the column's white in light.
pub fn field_fill(t: &ConduitTheme) -> Hsla {
    if t.dark {
        t.roles.raised_hover
    } else {
        t.surfaces.panel
    }
}

/// [`field_fill`] under the pointer: the ramp's step 3 in dark.
pub fn field_fill_hover(t: &ConduitTheme) -> Hsla {
    if t.dark {
        crate::theme::dark_step(t.surfaces.panel, t.roles.text, 3)
    } else {
        crate::theme::mix(t.surfaces.panel, t.roles.text, 0.04)
    }
}

/// A grouped card (an inset group, rows split by hairlines that start at
/// the row text), the phone's inset-grouped lists and System Settings'
/// groups.
pub fn grouped(rows: Vec<AnyElement>, cx: &App) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    let (_, card) = grouped_tones(t);
    let n = rows.len();
    let mut group = div()
        .w_full()
        .flex()
        .flex_col()
        .rounded(px(12.))
        .bg(card)
        .overflow_hidden();
    for (i, row) in rows.into_iter().enumerate() {
        group = group.child(row);
        if i + 1 < n {
            group = group.child(div().pl(px(12.)).child(divider(r.divider)));
        }
    }
    group
}

/// A grouped list's section: an optional title over the group and an
/// optional footer under it, as the phone's inset-grouped sections.
pub fn grouped_section(
    title: Option<SharedString>,
    rows: Vec<AnyElement>,
    footer: Option<SharedString>,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(6.))
        .when_some(title, |d, title| {
            d.child(
                div()
                    .px(px(12.))
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(title),
            )
        })
        .child(grouped(rows, cx))
        .when_some(footer, |d, footer| {
            d.child(
                div()
                    .px(px(12.))
                    .text_size(px(t.metrics.small))
                    .line_height(relative(1.35))
                    .text_color(r.text_subtle)
                    .child(footer),
            )
        })
}

/// A row that navigates, as the phone's list rows: an icon tile, a title
/// over a subtitle, and a chevron.
pub fn nav_row(
    id: impl Into<ElementId>,
    leading: IconName,
    title: SharedString,
    subtitle: Option<SharedString>,
    cx: &App,
) -> Stateful<Div> {
    nav_row_badged(id, leading, title, None, subtitle, cx)
}

/// [`nav_row`] with a small capsule after the title ("Beta").
pub fn nav_row_badged(
    id: impl Into<ElementId>,
    leading: IconName,
    title: SharedString,
    badge: Option<SharedString>,
    subtitle: Option<SharedString>,
    cx: &App,
) -> Stateful<Div> {
    let pressed = pressed_fill(cx.conduit().roles.hover, cx.conduit());
    let t = cx.conduit();
    let r = t.roles;
    let m = t.metrics;
    div()
        .id(id)
        .role(Role::Button)
        .aria_label(title.clone())
        .when_some(subtitle.clone(), |d, s| d.aria_description(s))
        .w_full()
        .min_h(px(m.row_height + 20.))
        .px(px(12.))
        .py(px(9.))
        .flex()
        .items_center()
        .gap(px(12.))
        .cursor_pointer()
        .hover(|s| s.bg(r.hover))
        .active(|s| s.bg(pressed))
        .child(icon_tile(
            leading,
            32.,
            with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }),
            r.text,
            8.,
        ))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .text_size(px(m.control + 1.))
                        .text_color(r.text)
                        .child(title)
                        .when_some(badge, |d, badge| {
                            d.child(
                                div()
                                    .px(px(6.))
                                    .py(px(1.))
                                    .rounded_full()
                                    .border_1()
                                    .border_color(r.border)
                                    .text_size(px(m.small - 1.))
                                    .text_color(r.text_subtle)
                                    .child(badge),
                            )
                        }),
                )
                .when_some(subtitle, |d, s| {
                    d.child(
                        div()
                            .text_size(px(m.small))
                            .line_height(relative(1.35))
                            .text_color(r.text_subtle)
                            .child(s),
                    )
                }),
        )
        .child(icon(IconName::ChevronRight, 13., r.text_faint))
}

/// One row of a [`grouped`] card: title (+ subtitle) leading, control
/// trailing.
pub fn setting_row(
    title: impl Into<SharedString>,
    subtitle: Option<SharedString>,
    control: impl IntoElement,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .w_full()
        .min_h(px(t.metrics.row_height + 16.))
        .px(px(12.))
        .py(px(8.))
        .flex()
        .items_center()
        .gap(px(12.))
        .child(
            // min_w_0: a long subtitle wraps instead of pushing the control
            // out of the row.
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text)
                        .child(title.into()),
                )
                .when_some(subtitle, |d, s| {
                    d.child(
                        div()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(s),
                    )
                }),
        )
        .child(control)
}
