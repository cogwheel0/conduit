//! The notification settings (`notifications.get/set`, refetched on
//! `notifications.changed`): core's, as the phone's Notifications page shows
//! them. What each notification does is core's decision too
//! (`notifications.route`, asked by [`crate::desktop`] when one comes in);
//! this store only holds what Settings › Notifications shows and changes.

use conduit_daemon::RpcError;
use conduit_protocol::{NoParams, NotificationSettingsDto, NotificationSettingsPatch, methods};
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::rpc::Rpc;

/// The events this store follows.
pub const EVENTS: &[&str] = &[conduit_protocol::events::NOTIFICATIONS_CHANGED];

pub struct NotificationsStore {
    rpc: Rpc,
    /// What the daemon last said; the desktop's defaults until it has.
    settings: NotificationSettingsDto,
    /// The daemon has answered at least once since connecting.
    pub loaded: bool,
    /// Why the last change was refused, until the next one.
    pub error: Option<RpcError>,
    generation: u64,
    _fetch: Option<Task<()>>,
}

/// What the daemon answers before anything is set: core's defaults with the
/// desktop's own host default (notifications on).
pub fn desktop_defaults() -> NotificationSettingsDto {
    NotificationSettingsDto {
        enabled: true,
        sound: true,
        sound_always: false,
        in_app_banner: true,
        system: true,
        answers: true,
        channels: true,
        mentions_only: false,
        synced: false,
    }
}

impl NotificationsStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            settings: desktop_defaults(),
            loaded: false,
            error: None,
            generation: 0,
            _fetch: None,
        }
    }

    pub fn settings(&self) -> &NotificationSettingsDto {
        &self.settings
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::NotificationsGet>(&NoParams);
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(settings) => s.adopt(settings, cx),
                        Err(e) => log::warn!("notifications.get: {e}"),
                    }
                });
            }),
        );
    }

    fn adopt(&mut self, settings: NotificationSettingsDto, cx: &mut Context<Self>) {
        self.loaded = true;
        self.settings = settings;
        cx.notify();
    }

    /// Sends `patch`, showing it at once; the store then shows what the
    /// daemon answers (or puts back what it had, on a refusal).
    pub fn set(&mut self, patch: NotificationSettingsPatch, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let before = self.settings.clone();
        apply(&mut self.settings, &patch);
        cx.notify();
        let call = self.rpc.call::<methods::NotificationsSet>(&patch);
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(settings) => {
                        s.error = None;
                        if s.generation == generation {
                            s.adopt(settings, cx);
                        }
                    }
                    Err(e) => {
                        log::warn!("notifications.set: {e}");
                        if s.generation == generation {
                            s.settings = before;
                        }
                        s.error = Some(e);
                        cx.notify();
                    }
                });
            }),
        );
    }
}

/// `patch` applied to `settings`, as the daemon will store it.
fn apply(settings: &mut NotificationSettingsDto, patch: &NotificationSettingsPatch) {
    let NotificationSettingsPatch {
        enabled,
        sound,
        sound_always,
        in_app_banner,
        system,
        answers,
        channels,
        mentions_only,
    } = patch;
    let set = |field: &mut bool, value: &Option<bool>| {
        if let Some(v) = value {
            *field = *v;
        }
    };
    set(&mut settings.enabled, enabled);
    set(&mut settings.sound, sound);
    set(&mut settings.sound_always, sound_always);
    set(&mut settings.in_app_banner, in_app_banner);
    set(&mut settings.system, system);
    set(&mut settings.answers, answers);
    set(&mut settings.channels, channels);
    set(&mut settings.mentions_only, mentions_only);
}

/// Wires the store to the connection: fetched on every new daemon session,
/// then kept by `notifications.changed`.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("notifications", EVENTS, vec![]));
    let s = stores.notifications.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                s.update(cx, |s, cx| s.refresh(cx));
            }
            ConnectionEvent::Daemon(event) => {
                if matches!(
                    event.as_ref(),
                    conduit_protocol::Event::NotificationsChanged
                ) {
                    s.update(cx, |s, cx| s.refresh(cx));
                }
            }
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;
    use gpui_kit::{AppContext as _, TestAppContext};

    #[gpui_kit::test]
    fn shows_a_change_at_once_and_puts_it_back_when_refused(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsGet>(NotificationSettingsDto {
            sound_always: true,
            ..desktop_defaults()
        });
        let store = cx.new(|_| NotificationsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.loaded && s.settings().sound_always));

        daemon.on::<methods::NotificationsSet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INVALID_PARAMS,
                "no",
            ))
        });
        store.update(cx, |s, cx| {
            s.set(
                NotificationSettingsPatch {
                    in_app_banner: Some(false),
                    ..Default::default()
                },
                cx,
            );
            // Shown before the daemon answers.
            assert!(!s.settings().in_app_banner);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.settings().in_app_banner);
            assert!(s.error.is_some());
        });
        let sent = daemon.calls::<methods::NotificationsSet>();
        assert_eq!(sent[0]["inAppBanner"], false);
        assert!(sent[0].get("enabled").is_none());
    }
}
