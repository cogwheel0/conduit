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

/// The store's own subscription key: `desktop` follows the answers and
/// channel posts under its own (a shared key would replace one list with
/// the other).
pub const SUBSCRIPTION_KEY: &str = "notification-settings";

pub struct NotificationsStore {
    rpc: Rpc,
    /// What the daemon last said; the desktop's defaults until it has.
    settings: NotificationSettingsDto,
    /// The daemon has answered at least once since connecting. Until then
    /// the settings are unknown: shown as the defaults, never written.
    pub loaded: bool,
    /// The read that would have made them known failed (Settings says so
    /// and reads again when it opens).
    pub load_failed: bool,
    /// Why the last change was refused, until the next one.
    pub error: Option<RpcError>,
    generation: u64,
    /// The read in flight; a newer read replaces it. Writes never share it:
    /// each runs to its end on its own task.
    _fetch: Option<Task<()>>,
    /// Writes sent and not yet answered.
    writes: usize,
    /// Writes answered so far: a read asked before one of them ended does
    /// not clear that write's refusal.
    writes_done: u64,
    /// A read was asked while writes were out (with [`Self::writes_done`]
    /// as it was then): it runs once they have all ended, its answer then
    /// the daemon's after them.
    read_after_writes: Option<u64>,
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
            load_failed: false,
            error: None,
            generation: 0,
            _fetch: None,
            writes: 0,
            writes_done: 0,
            read_after_writes: None,
        }
    }

    pub fn settings(&self) -> &NotificationSettingsDto {
        &self.settings
    }

    /// Reads the settings again: every read path (Settings opening, a
    /// reconnect, `notifications.changed`) comes here. A read never cancels
    /// a write: asked while writes are out, it runs once they have ended.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let asked = self.writes_done;
        if self.writes > 0 {
            // The earliest ask counts: no write it waited for clears.
            self.read_after_writes.get_or_insert(asked);
            return;
        }
        self.read(asked, cx);
    }

    /// The read itself, asked when [`Self::writes_done`] was `asked_after`.
    fn read(&mut self, asked_after: u64, cx: &mut Context<Self>) {
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
                        Ok(settings) => {
                            // What the daemon holds now: a refusal older
                            // than this read no longer stands (one that
                            // ended after it was asked still does).
                            if s.writes_done == asked_after {
                                s.error = None;
                            }
                            s.adopt(settings, cx);
                        }
                        Err(e) => {
                            log::warn!("notifications.get: {e}");
                            if !s.loaded {
                                s.load_failed = true;
                                cx.notify();
                            }
                        }
                    }
                });
            }),
        );
    }

    /// A new daemon session: what was read under the last one is not known
    /// to hold now, so the settings are unknown again (nothing is written,
    /// an answer meant for the old session is not taken) until this
    /// session's read lands; a failed read then says so.
    pub fn new_session(&mut self, cx: &mut Context<Self>) {
        self.loaded = false;
        self.load_failed = false;
        self.error = None;
        self.refresh(cx);
        cx.notify();
    }

    fn adopt(&mut self, settings: NotificationSettingsDto, cx: &mut Context<Self>) {
        self.loaded = true;
        self.load_failed = false;
        self.settings = settings;
        cx.notify();
    }

    /// Sends `patch`, showing it at once; the store then shows what the
    /// daemon answers (or puts back what it had, on a refusal).
    /// Nothing is sent while the settings are unknown: a switch shown at a
    /// default would write that default over what was saved.
    pub fn set(&mut self, patch: NotificationSettingsPatch, cx: &mut Context<Self>) {
        if !self.loaded {
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        let before = self.settings.clone();
        apply(&mut self.settings, &patch);
        cx.notify();
        let call = self.rpc.call::<methods::NotificationsSet>(&patch);
        self.writes += 1;
        // Its own task, never replaced by a read.
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.writes -= 1;
                s.writes_done += 1;
                match result {
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
                }
                if s.writes == 0
                    && let Some(asked) = s.read_after_writes.take()
                {
                    s.read(asked, cx);
                }
            });
        })
        .detach();
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
        .update(cx, |c, _| c.subscribe(SUBSCRIPTION_KEY, EVENTS, vec![]));
    let s = stores.notifications.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        match event {
            ConnectionEvent::Connected { .. } => {
                s.update(cx, |s, cx| s.new_session(cx));
            }
            ConnectionEvent::Gap => {
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

    /// The settings follow their own `notifications.changed` beside the
    /// alerts `desktop` follows: neither subscription replaces the other.
    #[gpui_kit::test]
    fn the_settings_and_the_alerts_keep_their_own_subscriptions(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-notify-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        cx.update(|cx| {
            wire(&stores, cx);
            crate::desktop::follow_alerts(&stores.connection, cx);
        });
    }

    /// Until a read lands the settings are unknown: nothing is written from
    /// the defaults shown meanwhile, and a failed read says so.
    #[gpui_kit::test]
    fn unknown_settings_are_never_written(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::NotificationsGet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INTERNAL,
                "unreadable",
            ))
        });
        daemon.returns::<methods::NotificationsSet>(desktop_defaults());
        let store = cx.new(|_| NotificationsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| !s.loaded && s.load_failed));
        store.update(cx, |s, cx| {
            s.set(
                NotificationSettingsPatch {
                    sound: Some(false),
                    ..Default::default()
                },
                cx,
            )
        });
        cx.run_until_parked();
        assert!(
            daemon.calls::<methods::NotificationsSet>().is_empty(),
            "a default shown before the settings were read was written over them"
        );
        assert!(store.read_with(cx, |s, _| s.settings().sound));
    }

    /// A read that lands shows what the daemon holds: an older refusal no
    /// longer stands.
    #[gpui_kit::test]
    fn a_read_that_lands_clears_an_older_refusal(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsGet>(desktop_defaults());
        daemon.on::<methods::NotificationsSet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INVALID_PARAMS,
                "no",
            ))
        });
        let store = cx.new(|_| NotificationsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            s.set(
                NotificationSettingsPatch {
                    sound: Some(false),
                    ..Default::default()
                },
                cx,
            )
        });
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.error.is_some()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.error.is_none()));
    }

    /// A new daemon session makes the settings unknown again: nothing is
    /// written until its read lands, and a failed read says so.
    #[gpui_kit::test]
    fn a_new_session_reads_again_before_anything_is_written(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsGet>(desktop_defaults());
        daemon.returns::<methods::NotificationsSet>(desktop_defaults());
        let scratch = std::env::temp_dir().join(format!("conduit-notify-s-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            let stores = Stores::for_test(daemon.rpc(), &scratch, cx);
            wire(&stores, cx);
            stores
        });
        let reconnect = |cx: &mut TestAppContext| {
            stores.connection.update(cx, |_, cx| {
                cx.emit(super::super::connection::ConnectionEvent::Connected {
                    handshake: Box::new(conduit_daemon::rpc::Handshake::from_value(
                        serde_json::json!({}),
                    )),
                    request: serde_json::from_value(serde_json::json!({
                        "protocolVersion": "1", "clientName": "test", "clientVersion": "1",
                        "windowKind": "main", "locale": "en"
                    }))
                    .unwrap(),
                })
            });
        };
        let sound_off = |cx: &mut TestAppContext| {
            stores.notifications.update(cx, |s, cx| {
                s.set(
                    NotificationSettingsPatch {
                        sound: Some(false),
                        ..Default::default()
                    },
                    cx,
                )
            });
            cx.run_until_parked();
        };
        reconnect(cx);
        cx.run_until_parked();
        assert!(stores.notifications.read_with(cx, |s, _| s.loaded));

        // The next session's read is slow: nothing is written meanwhile.
        let held = daemon.hold::<methods::NotificationsGet>();
        reconnect(cx);
        cx.run_until_parked();
        sound_off(cx);
        assert!(
            daemon.calls::<methods::NotificationsSet>().is_empty(),
            "a setting read under the last session was written before this one's read"
        );
        drop(held);
        cx.run_until_parked();
        assert!(stores.notifications.read_with(cx, |s, _| s.loaded));

        // The next session's read fails: that shows, and nothing is written.
        daemon.on::<methods::NotificationsGet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INTERNAL,
                "unreadable",
            ))
        });
        reconnect(cx);
        cx.run_until_parked();
        assert!(
            stores
                .notifications
                .read_with(cx, |s, _| !s.loaded && s.load_failed),
            "the failed read under the new session is not shown"
        );
        sound_off(cx);
        assert!(daemon.calls::<methods::NotificationsSet>().is_empty());
    }

    /// A read asked while a write is out (a refresh, a new session, the
    /// daemon's change event) never cancels it: a write that lands shows the
    /// value written, and one refused still says so and puts the value back.
    #[gpui_kit::test]
    fn a_read_never_cancels_a_write(cx: &mut TestAppContext) {
        for (read, refused) in [
            ("refresh", false),
            ("new_session", false),
            ("refresh", true),
            ("new_session", true),
        ] {
            let daemon = FakeDaemon::new();
            // The daemon holds what was last written.
            let held_settings = std::sync::Arc::new(std::sync::Mutex::new(desktop_defaults()));
            let on_get = held_settings.clone();
            daemon.on::<methods::NotificationsGet>(move |_| {
                Ok(serde_json::to_value(on_get.lock().unwrap().clone()).unwrap())
            });
            let on_set = held_settings.clone();
            daemon.on::<methods::NotificationsSet>(move |p| {
                if refused {
                    return Err(conduit_daemon::protocol::error(
                        conduit_daemon::protocol::codes::INVALID_PARAMS,
                        "no",
                    ));
                }
                let patch: NotificationSettingsPatch = serde_json::from_value(p.clone()).unwrap();
                let mut now = on_set.lock().unwrap();
                apply(&mut now, &patch);
                Ok(serde_json::to_value(now.clone()).unwrap())
            });
            let store = cx.new(|_| NotificationsStore::new(daemon.rpc()));
            store.update(cx, |s, cx| s.refresh(cx));
            cx.run_until_parked();
            let held = daemon.hold::<methods::NotificationsSet>();
            store.update(cx, |s, cx| {
                s.set(
                    NotificationSettingsPatch {
                        sound: Some(false),
                        ..Default::default()
                    },
                    cx,
                )
            });
            cx.run_until_parked();
            store.update(cx, |s, cx| match read {
                "refresh" => s.refresh(cx),
                _ => s.new_session(cx),
            });
            cx.run_until_parked();
            drop(held);
            cx.run_until_parked();
            store.read_with(cx, |s, _| {
                assert!(s.loaded, "{read}: the settings stayed unknown");
                if refused {
                    assert!(s.error.is_some(), "{read}: the refused write says nothing");
                    assert!(s.settings().sound, "{read}: the refused value stayed shown");
                } else {
                    assert!(s.error.is_none(), "{read}: {:?}", s.error);
                    assert!(
                        !s.settings().sound,
                        "{read}: the written value is not shown"
                    );
                }
            });
        }
    }
}
