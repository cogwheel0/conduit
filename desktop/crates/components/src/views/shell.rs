//! The main window's frame: sidebar, unified toolbar, chat column, and the
//! empty-chat greeting.

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, Role, SharedString, Stateful, Window, div,
    linear_color_stop, linear_gradient, px, relative,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, ToolbarLayout, UI_FONT, with_alpha};
use crate::views::focus::{ControlExt as _, Ring};
use crate::views::kit::{IconButton, heading};
use crate::window::{TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region};

/// Width of the chat column's text.
pub const CHAT_COLUMN: f32 = 720.;

/// The window frame: an optional sidebar beside a content column. Overlays
/// (palette, menus, toasts) are drawn above both.
#[derive(IntoElement)]
pub struct MainWindowFrame {
    sidebar: Option<AnyElement>,
    /// How much of the sidebar shows (0…1) while it slides in or out.
    sidebar_reveal: f32,
    content: AnyElement,
    overlays: Vec<AnyElement>,
}

impl MainWindowFrame {
    pub fn new(content: impl IntoElement) -> Self {
        Self {
            sidebar: None,
            sidebar_reveal: 1.,
            content: content.into_any_element(),
            overlays: vec![],
        }
    }
    pub fn sidebar(mut self, sidebar: impl IntoElement) -> Self {
        self.sidebar = Some(sidebar.into_any_element());
        self
    }
    /// Draws `reveal` (0…1) of the sidebar's width: it slides out to the
    /// leading edge, and the content beside it reflows into the room.
    pub fn sidebar_reveal(mut self, reveal: f32) -> Self {
        self.sidebar_reveal = reveal.clamp(0., 1.);
        self
    }
    pub fn overlay(mut self, overlay: impl IntoElement) -> Self {
        self.overlays.push(overlay.into_any_element());
        self
    }
}

impl RenderOnce for MainWindowFrame {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit();
        let st = cx.strings().clone();
        let r = t.roles;
        let has_sidebar = self.sidebar.is_some();
        let width = t.metrics.sidebar_width;
        let shown = width * self.sidebar_reveal;
        let sidebar = self.sidebar.map(|sidebar| {
            if self.sidebar_reveal >= 1. {
                return sidebar;
            }
            // A clip as wide as what shows, the sidebar sliding in it and
            // fading as it goes, so its toolbar buttons are gone before
            // they pass under the traffic lights.
            let fade = ((self.sidebar_reveal - 0.25) / 0.75).clamp(0., 1.);
            div()
                .id("sidebar-slide")
                .flex_none()
                .h_full()
                .w(px(shown))
                .overflow_hidden()
                .relative()
                .child(
                    div()
                        .absolute()
                        .top_0()
                        .bottom_0()
                        .left(px(shown - width))
                        .w(px(width))
                        .opacity(fade)
                        .child(sidebar),
                )
                .into_any_element()
        });
        div()
            .relative()
            .size_full()
            .flex()
            .flex_row()
            .font_family(UI_FONT)
            .text_size(px(t.metrics.body))
            .text_color(r.text)
            .children(sidebar)
            .child(
                div()
                    .id("content")
                    .role(Role::Main)
                    .aria_label(st.conversation.clone())
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .bg(r.content)
                    .when(has_sidebar, |d| d.border_l_1().border_color(r.divider))
                    .child(self.content),
            )
            .children(self.overlays)
    }
}

/// The model picker's trigger.
#[derive(IntoElement)]
pub struct ModelPickerButton {
    model: SharedString,
    /// The smaller chip used in the composer footer.
    compact: bool,
    open: bool,
    label: Option<SharedString>,
    on_click: Option<crate::views::kit::ClickHandler>,
}

impl ModelPickerButton {
    pub fn new(model: impl Into<SharedString>) -> Self {
        Self {
            model: model.into(),
            compact: false,
            open: false,
            label: None,
            on_click: None,
        }
    }
    /// What VoiceOver reads (default "Model: <name>").
    pub fn label(mut self, label: impl Into<SharedString>) -> Self {
        self.label = Some(label.into());
        self
    }
    pub fn on_click(mut self, handler: crate::views::kit::ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
    pub fn compact(mut self) -> Self {
        self.compact = true;
        self
    }
    pub fn open(mut self, open: bool) -> Self {
        self.open = open;
        self
    }
}

impl RenderOnce for ModelPickerButton {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let shortcut = crate::views::focus::hints(cx).model_picker;
        div()
            .id(if self.compact {
                "model-picker-composer"
            } else {
                "model-picker"
            })
            .role(Role::Button)
            .aria_label(
                self.label
                    .clone()
                    .unwrap_or_else(|| format!("Model: {}", self.model).into()),
            )
            .aria_expanded(self.open)
            .h(px(if self.compact { 26. } else { 30. }))
            .px(px(8.))
            .flex()
            .flex_none()
            .items_center()
            .gap(px(5.))
            .rounded(t.control_radius())
            .when(self.open, |d| d.bg(r.selected))
            .hover(|s| s.bg(r.hover))
            .active(|s| s.bg(crate::views::focus::pressed_fill(r.hover, &t)))
            .cursor_pointer()
            .when_some(shortcut.clone(), |d, k| d.aria_keyshortcuts(k))
            .when(self.compact, |d| {
                d.child(icon(IconName::Sparkles, 13., r.text_subtle))
            })
            .child(
                div()
                    .text_size(px(if self.compact {
                        m.small
                    } else {
                        m.control + 1.
                    }))
                    .font_weight(if self.compact {
                        FontWeight::MEDIUM
                    } else {
                        FontWeight::SEMIBOLD
                    })
                    .text_color(if self.compact { r.text_subtle } else { r.text })
                    .child(self.model),
            )
            .child(icon(
                IconName::ChevronDown,
                if self.compact { 12. } else { 13. },
                r.text_subtle,
            ))
            .on_click(crate::views::kit::on_click_or_noop(self.on_click))
            .keyboard_control(Ring::Outset(f32::from(t.control_radius())), window, cx)
    }
}

/// A capsule that groups toolbar controls, as the phone's glass clusters
/// and macOS 26's toolbar items: a light fill, a hairline and a soft shadow.
pub fn toolbar_capsule(t: &crate::ConduitTheme) -> Div {
    let r = t.roles;
    div()
        .flex()
        .items_center()
        .rounded_full()
        .border_1()
        .border_color(with_alpha(r.border, if t.dark { 0.9 } else { 0.8 }))
        .bg(crate::views::kit::raised_fill(t))
        .shadow(vec![gpui_kit::BoxShadow {
            color: with_alpha(gpui_kit::black(), if t.dark { 0.35 } else { 0.06 }),
            offset: gpui_kit::point(px(0.), px(1.)),
            blur_radius: px(4.),
            spread_radius: px(0.),
            inset: false,
        }])
}

/// The phone's header capsule: the chat's title over its model, or the
/// model alone in a new chat, centred in the toolbar. It opens the model
/// picker.
#[derive(IntoElement)]
pub struct TitlePill {
    title: Option<SharedString>,
    /// The title it had, crossfading out (with how far, 0…1).
    previous: Option<(SharedString, f32)>,
    model: SharedString,
    label: SharedString,
    open: bool,
    on_click: Option<crate::views::kit::ClickHandler>,
    /// A Hermes bot's face: the capsule names the bot, whose chat runs on
    /// its own model (no picker).
    face: Option<AnyElement>,
}

impl TitlePill {
    pub fn new(model: impl Into<SharedString>, label: impl Into<SharedString>) -> Self {
        Self {
            title: None,
            previous: None,
            model: model.into(),
            label: label.into(),
            open: false,
            on_click: None,
            face: None,
        }
    }
    /// A bot's chat: its face before its name (the model), and no picker.
    pub fn face(mut self, face: AnyElement) -> Self {
        self.face = Some(face);
        self
    }
    /// The chat's title, drawn over the model.
    pub fn title(mut self, title: Option<SharedString>) -> Self {
        self.title = title.filter(|t| !t.is_empty());
        self
    }
    /// The title it had until now, `progress` (0…1) of the way through a
    /// crossfade into the new one (a chat named after its first answer).
    pub fn previous(mut self, previous: Option<(SharedString, f32)>) -> Self {
        self.previous = previous.filter(|(t, p)| !t.is_empty() && *p < 1.);
        self
    }
    pub fn open(mut self, open: bool) -> Self {
        self.open = open;
        self
    }
    pub fn on_click(mut self, handler: crate::views::kit::ClickHandler) -> Self {
        self.on_click = Some(handler);
        self
    }
}

impl RenderOnce for TitlePill {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        if let Some(face) = self.face {
            // The phone's bot header: the bot's face and name, nothing to
            // pick.
            return toolbar_capsule(&t)
                .id("bot-title")
                .role(Role::Heading)
                .aria_label(self.label)
                .min_h(px(32.))
                .max_w(px(420.))
                .pl(px(8.))
                .pr(px(16.))
                .flex()
                .items_center()
                .gap(px(8.))
                .child(face)
                .child(
                    div()
                        .truncate()
                        .text_size(px(m.control))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(self.model),
                )
                .into_any_element();
        }
        let has_title = self.title.is_some();
        toolbar_capsule(&t)
            .id("model-picker")
            .role(Role::Button)
            .aria_label(self.label)
            // The title is read after the model the capsule picks.
            .when_some(self.title.clone(), |d, title| d.aria_description(title))
            .aria_expanded(self.open)
            .min_h(px(if has_title { 36. } else { 30. }))
            .py(px(3.))
            .max_w(px(420.))
            .px(px(16.))
            .flex_col()
            .justify_center()
            .cursor_pointer()
            .when(self.open, |d| {
                d.bg(crate::theme::composite(r.selected, r.content))
            })
            .hover(|s| s.bg(crate::theme::composite(r.hover, r.content)))
            .active(|s| {
                s.bg(crate::theme::composite(
                    crate::views::focus::pressed_fill(r.hover, &t),
                    r.content,
                ))
            })
            .when_some(self.title, |d, title| {
                let line = |text: SharedString| {
                    div()
                        .max_w_full()
                        .truncate()
                        .text_size(px(m.control))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(text)
                };
                match self.previous {
                    // The new title fades in where the old one fades out,
                    // centred on the same line (the capsule takes the new
                    // one's width).
                    Some((old, p)) => d.child(
                        div()
                            .relative()
                            .max_w_full()
                            .flex()
                            .justify_center()
                            .child(line(title).opacity(p))
                            .child(
                                div()
                                    .absolute()
                                    .top_0()
                                    .left_0()
                                    .right_0()
                                    .flex()
                                    .justify_center()
                                    .opacity(1. - p)
                                    .child(line(old)),
                            ),
                    ),
                    None => d.child(line(title)),
                }
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(3.))
                    .child(
                        div()
                            .truncate()
                            .text_size(px(if has_title { m.caption } else { m.control }))
                            .font_weight(if has_title {
                                FontWeight::NORMAL
                            } else {
                                FontWeight::MEDIUM
                            })
                            .text_color(if has_title { r.text_subtle } else { r.text })
                            .child(self.model),
                    )
                    .child(icon(
                        IconName::ChevronDown,
                        if has_title { 10. } else { 12. },
                        r.text_subtle,
                    )),
            )
            .on_click(crate::views::kit::on_click_or_noop(self.on_click))
            .keyboard_control(Ring::Outset(18.), window, cx)
            .into_any_element()
    }
}

/// The content column's toolbar, per [`ToolbarLayout`].
#[derive(IntoElement)]
pub struct ChatToolbar {
    title: SharedString,
    model: SharedString,
    /// Draw a hairline under the toolbar (content scrolled beneath it).
    scrolled: bool,
    temporary: bool,
    /// Leave room for the traffic lights (no sidebar).
    inset_for_traffic_lights: bool,
    picker_open: bool,
    /// Without the trailing buttons (the app draws its own).
    bare: bool,
    /// A control before the title (the app's Show sidebar button when the
    /// sidebar is hidden).
    leading: Option<AnyElement>,
    /// While the sidebar slides: the leading padding (the traffic lights'
    /// room left uncovered) and how far the leading control has faded in.
    leading_reveal: Option<(f32, f32)>,
    /// A short status beside the trailing edge ("Read-only" for a chat
    /// shared with the user).
    note: Option<SharedString>,
    /// The centred capsule ([`ToolbarLayout::Pill`]).
    pill: Option<AnyElement>,
    /// Controls at the trailing edge, grouped in one capsule.
    trailing: Vec<AnyElement>,
}

impl ChatToolbar {
    pub fn new(title: impl Into<SharedString>, model: impl Into<SharedString>) -> Self {
        Self {
            title: title.into(),
            model: model.into(),
            scrolled: false,
            temporary: false,
            inset_for_traffic_lights: false,
            picker_open: false,
            bare: false,
            leading: None,
            leading_reveal: None,
            note: None,
            pill: None,
            trailing: vec![],
        }
    }
    /// The centred title capsule ([`TitlePill`]).
    pub fn pill(mut self, pill: impl IntoElement) -> Self {
        self.pill = Some(pill.into_any_element());
        self
    }
    /// A control at the trailing edge; they share one capsule.
    pub fn trailing(mut self, control: impl IntoElement) -> Self {
        self.trailing.push(control.into_any_element());
        self
    }
    /// A short status pill at the trailing edge, read out as a status.
    pub fn note(mut self, label: impl Into<SharedString>) -> Self {
        self.note = Some(label.into());
        self
    }
    /// A control before the title, after the traffic lights' inset.
    pub fn leading(mut self, control: impl IntoElement) -> Self {
        self.leading = Some(control.into_any_element());
        self
    }
    /// Leaves out the temporary/share/more buttons.
    pub fn bare(mut self) -> Self {
        self.bare = true;
        self
    }
    pub fn scrolled(mut self, scrolled: bool) -> Self {
        self.scrolled = scrolled;
        self
    }
    pub fn temporary(mut self, temporary: bool) -> Self {
        self.temporary = temporary;
        self
    }
    pub fn inset_for_traffic_lights(mut self) -> Self {
        self.inset_for_traffic_lights = true;
        self
    }
    /// While the sidebar slides over the traffic lights: `inset` points of
    /// leading padding and the leading control at `opacity`.
    pub fn leading_reveal(mut self, inset: f32, opacity: f32) -> Self {
        self.leading_reveal = Some((inset, opacity.clamp(0., 1.)));
        self
    }
    pub fn picker_open(mut self, open: bool) -> Self {
        self.picker_open = open;
        self
    }
}

impl RenderOnce for ChatToolbar {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let has_title = !self.title.is_empty();
        if t.prefs.toolbar == ToolbarLayout::Pill {
            let pill = self.pill.unwrap_or_else(|| {
                TitlePill::new(self.model.clone(), format!("Model: {}", self.model))
                    .title(has_title.then(|| self.title.clone()))
                    .open(self.picker_open)
                    .into_any_element()
            });
            let trailing: Vec<AnyElement> = if self.bare || !self.trailing.is_empty() {
                self.trailing
            } else {
                vec![
                    IconButton::new("new-chat-toolbar", IconName::SquarePen, st.new_chat.clone())
                        .size(30., 16.)
                        .round()
                        .into_any_element(),
                    IconButton::new("chat-more", IconName::Ellipsis, st.more.clone())
                        .size(30., 16.)
                        .round()
                        .into_any_element(),
                ]
            };
            return drag_region("chat-toolbar")
                .role(Role::Toolbar)
                .aria_label(st.chat_toolbar.clone())
                .relative()
                .h(px(TOOLBAR_HEIGHT))
                .flex_none()
                .flex()
                .items_center()
                .gap(px(8.))
                .pl(px(match self.leading_reveal {
                    Some((inset, _)) => inset,
                    None if self.inset_for_traffic_lights => TRAFFIC_LIGHTS_WIDTH + 8.,
                    None => 10.,
                }))
                .pr(px(10.))
                .when(self.scrolled, |d| d.border_b_1().border_color(r.divider))
                .when_some(self.leading, |d, leading| {
                    let opacity = self.leading_reveal.map_or(1., |(_, o)| o);
                    d.child(
                        toolbar_capsule(&t)
                            .p(px(2.))
                            .opacity(opacity)
                            .child(leading),
                    )
                })
                // The capsule sits at the toolbar's centre whatever is at
                // its ends, as the phone's header does. It is drawn between
                // the two ends, so Tab reaches the toolbar left to right.
                .child(
                    div()
                        .absolute()
                        .top_0()
                        .bottom_0()
                        .left(px(120.))
                        .right(px(120.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(pill),
                )
                .child(div().flex_1())
                // A status, not a control: the glyph and words in the
                // secondary tone, with no fill or outline to press.
                .when_some(self.note, |d, note| {
                    d.child(
                        div()
                            .id("chat-note")
                            .role(Role::Status)
                            .aria_label(note.clone())
                            .h(px(24.))
                            .px(px(4.))
                            .flex()
                            .items_center()
                            .gap(px(5.))
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(icon(IconName::Lock, 12., r.text_subtle))
                            .child(note),
                    )
                })
                .when(!trailing.is_empty(), |d| {
                    d.child(toolbar_capsule(&t).p(px(2.)).gap(px(2.)).children(trailing))
                })
                .into_any_element();
        }
        let leading: AnyElement = match t.prefs.toolbar {
            ToolbarLayout::Pill => unreachable!("drawn above"),
            ToolbarLayout::Model => div()
                .flex()
                .items_center()
                .min_w_0()
                .gap(px(4.))
                .child(ModelPickerButton::new(self.model.clone()).open(self.picker_open))
                .when(has_title, |d| {
                    d.child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(px(m.control))
                            .text_color(r.text_subtle)
                            .child(self.title.clone()),
                    )
                })
                .into_any_element(),
            ToolbarLayout::Title => div()
                .min_w_0()
                .px(px(6.))
                .truncate()
                .text_size(px(m.control + 1.))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(if has_title { r.text } else { r.text_subtle })
                .child(if has_title {
                    self.title.clone()
                } else {
                    st.new_chat.clone()
                })
                .into_any_element(),
        };
        drag_region("chat-toolbar")
            .role(Role::Toolbar)
            .aria_label(st.chat_toolbar.clone())
            .h(px(TOOLBAR_HEIGHT))
            .flex_none()
            .flex()
            .items_center()
            .gap(px(8.))
            .pl(px(if self.inset_for_traffic_lights {
                TRAFFIC_LIGHTS_WIDTH + 8.
            } else {
                10.
            }))
            .pr(px(12.))
            .when(self.scrolled, |d| d.border_b_1().border_color(r.divider))
            .children(self.leading)
            .child(leading)
            .child(div().flex_1())
            .when_some(self.note, |d, note| {
                d.child(
                    div()
                        .id("chat-note")
                        .role(Role::Status)
                        .aria_label(note.clone())
                        .h(px(24.))
                        .px(px(8.))
                        .flex()
                        .items_center()
                        .gap(px(5.))
                        .rounded_full()
                        .bg(r.selected)
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(icon(IconName::Users, 13., r.text_subtle))
                        .child(note),
                )
            })
            .when(self.bare && self.temporary, |d| {
                d.child(
                    div()
                        .id("temporary-badge")
                        .role(Role::Status)
                        .aria_label(st.temporary_chat.clone())
                        .h(px(24.))
                        .px(px(8.))
                        .flex()
                        .items_center()
                        .gap(px(5.))
                        .rounded_full()
                        .bg(r.selected)
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(icon(IconName::ClockFading, 13., r.text_subtle))
                        .child(st.temporary_chat.clone()),
                )
            })
            .when(!self.bare, |d| {
                d.child(
                    IconButton::new(
                        "temporary-chat",
                        IconName::ClockFading,
                        st.temporary_chat.clone(),
                    )
                    .active(self.temporary),
                )
                .child(IconButton::new(
                    "share-chat",
                    IconName::Share,
                    st.share_chat.clone(),
                ))
                .child(IconButton::new(
                    "chat-more",
                    IconName::Ellipsis,
                    st.more.clone(),
                ))
            })
            .into_any_element()
    }
}

/// A transcript column: messages in a centred column that start at the top
/// while they fit and keep the newest at the bottom once they do not (as the
/// app's transcript), the composer docked below with a fade, and an optional
/// card docked above the composer (approvals).
#[derive(IntoElement)]
pub struct ChatColumn {
    messages: Vec<AnyElement>,
    composer: AnyElement,
    docked: Option<AnyElement>,
}

impl ChatColumn {
    pub fn new(messages: Vec<AnyElement>, composer: impl IntoElement) -> Self {
        Self {
            messages,
            composer: composer.into_any_element(),
            docked: None,
        }
    }
    pub fn docked(mut self, card: impl IntoElement) -> Self {
        self.docked = Some(card.into_any_element());
        self
    }
}

impl RenderOnce for ChatColumn {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit();
        let st = cx.strings().clone();
        let r = t.roles;
        let content = r.content;
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("transcript")
                    .role(Role::Log)
                    .aria_label(st.messages.clone())
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .justify_end()
                    .items_center()
                    .px(px(32.))
                    // At least as tall as the column: short, the messages
                    // sit at its top; taller, `justify_end` keeps its end
                    // in view and the top is clipped.
                    .child(
                        div()
                            .w_full()
                            .max_w(px(CHAT_COLUMN))
                            .min_h(relative(1.))
                            .flex_none()
                            .flex()
                            .flex_col()
                            .gap(px(24.))
                            .pt(px(28.))
                            .pb(px(16.))
                            .children(self.messages),
                    )
                    // Earlier messages slide under the toolbar through a
                    // fade rather than a hard cut.
                    .child(div().absolute().top_0().left_0().right_0().h(px(28.)).bg(
                        linear_gradient(
                            180.,
                            linear_color_stop(content, 0.),
                            linear_color_stop(with_alpha(content, 0.), 1.),
                        ),
                    )),
            )
            .child(
                div()
                    .relative()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .items_center()
                    .px(px(32.))
                    .pb(px(18.))
                    .child(
                        div()
                            .absolute()
                            .top(px(-24.))
                            .left_0()
                            .right_0()
                            .h(px(24.))
                            .bg(linear_gradient(
                                180.,
                                linear_color_stop(with_alpha(content, 0.), 0.),
                                linear_color_stop(content, 1.),
                            )),
                    )
                    .child(
                        div()
                            .w_full()
                            .max_w(px(CHAT_COLUMN + 40.))
                            .flex()
                            .flex_col()
                            .gap(px(8.))
                            .children(self.docked)
                            .child(self.composer),
                    ),
            )
    }
}

/// The empty chat as the phone draws it: the greeting in the middle of the
/// page and the composer at the bottom, where every chat has it. (The
/// phone offers no starter prompts; `suggestions` are not drawn.)
pub fn empty_chat(
    greeting: impl Into<SharedString>,
    composer: impl IntoElement,
    _suggestions: Vec<(IconName, SharedString)>,
    cx: &App,
) -> Div {
    let t = cx.conduit().clone();
    let r = t.roles;
    div()
        .flex_1()
        .min_h_0()
        .flex()
        .flex_col()
        .child(
            div()
                .flex_1()
                .min_h_0()
                .flex()
                .items_center()
                .justify_center()
                .px(px(32.))
                .child(heading(
                    "greeting",
                    greeting,
                    1,
                    28.,
                    FontWeight::BOLD,
                    r.text,
                )),
        )
        .child(
            div()
                .flex_none()
                .flex()
                .justify_center()
                .px(px(32.))
                .pb(px(16.))
                .child(div().w_full().max_w(px(CHAT_COLUMN + 40.)).child(composer)),
        )
}

#[allow(dead_code)]
fn suggestion_pill(
    i: usize,
    ic: IconName,
    label: SharedString,
    t: &crate::ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    div()
        .id(ElementId::NamedInteger("suggestion".into(), i as u64))
        .role(Role::Button)
        .aria_label(label.clone())
        .h(px(32.))
        .px(px(12.))
        .flex()
        .items_center()
        .gap(px(7.))
        .rounded_full()
        .border_1()
        .border_color(r.border)
        .bg(r.content)
        .cursor_pointer()
        .hover(|s| s.bg(r.hover))
        .text_size(px(t.metrics.control))
        .text_color(r.text_subtle)
        .child(icon(ic, 14., r.text_subtle))
        .child(label)
        .on_click(|_, _, _| {})
}
