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
    /// What is shown: [`Self::confirmed`] with every write still out applied
    /// on top, oldest first.
    settings: NotificationSettingsDto,
    /// What the daemon last confirmed (a read, or a write's answer); the
    /// desktop's defaults until it has.
    confirmed: NotificationSettingsDto,
    /// The write whose answer (or the read asked after it) [`Self::confirmed`]
    /// came from: an older write's answer, landing later, never replaces it.
    confirmed_by: u64,
    /// The daemon has answered at least once since connecting. Until then
    /// the settings are unknown: shown as the defaults, never written.
    pub loaded: bool,
    /// The read that would have made them known failed (Settings says so
    /// and reads again when it opens).
    pub load_failed: bool,
    /// Why the newest write was refused, until the next one.
    pub error: Option<RpcError>,
    /// The daemon session the store reads and writes under; an answer from
    /// an earlier one is dropped whole.
    session: u64,
    /// The last write started. A write's ticket is (session, its number):
    /// only the newest write's outcome sets or clears [`Self::error`].
    write_seq: u64,
    /// Writes sent this session and not answered yet, by number.
    pending: Vec<(u64, NotificationSettingsPatch)>,
    /// Writes answered so far: a read asked before one of them ended does
    /// not clear that write's refusal.
    writes_done: u64,
    /// The newest read asked; an older read's answer is not taken.
    read_seq: u64,
    /// The read in flight; a newer read replaces it. Writes never share it:
    /// each runs to its end on its own task.
    _fetch: Option<Task<()>>,
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
            confirmed: desktop_defaults(),
            confirmed_by: 0,
            loaded: false,
            load_failed: false,
            error: None,
            session: 0,
            write_seq: 0,
            pending: Vec::new(),
            writes_done: 0,
            read_seq: 0,
            _fetch: None,
            read_after_writes: None,
        }
    }

    pub fn settings(&self) -> &NotificationSettingsDto {
        &self.settings
    }

    /// Shows what the daemon confirmed with the writes still out on top.
    fn show(&mut self, cx: &mut Context<Self>) {
        let mut shown = self.confirmed.clone();
        for (_, patch) in &self.pending {
            apply(&mut shown, patch);
        }
        self.settings = shown;
        cx.notify();
    }

    /// Reads the settings again: every read path (Settings opening, a
    /// reconnect, `notifications.changed`) comes here. A read never cancels
    /// a write: asked while writes are out, it runs once they have ended.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let asked = self.writes_done;
        if !self.pending.is_empty() {
            // The earliest ask counts: no write it waited for clears.
            self.read_after_writes.get_or_insert(asked);
            return;
        }
        self.read(asked, cx);
    }

    /// The read itself, asked when [`Self::writes_done`] was `asked_done`.
    /// Its answer is taken only if no newer read, write or session started
    /// after it was asked.
    fn read(&mut self, asked_done: u64, cx: &mut Context<Self>) {
        self.read_seq += 1;
        let (session, read, writes) = (self.session, self.read_seq, self.write_seq);
        let call = self.rpc.call::<methods::NotificationsGet>(&NoParams);
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.session != session || s.read_seq != read {
                        return;
                    }
                    if s.write_seq != writes {
                        // A write started after it was asked: this answer
                        // may be from before it. Read again after the writes.
                        if s.pending.is_empty() {
                            s.read(asked_done, cx);
                        } else {
                            s.read_after_writes.get_or_insert(asked_done);
                        }
                        return;
                    }
                    match result {
                        Ok(settings) => {
                            // What the daemon holds now: a refusal older
                            // than this read no longer stands (one that
                            // ended after it was asked still does).
                            if s.writes_done == asked_done {
                                s.error = None;
                            }
                            s.confirmed = settings;
                            s.confirmed_by = writes;
                            s.loaded = true;
                            s.load_failed = false;
                            s.show(cx);
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
    /// and no answer meant for the old session, read or write, is taken)
    /// until this session's read lands; a failed read then says so.
    pub fn new_session(&mut self, cx: &mut Context<Self>) {
        self.session += 1;
        self.loaded = false;
        self.load_failed = false;
        self.error = None;
        self.pending.clear();
        self.read_after_writes = None;
        self.refresh(cx);
        cx.notify();
    }

    /// Sends `patch`, showing it at once; the store then shows what the
    /// daemon confirms (a refused patch drops out of what is shown).
    /// Nothing is sent while the settings are unknown: a switch shown at a
    /// default would write that default over what was saved.
    pub fn set(&mut self, patch: NotificationSettingsPatch, cx: &mut Context<Self>) {
        if !self.loaded {
            return;
        }
        self.write_seq += 1;
        let (session, seq) = (self.session, self.write_seq);
        self.pending.push((seq, patch.clone()));
        self.show(cx);
        let call = self.rpc.call::<methods::NotificationsSet>(&patch);
        // Its own task, never replaced by a read.
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                // An earlier session's write: nothing of it is taken.
                if s.session != session {
                    return;
                }
                s.pending.retain(|(n, _)| *n != seq);
                s.writes_done += 1;
                let newest = seq == s.write_seq;
                match result {
                    Ok(settings) => {
                        if seq > s.confirmed_by {
                            s.confirmed = settings;
                            s.confirmed_by = seq;
                            // The daemon applied the older writes still out
                            // before this one: what this one set is no
                            // longer theirs to show. Their other switches
                            // stay shown until they land.
                            for (n, older) in &mut s.pending {
                                if *n < seq {
                                    superseded(older, &patch);
                                }
                            }
                        }
                        if newest {
                            s.error = None;
                        }
                    }
                    Err(e) => {
                        log::warn!("notifications.set: {e}");
                        if newest {
                            s.error = Some(e);
                        }
                    }
                }
                s.show(cx);
                if s.pending.is_empty()
                    && let Some(asked) = s.read_after_writes.take()
                {
                    s.read(asked, cx);
                }
            });
        })
        .detach();
    }
}

/// `older` without the switches `newer` sets: a confirmed newer write
/// decides them.
fn superseded(older: &mut NotificationSettingsPatch, newer: &NotificationSettingsPatch) {
    let NotificationSettingsPatch {
        enabled,
        sound,
        sound_always,
        in_app_banner,
        system,
        answers,
        channels,
        mentions_only,
    } = newer;
    let drop_if = |field: &mut Option<bool>, newer: &Option<bool>| {
        if newer.is_some() {
            *field = None;
        }
    };
    drop_if(&mut older.enabled, enabled);
    drop_if(&mut older.sound, sound);
    drop_if(&mut older.sound_always, sound_always);
    drop_if(&mut older.in_app_banner, in_app_banner);
    drop_if(&mut older.system, system);
    drop_if(&mut older.answers, answers);
    drop_if(&mut older.channels, channels);
    drop_if(&mut older.mentions_only, mentions_only);
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
    /// value written, and one refused still says so and puts the value back
    /// (unless a new session began meanwhile: its read then wins).
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
                if refused && read == "new_session" {
                    // The write belongs to the session before: its refusal
                    // is dropped, and the new session's read is shown.
                    assert!(s.error.is_none(), "{read}: the old session's refusal shows");
                    assert!(s.settings().sound, "{read}: the refused value stayed shown");
                } else if refused {
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

    /// Two writes out at once; the newer is refused first, then the older
    /// lands: the refusal stays shown, and the refused value goes back to the
    /// daemon's while the older write's value stays.
    #[gpui_kit::test]
    fn an_older_write_landing_late_never_hides_a_newer_refusal(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsGet>(desktop_defaults());
        let store = cx.new(|_| NotificationsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        // The older write (sound off) lands; the newer (banner off) is refused.
        daemon.on::<methods::NotificationsSet>(|p| {
            if p.get("inAppBanner").is_some() {
                return Err(conduit_daemon::protocol::error(
                    conduit_daemon::protocol::codes::INVALID_PARAMS,
                    "no",
                ));
            }
            Ok(serde_json::to_value(NotificationSettingsDto {
                sound: false,
                ..desktop_defaults()
            })
            .unwrap())
        });
        let older = daemon.hold_one::<methods::NotificationsSet>(0);
        store.update(cx, |s, cx| {
            s.set(
                NotificationSettingsPatch {
                    sound: Some(false),
                    ..Default::default()
                },
                cx,
            );
            s.set(
                NotificationSettingsPatch {
                    in_app_banner: Some(false),
                    ..Default::default()
                },
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.error.is_some(), "the newer refusal is not shown")
        });
        drop(older);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.error.is_some(),
                "the older write's answer hid the newer refusal"
            );
            assert!(s.settings().in_app_banner, "the refused value stayed shown");
            assert!(!s.settings().sound, "the older write's value went");
        });
    }

    /// Two writes to the same switch answered newest first: the newer's
    /// confirmed value shows at once, not the older one still out (which
    /// the daemon applied before it). An older write to another switch
    /// stays shown until it lands.
    #[gpui_kit::test]
    fn a_confirmed_write_supersedes_older_writes_to_the_same_switch(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsGet>(desktop_defaults());
        let store = cx.new(|_| NotificationsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        // The daemon applies each in turn: its answers say so.
        let state = std::sync::Arc::new(std::sync::Mutex::new(desktop_defaults()));
        let held_state = state.clone();
        daemon.on::<methods::NotificationsSet>(move |p| {
            let mut st = held_state.lock().unwrap();
            if let Some(v) = p.get("sound").and_then(|v| v.as_bool()) {
                st.sound = v;
            }
            if let Some(v) = p.get("system").and_then(|v| v.as_bool()) {
                st.system = v;
            }
            Ok(serde_json::to_value(st.clone()).unwrap())
        });
        let older = daemon.hold_one::<methods::NotificationsSet>(0);
        let set = |s: &mut NotificationsStore, patch, cx: &mut Context<NotificationsStore>| {
            s.set(patch, cx)
        };
        store.update(cx, |s, cx| {
            set(
                s,
                NotificationSettingsPatch {
                    sound: Some(false),
                    mentions_only: Some(true),
                    ..Default::default()
                },
                cx,
            );
            set(
                s,
                NotificationSettingsPatch {
                    sound: Some(true),
                    ..Default::default()
                },
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.settings().sound, "the older write's value came back");
            assert!(
                s.settings().mentions_only,
                "the older write's other switch went before it landed"
            );
        });
        drop(older);
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.settings().sound));
    }

    /// A write still out when a new daemon session begins: the new
    /// session's read lands at once, and the old write's answer (here a
    /// refusal) is dropped whole.
    #[gpui_kit::test]
    fn a_write_from_an_earlier_session_is_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotificationsGet>(desktop_defaults());
        daemon.on::<methods::NotificationsSet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INTERNAL,
                "the old session went",
            ))
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
        store.update(cx, |s, cx| s.new_session(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.loaded, "the new session's read waited on the old write");
            assert!(s.settings().sound);
        });
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.error.is_none(), "the old session's refusal was shown");
            assert!(s.settings().sound, "the old session's write was taken");
        });
    }
}
