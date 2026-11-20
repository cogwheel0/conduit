//! Core's `AppSettings` (`settings.get/set`, refetched on `settings.changed`)
//! and the realtime socket's health (`data.connection`, followed by
//! `socket.health`), for Settings and for the views that act on them.
//!
//! The fields keep core's names (`send_on_enter`, `quick_pills`,
//! `show_composer_notes_button`, `temporary_chat_by_default`, ...), so the
//! composer's preferences read straight from [`AppSettingsStore::settings`].
//! A change goes to the daemon and the store shows what it answers; nothing
//! is patched here.

use conduit_daemon::RpcError;
use conduit_protocol::{AppSettingsDto, AppSettingsPatch, ConnectionHealth, NoParams, methods};
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::rpc::Rpc;

/// The events this store follows.
pub const EVENTS: &[&str] = &[
    conduit_protocol::events::SETTINGS_CHANGED,
    conduit_protocol::events::SOCKET_HEALTH,
];

pub struct AppSettingsStore {
    rpc: Rpc,
    /// What the daemon last said; core's defaults until it has.
    settings: AppSettingsDto,
    /// The daemon has answered at least once since connecting.
    pub loaded: bool,
    pub health: Option<ConnectionHealth>,
    /// Live Updates › Retry is trying to reconnect.
    pub reconnecting: bool,
    /// The last Retry ended still disconnected (until the next one, or the
    /// connection comes back).
    pub reconnect_failed: bool,
    /// Why the last change was refused, until the next one.
    pub error: Option<RpcError>,
    generation: u64,
    /// Show Scheduled Runs changes asked so far: a refusal is said only
    /// while no newer change of it was asked.
    pub scheduled_runs_writes: u64,
    _fetch: Option<Task<()>>,
    _health: Option<Task<()>>,
}

/// What the daemon answers before anything is set, shown until it has:
/// core's defaults (`AppSettings()`) with the desktop's own, which the
/// daemon applies too (`AppSettingsHostDefaults`): Send with Enter on.
pub fn desktop_defaults() -> AppSettingsDto {
    AppSettingsDto {
        computer_enabled: true,
        quick_pills: vec![],
        inline_message_actions: None,
        send_on_enter: true,
        show_composer_notes_button: true,
        show_model_name_in_composer: false,
        temporary_chat_by_default: false,
        citation_show_titles: false,
        citation_background: true,
        advanced_features_enabled: false,
        default_model: None,
        open_router_image_generation_model: None,
        socket_transport_mode: "ws".into(),
        hermes_show_scheduled_sessions: true,
        voice_call_mode: "auto".into(),
        stt_preference: "deviceOnly".into(),
        voice_locale_id: None,
        stt_language_code: None,
        voice_silence_duration: 2000,
        voice_barge_in_enabled: false,
        tts_engine: "device".into(),
        tts_voice: None,
        tts_voice_name: None,
        tts_server_voice_id: None,
        tts_server_voice_name: None,
        tts_speed: 1.0,
        direct_voice_provider: None,
        message_actions: vec![],
        default_inline_message_actions: vec![],
    }
}

impl AppSettingsStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            settings: desktop_defaults(),
            loaded: false,
            health: None,
            reconnecting: false,
            reconnect_failed: false,
            error: None,
            generation: 0,
            scheduled_runs_writes: 0,
            _fetch: None,
            _health: None,
        }
    }

    /// Live Updates › Retry: asks the daemon to reconnect the realtime
    /// socket now (`data.reconnect`), as the phone's button does.
    pub fn reconnect(&mut self, cx: &mut Context<Self>) {
        if self.reconnecting {
            return;
        }
        self.reconnecting = true;
        self.reconnect_failed = false;
        cx.notify();
        let call = self.rpc.call::<methods::DataReconnect>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.reconnecting = false;
                match result {
                    Ok(health) => {
                        s.reconnect_failed = health.available && !health.connected;
                        s.health = Some(health);
                    }
                    Err(e) => {
                        log::debug!("data.reconnect: {e}");
                        s.reconnect_failed = true;
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The settings as the daemon has them.
    pub fn settings(&self) -> &AppSettingsDto {
        &self.settings
    }

    /// The message actions shown below a response, in order: the chosen
    /// ones, or core's defaults while Automatic.
    pub fn inline_message_actions(&self) -> Vec<String> {
        self.settings
            .inline_message_actions
            .clone()
            .unwrap_or_else(|| self.settings.default_inline_message_actions.clone())
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::SettingsGet>(&NoParams);
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    match result {
                        Ok(settings) => s.adopt(settings, cx),
                        Err(e) => log::warn!("settings.get: {e}"),
                    }
                });
            }),
        );
        self.refresh_health(cx);
    }

    /// Takes what `settings.get` or a reply carried.
    pub fn adopt(&mut self, settings: AppSettingsDto, cx: &mut Context<Self>) {
        self.loaded = true;
        if self.settings != settings {
            self.settings = settings;
        }
        cx.notify();
    }

    /// Sends `patch`; the store shows the daemon's answer.
    pub fn set(&mut self, patch: AppSettingsPatch, cx: &mut Context<Self>) {
        drop(self.save(patch, cx));
    }

    /// [`Self::set`], answering whether the daemon took `patch`. Every save
    /// is answered: a later save or a refresh never drops the answer (only
    /// what is shown follows the newest).
    pub fn save(
        &mut self,
        patch: AppSettingsPatch,
        cx: &mut Context<Self>,
    ) -> futures::channel::oneshot::Receiver<bool> {
        let (done, answer) = futures::channel::oneshot::channel();
        // A later reply wins over an earlier fetch.
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::SettingsSet>(&patch);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(settings) => {
                    s.error = None;
                    if s.generation == generation {
                        s.adopt(settings, cx);
                    }
                    let _ = done.send(true);
                }
                Err(e) => {
                    log::warn!("settings.set: {e}");
                    s.error = Some(e);
                    cx.notify();
                    let _ = done.send(false);
                }
            });
        })
        .detach();
        answer
    }

    pub fn refresh_health(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::DataConnection>(&NoParams);
        self._health = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(health) => {
                            if health.connected {
                                s.reconnect_failed = false;
                            }
                            s.health = Some(health);
                        }
                        Err(e) => log::debug!("data.connection: {e}"),
                    }
                    cx.notify();
                });
            }),
        );
    }
}

/// Wires the store to the connection: fetched on every new daemon session,
/// then kept by `settings.changed` and `socket.health`.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("app-settings", EVENTS, vec![]));
    let s = stores.app_settings.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                s.update(cx, |s, cx| s.refresh(cx));
            }
            ConnectionEvent::Daemon(event) => match event.as_ref() {
                conduit_protocol::Event::SettingsChanged => {
                    s.update(cx, |s, cx| s.refresh(cx));
                }
                conduit_protocol::Event::SocketHealth => {
                    s.update(cx, |s, cx| s.refresh_health(cx));
                }
                _ => {}
            },
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

    fn sample() -> AppSettingsDto {
        AppSettingsDto {
            send_on_enter: false,
            quick_pills: vec!["web".into()],
            default_inline_message_actions: vec!["copy".into(), "tts".into()],
            ..desktop_defaults()
        }
    }

    #[gpui_kit::test]
    fn loads_then_shows_what_a_change_answers(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::SettingsGet>(sample());
        daemon.returns::<methods::DataConnection>(ConnectionHealth::default());
        daemon.on::<methods::SettingsSet>(|params| {
            let patch: AppSettingsPatch = serde_json::from_value(params.clone()).unwrap();
            let mut answer = sample();
            if let Some(v) = patch.temporary_chat_by_default {
                answer.temporary_chat_by_default = v;
            }
            Ok(serde_json::to_value(answer).unwrap())
        });
        let store = cx.new(|_| AppSettingsStore::new(daemon.rpc()));
        // The desktop's default until the daemon answers.
        assert!(store.read_with(cx, |s, _| s.settings().send_on_enter));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.loaded);
            assert!(!s.settings().send_on_enter);
            assert_eq!(s.inline_message_actions(), vec!["copy", "tts"]);
        });
        store.update(cx, |s, cx| {
            s.set(
                AppSettingsPatch {
                    temporary_chat_by_default: Some(true),
                    ..Default::default()
                },
                cx,
            )
        });
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.settings().temporary_chat_by_default));
        let sent = daemon.calls::<methods::SettingsSet>();
        assert_eq!(sent[0]["temporaryChatByDefault"], true);
        assert!(sent[0].get("sendOnEnter").is_none());
    }

    #[gpui_kit::test]
    fn a_refused_change_keeps_what_was_shown(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::SettingsSet>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::INVALID_PARAMS,
                "no",
            ))
        });
        let store = cx.new(|_| AppSettingsStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.set(
                AppSettingsPatch {
                    send_on_enter: Some(false),
                    ..Default::default()
                },
                cx,
            )
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.settings().send_on_enter);
            assert!(s.error.is_some());
        });
    }
}
