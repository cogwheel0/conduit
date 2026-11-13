//! The composer: an IME-aware GPUI Kit Textarea (Enter sends, Shift+Enter
//! breaks the line), attachments with upload progress, feature
//! toggles, the model chip (`toolbar=title`), mic, and Send/Stop.

use gpui_kit::component::input::{Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, BoxShadow, Context, ElementId, Entity, Focusable as _, FontWeight, Role,
    SharedString, Window, div, point, px,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, ToolbarLayout, with_alpha};
use crate::views::kit::{IconButton, icon_tile};
use crate::views::model::Attachment;
use crate::views::shell::ModelPickerButton;

/// How the composer's capsule is drawn: its fill, resting outline, corner
/// radius and shadow. A card docked on the composer (an approval) is drawn
/// the same way, so the two read as one stack.
pub struct ComposerFrame {
    pub fill: gpui_kit::Hsla,
    pub border: gpui_kit::Hsla,
    pub radius: f32,
    pub shadow: Vec<BoxShadow>,
}

/// The composer's frame for `t` (see [`ComposerFrame`]).
pub fn composer_frame(t: &crate::ConduitTheme) -> ComposerFrame {
    let r = t.roles;
    ComposerFrame {
        fill: crate::views::kit::raised_fill(t),
        border: r.border,
        radius: 22.,
        shadow: vec![BoxShadow {
            color: with_alpha(gpui_kit::black(), if t.dark { 0.3 } else { 0.06 }),
            offset: point(px(0.), px(2.)),
            blur_radius: px(10.),
            spread_radius: px(0.),
            inset: false,
        }],
    }
}

/// A feature toggle chip in the composer footer ("Web search").
#[derive(Clone, Debug, PartialEq)]
pub struct ComposerToggle {
    pub label: SharedString,
    pub icon: IconName,
    pub on: bool,
}

/// The composer view. The app subscribes to its Textarea's `InputEvent`s and
/// checks `marked_text_range()` before sending: Enter that confirms an
/// input method's text must not send it.
pub struct Composer {
    pub input: Entity<TextareaState>,
    pub model: SharedString,
    pub attachments: Vec<Attachment>,
    pub toggles: Vec<ComposerToggle>,
    pub streaming: bool,
    /// Draw as focused even when the window isn't key (gallery renders).
    pub force_focus: bool,
}

impl Composer {
    pub fn new(
        placeholder: impl Into<SharedString>,
        model: impl Into<SharedString>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let placeholder: SharedString = placeholder.into();
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 8)
                .placeholder(placeholder)
                .submit_on_enter(true)
        });
        Self {
            input,
            model: model.into(),
            attachments: vec![],
            toggles: vec![],
            streaming: false,
            force_focus: false,
        }
    }

    pub fn set_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let text = text.to_string();
        self.input.update(cx, |s, cx| s.set_value(text, window, cx));
        cx.notify();
    }
}

fn attachment(a: &Attachment, i: usize, t: &crate::ConduitTheme) -> AnyElement {
    let r = t.roles;
    let uploading = a.progress.is_some_and(|p| p < 1.);
    div()
        .id(ElementId::NamedInteger(
            "composer-attachment".into(),
            i as u64,
        ))
        .role(Role::Group)
        .aria_label(match a.progress {
            Some(p) if p < 1. => format!("{}, uploading {}%", a.name, (p * 100.) as u32),
            _ => format!("{}, {}", a.name, a.detail),
        })
        .relative()
        .h(px(44.))
        .w(px(200.))
        .pl(px(5.))
        .pr(px(6.))
        .flex()
        .items_center()
        .gap(px(8.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(crate::views::kit::on_raised_fill(t))
        .overflow_hidden()
        .child(icon_tile(
            if a.image {
                IconName::Image
            } else {
                IconName::FileText
            },
            32.,
            with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }),
            r.text_subtle,
            6.,
        ))
        .child(
            div()
                .flex_1()
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
                        .child(match a.progress {
                            Some(p) if p < 1. => SharedString::from(format!(
                                "Uploading\u{2026} {}%",
                                (p * 100.) as u32
                            )),
                            _ => a.detail.clone(),
                        }),
                ),
        )
        .child(
            IconButton::new(
                ElementId::NamedInteger("remove-attachment".into(), i as u64),
                IconName::X,
                format!("Remove {}", a.name),
            )
            .size(20., 12.),
        )
        .when(uploading, |d| {
            let p = a.progress.unwrap_or(0.);
            d.child(
                div()
                    .absolute()
                    .left_0()
                    .bottom_0()
                    .h(px(2.))
                    .w(px(200. * p))
                    .bg(r.checked),
            )
        })
        .into_any_element()
}

impl Render for Composer {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let focused = self.force_focus || self.input.read(cx).focus_handle(cx).is_focused(window);
        let empty = self.input.read(cx).value().trim().is_empty() && self.attachments.is_empty();
        let frame = composer_frame(&t);
        let (bg, shadows) = (frame.fill, frame.shadow);
        let send: AnyElement = if self.streaming {
            IconButton::new("stop", IconName::Square, "Stop Generating")
                .size(32., 13.)
                .filled(r.primary, r.primary_foreground)
                .into_any_element()
        } else if empty {
            IconButton::new("send", IconName::ArrowUp, "Send")
                .size(32., 17.)
                .filled(
                    with_alpha(r.text, if t.dark { 0.16 } else { 0.10 }),
                    r.text_faint,
                )
                .into_any_element()
        } else {
            IconButton::new("send", IconName::ArrowUp, "Send")
                .size(32., 17.)
                .filled(r.primary, r.primary_foreground)
                .into_any_element()
        };
        let show_model = t.prefs.toolbar == ToolbarLayout::Title;
        // The phone's composer: a capsule with + at the leading edge, the
        // field and the round send button; switches that are on show as
        // chips (the + menu holds them all).
        let on_toggles: Vec<AnyElement> = self
            .toggles
            .iter()
            .enumerate()
            .filter(|(_, tg)| tg.on)
            .map(|(i, tg)| {
                div()
                    .id(ElementId::NamedInteger("composer-toggle".into(), i as u64))
                    .role(Role::Switch)
                    .aria_label(tg.label.clone())
                    .aria_toggled(gpui_kit::Toggled::True)
                    .h(px(28.))
                    .px(px(9.))
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .rounded_full()
                    .border_1()
                    .border_color(r.border_strong)
                    .bg(r.selected)
                    .cursor_pointer()
                    .text_size(px(m.small))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(r.text)
                    .child(icon(tg.icon, 13., r.selected_icon))
                    .child(tg.label.clone())
                    .on_click(|_, _, _| {})
                    .into_any_element()
            })
            .collect();
        div()
            .id("composer")
            .role(Role::Group)
            .aria_label(st.composer.clone())
            .w_full()
            .flex()
            .flex_col()
            .gap(px(4.))
            .rounded(px(frame.radius))
            .border_1()
            .border_color(if focused {
                r.border_strong
            } else {
                frame.border
            })
            .bg(bg)
            .shadow(shadows)
            .p(px(5.))
            .when(!self.attachments.is_empty(), |d| {
                d.child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap(px(6.))
                        .px(px(4.))
                        .pt(px(3.))
                        .children(
                            self.attachments
                                .iter()
                                .enumerate()
                                .map(|(i, a)| attachment(a, i, &t)),
                        ),
                )
            })
            .when(!on_toggles.is_empty(), |d| {
                d.child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap(px(6.))
                        .px(px(4.))
                        .pt(px(2.))
                        .children(on_toggles),
                )
            })
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .child(
                        IconButton::new("attach", IconName::Plus, st.attach_files.clone())
                            .size(30., 17.)
                            .color(r.text_subtle),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .min_h(px(32.))
                            .px(px(4.))
                            .py(px(6.))
                            .flex()
                            .flex_col()
                            .justify_center()
                            .text_size(px(m.body))
                            .text_color(r.text)
                            .child(
                                Textarea::new(&self.input)
                                    .appearance(false)
                                    .bordered(false)
                                    .text_size(px(m.body))
                                    .aria_label(st.message_field.clone())
                                    .accessibility_id("composer-input"),
                            ),
                    )
                    .when(show_model, |d| {
                        d.child(ModelPickerButton::new(self.model.clone()).compact())
                    })
                    // Dictation, beside Send (the app's composer drives it).
                    .when(!self.streaming, |d| {
                        d.child(
                            IconButton::new("dictate", IconName::Mic, "Start Dictation")
                                .size(30., 16.)
                                .color(r.text_subtle),
                        )
                    })
                    .child(send),
            )
    }
}
