//! External apps in channels (Open WebUI 0.12.1), as the phone and the web
//! draw them: an app's cards (author, linked title, markdown text,
//! thumbnail, fields, footer, an accent bar in the card's colour) and its
//! buttons and links; and an app's private answer to the user, under the
//! message it answers, with "Only visible to you · Dismiss" and, for a
//! report, a button that saves it as a file.
//!
//! App content is untrusted: its markdown goes through the same renderer
//! as messages (raw HTML shows as text), only http(s) links open, and a
//! remote thumbnail is never fetched (an image loaded from anywhere is a
//! tracking pixel, as for messages).

use std::rc::Rc;

use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{Button, icon_tile, raised_fill};
use conduit_protocol::{
    ChannelAppActionDto, ChannelAppContentDto, ChannelAppEmbedDto, ChannelAppReplyDto,
    ChannelAppReplyEvent, ChannelAppReplyKind,
};
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, ElementId, Entity, FontWeight, Hsla, Role, SharedString, Window, div,
    px, rgb,
};

use crate::l10n::L10n;

/// Makes (or finds) the TextView state for some markdown, by key.
pub type TextFor<'a, V> = dyn FnMut(&str, &str, &mut Context<V>) -> Entity<TextViewState> + 'a;

/// Presses an app's button, by its action id.
pub type Press = Rc<dyn Fn(&str, &mut App)>;

/// The small "App" label beside an app's name.
pub fn app_badge(l: &L10n, t: &ConduitTheme) -> AnyElement {
    let r = t.roles;
    div()
        .flex_none()
        .px(px(5.))
        .h(px(16.))
        .rounded(px(4.))
        .bg(with_alpha(r.text, 0.08))
        .flex()
        .items_center()
        .text_size(px(t.metrics.caption - 1.))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(r.text_subtle)
        .child(SharedString::from(l.channel_app_badge()))
        .into_any_element()
}

/// The cards and buttons of an app's message.
#[allow(clippy::too_many_arguments)]
pub fn app_content<V: 'static>(
    key: &str,
    message_id: &str,
    app: &ChannelAppContentDto,
    pending: bool,
    press: Press,
    text: &mut TextFor<'_, V>,
    l: &L10n,
    t: &ConduitTheme,
    cx: &mut Context<V>,
) -> AnyElement {
    let mut column = div().flex().flex_col().gap(px(8.)).pt(px(2.));
    for (n, embed) in app.embeds.iter().enumerate() {
        column = column.child(embed_card(&format!("{key}-embed{n}"), embed, text, t, cx));
    }
    if !app.actions.is_empty() {
        column = column.child(actions(
            key,
            message_id,
            &app.actions,
            pending,
            Some(press),
            l,
            t,
        ));
    }
    column.into_any_element()
}

fn actions(
    key: &str,
    _message_id: &str,
    actions: &[ChannelAppActionDto],
    pending: bool,
    press: Option<Press>,
    _l: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let mut row = div().flex().flex_wrap().gap(px(6.));
    for (n, action) in actions.iter().enumerate() {
        let id = format!("{key}-action{n}");
        let label = action.label.clone();
        let button = match (&action.url, &action.action_id) {
            (Some(url), _) => {
                let url = url.clone();
                Button::new(ElementId::Name(id.into()), label)
                    .icon(IconName::ExternalLink)
                    .on_click(Rc::new(move |_, _, cx| {
                        crate::views::chat::markdown::open_web_link(&url, cx)
                    }))
            }
            (None, Some(action_id)) => {
                let action_id = action_id.clone();
                let press = press.clone();
                let mut b = Button::new(ElementId::Name(id.into()), label)
                    .disabled(pending || press.is_none());
                // The first button is the main one, as on the web.
                if n == 0 {
                    b = b.primary();
                }
                b.on_click(Rc::new(move |_, _, cx| {
                    if let Some(press) = &press {
                        press(&action_id, cx);
                    }
                }))
            }
            (None, None) => continue,
        };
        row = row.child(button);
    }
    let _ = t;
    row.into_any_element()
}

fn embed_card<V: 'static>(
    key: &str,
    embed: &ChannelAppEmbedDto,
    text: &mut TextFor<'_, V>,
    t: &ConduitTheme,
    cx: &mut Context<V>,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let accent: Option<Hsla> = embed.color.map(|c| rgb(c as u32).into());
    let mut body = div().flex_1().min_w_0().flex().flex_col().gap(px(4.));
    if let Some(author) = &embed.author_name {
        body = body.child(
            div()
                .text_size(px(m.caption))
                .text_color(r.text_subtle)
                .child(SharedString::from(author.clone())),
        );
    }
    if !embed.title.is_empty() {
        let title = div()
            .text_size(px(m.body))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(r.text);
        body = body.child(match &embed.url {
            Some(url) => {
                let url = url.clone();
                title
                    .id(ElementId::Name(format!("{key}-title").into()))
                    .role(Role::Link)
                    .aria_label(SharedString::from(embed.title.clone()))
                    .cursor_pointer()
                    .underline()
                    .child(SharedString::from(embed.title.clone()))
                    .tip(url.clone(), None)
                    .on_click(move |_, _, cx| crate::views::chat::markdown::open_web_link(&url, cx))
                    .into_any_element()
            }
            None => title
                .child(SharedString::from(embed.title.clone()))
                .into_any_element(),
        });
    }
    if !embed.description.trim().is_empty() {
        let state = text(&format!("{key}-description"), &embed.description, cx);
        body = body.child(div().text_size(px(m.small)).text_color(r.text).child(
            crate::views::chat::markdown::chat_text(&state, format!("{key}-description").into()),
        ));
    }
    if !embed.fields.is_empty() {
        let mut fields = div()
            .flex()
            .flex_wrap()
            .gap_x(px(16.))
            .gap_y(px(6.))
            .pt(px(2.));
        for (n, field) in embed.fields.iter().enumerate() {
            let state = text(&format!("{key}-field{n}"), &field.value, cx);
            fields = fields.child(
                div()
                    .when(field.inline, |d| d.min_w(px(120.)).max_w(px(180.)))
                    .when(!field.inline, |d| d.w_full())
                    .flex()
                    .flex_col()
                    .gap(px(1.))
                    .child(
                        div()
                            .text_size(px(m.caption))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(field.name.clone())),
                    )
                    .child(div().text_size(px(m.small)).text_color(r.text).child(
                        crate::views::chat::markdown::chat_text(
                            &state,
                            format!("{key}-field{n}").into(),
                        ),
                    )),
            );
        }
        body = body.child(fields);
    }
    if let Some(footer) = &embed.footer_text {
        body = body.child(
            div()
                .text_size(px(m.caption))
                .text_color(r.text_subtle)
                .child(SharedString::from(footer.clone())),
        );
    }
    div()
        .id(ElementId::Name(key.to_string().into()))
        .role(Role::Group)
        .aria_label(SharedString::from(embed.title.clone()))
        .max_w(px(520.))
        .flex()
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(raised_fill(t))
        .overflow_hidden()
        .when_some(accent, |d, c| d.child(div().w(px(3.)).flex_none().bg(c)))
        .child(div().flex_1().min_w_0().px(px(12.)).py(px(9.)).child(body))
        .into_any_element()
}

/// Saves a report an app sent the user.
pub type SaveReport = Rc<dyn Fn(ChannelAppReplyDto, &mut Window, &mut App)>;

/// An app's answer to the user alone, with Dismiss.
#[allow(clippy::too_many_arguments)]
pub fn private_reply<V: 'static>(
    key: &str,
    event: &ChannelAppReplyEvent,
    dismiss: Rc<dyn Fn(&mut App)>,
    save: SaveReport,
    text: &mut TextFor<'_, V>,
    l: &L10n,
    t: &ConduitTheme,
    cx: &mut Context<V>,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let reply = &event.reply;
    let name = event
        .app_name
        .clone()
        .filter(|n| !n.trim().is_empty())
        .unwrap_or_else(|| l.channel_app_badge());
    let mut column = div().flex_1().min_w_0().flex().flex_col().gap(px(6.));
    column = column.child(
        div()
            .flex()
            .items_center()
            .gap(px(6.))
            .child(
                div()
                    .text_size(px(m.body))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(r.text)
                    .child(SharedString::from(name.clone())),
            )
            .child(app_badge(l, t)),
    );
    if !reply.title.is_empty() {
        column = column.child(
            div()
                .text_size(px(m.body))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text)
                .child(SharedString::from(reply.title.clone())),
        );
    }
    // A report's content is the file, not something to read here.
    if !reply.content.trim().is_empty() && reply.kind != ChannelAppReplyKind::Download {
        let state = text(&format!("{key}-content"), &reply.content, cx);
        column = column.child(div().text_size(px(m.body)).text_color(r.text).child(
            crate::views::chat::markdown::chat_text(&state, format!("{key}-content").into()),
        ));
    }
    for (n, embed) in reply.embeds.iter().enumerate() {
        column = column.child(embed_card(&format!("{key}-embed{n}"), embed, text, t, cx));
    }
    if reply.kind == ChannelAppReplyKind::Error && reply.content.trim().is_empty() {
        column = column.child(
            div()
                .text_size(px(m.small))
                .text_color(r.text)
                .child(SharedString::from(l.channel_app_error_fallback())),
        );
    }
    if reply.kind == ChannelAppReplyKind::Download {
        let dto = reply.clone();
        column = column.child(
            div().flex().child(
                Button::new(
                    ElementId::Name(format!("{key}-download").into()),
                    l.channel_app_download(&reply.filename),
                )
                .icon(IconName::Download)
                .on_click(Rc::new(move |_, window, cx| save(dto.clone(), window, cx))),
            ),
        );
    }
    if !reply.actions.is_empty() {
        column = column.child(actions(
            key,
            &event.message_id,
            &reply.actions,
            false,
            None,
            l,
            t,
        ));
    }
    column = column.child(
        div()
            .flex()
            .items_center()
            .gap(px(6.))
            .text_size(px(m.caption))
            .text_color(r.text_subtle)
            .child(icon(IconName::EyeOff, 12., r.text_subtle))
            .child(SharedString::from(l.channel_app_only_visible_to_you()))
            .child(SharedString::from("·"))
            .child(
                div()
                    .id(ElementId::Name(format!("{key}-dismiss").into()))
                    .role(Role::Button)
                    .aria_label(SharedString::from(l.channel_app_dismiss()))
                    .cursor_pointer()
                    .underline()
                    .hover(|s| s.text_color(r.text))
                    .child(SharedString::from(l.channel_app_dismiss()))
                    .on_click(move |_, _, cx| dismiss(cx)),
            ),
    );
    div()
        .id(ElementId::Name(key.to_string().into()))
        .role(Role::Article)
        .aria_label(SharedString::from(format!(
            "{name}: {} {}",
            reply.title,
            l.channel_app_only_visible_to_you()
        )))
        .px(px(16.))
        .py(px(6.))
        .flex()
        .child(
            div()
                .w(px(super::timeline::GUTTER))
                .flex_none()
                .pt(px(2.))
                .child(icon_tile(
                    IconName::LayoutGrid,
                    super::timeline::AVATAR,
                    with_alpha(r.text, 0.08),
                    r.text_subtle,
                    8.,
                )),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .rounded(t.card_radius())
                .border_1()
                .border_color(r.border)
                .border_dashed()
                .px(px(12.))
                .py(px(9.))
                .child(column),
        )
        .into_any_element()
}
