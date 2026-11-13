//! The model picker's dropdown: search, pinned models, then the rest, each
//! with its connection. The trigger is [`crate::views::shell::ModelPickerButton`].

use gpui_kit::prelude::*;
use gpui_kit::{App, ElementId, FontWeight, Role, SharedString, Window, div, px};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, with_alpha};
use crate::views::kit::{icon_tile, overlay_shadow};
use crate::views::model::ModelOption;

#[derive(IntoElement)]
pub struct ModelMenu {
    models: Vec<ModelOption>,
    selected: SharedString,
    highlighted: Option<usize>,
}

impl ModelMenu {
    pub fn new(models: Vec<ModelOption>, selected: impl Into<SharedString>) -> Self {
        Self {
            models,
            selected: selected.into(),
            highlighted: None,
        }
    }
    pub fn highlighted(mut self, index: usize) -> Self {
        self.highlighted = Some(index);
        self
    }
}

impl RenderOnce for ModelMenu {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let total = self.models.len();
        let (pinned, rest): (Vec<_>, Vec<_>) =
            self.models.iter().enumerate().partition(|(_, o)| o.pinned);
        let row = |i: usize, o: &ModelOption| {
            let on = o.id == self.selected;
            let hot = self.highlighted == Some(i);
            div()
                .id(ElementId::Name(format!("model-{}", o.id).into()))
                .role(Role::MenuItemRadio)
                .aria_label(format!("{}, {}", o.name, o.provider))
                .aria_selected(on)
                .aria_position_in_set(i + 1)
                .aria_size_of_set(total)
                .h(px(m.row_height + 14.))
                .px(px(8.))
                .flex()
                .items_center()
                .gap(px(10.))
                .rounded(px(7.))
                .when(hot, |d| d.bg(r.overlay_hover))
                .cursor_pointer()
                .child(icon_tile(
                    IconName::Sparkles,
                    26.,
                    with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }),
                    r.text_subtle,
                    7.,
                ))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .text_size(px(m.control))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(r.text)
                                .child(o.name.clone()),
                        )
                        .child(
                            div()
                                .truncate()
                                .text_size(px(m.caption))
                                .text_color(r.text_subtle)
                                .child(o.provider.clone()),
                        ),
                )
                .when(on, |d| d.child(icon(IconName::Check, 15., r.selected_icon)))
                .on_click(|_, _, _| {})
        };
        let label = |s: SharedString| {
            div()
                .px(px(8.))
                .pt(px(8.))
                .pb(px(2.))
                .text_size(px(m.caption))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(s)
        };
        div()
            .id("model-menu")
            .role(Role::Menu)
            .aria_label(st.models.clone())
            .w(px(300.))
            .p(px(6.))
            .flex()
            .flex_col()
            .rounded(t.overlay_radius())
            .border_1()
            .border_color(r.border_strong)
            .bg(r.overlay)
            .shadow(overlay_shadow(&t))
            .child(
                div()
                    .h(px(m.control_height + 2.))
                    .mx(px(2.))
                    .mb(px(2.))
                    .px(px(8.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .rounded(px(7.))
                    .bg(with_alpha(r.text, if t.dark { 0.08 } else { 0.05 }))
                    .text_size(px(m.control))
                    .text_color(r.text_faint)
                    .child(icon(IconName::Search, 13., r.text_faint))
                    .child(st.search_models.clone()),
            )
            .child(label(st.pinned.clone()))
            .children(pinned.iter().map(|(i, o)| row(*i, o)))
            .child(label(st.all_models.clone()))
            .children(rest.iter().map(|(i, o)| row(*i, o)))
    }
}
