//! Quick Ask: the 720×320 floating panel (⇧⌘Space). The window is a GPUI
//! `PopUp` over an NSVisualEffectView; this view draws its content with a
//! palette tint over the material.

use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    Context, ElementId, Entity, FontWeight, Role, SharedString, Window, div, px, relative,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, UI_FONT, with_alpha};
use crate::views::kit::{ESC_KEYCAP, IconButton, keycap, shortcut};
use crate::views::markdown::text_view;
use crate::views::shell::ModelPickerButton;

/// The Quick Ask panel's content.
pub struct QuickAsk {
    pub query: Entity<InputState>,
    pub model: SharedString,
    pub answer: Option<Entity<TextViewState>>,
    pub recent: Vec<SharedString>,
}

impl QuickAsk {
    pub fn new(
        model: impl Into<SharedString>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            query: cx.new(|cx| InputState::new(window, cx).placeholder("Ask anything\u{2026}")),
            model: model.into(),
            answer: None,
            recent: vec![],
        }
    }

    pub fn set_query(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let text = text.to_string();
        self.query.update(cx, |s, cx| s.set_value(text, window, cx));
    }

    pub fn set_answer(&mut self, markdown: &str, cx: &mut Context<Self>) {
        let md = markdown.to_string();
        self.answer = Some(cx.new(|cx| TextViewState::markdown(&md, cx)));
        cx.notify();
    }
}

impl Render for QuickAsk {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        // The app's tint: the dark ramp's raised tone, nearly opaque.
        let tint = if t.dark {
            with_alpha(r.raised, 0.94)
        } else {
            with_alpha(r.overlay, 0.62)
        };
        let hint = |keys: &'static str, label: SharedString| {
            div()
                .flex()
                .items_center()
                .gap(px(5.))
                .child(keycap(keys, &t))
                .child(label)
        };
        let answer_label = self
            .answer
            .as_ref()
            .map(|a| a.read(cx).rendered_text().as_str().to_string())
            .unwrap_or_default();
        div()
            .id("quick-ask")
            .role(Role::Dialog)
            .aria_label(st.quick_ask.clone())
            .size_full()
            .flex()
            .flex_col()
            .font_family(UI_FONT)
            .text_color(r.text)
            .rounded(px(16.))
            .bg(tint)
            .border_1()
            .border_color(with_alpha(r.text, if t.dark { 0.16 } else { 0.10 }))
            .overflow_hidden()
            .child(
                div()
                    .h(px(60.))
                    .flex_none()
                    .px(px(18.))
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(icon(IconName::Sparkles, 20., r.text_subtle))
                    .child(
                        div().flex_1().text_size(px(19.)).child(
                            Input::new(&self.query)
                                .appearance(false)
                                .bordered(false)
                                .px_0()
                                .h(px(36.))
                                .text_size(px(19.))
                                .aria_label(st.ask.clone())
                                .accessibility_id("quick-ask-input"),
                        ),
                    )
                    .child(ModelPickerButton::new(self.model.clone()).compact()),
            )
            .child(
                div()
                    .h(px(1.))
                    .mx(px(18.))
                    .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.08 })),
            )
            .child(match &self.answer {
                Some(answer) => div()
                    .id("quick-ask-answer")
                    .role(Role::Article)
                    .aria_label(SharedString::from(format!(
                        "{}: {answer_label}",
                        self.model
                    )))
                    .flex_1()
                    .min_h_0()
                    .px(px(20.))
                    .py(px(14.))
                    .text_size(px(m.body))
                    .line_height(relative(m.leading))
                    .child(text_view(answer))
                    .into_any_element(),
                None => div()
                    .id("quick-ask-recent")
                    .role(Role::List)
                    .aria_label(st.recent_questions.clone())
                    .flex_1()
                    .min_h_0()
                    .px(px(10.))
                    .py(px(8.))
                    .flex()
                    .flex_col()
                    .gap(px(1.))
                    .child(
                        div()
                            .px(px(10.))
                            .pb(px(4.))
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(st.recent.clone()),
                    )
                    .children(self.recent.iter().enumerate().map(|(i, q)| {
                        div()
                            .id(ElementId::NamedInteger("quick-recent".into(), i as u64))
                            .role(Role::Button)
                            .aria_label(q.clone())
                            .h(px(m.row_height + 4.))
                            .px(px(10.))
                            .flex()
                            .items_center()
                            .gap(px(10.))
                            .rounded(px(7.))
                            .when(i == 0, |d| d.bg(r.selected))
                            .cursor_pointer()
                            .child(icon(IconName::Clock, 14., r.text_faint))
                            .child(
                                div()
                                    .flex_1()
                                    .truncate()
                                    .text_size(px(m.control + 1.))
                                    .child(q.clone()),
                            )
                            .when(i == 0, |d| {
                                d.child(shortcut("\u{21a9}", r.text_subtle, m.small))
                            })
                            .on_click(|_, _, _| {})
                    }))
                    .into_any_element(),
            })
            .child(
                div()
                    .h(px(40.))
                    .flex_none()
                    .px(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(16.))
                    .border_t_1()
                    .border_color(with_alpha(r.text, if t.dark { 0.12 } else { 0.07 }))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(hint("\u{21a9}", st.ask.clone()))
                    .child(hint("\u{2318}\u{21a9}", st.continue_in_conduit.clone()))
                    .child(hint(ESC_KEYCAP, st.close.clone()))
                    .child(div().flex_1())
                    .when(self.answer.is_some(), |d| {
                        d.child(
                            IconButton::new("quick-copy", IconName::Copy, "Copy answer")
                                .size(26., 14.),
                        )
                    }),
            )
    }
}
