//! `{{USER_LOCATION}}` (`location.*`): this window's part in it.
//!
//! The daemon decides when the Mac's location is needed: a request or a
//! prompt template that names `{{USER_LOCATION}}`, while the account's
//! location setting is on (the core's location policy). Each
//! `location.command` it sends is answered by the window's engine
//! ([`crate::shell::location`]: CoreLocation, or the stand-in every scripted
//! run uses) and goes back as `location.report`.

use conduit_protocol::{LocationCommand, LocationCommandKind, events, methods};
use gpui_kit::{App, AsyncApp, Context, WeakEntity};

use super::Stores;
use super::rpc::Rpc;
use crate::shell::location;

/// The events this store follows.
pub const EVENTS: &[&str] = &[events::LOCATION_COMMAND];

pub struct LocationStore {
    rpc: Rpc,
    /// What the daemon asked, in order (for the E2E pass).
    pub asked: Vec<LocationCommandKind>,
}

impl LocationStore {
    pub fn new(rpc: Rpc) -> Self {
        Self { rpc, asked: vec![] }
    }

    fn on_command(&mut self, command: &LocationCommand, cx: &mut Context<Self>) {
        self.asked.push(command.kind);
        log::info!("location: the daemon asks {:?}", command.kind);
        let report = location::answer(command);
        let rpc = self.rpc.clone();
        let id = command.id;
        cx.spawn(async move |_: WeakEntity<Self>, _: &mut AsyncApp| {
            let report = report
                .await
                .unwrap_or_else(|_| conduit_protocol::LocationReport {
                    id,
                    ok: false,
                    error: Some("no answer".into()),
                    services_enabled: None,
                    permission: None,
                    latitude: None,
                    longitude: None,
                });
            if let Err(e) = rpc.call::<methods::LocationReport>(&report).await {
                log::debug!("location.report: {e}");
            }
        })
        .detach();
    }
}

pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("location", EVENTS, vec![]));
    let s = stores.location.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        if let ConnectionEvent::Daemon(event) = event
            && let conduit_protocol::Event::LocationCommand(command) = event.as_ref()
        {
            s.update(cx, |s, cx| s.on_command(command, cx));
        }
    })
    .detach();
}
