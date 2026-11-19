//! A channel's pane in the main window: [`ChannelPane`], made when a
//! channel is shown and closed when something else is.

use conduit_components::theme::ConduitTheme;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, Context, Window, div};

use super::AreaPane;
use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;
use crate::views::channels::ChannelPane;

/// Keeps the area pane's channel pane on the channel shown (`item`), or
/// closes it.
pub fn sync(
    pane: &mut AreaPane,
    item: Option<&AreaItem>,
    window: &mut Window,
    cx: &mut Context<AreaPane>,
) {
    let wanted = match item {
        Some(AreaItem::Channel(id)) => Some(id.clone()),
        _ => None,
    };
    let current = pane.channel.as_ref().map(|c| c.read(cx).channel_id.clone());
    if current == wanted {
        return;
    }
    if let Some(old) = pane.channel.take() {
        old.update(cx, |p, cx| p.close(cx));
    }
    if let Some(id) = wanted {
        let stores = pane.stores.clone();
        let view = cx.new(|cx| ChannelPane::new(stores, id, window, cx));
        cx.observe(&view, |_, _, cx| cx.notify()).detach();
        pane.channel = Some(view);
    }
}

/// The selection moved: the channel pane closes unless it still shows
/// the channel selected.
pub fn on_navigation(pane: &mut AreaPane, cx: &mut Context<AreaPane>) {
    let selected = match pane.stores.navigation.read(cx).selected_item() {
        Some(AreaItem::Channel(id)) => Some(id.clone()),
        _ => None,
    };
    let keep = pane
        .channel
        .as_ref()
        .is_some_and(|c| Some(&c.read(cx).channel_id) == selected.as_ref());
    if !keep && let Some(old) = pane.channel.take() {
        old.update(cx, |p, cx| p.close(cx));
    }
}

/// The channel's title as its open pane has it (`channels.open`, with
/// the list's fresher fields): a channel opened from a link, or just made,
/// before the list has it. Read from the area pane's own field, never
/// through the main view, which may be drawing this pane.
pub fn shown_title(pane: &AreaPane, item: &AreaItem, cx: &App) -> Option<String> {
    let AreaItem::Channel(id) = item else {
        return None;
    };
    let channel = pane.channel.as_ref()?.read(cx);
    (channel.channel_id == *id)
        .then(|| channel.title(cx))
        .flatten()
}

/// The toolbar's Members and More while a channel is shown.
pub fn toolbar_items(pane: &AreaPane, cx: &mut Context<AreaPane>) -> Option<AnyElement> {
    let channel = pane.channel.clone()?;
    if channel.read(cx).unavailable {
        return None;
    }
    Some(channel.update(cx, |p, cx| p.toolbar_items(cx)))
}

/// Channel `id`'s pane.
pub fn pane(area: &AreaPane, id: &str, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    match &area.channel {
        Some(view) => div()
            .flex_1()
            .min_h_0()
            .flex()
            .child(view.clone())
            .into_any_element(),
        None => super::placeholder(&AreaItem::Channel(id.to_string()), title, t, l),
    }
}
