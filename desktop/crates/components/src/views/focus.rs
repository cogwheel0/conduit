//! Keyboard reach, focus rings, tooltips and pressed fills: what makes a
//! drawn control behave like a Mac control.
//!
//! * **Full Keyboard Access.** With System Settings › Keyboard ›
//!   Keyboard Navigation on ([`KeyboardAccess`]), Tab reaches every control;
//!   off, it reaches text fields and lists only, as in AppKit. The app keeps
//!   the global in step with the system.
//! * **Focus ring.** A control reached from the keyboard draws a ring in the
//!   label colour at 55%, 2 pt wide and 2 pt outside its edge, following its
//!   radius ([`Ring::Outset`]); a row inside a card draws it on its own edge
//!   ([`Ring::Inset`]). A click never moves focus to a button, as on macOS.
//! * **The key loop.** A disabled control is no stop. A radio group or
//!   segmented control is one stop ([`RadioGroupExt`], [`radio_keys`]): the
//!   arrows choose inside it and the chosen option rings.
//! * **Lists.** A focused (key) list shows its focus by inverting its
//!   selection ([`selection_fill`]): the label colour as the fill, the page
//!   colour as the text ([`on_selection`]), as Finder's key list draws its
//!   selection in the accent and an inactive one in grey (Conduit has no
//!   accent: black on white, white on black). Never a ring over a row.
//! * **Tooltips.** Every icon-only control names itself, with its shortcut
//!   when it has one ("New Chat ⌘N"), after [`TOOLTIP_DELAY`].
//! * **Pressed.** Pressed reads darker than hover: the hover fill plus a 7%
//!   wash of the label colour ([`pressed_fill`]).

use std::sync::Arc;
use std::time::Duration;

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyView, App, BoxShadow, Context, Div, ElementId, FocusHandle, Global, Hsla, MouseButton,
    SharedString, Stateful, Window, div, point, px,
};

use crate::theme::{ActiveConduitTheme, ConduitTheme, UI_FONT, composite, with_alpha};

/// How long the pointer rests on a control before its tooltip shows (AppKit
/// waits about a second).
pub const TOOLTIP_DELAY: Duration = Duration::from_millis(800);

/// The ring's width and its gap from the control's edge.
pub const RING_WIDTH: f32 = 2.;
pub const RING_GAP: f32 = 2.;

/// Whether Tab reaches every control (System Settings › Keyboard ›
/// Keyboard Navigation), or only text fields and lists.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyboardAccess {
    pub all_controls: bool,
}

impl Default for KeyboardAccess {
    /// Every control: the gallery and tests, which have no system setting
    /// to follow.
    fn default() -> Self {
        Self { all_controls: true }
    }
}

impl Global for KeyboardAccess {}

/// Whether Tab reaches buttons, switches and the like.
pub fn full_keyboard_access(cx: &App) -> bool {
    cx.try_global::<KeyboardAccess>()
        .copied()
        .unwrap_or_default()
        .all_controls
}

/// The chords the app binds for the commands its icon buttons also carry,
/// as menus write them (`⌘N`), so tooltips can teach them. The app installs
/// it and replaces it when a shortcut is rebound.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShortcutHints {
    pub new_chat: Option<SharedString>,
    pub toggle_sidebar: Option<SharedString>,
    pub settings: Option<SharedString>,
    pub palette: Option<SharedString>,
    pub model_picker: Option<SharedString>,
    pub stop: Option<SharedString>,
    pub send: Option<SharedString>,
    pub copy_last_reply: Option<SharedString>,
    pub quick_ask: Option<SharedString>,
    pub find: Option<SharedString>,
    /// File › New Temporary Chat (the toolbar's temporary switch).
    pub temporary_chat: Option<SharedString>,
    /// Chat › Regenerate (the last answer's Regenerate).
    pub regenerate: Option<SharedString>,
    /// Start or Stop Dictation (the composer's mic).
    pub dictate: Option<SharedString>,
    /// Chat › Read Aloud (the last answer's Read Aloud).
    pub read_aloud: Option<SharedString>,
    /// Chat › Start Voice Call (the composer's call button).
    pub voice_call: Option<SharedString>,
}

impl Global for ShortcutHints {}

/// The installed [`ShortcutHints`] (none in the gallery).
pub fn hints(cx: &App) -> ShortcutHints {
    cx.try_global::<ShortcutHints>()
        .cloned()
        .unwrap_or_default()
}

/// Where a control draws its focus ring.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ring {
    /// Outside the edge, for a control with this corner radius.
    Outset(f32),
    /// On the edge, for a row inside a list with this corner radius.
    Inset(f32),
}

/// The ring's colour: the label colour at 55%, never an accent.
pub fn ring_color(t: &ConduitTheme) -> Hsla {
    with_alpha(t.roles.text, 0.55)
}

/// The ring itself, as an overlay of the control (which must be
/// `relative`). It takes no clicks.
pub fn ring_overlay(ring: Ring, t: &ConduitTheme) -> Div {
    let color = ring_color(t);
    match ring {
        Ring::Outset(radius) => {
            let o = RING_GAP + RING_WIDTH;
            div()
                .debug_selector(|| "focus-ring".into())
                .absolute()
                .top(px(-o))
                .left(px(-o))
                .right(px(-o))
                .bottom(px(-o))
                .rounded(px(radius + o))
                .border_2()
                .border_color(color)
        }
        Ring::Inset(radius) => div()
            .debug_selector(|| "focus-ring".into())
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .bottom_0()
            .rounded(px(radius))
            .border_2()
            .border_color(color),
    }
}

/// A rounded rectangle's outset ring as a shadow, for a control drawn as a
/// single element that cannot hold an overlay (a text field's frame).
pub fn ring_shadow(t: &ConduitTheme) -> Vec<BoxShadow> {
    vec![BoxShadow {
        color: ring_color(t),
        offset: point(px(0.), px(0.)),
        blur_radius: px(0.),
        spread_radius: px(RING_WIDTH + 1.),
        inset: false,
    }]
}

/// The fill a control shows while the pointer presses it: `hover` plus a 7%
/// wash of the label colour, so pressed always reads darker than hover.
pub fn pressed_fill(hover: Hsla, t: &ConduitTheme) -> Hsla {
    let wash = with_alpha(t.roles.text, if t.dark { 0.10 } else { 0.07 });
    if hover.a >= 0.999 {
        composite(wash, hover)
    } else {
        // Both translucent: stack the washes.
        with_alpha(hover, (hover.a + wash.a).min(1.))
    }
}

/// A list's selection fill: the plain grey wash, or, while the list is key
/// (has keyboard focus), the label colour itself, opaque (black in light,
/// near-white in dark). AppKit shows a focused list by emphasizing its
/// selection (the accent in Finder, grey once another view is key), never
/// by ringing a row on top of it.
pub fn selection_fill(t: &ConduitTheme, key: bool) -> Hsla {
    if !key {
        return t.roles.selected;
    }
    // With Settings › Appearance's system accent, Finder's own: the accent,
    // darkened as far as white text needs for AA.
    if t.prefs.accent == crate::theme::AccentPolicy::System {
        return crate::theme::legible_fill(t.roles.selected_icon, t.roles.checked_foreground, 4.5);
    }
    let mut fill = t.roles.text;
    fill.a = 1.;
    fill
}

/// `color` (a selected row's title, date or glyph) as drawn on its
/// selection: unchanged on the grey one; on a key list's inverted fill, the
/// page colour for the label and primary text, and a softer page tone (still
/// AA) for anything secondary.
pub fn on_selection(color: Hsla, t: &ConduitTheme, key: bool) -> Hsla {
    if !key {
        return color;
    }
    let r = &t.roles;
    if color == r.text || color == r.sidebar_text {
        selection_ink(t)
    } else {
        selection_ink_subtle(t)
    }
}

/// Text on a key list's inverted selection: the page colour (white on the
/// system accent).
pub fn selection_ink(t: &ConduitTheme) -> Hsla {
    let mut ink = if t.prefs.accent == crate::theme::AccentPolicy::System {
        t.roles.checked_foreground
    } else {
        t.roles.content
    };
    ink.a = 1.;
    ink
}

/// Secondary text and glyphs on a key list's inverted selection: the page
/// colour toward the fill, as far as AA (4.5:1) on the fill allows.
pub fn selection_ink_subtle(t: &ConduitTheme) -> Hsla {
    let fill = selection_fill(t, true);
    let ink = selection_ink(t);
    let soft = crate::theme::mix(ink, fill, 0.3);
    // A light fill (the label colour in dark mode) takes darker ink; a dark
    // one lighter.
    let light_fill = crate::theme::contrast::relative_luminance(fill) > 0.5;
    crate::theme::legible_lightness(soft, &[fill], !light_fill, 4.5)
}

/// Where a key takes the choice in a radio group or segmented control of
/// `count` options from `selected`: ← and ↑ the option before, → and ↓ the
/// one after (stopping at the ends, as AppKit's), Home and End the ends.
/// `None` for any other key, or when the choice would not change.
pub fn radio_step(key: &str, selected: usize, count: usize) -> Option<usize> {
    if count == 0 {
        return None;
    }
    let next = match key {
        "left" | "up" => selected.checked_sub(1)?,
        "right" | "down" => selected + 1,
        "home" => 0,
        "end" => count - 1,
        _ => return None,
    };
    (next < count && next != selected).then_some(next)
}

/// A radio group's key handler: an arrow chooses through `on_select`
/// ([`radio_step`]); one pressed at an end stays in the group.
pub fn radio_keys(
    selected: usize,
    count: usize,
    on_select: Option<crate::views::kit::SelectHandler>,
) -> impl Fn(&gpui_kit::KeyDownEvent, &mut Window, &mut App) + 'static {
    move |ev, window, cx| {
        let k = &ev.keystroke;
        if k.modifiers.modified() {
            return;
        }
        if let Some(next) = radio_step(&k.key, selected, count) {
            if let Some(h) = &on_select {
                h(next, window, cx);
            }
            cx.stop_propagation();
        } else if matches!(k.key.as_str(), "left" | "right" | "up" | "down") {
            cx.stop_propagation();
        }
    }
}

/// A radio group drawn where no window is at hand (a builder taking
/// `&App`) as one key-view stop, as AppKit's: its chosen option is the stop.
pub trait RadioGroupExt: Sized {
    /// The group: with Full Keyboard Access, the arrows choose
    /// ([`radio_step`]) while its chosen option has focus.
    fn radio_group(
        self,
        selected: usize,
        count: usize,
        on_select: Option<crate::views::kit::SelectHandler>,
        cx: &App,
    ) -> Self;
    /// An option with no fill of its own. The chosen one is the group's one
    /// stop, with its ring `RING_GAP` outside its content while it has
    /// keyboard focus (laid out so nothing moves, as
    /// [`ControlExt::keyboard_outline`]); a click focuses none. The option's
    /// id must come from [`radio_option_id`], so focus stays with the
    /// choice as the arrows move it.
    fn radio_option_outline(self, on: bool, radius: f32, cx: &App) -> Self;
}

/// A radio option's element id: the chosen option keeps one id whichever
/// it is, so its focus (kept under its id) follows the choice.
pub fn radio_option_id(group: &str, index: usize, on: bool) -> ElementId {
    if on {
        ElementId::Name(format!("{group}-chosen").into())
    } else {
        ElementId::NamedInteger(group.to_string().into(), index as u64)
    }
}

impl RadioGroupExt for Stateful<Div> {
    fn radio_group(
        self,
        selected: usize,
        count: usize,
        on_select: Option<crate::views::kit::SelectHandler>,
        cx: &App,
    ) -> Self {
        if !full_keyboard_access(cx) {
            return self;
        }
        self.on_key_down(radio_keys(selected, count, on_select))
    }

    fn radio_option_outline(self, on: bool, radius: f32, cx: &App) -> Self {
        if !full_keyboard_access(cx) {
            return self;
        }
        let color = ring_color(cx.conduit());
        let o = RING_GAP + RING_WIDTH;
        let el = self
            // No button's click focuses it (a right click would, else).
            .on_any_mouse_down(|_, window, _| window.prevent_default())
            .border_2()
            .border_color(with_alpha(color, 0.))
            .rounded(px(radius + o))
            .p(px(RING_GAP))
            .m(px(-o));
        if on {
            el.tab_index(0)
                .focus_visible(move |s| s.border_color(color))
        } else {
            el
        }
    }
}

/// The element's focus handle, kept across frames under its id.
pub fn control_focus_handle(id: &ElementId, window: &mut Window, cx: &mut App) -> FocusHandle {
    let key = ElementId::NamedChild(Arc::new(id.clone()), "focus".into());
    window
        .use_keyed_state(key, cx, |_, cx| cx.focus_handle())
        .read(cx)
        .clone()
}

/// What makes a drawn `Stateful<Div>` a Mac control.
pub trait ControlExt: Sized {
    /// Tab reaches it (with Full Keyboard Access on, unless `always`), it
    /// draws `ring` while focused, and a click leaves focus where it was.
    /// The element needs its id set first.
    fn keyboard_control(self, ring: Ring, window: &mut Window, cx: &mut App) -> Self;
    /// [`Self::keyboard_control`] for a list or text-like control Tab reaches
    /// whatever the system setting (as AppKit's lists and fields).
    fn keyboard_list_item(self, ring: Ring, window: &mut Window, cx: &mut App) -> Self;
    /// A tooltip naming it, with its shortcut.
    fn tip(self, label: impl Into<SharedString>, shortcut: Option<SharedString>) -> Self;
    /// For a control drawn where no window is at hand (a builder taking
    /// `&App`) with no fill of its own: Tab reaches it (with Full Keyboard
    /// Access) and its ring is a border `RING_GAP` outside its content,
    /// laid out so nothing moves. The element must have no padding or
    /// margin of its own.
    fn keyboard_outline(self, radius: f32, cx: &App) -> Self;
    /// The same for an opaque control: its ring hugs its edge.
    fn keyboard_shadow(self, cx: &App) -> Self;
    /// The same for a control with a hairline border (a pill, a card
    /// row): the border thickens to the ring while it has focus.
    fn keyboard_border(self, cx: &App) -> Self;
}

fn attach_focus(el: Stateful<Div>, ring: Ring, window: &mut Window, cx: &mut App) -> Stateful<Div> {
    let mut el = el;
    let Some(id) = el.interactivity().element_id.clone() else {
        return el;
    };
    let handle = control_focus_handle(&id, window, cx).tab_stop(true);
    let focused = handle.is_focused(window);
    let t = cx.conduit().clone();
    el.track_focus(&handle)
        // A click does not take focus from the field being typed in, as
        // AppKit's buttons do not.
        .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
        .relative()
        .when(focused, |d| d.child(ring_overlay(ring, &t)))
}

impl ControlExt for Stateful<Div> {
    fn keyboard_control(self, ring: Ring, window: &mut Window, cx: &mut App) -> Self {
        if !full_keyboard_access(cx) {
            return self;
        }
        attach_focus(self, ring, window, cx)
    }

    fn keyboard_list_item(self, ring: Ring, window: &mut Window, cx: &mut App) -> Self {
        attach_focus(self, ring, window, cx)
    }

    fn tip(self, label: impl Into<SharedString>, shortcut: Option<SharedString>) -> Self {
        let label = label.into();
        self.tooltip(tooltip_builder(label, shortcut))
            .tooltip_show_delay(TOOLTIP_DELAY)
    }

    fn keyboard_outline(self, radius: f32, cx: &App) -> Self {
        if !full_keyboard_access(cx) {
            return self;
        }
        let color = ring_color(cx.conduit());
        let o = RING_GAP + RING_WIDTH;
        self.tab_index(0)
            .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
            .border_2()
            .border_color(with_alpha(color, 0.))
            .rounded(px(radius + o))
            .p(px(RING_GAP))
            .m(px(-o))
            .focus_visible(move |s| s.border_color(color))
    }

    fn keyboard_shadow(self, cx: &App) -> Self {
        if !full_keyboard_access(cx) {
            return self;
        }
        let ring = ring_shadow(cx.conduit());
        self.tab_index(0)
            .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
            .focus_visible(move |s| s.shadow(ring))
    }

    fn keyboard_border(self, cx: &App) -> Self {
        if !full_keyboard_access(cx) {
            return self;
        }
        let color = ring_color(cx.conduit());
        self.tab_index(0)
            .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
            .focus_visible(move |s| s.border_2().border_color(color))
    }
}

/// A tooltip: the name and, after it in the secondary tone, the shortcut,
/// on the menu surface (the system draws its tooltips on a pale card).
pub struct Tip {
    pub label: SharedString,
    pub shortcut: Option<SharedString>,
}

impl Render for Tip {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        // The pointer's own height: the card starts under the cursor, as
        // AppKit places its tooltips.
        div().pl(px(2.)).pt(px(18.)).child(
            div()
                .id("tooltip")
                .debug_selector(|| "tooltip".into())
                .relative()
                // Kept whole by a mask that fades a list's edges.
                .child(crate::views::overlays::overlay_marker())
                .flex()
                .items_center()
                .gap(px(10.))
                .px(px(7.))
                .py(px(3.))
                .rounded(px(5.))
                .bg(r.overlay)
                .border_1()
                .border_color(with_alpha(r.text, if t.dark { 0.18 } else { 0.12 }))
                .shadow(vec![BoxShadow {
                    color: with_alpha(gpui_kit::black(), if t.dark { 0.45 } else { 0.14 }),
                    offset: point(px(0.), px(2.)),
                    blur_radius: px(6.),
                    spread_radius: px(0.),
                    inset: false,
                }])
                .font_family(UI_FONT)
                .text_size(px(11.5))
                .text_color(r.text)
                .whitespace_nowrap()
                .child(self.label.clone())
                .when_some(self.shortcut.clone(), |d, keys| {
                    d.child(div().text_color(r.text_subtle).child(keys))
                }),
        )
    }
}

/// The builder GPUI's `tooltip` takes, for a [`Tip`].
pub fn tooltip_builder(
    label: SharedString,
    shortcut: Option<SharedString>,
) -> impl Fn(&mut Window, &mut App) -> AnyView + 'static {
    move |_, cx| {
        let (label, shortcut) = (label.clone(), shortcut.clone());
        cx.new(|_| Tip { label, shortcut }).into()
    }
}

/// A tooltip's text as one line, the way the capture notes and tests read
/// it: the name, then the shortcut after a space.
pub fn tip_text(label: &str, shortcut: Option<&str>) -> String {
    match shortcut {
        Some(k) if !k.is_empty() => format!("{label} {k}"),
        _ => label.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pressed_reads_darker_than_hover() {
        for dark in [false, true] {
            let t = ConduitTheme::new(
                "conduit",
                dark,
                crate::theme::DesignPrefs::default(),
                gpui_kit::rgb(crate::theme::DEFAULT_SYSTEM_ACCENT).into(),
            );
            let hover = t.roles.hover;
            let pressed = pressed_fill(hover, &t);
            assert!(
                pressed.a > hover.a,
                "pressed {pressed:?} must be stronger than hover {hover:?}"
            );
            // An opaque fill gets darker in light mode, lighter in dark.
            let solid = t.surfaces.panel;
            assert_ne!(pressed_fill(solid, &t), solid);
        }
    }

    #[test]
    fn arrows_step_through_a_radio_group_and_stop_at_its_ends() {
        assert_eq!(radio_step("right", 0, 3), Some(1));
        assert_eq!(radio_step("down", 1, 3), Some(2));
        assert_eq!(radio_step("left", 2, 3), Some(1));
        assert_eq!(radio_step("up", 1, 3), Some(0));
        // No wrapping, as AppKit's radio groups and segments.
        assert_eq!(radio_step("right", 2, 3), None);
        assert_eq!(radio_step("left", 0, 3), None);
        assert_eq!(radio_step("home", 2, 3), Some(0));
        assert_eq!(radio_step("end", 0, 3), Some(2));
        assert_eq!(radio_step("end", 2, 3), None);
        assert_eq!(radio_step("tab", 0, 3), None);
        assert_eq!(radio_step("right", 0, 0), None);
    }

    #[test]
    fn a_key_list_inverts_its_selection() {
        use crate::theme::contrast::contrast_ratio;
        for dark in [false, true] {
            let t = ConduitTheme::new(
                "conduit",
                dark,
                crate::theme::DesignPrefs::default(),
                gpui_kit::rgb(crate::theme::DEFAULT_SYSTEM_ACCENT).into(),
            );
            let (rest, key) = (selection_fill(&t, false), selection_fill(&t, true));
            // Grey while another view is key; the label colour, opaque,
            // while the list is.
            assert_eq!(rest, t.roles.selected);
            assert_eq!(key.a, 1.);
            assert_eq!(
                (key.h, key.s, key.l),
                (t.roles.text.h, t.roles.text.s, t.roles.text.l)
            );
            // Black on white in light, white on black in dark.
            if dark {
                assert!(key.l > 0.8 && selection_ink(&t).l < 0.2, "{key:?}");
            } else {
                assert!(key.l < 0.2 && selection_ink(&t).l > 0.8, "{key:?}");
            }
            // The title flips to the page colour; a date or glyph to a softer
            // tone of it; both read at AA on the fill.
            let title = on_selection(t.roles.sidebar_text, &t, true);
            let date = on_selection(t.roles.selected_text_subtle, &t, true);
            assert_eq!(title, selection_ink(&t));
            assert_ne!(date, title);
            assert!(contrast_ratio(title, key) >= 7., "title {dark}");
            assert!(contrast_ratio(date, key) >= 4.5, "date {dark}");
            // Not key: as given.
            assert_eq!(
                on_selection(t.roles.sidebar_text, &t, false),
                t.roles.sidebar_text
            );
            // With the system accent chosen, Finder's own: the accent with
            // white text, at AA.
            let accented = ConduitTheme::new(
                "conduit",
                dark,
                crate::theme::DesignPrefs {
                    accent: crate::theme::AccentPolicy::System,
                    ..Default::default()
                },
                gpui_kit::rgb(crate::theme::DEFAULT_SYSTEM_ACCENT).into(),
            );
            let fill = selection_fill(&accented, true);
            assert!(
                (fill.h - accented.roles.selected_icon.h).abs() < 0.02,
                "{fill:?}"
            );
            assert!(contrast_ratio(selection_ink(&accented), fill) >= 4.5);
            assert!(contrast_ratio(selection_ink_subtle(&accented), fill) >= 4.5);
        }
    }

    #[test]
    fn tooltips_read_name_then_shortcut() {
        assert_eq!(tip_text("New Chat", Some("⌘N")), "New Chat ⌘N");
        assert_eq!(tip_text("Copy", None), "Copy");
        assert_eq!(tip_text("Copy", Some("")), "Copy");
    }
}
