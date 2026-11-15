//! The main pane for the sidebar's other areas: what an item opens when it
//! is not a chat.
//!
//! [`AreaPane`] draws the toolbar every pane shares (the item's title, and
//! the sidebar's toggle while the sidebar is hidden) and hands the body to
//! the item's area, one module each, so an area's changes stay in its own
//! module:
//!
//! * [`notes`], [`channels`], [`workspace`], [`terminal`], [`calendar`],
//!   [`automations`] and [`hermes`].
//!
//! An item no module draws shows a neutral page: the item's glyph, its
//! title and the area it is in.

pub mod automations;
pub mod calendar;
pub mod channels;
pub mod hermes;
pub mod notes;
pub mod terminal;
pub mod workspace;

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::{IconButton, heading};
use conduit_components::views::shell::toolbar_capsule;
use conduit_components::window::{TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FontWeight, Role, SharedString, Subscription, Window, div, px,
};

use crate::actions::ToggleSidebar;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::layout::LayoutStore;
use crate::stores::navigation::AreaItem;
use crate::views::main_window::SidebarReveal;
use crate::views::sidebar::{area_label, item_icon, item_title};

/// The pane the main window shows for an area item.
pub struct AreaPane {
    stores: Stores,
    layout: Entity<LayoutStore>,
    _subscriptions: Vec<Subscription>,
}

impl AreaPane {
    pub fn new(stores: Stores, layout: Entity<LayoutStore>, cx: &mut Context<Self>) -> Self {
        let subscriptions = vec![
            cx.observe(&stores.navigation, |_, _, cx| cx.notify()),
            cx.observe(&stores.areas, |_, _, cx| cx.notify()),
            cx.observe(&layout, |_, _, cx| cx.notify()),
        ];
        Self {
            stores,
            layout,
            _subscriptions: subscriptions,
        }
    }

    /// The item shown, if the main window shows one.
    pub fn item(&self, cx: &App) -> Option<AreaItem> {
        self.stores.navigation.read(cx).selected_item().cloned()
    }

    /// The shown item's title, as its pane and toolbar say it.
    pub fn title(&self, cx: &App) -> Option<String> {
        let item = self.item(cx)?;
        Some(title_of(&item, &self.stores, cx))
    }
}

/// `item`'s title, from the account's lists ("Untitled" until listed).
pub fn title_of(item: &AreaItem, stores: &Stores, cx: &App) -> String {
    let areas = stores.areas.read(cx);
    let listed = match item {
        AreaItem::Note(id) => areas.note(id).map(|n| n.title.clone()),
        AreaItem::Channel(id) => areas.channel(id).map(|c| c.name.clone()),
        AreaItem::HermesSession(id) => areas.hermes_session(id).map(|s| s.title.clone()),
        AreaItem::Terminal(id) => areas
            .terminal(id)
            .map(|t| t.name.clone())
            .filter(|n| !n.trim().is_empty())
            .or_else(|| Some(id.clone())),
        AreaItem::Workspace(_) | AreaItem::Calendar | AreaItem::Automations => None,
    };
    item_title(item, listed.as_deref(), cx.l10n())
}

/// The page an area shows until its own pane lands: the item's glyph, its
/// title as the page's heading, and the area it is in.
pub fn placeholder(item: &AreaItem, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    let r = t.roles;
    let area = area_label(item.area(), l);
    div()
        .id("area-pane-body")
        .role(Role::Group)
        .aria_label(SharedString::from(format!("{title}, {area}")))
        .flex_1()
        .min_h_0()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap(px(8.))
        .px(px(32.))
        .pb(px(TOOLBAR_HEIGHT))
        .child(icon(item_icon(item), 32., r.text_faint))
        .child(
            heading(
                "area-pane-title",
                SharedString::from(title.to_string()),
                1,
                22.,
                FontWeight::SEMIBOLD,
                r.text,
            )
            .max_w(px(480.))
            .text_center(),
        )
        .child(
            div()
                .text_size(px(t.metrics.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(area)),
        )
        .into_any_element()
}

impl Render for AreaPane {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        let Some(item) = self.item(cx) else {
            return div().size_full().bg(r.content).into_any_element();
        };
        let title = title_of(&item, &self.stores, cx);
        let body = match &item {
            AreaItem::Note(id) => notes::pane(id, &title, &t, &l),
            AreaItem::Channel(id) => channels::pane(id, &title, &t, &l),
            AreaItem::HermesSession(id) => hermes::pane(id, &title, &t, &l),
            AreaItem::Workspace(section) => workspace::pane(*section, &title, &t, &l),
            AreaItem::Terminal(id) => terminal::pane(id, &title, &t, &l),
            AreaItem::Calendar => calendar::pane(&title, &t, &l),
            AreaItem::Automations => automations::pane(&title, &t, &l),
        };
        // As the chat's toolbar: with the sidebar hidden it starts after
        // the traffic lights and offers the sidebar back.
        let sidebar_visible = self.layout.read(cx).state.sidebar_visible;
        let reveal = SidebarReveal::of(sidebar_visible, cx);
        let shown = ((0.3 - reveal) / 0.25).clamp(0., 1.);
        let covered = t.metrics.sidebar_width * reveal;
        let inset = if reveal < 1. {
            (TRAFFIC_LIGHTS_WIDTH + 8. - covered).max(10.)
        } else {
            10.
        };
        let keys = conduit_components::views::focus::hints(cx);
        let toolbar = drag_region("area-pane-toolbar")
            .role(Role::Toolbar)
            .aria_label(SharedString::from(title.clone()))
            .relative()
            .h(px(TOOLBAR_HEIGHT))
            .flex_none()
            .flex()
            .items_center()
            .pl(px(inset))
            .pr(px(10.))
            .when(reveal < 1., |d| {
                d.child(
                    toolbar_capsule(&t).p(px(2.)).opacity(shown).child(
                        IconButton::new(
                            "show-sidebar",
                            IconName::PanelLeft,
                            l.desktop_menu_show_sidebar(),
                        )
                        .size(30., 16.)
                        .round()
                        .shortcut(keys.toggle_sidebar.clone())
                        .on_click(Rc::new(|_, window, cx| {
                            window.dispatch_action(Box::new(ToggleSidebar), cx)
                        })),
                    ),
                )
            })
            .child(
                div()
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .left(px(TRAFFIC_LIGHTS_WIDTH + 48.))
                    .right(px(TRAFFIC_LIGHTS_WIDTH + 48.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.control))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(title)),
                    ),
            );
        div()
            .id("area-pane")
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .child(toolbar)
            .child(body)
            .into_any_element()
    }
}
