//! Settings › Connection, the phone's Data & Connection page: how the
//! Open WebUI server's realtime socket travels (Polling Fallback or
//! WebSocket Only, a choice only when the server allows both) and its
//! health (connected, latency and quality, the last heartbeat,
//! reconnects), which `socket.health` keeps current.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Segment, Segmented, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{AppSettingsPatch, ConnectionHealth};
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, SharedString, div, px};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;

use super::controls::value;

/// The transports in the segmented control's order.
const TRANSPORTS: [&str; 2] = ["polling", "ws"];

pub fn sections(stores: &Stores, cx: &mut App) -> Vec<AnyElement> {
    let l10n = cx.l10n().clone();
    let store = stores.app_settings.read(cx);
    let mode = store.settings().socket_transport_mode.clone();
    let health = store.health.clone().unwrap_or_default();
    let both = health.allow_polling && health.allow_websocket;
    // What the server allows wins over a stored choice it no longer does,
    // as the phone shows it.
    let shown = if !health.allow_websocket {
        "polling"
    } else if !health.allow_polling {
        "ws"
    } else if mode == "polling" {
        "polling"
    } else {
        "ws"
    };
    let app_settings = stores.app_settings.clone();
    let transport = Segmented::new(
        "transport-mode",
        l10n.transport_mode(),
        vec![
            Segment::new(l10n.transport_mode_polling()),
            Segment::new(l10n.transport_mode_ws()),
        ],
        TRANSPORTS.iter().position(|t| *t == shown).unwrap_or(1),
    )
    .on_select(Rc::new(move |i, _, cx| {
        if !both {
            return;
        }
        let mode = TRANSPORTS[i].to_string();
        app_settings.update(cx, |s, cx| {
            s.set(
                AppSettingsPatch {
                    socket_transport_mode: Some(mode),
                    ..Default::default()
                },
                cx,
            )
        });
    }));
    let footer = if shown == "polling" {
        l10n.transport_mode_polling_info()
    } else {
        l10n.transport_mode_ws_info()
    };
    let mut out = vec![
        settings_section(
            SharedString::default(),
            Some(footer.into()),
            vec![setting_row(l10n.transport_mode(), None, transport, cx).into_any_element()],
            cx,
        )
        .into_any_element(),
    ];
    if health.available {
        out.push(health_section(&health, &l10n, cx));
    }
    out
}

fn health_section(h: &ConnectionHealth, l10n: &L10n, cx: &mut App) -> AnyElement {
    let t = cx.conduit().clone();
    let (dot, status) = if h.connected {
        (t.roles.success, l10n.socket_connected())
    } else {
        (t.roles.danger, l10n.socket_disconnected())
    };
    let status_value = div()
        .flex()
        .items_center()
        .gap(px(6.))
        .child(div().size(px(8.)).rounded_full().bg(dot))
        .child(value(status.clone(), cx));
    let quality = match h.quality.as_str() {
        "excellent" => Some(l10n.socket_quality_excellent()),
        "good" => Some(l10n.socket_quality_good()),
        "fair" => Some(l10n.socket_quality_fair()),
        "poor" => Some(l10n.socket_quality_poor()),
        _ => None,
    };
    let latency = match (h.latency_ms, quality) {
        (Some(ms), Some(q)) => format!("{} · {q}", l10n.desktop_latency_ms(ms)),
        (Some(ms), None) => l10n.desktop_latency_ms(ms),
        (None, _) => "\u{2014}".into(),
    };
    let transport = match h.transport.as_str() {
        "websocket" => l10n.socket_transport_web_socket(),
        "polling" => l10n.socket_transport_polling(),
        _ => "\u{2014}".into(),
    };
    let mut rows = vec![
        setting_row(
            l10n.account_status(),
            Some(SharedString::from(transport)),
            status_value,
            cx,
        )
        .into_any_element(),
        setting_row(l10n.socket_latency_label(), None, value(latency, cx), cx).into_any_element(),
        setting_row(
            l10n.socket_reconnects_label(),
            None,
            value(h.reconnects.to_string(), cx),
            cx,
        )
        .into_any_element(),
    ];
    let heartbeat = h
        .last_heartbeat_ms
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map(|at| {
            let local = at.with_timezone(&chrono::Local);
            l10n.socket_last_heartbeat(&local.format("%H:%M:%S").to_string())
        });
    let footer = heartbeat.map(SharedString::from);
    if !h.connected {
        rows.truncate(1);
    }
    settings_section(l10n.connection_health(), footer, rows, cx).into_any_element()
}
