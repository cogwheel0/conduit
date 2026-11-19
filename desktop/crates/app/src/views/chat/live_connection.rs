//! Live Updates: the chat toolbar's item while the Open WebUI server's
//! realtime socket is down, and its popover, as the phone's
//! `LiveConnectionButton` (a cloud with a slash, in the danger colour, then
//! its details with Retry).
//!
//! * **Quiet when healthy**, as on the phone: the item shows only while the
//!   socket is disconnected (and never in a Hermes chat, which does not
//!   use it). It waits [`SHOW_AFTER`] first, so a reconnect that settles at
//!   once (after a wake, a network change) never flashes it.
//! * **The popover** says what the phone's details say: live updates are
//!   disconnected and replies may be delayed; the transport, reconnects and
//!   last heartbeat (as Settings › Connection shows them); Retry, which
//!   asks the daemon to reconnect now (`data.reconnect`), and Connection
//!   Settings…. A Retry that ends still disconnected says so in place.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::{Button, ClickHandler};
use conduit_protocol::ConnectionHealth;
use gpui_kit::prelude::*;
use gpui_kit::{Div, FontWeight, Role, SharedString, Stateful, div, px, relative};

use crate::l10n::L10n;

/// How long the socket must have been down before the item shows.
pub const SHOW_AFTER: Duration = Duration::from_secs(3);

/// The popover's width.
pub const CARD_WIDTH: f32 = 300.;

/// The details under the message: the transport, reconnects and the last
/// heartbeat, as Settings › Connection words them.
pub fn detail_lines(h: &ConnectionHealth, l10n: &L10n) -> Vec<String> {
    let mut lines = vec![match h.transport.as_str() {
        "websocket" => l10n.socket_transport_web_socket(),
        "polling" => l10n.socket_transport_polling(),
        _ => l10n.socket_transport_unknown(),
    }];
    lines.push(format!(
        "{}: {}",
        l10n.socket_reconnects_label(),
        h.reconnects
    ));
    if let Some(at) = h
        .last_heartbeat_ms
        .and_then(chrono::DateTime::from_timestamp_millis)
    {
        let local = at.with_timezone(&chrono::Local);
        lines.push(l10n.socket_last_heartbeat(&local.format("%H:%M:%S").to_string()));
    }
    lines
}

/// The popover's card.
pub fn card(
    h: &ConnectionHealth,
    reconnecting: bool,
    failed: bool,
    on_retry: ClickHandler,
    on_settings: ClickHandler,
    l10n: &L10n,
    t: &ConduitTheme,
) -> Stateful<Div> {
    let r = t.roles;
    let m = t.metrics;
    let (dot, status) = if h.connected {
        (r.success, l10n.socket_connected())
    } else {
        (r.danger, l10n.socket_disconnected())
    };
    div()
        .id("live-updates-popover")
        .role(Role::Dialog)
        .aria_label(SharedString::from(l10n.live_connection_details_title()))
        .occlude()
        .w(px(CARD_WIDTH))
        .p(px(14.))
        .flex()
        .flex_col()
        .gap(px(10.))
        .rounded(t.overlay_radius())
        .border_1()
        .border_color(r.border_strong)
        .bg(r.overlay)
        .shadow(conduit_components::views::kit::overlay_shadow(t))
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(icon(IconName::CloudOff, 16., r.danger))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(m.control))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(SharedString::from(l10n.live_connection_details_title())),
                )
                .child(
                    div()
                        .id("live-updates-status")
                        .role(Role::Status)
                        .flex()
                        .items_center()
                        .gap(px(5.))
                        .child(div().size(px(7.)).rounded_full().bg(dot))
                        .child(
                            div()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(status)),
                        ),
                ),
        )
        .child(
            div()
                .text_size(px(m.small))
                .line_height(relative(1.4))
                .text_color(r.text)
                .child(SharedString::from(l10n.live_connection_details_message())),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(2.))
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .children(
                    detail_lines(h, l10n)
                        .into_iter()
                        .map(|line| div().child(SharedString::from(line))),
                ),
        )
        .when(failed && !reconnecting, |d| {
            d.child(
                div()
                    .id("live-updates-retry-failed")
                    .role(Role::Alert)
                    .text_size(px(m.small))
                    .text_color(r.danger)
                    .child(SharedString::from(l10n.desktop_live_updates_retry_failed()))
                    .child(live_text(
                        "live",
                        Some(l10n.desktop_live_updates_retry_failed().into()),
                        Priority::High,
                    )),
            )
        })
        .child(
            div()
                .pt(px(2.))
                .flex()
                .justify_end()
                .gap(px(8.))
                .child(
                    Button::new("live-updates-settings", l10n.desktop_connection_settings())
                        .on_click(on_settings),
                )
                .child(
                    Button::new(
                        "live-updates-retry",
                        if reconnecting {
                            l10n.connecting()
                        } else {
                            l10n.retry()
                        },
                    )
                    .primary()
                    .disabled(reconnecting || h.connected)
                    .on_click(on_retry),
                ),
        )
}

/// A click handler from a closure.
pub fn handler(f: impl Fn(&mut gpui_kit::Window, &mut gpui_kit::App) + 'static) -> ClickHandler {
    Rc::new(move |_, window, cx| f(window, cx))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn details_say_the_transport_reconnects_and_heartbeat() {
        let l10n = L10n::new("en");
        let h = ConnectionHealth {
            available: true,
            connected: false,
            transport: "polling".into(),
            reconnects: 4,
            last_heartbeat_ms: Some(1_700_000_000_000),
            ..Default::default()
        };
        let lines = detail_lines(&h, &l10n);
        assert_eq!(lines[0], "HTTP polling transport");
        assert_eq!(lines[1], "Reconnects: 4");
        assert!(lines[2].starts_with("Last heartbeat: "), "{}", lines[2]);
        let none = detail_lines(
            &ConnectionHealth {
                transport: "unknown".into(),
                ..Default::default()
            },
            &l10n,
        );
        assert_eq!(
            none,
            vec!["Unknown transport".to_string(), "Reconnects: 0".into()]
        );
    }
}
