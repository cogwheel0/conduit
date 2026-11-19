//! Messages. Each one is a labelled `Role::Article` whose label carries the
//! message text, because a bare TextView is invisible to VoiceOver.

use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, ElementId, Entity, FontWeight, Role, SharedString, Window, div, px,
    relative,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, ConduitTheme, UserMessageStyle, with_alpha};
use crate::views::blocks;
use crate::views::kit::{IconButton, avatar, icon_tile};
use crate::views::markdown::text_view;
use crate::views::model::{AssistantMessage, Attachment, Block, UserMessage};

/// Indent of message bodies, so text lines up with the author's name.
pub const BODY_INDENT: f32 = 30.;

/// The streaming caret appended to the last text block while a reply
/// streams.
const CARET: &str = "\u{2009}\u{258d}";

/// "‹ 2 / 3 ›" for regenerated replies and edited prompts.
pub fn version_switcher(id: &str, current: usize, total: usize, cx: &App) -> AnyElement {
    let t = cx.conduit();
    let st = cx.strings().clone();
    let r = t.roles;
    div()
        .id(ElementId::Name(format!("versions-{id}").into()))
        .role(Role::Group)
        .aria_label(format!("Version {current} of {total}"))
        .flex()
        .items_center()
        .gap(px(1.))
        .child(
            IconButton::new(
                ElementId::Name(format!("prev-version-{id}").into()),
                IconName::ChevronLeft,
                st.previous_version.clone(),
            )
            .size(24., 14.)
            .color(r.text_faint),
        )
        .child(
            div()
                .text_size(px(t.metrics.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(format!("{current} / {total}"))),
        )
        .child(
            IconButton::new(
                ElementId::Name(format!("next-version-{id}").into()),
                IconName::ChevronRight,
                st.next_version.clone(),
            )
            .size(24., 14.)
            .color(r.text_faint),
        )
        .into_any_element()
}

fn action(id: String, ic: IconName, label: &str, active: bool, t: &ConduitTheme) -> IconButton {
    IconButton::new(ElementId::Name(id.into()), ic, label.to_string())
        .size(26., 15.)
        .color(if active {
            t.roles.text
        } else {
            t.roles.text_faint
        })
        .active(active)
}

fn attachment_chip(a: &Attachment, id: String, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    div()
        .id(ElementId::Name(id.into()))
        .role(Role::Group)
        .aria_label(format!("Attachment {}, {}", a.name, a.detail))
        .h(px(40.))
        .max_w(px(240.))
        .pl(px(4.))
        .pr(px(10.))
        .flex()
        .items_center()
        .gap(px(8.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(crate::views::kit::raised_fill(t))
        .child(icon_tile(
            if a.image {
                IconName::Image
            } else {
                IconName::FileText
            },
            30.,
            with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }),
            r.text_subtle,
            6.,
        ))
        .child(
            div()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.small))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(r.text)
                        .child(a.name.clone()),
                )
                .child(
                    div()
                        .text_size(px(t.metrics.caption))
                        .text_color(r.text_subtle)
                        .child(a.detail.clone()),
                ),
        )
        .into_any_element()
}

/// A user message, drawn per [`UserMessageStyle`].
#[derive(IntoElement)]
pub struct UserMessageView {
    msg: UserMessage,
}

impl UserMessageView {
    pub fn new(msg: UserMessage) -> Self {
        Self { msg }
    }
}

impl RenderOnce for UserMessageView {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let msg = self.msg;
        let id = msg.id.to_string();
        let attachments: Vec<AnyElement> = msg
            .attachments
            .iter()
            .enumerate()
            .map(|(i, a)| attachment_chip(a, format!("att-{id}-{i}"), &t))
            .collect();
        let actions = |cx: &App| {
            div()
                .flex()
                .items_center()
                .gap(px(2.))
                .when_some(msg.version, |d, (c, n)| {
                    d.child(version_switcher(&id, c, n, cx))
                })
                .when(msg.show_actions, |d| {
                    d.child(action(
                        format!("copy-{id}"),
                        IconName::Copy,
                        &st.copy,
                        false,
                        &t,
                    ))
                    .child(action(
                        format!("edit-{id}"),
                        IconName::Pencil,
                        &st.edit,
                        false,
                        &t,
                    ))
                })
        };
        let label = format!("{}: {}", msg.author, msg.text);
        let article = div()
            .id(ElementId::Name(format!("message-{id}").into()))
            .role(Role::Article)
            .aria_label(SharedString::from(label))
            .w_full()
            .flex()
            .flex_col();
        match t.prefs.user_message {
            UserMessageStyle::Bubble => article
                .items_end()
                .gap(px(6.))
                .when(!attachments.is_empty(), |d| {
                    d.child(div().flex().gap(px(6.)).children(attachments))
                })
                .child(
                    div()
                        .max_w(relative(0.78))
                        .px(px(14.))
                        .py(px(9.))
                        .rounded(px(18.))
                        .bg(r.bubble)
                        .text_size(px(m.body))
                        .line_height(relative(m.leading - 0.05))
                        .text_color(r.text)
                        .child(msg.text.clone()),
                )
                .child(actions(cx)),
            UserMessageStyle::Plain => article
                .gap(px(4.))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(avatar(
                            &msg.initials,
                            22.,
                            with_alpha(r.text, if t.dark { 0.16 } else { 0.09 }),
                            r.text,
                        ))
                        .child(
                            div()
                                .text_size(px(m.control))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.text)
                                .child(msg.author.clone()),
                        )
                        .child(
                            div()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(msg.time.clone()),
                        ),
                )
                .child(
                    div()
                        .pl(px(BODY_INDENT))
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .when(!attachments.is_empty(), |d| {
                            d.child(div().flex().gap(px(6.)).children(attachments))
                        })
                        .child(
                            div()
                                .text_size(px(m.body))
                                .line_height(relative(m.leading))
                                .text_color(r.text)
                                .child(msg.text.clone()),
                        )
                        .child(div().ml(px(-6.)).child(actions(cx))),
                ),
        }
    }
}

/// An assistant reply. Owns one TextView state per text block; call
/// [`AssistantMessageView::set`] with each new `turn.blocks` snapshot.
pub struct AssistantMessageView {
    msg: AssistantMessage,
    texts: Vec<Option<Entity<TextViewState>>>,
}

impl AssistantMessageView {
    pub fn new(msg: AssistantMessage, cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            msg: msg.clone(),
            texts: vec![],
        };
        view.set(msg, cx);
        view
    }

    /// Replaces the message, reusing text states block by block so a
    /// streaming update re-lays out only what changed.
    pub fn set(&mut self, msg: AssistantMessage, cx: &mut Context<Self>) {
        let last_text = msg.blocks.iter().rposition(|b| matches!(b, Block::Text(_)));
        let mut texts = Vec::with_capacity(msg.blocks.len());
        for (i, block) in msg.blocks.iter().enumerate() {
            let Block::Text(md) = block else {
                texts.push(None);
                continue;
            };
            let mut md = md.to_string();
            if msg.streaming && Some(i) == last_text {
                md.push_str(CARET);
            }
            let state = match self.texts.get(i).cloned().flatten() {
                Some(state) => {
                    state.update(cx, |s, cx| s.set_text(&md, cx));
                    state
                }
                None => cx.new(|cx| TextViewState::markdown(&md, cx)),
            };
            texts.push(Some(state));
        }
        self.texts = texts;
        self.msg = msg;
        cx.notify();
    }

    fn spoken_text(&self, cx: &App) -> String {
        let mut out = String::new();
        for (block, state) in self.msg.blocks.iter().zip(&self.texts) {
            if let (Block::Text(_), Some(state)) = (block, state) {
                let text = state.read(cx).rendered_text().as_str().replace(CARET, "");
                if !out.is_empty() {
                    out.push(' ');
                }
                out.push_str(text.trim());
            }
        }
        out
    }
}

impl Render for AssistantMessageView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let msg = &self.msg;
        let id = msg.id.to_string();
        let mut body: Vec<AnyElement> = vec![];
        for (i, block) in msg.blocks.iter().enumerate() {
            let bid = format!("{id}-{i}");
            let el = match block {
                Block::Text(_) => match &self.texts[i] {
                    Some(state) => div()
                        .w_full()
                        .text_size(px(m.body))
                        .line_height(relative(m.leading))
                        .text_color(r.text)
                        .child(text_view(state))
                        .into_any_element(),
                    None => continue,
                },
                Block::Reasoning {
                    summary,
                    body,
                    streaming,
                    expanded,
                } => blocks::reasoning(&bid, summary, body, *streaming, *expanded, cx)
                    .into_any_element(),
                Block::ToolCall {
                    title,
                    detail,
                    tool,
                    arguments,
                    result,
                    status,
                    expanded,
                } => blocks::tool_call(
                    &bid,
                    title,
                    detail,
                    tool,
                    arguments.as_ref(),
                    result.as_ref(),
                    *status,
                    *expanded,
                    cx,
                )
                .into_any_element(),
                Block::CodeInterpreter {
                    language,
                    code,
                    output,
                    status,
                    expanded,
                } => blocks::code_interpreter(
                    &bid,
                    language,
                    code,
                    output.as_ref(),
                    *status,
                    *expanded,
                    cx,
                )
                .into_any_element(),
                Block::Status { text, done } => {
                    blocks::status_line(&bid, text, *done, cx).into_any_element()
                }
                Block::Citations(sources) => {
                    blocks::citations(&bid, sources, cx).into_any_element()
                }
                Block::FollowUps(items) => blocks::follow_ups(&bid, items, cx).into_any_element(),
            };
            body.push(el);
        }
        let spoken = self.spoken_text(cx);
        let label = if msg.streaming {
            format!("{} (writing): {spoken}", msg.model)
        } else {
            format!("{}: {spoken}", msg.model)
        };
        let show_actions = msg.show_actions && !msg.streaming;
        div()
            .id(ElementId::Name(format!("message-{id}").into()))
            .role(Role::Article)
            .aria_label(SharedString::from(label))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(6.))
            // The phone's answer header: a small glyph and the model's name
            // in the secondary tone, over a reply that shares its edge.
            .child(
                div()
                    .h(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .child(icon(IconName::Sparkles, 15., r.text_subtle))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(msg.model.clone()),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .children(body)
                    .when(show_actions, |d| {
                        d.child(
                            div()
                                .ml(px(-6.))
                                .flex()
                                .items_center()
                                .gap(px(2.))
                                .when_some(msg.version, |d, (c, n)| {
                                    d.child(version_switcher(&id, c, n, cx))
                                })
                                .child(action(
                                    format!("copy-{id}"),
                                    IconName::Copy,
                                    &st.copy,
                                    false,
                                    &t,
                                ))
                                .child(action(
                                    format!("regen-{id}"),
                                    IconName::RotateCcw,
                                    &st.regenerate,
                                    false,
                                    &t,
                                ))
                                .child(action(
                                    format!("more-{id}"),
                                    IconName::Ellipsis,
                                    &st.more,
                                    false,
                                    &t,
                                )),
                        )
                    }),
            )
    }
}
