//! The designed connection states: a centred status card in the first-run
//! frame (connecting, core starting, failed with Retry, unreadable data with
//! Reset local data, version mismatch), and the reconnect banner shown over
//! content that is already routed.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, brand_mark, icon};
use conduit_components::theme::{MONO_FONT, with_alpha};
use conduit_components::views::kit::{Button, ClickHandler, heading};
use conduit_components::views::onboarding::first_run_frame;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, Div, Entity, FontWeight, Role, SharedString, div, px, relative};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::connection::{ConnectionStore, Diagnostics, Status};

/// The word beside the composer's Send while it can't send: the state the
/// window's banner shows for the same connection ("Reconnecting…",
/// "Starting Conduit…"), so the two never disagree, else "Offline" (no
/// network, or the helper out of reach with no banner of its own).
pub fn send_state(status: &Status, l10n: &L10n) -> String {
    match status {
        Status::Reconnecting { .. } => l10n.desktop_core_reconnecting(),
        Status::Connecting | Status::CoreStarting => l10n.desktop_core_connecting(),
        _ => l10n.desktop_send_offline(),
    }
}

/// Why Send waits, for its tooltip while it is dimmed: the main window
/// shows the state once (the toolbar's pill), so the button only explains
/// itself.
pub fn send_waits(status: &Status, l10n: &L10n) -> String {
    match status {
        Status::Reconnecting { .. } => l10n.desktop_send_waits_reconnecting(),
        Status::Connecting | Status::CoreStarting => l10n.desktop_send_waits_starting(),
        _ => l10n.desktop_send_waits_offline(),
    }
}

fn handler(f: impl Fn(&mut App) + 'static) -> ClickHandler {
    Rc::new(move |_, _, cx| f(cx))
}

/// The full-window status card for `status`.
pub fn status_screen(status: &Status, store: &Entity<ConnectionStore>, cx: &App) -> Div {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let r = t.roles;
    let conn = store.read(cx);

    let (title, body, busy, tone): (
        SharedString,
        Option<SharedString>,
        bool,
        Option<gpui_kit::Hsla>,
    ) = match status {
        Status::Connecting => (l10n.desktop_core_connecting().into(), None, true, None),
        Status::CoreStarting | Status::Connected => {
            (l10n.desktop_core_opening_data().into(), None, true, None)
        }
        Status::Reconnecting { .. } => (l10n.desktop_core_reconnecting().into(), None, true, None),
        Status::Failed { .. } => (
            l10n.desktop_core_unavailable().into(),
            Some(l10n.desktop_core_failed_hint().into()),
            false,
            Some(r.danger),
        ),
        Status::StoreUnreadable => (
            l10n.desktop_store_unreadable_title().into(),
            Some(l10n.desktop_store_unreadable_body().into()),
            false,
            Some(r.warning),
        ),
        Status::VersionMismatch { .. } => (
            l10n.desktop_core_version_mismatch().into(),
            None,
            false,
            Some(r.danger),
        ),
    };
    let detail: Option<SharedString> = match status {
        Status::Failed { detail } => Some(detail.clone().into()),
        Status::VersionMismatch { daemon, app } => {
            Some(format!("conduitd {daemon} · app {app}").into())
        }
        _ => None,
    };

    let mut buttons: Vec<AnyElement> = vec![];
    let logs = conn.paths().logs.clone();
    let show_logs = Button::new("status-logs", l10n.desktop_show_logs())
        .icon(IconName::FolderOpen)
        .on_click(handler(move |cx| cx.reveal_path(&logs)));
    match status {
        Status::Failed { .. } => {
            let s = store.clone();
            buttons.push(
                Button::new("status-retry", l10n.retry())
                    .primary()
                    .icon(IconName::RotateCcw)
                    .on_click(handler(move |cx| {
                        if s.update(cx, |s, cx| s.retry(cx))
                            && let Some(state) = cx.try_global::<crate::AppState>()
                        {
                            let session = state.stores.session.clone();
                            session.update(cx, |s, cx| s.refresh(cx));
                        }
                    }))
                    .into_any_element(),
            );
            buttons.push(show_logs.into_any_element());
        }
        Status::StoreUnreadable => {
            let s = store.clone();
            buttons.push(
                Button::new("status-reset", l10n.desktop_reset_local_data())
                    .primary()
                    .on_click(handler(move |cx| {
                        s.update(cx, |s, cx| s.reset_local_data(cx))
                    }))
                    .into_any_element(),
            );
            buttons.push(show_logs.into_any_element());
        }
        Status::VersionMismatch { .. } => {
            buttons.push(show_logs.into_any_element());
            buttons.push(
                Button::new("status-quit", l10n.desktop_menu_quit())
                    .on_click(handler(|cx| cx.quit()))
                    .into_any_element(),
            );
        }
        _ => {}
    }
    // A fixed sentence; the system's reason is in the log (and Show Logs is
    // beside it).
    let reset_error = conn
        .reset_error
        .as_ref()
        .map(|_| SharedString::from(l10n.desktop_reset_failed()));

    let mark = div()
        .size(px(56.))
        .rounded(px(14.))
        .bg(r.primary)
        .flex()
        .items_center()
        .justify_center()
        .child(brand_mark(34., r.primary_foreground));

    let card = div()
        .id("connection-status")
        .role(Role::Status)
        .aria_label(title.clone())
        .flex()
        .flex_col()
        .items_center()
        .gap(px(14.))
        .child(mark)
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .when_some(tone, |d, c| d.child(icon(IconName::CircleAlert, 18., c)))
                .child(heading(
                    "status-title",
                    title,
                    1,
                    20.,
                    FontWeight::SEMIBOLD,
                    r.text,
                )),
        )
        .when(busy, |d| {
            d.child(gpui_kit::component::spinner::Spinner::new().color(r.text_subtle))
        })
        .when_some(body, |d, b| {
            d.child(
                div()
                    .text_size(px(t.metrics.control + 1.))
                    .line_height(relative(1.45))
                    .text_color(r.text_subtle)
                    .text_center()
                    .child(b),
            )
        })
        .when_some(detail, |d, text| {
            d.child(
                div()
                    .id("status-detail")
                    .role(Role::Note)
                    .aria_label(text.clone())
                    .max_w_full()
                    .px(px(10.))
                    .py(px(6.))
                    .rounded(t.control_radius())
                    .bg(with_alpha(r.text, if t.dark { 0.08 } else { 0.05 }))
                    .font_family(MONO_FONT)
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(text),
            )
        })
        .when_some(reset_error, |d, e| {
            d.child(
                div()
                    .text_size(px(t.metrics.small))
                    .text_color(r.danger)
                    .child(e),
            )
        })
        .when(!buttons.is_empty(), |d| {
            d.child(div().pt(px(6.)).flex().gap(px(10.)).children(buttons))
        });
    first_run_frame(card, cx)
}

/// A pill over routed content while the connection recovers.
pub fn reconnect_banner(text: SharedString, cx: &App) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .absolute()
        .top(px(conduit_components::window::TOOLBAR_HEIGHT + 6.))
        .left_0()
        .right_0()
        .flex()
        .justify_center()
        .child(
            div()
                .id("reconnect-banner")
                .role(Role::Status)
                .aria_label(text.clone())
                .h(px(28.))
                .px(px(12.))
                .flex()
                .items_center()
                .gap(px(8.))
                .rounded_full()
                // A hairline and a small shadow, as the toolbar's capsules:
                // lifted off the page without a halo around it.
                .bg(conduit_components::views::kit::raised_fill(t))
                .border_1()
                .border_color(r.border)
                .shadow(conduit_components::views::kit::pill_shadow(t))
                .text_size(px(t.metrics.small))
                .text_color(r.text)
                .child(gpui_kit::component::spinner::Spinner::new().color(r.text_subtle))
                .child(text),
        )
}

/// The banner over the main frame while the active server is out of reach:
/// what is shown is what the daemon stored, and sending waits.
pub fn offline_banner(text: SharedString, cx: &App) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .absolute()
        .top(px(conduit_components::window::TOOLBAR_HEIGHT + 6.))
        .left_0()
        .right_0()
        .flex()
        .justify_center()
        .px(px(16.))
        .child(
            div()
                .id("offline-banner")
                .role(Role::Status)
                .aria_label(text.clone())
                .max_w(px(560.))
                .min_h(px(28.))
                .px(px(12.))
                .py(px(5.))
                .flex()
                .items_center()
                .gap(px(8.))
                .rounded(px(14.))
                // A hairline and a small shadow, as the toolbar's capsules:
                // lifted off the page without a halo around it.
                .bg(conduit_components::views::kit::raised_fill(t))
                .border_1()
                .border_color(r.border)
                .shadow(conduit_components::views::kit::pill_shadow(t))
                .text_size(px(t.metrics.small))
                .text_color(r.text)
                .child(icon(IconName::CloudOff, 14., r.warning).flex_none())
                .child(div().min_w_0().child(text)),
        )
}

/// "Export diagnostics" with its state line, for Settings › About.
pub fn diagnostics_state(diagnostics: &Diagnostics, cx: &App) -> Option<SharedString> {
    let l10n = cx.l10n();
    match diagnostics {
        Diagnostics::Idle => None,
        Diagnostics::Exporting => Some(l10n.desktop_exporting().into()),
        Diagnostics::Saved(path) => Some(
            l10n.desktop_diagnostics_saved(
                &path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default(),
            )
            .into(),
        ),
        Diagnostics::Failed(_) => Some(l10n.desktop_diagnostics_failed().into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_composer_says_what_the_banner_says() {
        let l10n = L10n::new("en");
        assert_eq!(
            send_state(&Status::Reconnecting { attempt: 2 }, &l10n),
            "Reconnecting\u{2026}"
        );
        assert_eq!(
            send_state(&Status::Connecting, &l10n),
            "Starting Conduit\u{2026}"
        );
        // Connected but no network: the one word for it.
        assert_eq!(send_state(&Status::Connected, &l10n), "Offline");
        // The main window's dimmed Send says why in its tooltip instead.
        assert_eq!(
            send_waits(&Status::Reconnecting { attempt: 1 }, &l10n),
            "You can send once Conduit reconnects."
        );
        assert_eq!(
            send_waits(&Status::CoreStarting, &l10n),
            "You can send once Conduit has started."
        );
        assert_eq!(
            send_waits(&Status::Connected, &l10n),
            "You can send once you're back online."
        );
    }
}
