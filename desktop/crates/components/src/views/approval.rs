//! Approval cards for the daemon's `ui.request`: docked above the composer,
//! answered from the keyboard with ⌥⌘↩ (confirm) and ⌥⌘⌫ (decline).
//!
//! The body is one of [`ApprovalKind`]; the buttons are the kind's defaults
//! (for the gallery) or the app's own [`ApprovalAction`]s.

use gpui_kit::component::input::InputState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ElementId, Entity, FontWeight, Role, SharedString, Window, div, px, relative,
};

use crate::assets::IconName;
use crate::strings::{ActiveStrings as _, fill};
use crate::theme::{ActiveConduitTheme, MONO_FONT, with_alpha};
use crate::views::composer::composer_frame;
use crate::views::focus::{
    Ring, control_focus_handle, full_keyboard_access, pressed_fill, radio_keys, radio_step,
    ring_overlay,
};
use crate::views::kit::{
    Button, ButtonKind, ClickHandler, SelectHandler, bare_input, field_frame, icon_tile, radio_dot,
};

/// A code box inside the card: the code blocks' fill in light; in dark the
/// card is itself raised, so the box is one step above it.
fn inset_fill(t: &crate::ConduitTheme) -> gpui_kit::Hsla {
    if t.dark {
        t.roles.raised_hover
    } else {
        crate::theme::composite(t.roles.raised, t.surfaces.panel)
    }
}

/// One choice of a select prompt.
#[derive(Clone, Debug, PartialEq)]
pub struct SelectOption {
    pub label: SharedString,
    pub detail: Option<SharedString>,
}

/// What the request asks for.
#[derive(Clone, Debug, PartialEq)]
pub enum ApprovalKind {
    /// Run a tool with these arguments (a command, a file write…).
    Tool {
        tool: SharedString,
        preview: SharedString,
    },
    /// Pick one option.
    Select {
        options: Vec<SelectOption>,
        selected: usize,
    },
    /// Only the title and detail: a confirmation, or a notice.
    Message,
    /// A value to type: a Kit input the app owns (masked for a password).
    Input {
        state: Entity<InputState>,
        label: SharedString,
    },
    /// What a tool would run with, in a code box under a caption.
    Code {
        caption: SharedString,
        code: SharedString,
    },
    /// A question with choices (Open WebUI's `ask_user`): pick one, or
    /// answer in your own words in `other`.
    Question {
        /// The question itself, over the choices.
        question: SharedString,
        options: Vec<SelectOption>,
        /// The choice picked; none while nothing is, or while the own
        /// words are.
        selected: Option<usize>,
        /// The own-words field, when the question takes one, and its label.
        other: Option<(Entity<InputState>, SharedString)>,
        /// The own words are the answer.
        other_selected: bool,
    },
}

/// One button of a card.
#[derive(Clone)]
pub struct ApprovalAction {
    pub id: SharedString,
    pub label: SharedString,
    pub kind: ButtonKind,
    /// Shown after the label (`⌥⌘↩`), and announced.
    pub shortcut: Option<SharedString>,
    pub disabled: bool,
    pub on_click: Option<ClickHandler>,
}

impl ApprovalAction {
    pub fn new(id: impl Into<SharedString>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            kind: ButtonKind::Secondary,
            shortcut: None,
            disabled: false,
            on_click: None,
        }
    }
    pub fn primary(mut self) -> Self {
        self.kind = ButtonKind::Primary;
        self
    }
    pub fn shortcut(mut self, keys: impl Into<SharedString>) -> Self {
        self.shortcut = Some(keys.into());
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

/// Where a key takes a question's choice from `current` (`None`: nothing
/// chosen yet): with nothing chosen an arrow or Home chooses the first
/// answer and End the last, rather than step from one never chosen.
fn question_step(key: &str, current: Option<usize>, count: usize) -> Option<usize> {
    match current {
        Some(at) => radio_step(key, at, count),
        None if count == 0 => None,
        None => match key {
            "left" | "up" | "right" | "down" | "home" => Some(0),
            "end" => Some(count - 1),
            _ => None,
        },
    }
}

/// The question's key handler ([`question_step`]): as `radio_keys`, an
/// arrow at an end stays in the group.
fn question_keys(
    current: Option<usize>,
    count: usize,
    on_select: Option<crate::views::kit::SelectHandler>,
) -> impl Fn(&gpui_kit::KeyDownEvent, &mut Window, &mut App) + 'static {
    move |ev, window, cx| {
        let k = &ev.keystroke;
        if k.modifiers.modified() {
            return;
        }
        if let Some(next) = question_step(&k.key, current, count) {
            if let Some(h) = &on_select {
                h(next, window, cx);
            }
            cx.stop_propagation();
        } else if matches!(k.key.as_str(), "left" | "right" | "up" | "down") {
            cx.stop_propagation();
        }
    }
}

/// `⌥⌘↩` and `⌥⌘⌫`, as the cards show them.
pub const ALLOW_KEYS: &str = "\u{2325}\u{2318}\u{21a9}";
pub const DENY_KEYS: &str = "\u{2325}\u{2318}\u{232b}";

/// The docked card.
#[derive(IntoElement)]
pub struct ApprovalCard {
    id: SharedString,
    title: SharedString,
    detail: SharedString,
    /// Who asks ("Hermes · tool call").
    source: SharedString,
    kind: ApprovalKind,
    /// "1 of 2" when more requests are queued.
    queue: Option<(usize, usize)>,
    /// Which question of one request this is (0-based), when it is one of
    /// several: see [`Self::step`].
    step: Option<usize>,
    actions: Option<Vec<ApprovalAction>>,
    on_option: Option<SelectHandler>,
    tile: Option<IconName>,
    note: Option<SharedString>,
    /// A body the app draws itself, in place of the kind's (a form, cost
    /// chips under an approval).
    body: Option<AnyElement>,
}

impl ApprovalCard {
    pub fn new(
        id: impl Into<SharedString>,
        title: impl Into<SharedString>,
        detail: impl Into<SharedString>,
        source: impl Into<SharedString>,
        kind: ApprovalKind,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            detail: detail.into(),
            source: source.into(),
            kind,
            queue: None,
            step: None,
            actions: None,
            on_option: None,
            tile: None,
            note: None,
            body: None,
        }
    }
    pub fn queue(mut self, current: usize, total: usize) -> Self {
        self.queue = Some((current, total));
        self
    }
    /// Question `index` (0-based) of the `count` one request asks, shown
    /// with its place as [`Self::queue`] shows it. Each question is heard
    /// as Next or Back reaches it, with its place, even one worded as the
    /// question before.
    pub fn step(mut self, index: usize, count: usize) -> Self {
        self.queue = Some((index + 1, count));
        self.step = Some(index);
        self
    }
    /// The buttons, replacing the kind's defaults.
    pub fn actions(mut self, actions: Vec<ApprovalAction>) -> Self {
        self.actions = Some(actions);
        self
    }
    /// Called with the index of the option picked in a select card.
    pub fn on_option(mut self, handler: SelectHandler) -> Self {
        self.on_option = Some(handler);
        self
    }
    /// The icon on the card's tile (default per kind).
    pub fn tile(mut self, icon: IconName) -> Self {
        self.tile = Some(icon);
        self
    }
    /// A line under the body (an error, "Answered").
    pub fn note(mut self, note: impl Into<SharedString>) -> Self {
        self.note = Some(note.into());
        self
    }
    /// The app's own body, drawn in place of the kind's: a Hermes form, a
    /// paid tool's cost chips.
    pub fn body(mut self, body: impl IntoElement) -> Self {
        self.body = Some(body.into_any_element());
        self
    }
}

fn render_actions(actions: Vec<ApprovalAction>) -> Vec<AnyElement> {
    actions
        .into_iter()
        .map(|a| {
            let mut b = Button::new(ElementId::Name(a.id), a.label)
                .kind(a.kind)
                .disabled(a.disabled);
            if let Some(k) = a.shortcut {
                b = b.shortcut(k);
            }
            if let Some(h) = a.on_click
                && !a.disabled
            {
                b = b.on_click(h);
            }
            b.into_any_element()
        })
        .collect()
}

impl RenderOnce for ApprovalCard {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let id = self.id.to_string();
        let on_option = self.on_option.clone();
        let (tile, body, buttons): (IconName, AnyElement, Vec<AnyElement>) = match &self.kind {
            ApprovalKind::Tool { tool, preview } => (
                IconName::ShieldAlert,
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(tool.clone()),
                    )
                    .child(
                        div()
                            .id(ElementId::Name(format!("approval-preview-{id}").into()))
                            .role(Role::Code)
                            .aria_label(preview.clone())
                            .px(px(12.))
                            .py(px(9.))
                            .rounded(px(8.))
                            .border_1()
                            .border_color(r.border)
                            .bg(inset_fill(&t))
                            .font_family(MONO_FONT)
                            .text_size(px(m.code))
                            .line_height(relative(1.5))
                            .text_color(r.text)
                            .child(preview.clone()),
                    )
                    .into_any_element(),
                vec![
                    Button::new(
                        ElementId::Name(format!("deny-{id}").into()),
                        st.deny.clone(),
                    )
                    .shortcut(DENY_KEYS)
                    .into_any_element(),
                    Button::new(
                        ElementId::Name(format!("always-{id}").into()),
                        st.always_allow.clone(),
                    )
                    .into_any_element(),
                    Button::new(
                        ElementId::Name(format!("allow-{id}").into()),
                        st.allow_once.clone(),
                    )
                    .primary()
                    .shortcut(ALLOW_KEYS)
                    .into_any_element(),
                ],
            ),
            ApprovalKind::Select { options, selected } => {
                let count = options.len();
                // One key-view stop, as a radio group: Tab reaches it, the
                // arrows choose, and the chosen option rings.
                let group_id = ElementId::Name(format!("approval-options-{id}").into());
                let focus = full_keyboard_access(cx)
                    .then(|| control_focus_handle(&group_id, window, cx).tab_stop(true));
                let focused = focus.as_ref().is_some_and(|f| f.is_focused(window));
                let keys = radio_keys(*selected, count, on_option.clone());
                (
                    IconName::ListChecks,
                    div()
                        .id(group_id)
                        .role(Role::RadioGroup)
                        .aria_label(self.title.clone())
                        .when_some(focus, |d, focus| {
                            d.track_focus(&focus)
                                .on_any_mouse_down(|_, window, _| window.prevent_default())
                                .on_key_down(keys)
                        })
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .children(options.iter().enumerate().map(|(i, o)| {
                            let on = i == *selected;
                            div()
                                .id(ElementId::Name(format!("approval-option-{id}-{i}").into()))
                                .role(Role::RadioButton)
                                .aria_label(o.label.clone())
                                .aria_selected(on)
                                .aria_position_in_set(i + 1)
                                .aria_size_of_set(count)
                                .when(on && focused, |d| d.aria_active_descendant())
                                .min_h(px(m.row_height + 10.))
                                .px(px(10.))
                                .py(px(6.))
                                .flex()
                                .items_center()
                                .gap(px(10.))
                                .rounded(px(8.))
                                .when(on, |d| d.bg(r.selected))
                                .when(!on, |d| d.hover(|s| s.bg(r.hover)))
                                .active(|s| s.bg(pressed_fill(r.hover, &t)))
                                .cursor_pointer()
                                .relative()
                                .when(on && focused, |d| {
                                    d.child(ring_overlay(Ring::Inset(8.), &t))
                                })
                                .on_any_mouse_down(|_, window, _| window.prevent_default())
                                .child(radio_dot(on, &t))
                                .child(
                                    div()
                                        .flex_1()
                                        .flex()
                                        .flex_col()
                                        .child(
                                            div()
                                                .text_size(px(m.control))
                                                .text_color(r.text)
                                                .child(o.label.clone()),
                                        )
                                        .when_some(o.detail.clone(), |d, s| {
                                            d.child(
                                                div()
                                                    .text_size(px(m.small))
                                                    .text_color(r.text_subtle)
                                                    .child(s),
                                            )
                                        }),
                                )
                                .on_click({
                                    let handler = on_option.clone();
                                    move |_, window, cx| {
                                        if let Some(h) = &handler {
                                            h(i, window, cx)
                                        }
                                    }
                                })
                        }))
                        .into_any_element(),
                    vec![
                        Button::new(
                            ElementId::Name(format!("cancel-{id}").into()),
                            st.cancel.clone(),
                        )
                        .shortcut(DENY_KEYS)
                        .into_any_element(),
                        Button::new(
                            ElementId::Name(format!("submit-{id}").into()),
                            st.submit.clone(),
                        )
                        .primary()
                        .shortcut(ALLOW_KEYS)
                        .into_any_element(),
                    ],
                )
            }
            ApprovalKind::Question {
                question,
                options,
                selected,
                other,
                other_selected,
            } => {
                let count = options.len() + usize::from(other.is_some());
                let group_id = ElementId::Name(format!("approval-question-{id}").into());
                let focus = full_keyboard_access(cx)
                    .then(|| control_focus_handle(&group_id, window, cx).tab_stop(true));
                let focused = focus.as_ref().is_some_and(|f| f.is_focused(window));
                // The arrows walk the choices; the own-words field is the
                // last stop of the group.
                let current = if *other_selected {
                    Some(options.len())
                } else {
                    *selected
                };
                let keys = question_keys(current, count, on_option.clone());
                let row = |i: usize,
                           on: bool,
                           label: SharedString,
                           detail: Option<SharedString>,
                           extra: Option<AnyElement>| {
                    div()
                        .id(ElementId::Name(format!("approval-choice-{id}-{i}").into()))
                        .role(Role::RadioButton)
                        .aria_label(match &detail {
                            Some(d) => SharedString::from(format!("{label}. {d}")),
                            None => label.clone(),
                        })
                        .aria_selected(on)
                        .aria_position_in_set(i + 1)
                        .aria_size_of_set(count)
                        .when(on && focused, |d| d.aria_active_descendant())
                        .min_h(px(m.row_height + 10.))
                        .px(px(10.))
                        .py(px(6.))
                        .flex()
                        .items_center()
                        .gap(px(10.))
                        .rounded(px(8.))
                        .when(on, |d| d.bg(r.selected))
                        .when(!on, |d| d.hover(|s| s.bg(r.hover)))
                        .cursor_pointer()
                        .relative()
                        .when(on && focused, |d| {
                            d.child(ring_overlay(Ring::Inset(8.), &t))
                        })
                        .child(radio_dot(on, &t))
                        .child(match extra {
                            Some(field) => field,
                            None => div()
                                .flex_1()
                                .flex()
                                .flex_col()
                                .child(
                                    div()
                                        .text_size(px(m.control))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(r.text)
                                        .child(label.clone()),
                                )
                                .when_some(detail.clone(), |d, s| {
                                    d.child(
                                        div()
                                            .text_size(px(m.small))
                                            .text_color(r.text_subtle)
                                            .child(s),
                                    )
                                })
                                .into_any_element(),
                        })
                        .on_click({
                            let handler = on_option.clone();
                            move |_, window, cx| {
                                if let Some(h) = &handler {
                                    h(i, window, cx)
                                }
                            }
                        })
                };
                let mut rows: Vec<AnyElement> = options
                    .iter()
                    .enumerate()
                    .map(|(i, o)| {
                        row(
                            i,
                            !*other_selected && *selected == Some(i),
                            o.label.clone(),
                            o.detail.clone(),
                            None,
                        )
                        .on_any_mouse_down(|_, window, _| window.prevent_default())
                        .into_any_element()
                    })
                    .collect();
                if let Some((state, label)) = other {
                    let field = field_frame(false, m.control_height + 4., cx)
                        .flex_1()
                        .child(
                            div()
                                .flex_1()
                                .child(bare_input(state, label.clone(), m.control)),
                        )
                        .into_any_element();
                    rows.push(
                        row(
                            options.len(),
                            *other_selected,
                            label.clone(),
                            None,
                            Some(field),
                        )
                        .into_any_element(),
                    );
                }
                (
                    IconName::MessageSquare,
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .when(!question.is_empty(), |d| {
                            d.child(
                                div()
                                    .text_size(px(m.control))
                                    .line_height(relative(1.4))
                                    .text_color(r.text)
                                    .child(question.clone()),
                            )
                        })
                        .child(
                            div()
                                .id(group_id)
                                .role(Role::RadioGroup)
                                .aria_label(question.clone())
                                .when_some(focus, |d, focus| {
                                    d.track_focus(&focus).on_key_down(keys)
                                })
                                .max_h(px(320.))
                                .overflow_y_scroll()
                                .flex()
                                .flex_col()
                                .gap(px(2.))
                                .children(rows),
                        )
                        .into_any_element(),
                    vec![
                        Button::new(
                            ElementId::Name(format!("cancel-{id}").into()),
                            st.cancel.clone(),
                        )
                        .shortcut(DENY_KEYS)
                        .into_any_element(),
                        Button::new(
                            ElementId::Name(format!("submit-{id}").into()),
                            st.submit.clone(),
                        )
                        .primary()
                        .shortcut(ALLOW_KEYS)
                        .into_any_element(),
                    ],
                )
            }
            ApprovalKind::Message => (
                IconName::ShieldAlert,
                div().into_any_element(),
                vec![
                    Button::new(
                        ElementId::Name(format!("deny-{id}").into()),
                        st.deny.clone(),
                    )
                    .shortcut(DENY_KEYS)
                    .into_any_element(),
                    Button::new(
                        ElementId::Name(format!("allow-{id}").into()),
                        st.allow.clone(),
                    )
                    .primary()
                    .shortcut(ALLOW_KEYS)
                    .into_any_element(),
                ],
            ),
            ApprovalKind::Input { state, label } => (
                IconName::MessageSquare,
                field_frame(false, m.control_height + 4., cx)
                    .child(
                        div()
                            .flex_1()
                            .child(bare_input(state, label.clone(), m.control)),
                    )
                    .into_any_element(),
                vec![
                    Button::new(
                        ElementId::Name(format!("cancel-{id}").into()),
                        st.cancel.clone(),
                    )
                    .shortcut(DENY_KEYS)
                    .into_any_element(),
                    Button::new(
                        ElementId::Name(format!("submit-{id}").into()),
                        st.submit.clone(),
                    )
                    .primary()
                    .shortcut(ALLOW_KEYS)
                    .into_any_element(),
                ],
            ),
            ApprovalKind::Code { caption, code } => (
                IconName::ShieldAlert,
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(caption.clone()),
                    )
                    .when(!code.is_empty(), |d| {
                        d.child(
                            div()
                                .id(ElementId::Name(format!("approval-code-{id}").into()))
                                .role(Role::Code)
                                .aria_label(code.clone())
                                .max_h(px(160.))
                                .overflow_y_scroll()
                                .px(px(12.))
                                .py(px(9.))
                                .rounded(px(8.))
                                .border_1()
                                .border_color(r.border)
                                .bg(inset_fill(&t))
                                .font_family(MONO_FONT)
                                .text_size(px(m.code))
                                .line_height(relative(1.5))
                                .text_color(r.text)
                                .child(code.clone()),
                        )
                    })
                    .into_any_element(),
                vec![
                    Button::new(
                        ElementId::Name(format!("deny-{id}").into()),
                        st.deny.clone(),
                    )
                    .shortcut(DENY_KEYS)
                    .into_any_element(),
                    Button::new(
                        ElementId::Name(format!("allow-{id}").into()),
                        st.allow_once.clone(),
                    )
                    .primary()
                    .shortcut(ALLOW_KEYS)
                    .into_any_element(),
                ],
            ),
        };
        let tile = self.tile.unwrap_or(tile);
        let buttons = match self.actions {
            Some(actions) => render_actions(actions),
            None => buttons,
        };
        // A tool called with no arguments has no input to show: no caption
        // over an empty box.
        let has_body = self.body.is_some()
            || match &self.kind {
                ApprovalKind::Message => false,
                ApprovalKind::Code { code, .. } => !code.is_empty(),
                _ => true,
            };
        let body = self.body.unwrap_or(body);
        // Docked on the composer, it is drawn as the composer is: the same
        // fill, outline, corner radius and shadow (and, docked, its width),
        // so the two read as one stack. The request's glyph is neutral, as
        // the answer header's: tint is kept for what is destructive or done.
        let frame = composer_frame(&t);
        let place = |(c, n): (usize, usize)| {
            fill(
                &st.position,
                &[("index", &c.to_string()), ("count", &n.to_string())],
            )
        };
        let spoken = match (self.step, self.queue) {
            (Some(_), Some(at)) => format!("{}: {}, {}", self.title, self.detail, place(at)),
            _ => format!("{}: {}", self.title, self.detail),
        };
        div()
            .id(ElementId::Name(format!("approval-{id}").into()))
            .role(Role::AlertDialog)
            .aria_label(format!("{}: {}", self.title, self.detail))
            // Said when it appears over the composer, as the phone's prompt
            // surface is: the focus stays where the user was typing. A
            // request's questions are each said with their place.
            .child(
                crate::announce::live_text(
                    "live",
                    Some(spoken.into()),
                    crate::announce::Priority::High,
                )
                .attempt(self.step.map_or(0, |i| i as u64)),
            )
            .w_full()
            .flex()
            .flex_col()
            .gap(px(12.))
            .p(px(16.))
            .rounded(px(frame.radius))
            .border_1()
            .border_color(frame.border)
            .bg(frame.fill)
            .shadow(frame.shadow)
            .child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(10.))
                    .child(icon_tile(
                        tile,
                        30.,
                        with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }),
                        r.text_subtle,
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
                                    .text_size(px(m.control + 1.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(r.text)
                                    .child(self.title.clone()),
                            )
                            .when(!self.detail.is_empty(), |d| {
                                d.child(
                                    div()
                                        .text_size(px(m.small))
                                        .line_height(relative(1.4))
                                        .text_color(r.text_subtle)
                                        .child(self.detail.clone()),
                                )
                            }),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .text_size(px(m.caption))
                            .text_color(r.text_subtle)
                            .when_some(self.queue, |d, at| d.child(SharedString::from(place(at))))
                            .child(self.source.clone()),
                    ),
            )
            .when(has_body, |d| d.child(div().pl(px(40.)).child(body)))
            .when_some(self.note, |d, note| {
                d.child(
                    div()
                        .pl(px(40.))
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(note),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .justify_end()
                    .gap(px(8.))
                    .children(buttons),
            )
    }
}

#[cfg(test)]
mod question_tests {
    use super::question_step;

    #[test]
    fn with_nothing_chosen_the_keys_start_at_the_first_answer() {
        // Nothing chosen: Down, Right or Home choose the first, End the last.
        assert_eq!(question_step("down", None, 3), Some(0));
        assert_eq!(question_step("right", None, 3), Some(0));
        assert_eq!(question_step("home", None, 3), Some(0));
        assert_eq!(question_step("end", None, 3), Some(2));
        assert_eq!(question_step("down", None, 0), None);
        // Chosen: as any radio group.
        assert_eq!(question_step("down", Some(0), 3), Some(1));
        assert_eq!(question_step("home", Some(2), 3), Some(0));
        assert_eq!(question_step("up", Some(0), 3), None);
    }
}
