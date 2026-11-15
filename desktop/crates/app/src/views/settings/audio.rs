//! Settings › Audio, the phone's Audio page and its Voice Provider page:
//! how calls talk (Realtime or Standard), speech to text (on this Mac, the
//! server, or Whisper on this Mac; the transcription language and the
//! pause that ends dictation), barge-in, text to speech (on this Mac or the
//! server; the voice, the speed, a preview), and the Direct connection that
//! speaks and listens for Direct and Apple chats.
//!
//! The engines themselves live with dictation, read aloud and calls
//! (`crate::voice`, `crate::shell::speech_engine`). This pane stores
//! and checks the choices through `settings.set` (core's `AppSettings`)
//! and `voice.*` (what the server can do, the desktop's own transcription
//! engine); the voices on this Mac are AVSpeech's ([`crate::shell::speech`]).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, Switch, setting_row};
use conduit_components::views::settings::{settings_section, stepper_with};
use conduit_protocol::{
    AppSettingsDto, AppSettingsPatch, DirectVoiceProviderDto, NoParams, VoiceProviderOptions,
    VoiceSettings, VoiceSettingsEdit, VoiceSpeak, VoiceVoices, methods,
};
use gpui_kit::component::input::{InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, Entity, SharedString, WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n, LOCALES, locale};
use crate::shell::speech::{self, DeviceVoice};
use crate::stores::Stores;
use crate::stores::app_settings::AppSettingsStore;
use crate::views::forms;

use super::controls::{self, Choice, popup};

/// Core's `ttsSpeedPresets`.
pub const SPEEDS: [f64; 5] = [0.75, 1.0, 1.25, 1.5, 2.0];

/// The speech-to-text engine shown: core's `sttPreference` picks the
/// device or not, and the desktop's own engine (`voice.*`) the server or
/// Whisper on this Mac.
pub fn stt_engine(settings: &AppSettingsDto, voice: Option<&VoiceSettings>) -> &'static str {
    if settings.stt_preference == "deviceOnly" {
        "device"
    } else if voice.is_some_and(|v| v.stt_engine == "local") {
        "local"
    } else {
        "server"
    }
}

pub struct AudioPane {
    stores: Stores,
    pub voice: Option<VoiceSettings>,
    pub server_voices: Option<VoiceVoices>,
    pub device_voices: Vec<DeviceVoice>,
    pub providers: Option<VoiceProviderOptions>,
    pub transcription_model: Entity<InputState>,
    pub speech_model: Entity<InputState>,
    pub speech_voice: Entity<InputState>,
    pub realtime_model: Entity<InputState>,
    pub realtime_voice: Entity<InputState>,
    pub instructions: Entity<TextareaState>,
    /// The connection chosen in the pop-up, before Save.
    pub provider: Option<String>,
    pub provider_saved: Option<bool>,
    pub previewing: bool,
    /// Bumped when the pane is left: a preview still on its way stays
    /// silent.
    preview_round: u64,
    /// The fields hold the loaded settings' provider.
    provider_filled: bool,
}

impl AudioPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let field = |hint: &str, window: &mut Window, cx: &mut Context<Self>| {
            forms::input(hint.to_string(), false, window, cx)
        };
        let transcription_model = field("whisper-1", window, cx);
        let speech_model = field("tts-1", window, cx);
        let speech_voice = field("alloy", window, cx);
        let realtime_model = field("gpt-realtime-2.1-mini", window, cx);
        let realtime_voice = field("marin", window, cx);
        let instructions = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, 8)
                .placeholder(l10n.voice_provider_realtime_instructions_hint())
        });
        // Opened before settings.get answered: the saved provider goes in
        // the fields once it is in (not over what was typed since).
        cx.observe_in(
            &stores.app_settings,
            window,
            |this: &mut Self, store, window, cx| {
                if !this.provider_filled && store.read(cx).loaded {
                    // What was chosen or typed meanwhile stays.
                    if this.provider_untouched(cx) {
                        this.fill_provider(window, cx);
                    } else {
                        this.provider_filled = true;
                    }
                }
                cx.notify()
            },
        )
        .detach();
        let mut this = Self {
            stores,
            voice: None,
            server_voices: None,
            device_voices: speech::voices(),
            providers: None,
            transcription_model,
            speech_model,
            speech_voice,
            realtime_model,
            realtime_voice,
            instructions,
            provider: None,
            provider_saved: None,
            preview_round: 0,
            provider_filled: false,
            previewing: false,
        };
        this.refresh(window, cx);
        this
    }

    fn store(&self) -> Entity<AppSettingsStore> {
        self.stores.app_settings.clone()
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.rpc(cx);
        let voice = rpc.call::<methods::VoiceSettings>(&NoParams);
        let voices = rpc.call::<methods::VoiceVoices>(&NoParams);
        let providers = rpc.call::<methods::SettingsVoiceProviders>(&NoParams);
        self.fill_provider(window, cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let (voice, voices, providers) = (voice.await, voices.await, providers.await);
                let _ = this.update(cx, |s, cx| {
                    match voice {
                        Ok(v) => s.voice = Some(v),
                        Err(e) => log::warn!("voice.settings: {e}"),
                    }
                    // No server, or one with no voices: only the default.
                    s.server_voices = voices.ok();
                    match providers {
                        Ok(p) => s.providers = Some(p),
                        Err(e) => log::warn!("settings.voiceProviders: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Puts the saved Voice Provider in the fields.
    /// Nothing chosen or typed in the Voice Provider group yet.
    fn provider_untouched(&self, cx: &App) -> bool {
        self.provider.is_none()
            && [
                &self.transcription_model,
                &self.speech_model,
                &self.speech_voice,
                &self.realtime_model,
                &self.realtime_voice,
            ]
            .into_iter()
            .all(|i| i.read(cx).value().is_empty())
            && self.instructions.read(cx).value().is_empty()
    }

    fn fill_provider(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let store = self.store().read(cx);
        self.provider_filled = store.loaded;
        let saved = store.settings().direct_voice_provider.clone();
        self.provider = saved.as_ref().map(|p| p.profile_id.clone());
        let p = saved.unwrap_or(DirectVoiceProviderDto {
            profile_id: String::new(),
            transcription_model: None,
            speech_model: None,
            speech_voice: None,
            realtime_model: None,
            realtime_voice: None,
            realtime_instructions: None,
        });
        let values = [
            (&self.transcription_model, p.transcription_model),
            (&self.speech_model, p.speech_model),
            (&self.speech_voice, p.speech_voice),
            (&self.realtime_model, p.realtime_model),
            (&self.realtime_voice, p.realtime_voice),
        ];
        for (input, value) in values {
            let value = value.unwrap_or_default();
            input.update(cx, |s, cx| s.set_value(value, window, cx));
        }
        let instructions = p.realtime_instructions.unwrap_or_default();
        self.instructions
            .update(cx, |s, cx| s.set_value(instructions, window, cx));
    }

    fn set(&self, patch: AppSettingsPatch, cx: &mut App) {
        self.store().update(cx, |s, cx| s.set(patch, cx));
    }

    /// Saves through `voice.saveSettings` and shows what it answers.
    fn save_voice(&mut self, edit: VoiceSettingsEdit, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc(cx).call::<methods::VoiceSaveSettings>(&edit);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(v) => s.voice = Some(v),
                        Err(e) => log::warn!("voice.saveSettings: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// A pop-up's pick.
    pub fn choose(&mut self, menu: &str, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        match menu {
            "audio-stt-engine" => self.choose_stt_engine(value, window, cx),
            "audio-stt-language" => {
                let patch = if value.is_empty() {
                    AppSettingsPatch {
                        clear: vec!["sttLanguageCode".into()],
                        ..Default::default()
                    }
                } else {
                    AppSettingsPatch {
                        stt_language_code: Some(value.to_string()),
                        ..Default::default()
                    }
                };
                self.set(patch, cx);
            }
            "audio-tts-voice" => self.choose_voice(value, cx),
            "audio-voice-provider" => {
                // A choice made (None too): the saved one never replaces it.
                self.provider_filled = true;
                self.provider = (!value.is_empty()).then(|| value.to_string());
                self.provider_saved = None;
                cx.notify();
            }
            _ => {}
        }
    }

    /// On This Mac is core's device preference; Server and Whisper on This
    /// Mac are its server one, with the desktop's engine saying which.
    pub fn choose_stt_engine(&mut self, engine: &str, window: &mut Window, cx: &mut Context<Self>) {
        match engine {
            "device" => self.set(
                AppSettingsPatch {
                    stt_preference: Some("deviceOnly".into()),
                    ..Default::default()
                },
                cx,
            ),
            "server" | "local" => {
                self.set(
                    AppSettingsPatch {
                        stt_preference: Some("serverOnly".into()),
                        ..Default::default()
                    },
                    cx,
                );
                self.save_voice(
                    VoiceSettingsEdit {
                        stt_engine: Some(engine.into()),
                        ..Default::default()
                    },
                    window,
                    cx,
                );
            }
            _ => {}
        }
    }

    fn choose_voice(&mut self, value: &str, cx: &mut Context<Self>) {
        let device = self.store().read(cx).settings().tts_engine != "server";
        let patch = if device {
            if value.is_empty() {
                AppSettingsPatch {
                    clear: vec!["ttsVoice".into()],
                    ..Default::default()
                }
            } else {
                let name = self
                    .device_voices
                    .iter()
                    .find(|v| v.id == value)
                    .map(|v| v.name.clone());
                AppSettingsPatch {
                    tts_voice: Some(value.to_string()),
                    tts_voice_name: name,
                    ..Default::default()
                }
            }
        } else if value.is_empty() {
            AppSettingsPatch {
                clear: vec!["ttsServerVoiceId".into()],
                ..Default::default()
            }
        } else {
            let name = self
                .server_voices
                .as_ref()
                .and_then(|v| v.voices.iter().find(|o| o.id == value))
                .map(|o| {
                    if o.name.is_empty() {
                        o.id.clone()
                    } else {
                        o.name.clone()
                    }
                });
            AppSettingsPatch {
                tts_server_voice_id: Some(value.to_string()),
                tts_server_voice_name: name,
                ..Default::default()
            }
        };
        self.set(patch, cx);
    }

    /// Preview Voice: the phone's sentence in the chosen voice and speed.
    pub fn preview(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let s = self.store().read(cx).settings().clone();
        let text = l10n.tts_preview_text();
        if s.tts_engine != "server" {
            speech::speak(&text, s.tts_voice.as_deref(), s.tts_speed);
            return;
        }
        let call = self.rpc(cx).call::<methods::VoiceSpeak>(&VoiceSpeak {
            text,
            voice: s.tts_server_voice_id.clone(),
        });
        let http = self.stores.connection.read(cx).http().cloned();
        self.previewing = true;
        let round = self.preview_round;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let audio = match (call.await, http) {
                    (Ok(job), Some(http)) => match http.speech(&job.job_id).await {
                        Ok(audio) => Some(audio),
                        Err(e) => {
                            log::warn!("the server's speech for a preview: {e}");
                            None
                        }
                    },
                    (Err(e), _) => {
                        log::warn!("voice.speak: {e}");
                        None
                    }
                    _ => None,
                };
                let _ = this.update(cx, |s, cx| {
                    s.previewing = false;
                    if s.preview_round != round {
                        cx.notify();
                        return;
                    }
                    if let Some(audio) = audio
                        && !speech::play(&audio.bytes)
                    {
                        log::warn!(
                            "the server's speech would not play ({})",
                            audio.content_type
                        );
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Stops Preview Voice (the pane was left, or Settings closed).
    pub fn stop_preview(&mut self, cx: &mut Context<Self>) {
        self.preview_round += 1;
        if std::mem::take(&mut self.previewing) {
            cx.notify();
        }
        speech::stop();
    }

    pub fn save_provider(&mut self, cx: &mut Context<Self>) {
        let patch = match &self.provider {
            None => AppSettingsPatch {
                clear: vec!["directVoiceProvider".into()],
                ..Default::default()
            },
            Some(id) => {
                let value = |i: &Entity<InputState>| {
                    let v = forms::text(i, cx);
                    (!v.is_empty()).then_some(v)
                };
                let instructions = self.instructions.read(cx).value().to_string();
                AppSettingsPatch {
                    direct_voice_provider: Some(DirectVoiceProviderDto {
                        profile_id: id.clone(),
                        transcription_model: value(&self.transcription_model),
                        speech_model: value(&self.speech_model),
                        speech_voice: value(&self.speech_voice),
                        realtime_model: value(&self.realtime_model),
                        realtime_voice: value(&self.realtime_voice),
                        realtime_instructions: (!instructions.trim().is_empty())
                            .then_some(instructions),
                    }),
                    ..Default::default()
                }
            }
        };
        // "Saved" once the daemon took it; a refusal says so.
        self.provider_saved = None;
        let answer = self.store().update(cx, |s, cx| s.save(patch, cx));
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut gpui_kit::AsyncApp| {
                if let Ok(ok) = answer.await {
                    let _ = this.update(cx, |s, cx| {
                        s.provider_saved = Some(ok);
                        cx.notify();
                    });
                }
            },
        )
        .detach();
        cx.notify();
    }

    fn calls_group(&self, s: &AppSettingsDto, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let modes = ["auto", "standard"];
        let store = self.store();
        let control = Segmented::new(
            "voice-call-mode",
            l10n.voice_call_mode_title(),
            vec![
                Segment::new(l10n.voice_call_mode_realtime()),
                Segment::new(l10n.voice_call_mode_standard()),
            ],
            modes
                .iter()
                .position(|m| *m == s.voice_call_mode)
                .unwrap_or(0),
        )
        .on_select(Rc::new(move |i, _, cx| {
            store.update(cx, |st, cx| {
                st.set(
                    AppSettingsPatch {
                        voice_call_mode: Some(modes[i].into()),
                        ..Default::default()
                    },
                    cx,
                )
            });
        }));
        let footer = if s.voice_call_mode == "standard" {
            l10n.voice_call_mode_standard_description()
        } else {
            l10n.voice_call_mode_realtime_description()
        };
        settings_section(
            SharedString::default(),
            Some(footer.into()),
            vec![setting_row(l10n.voice_call_mode_title(), None, control, cx).into_any_element()],
            cx,
        )
        .into_any_element()
    }

    fn stt_group(
        &self,
        s: &AppSettingsDto,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let voice = self.voice.as_ref();
        let engine = stt_engine(s, voice);
        let mut engines = vec![Choice::new("device", l10n.desktop_on_this_mac())];
        if voice.is_none_or(|v| v.server_stt) || engine == "server" {
            engines.push(Choice::new("server", l10n.stt_engine_server()));
        }
        if voice.is_some_and(|v| v.local_stt) || engine == "local" {
            engines.push(Choice::new("local", l10n.desktop_stt_engine_whisper()));
        }
        let mut rows = vec![
            setting_row(
                l10n.desktop_speech_recognition(),
                None,
                popup(
                    "audio-stt-engine",
                    &l10n.desktop_speech_recognition(),
                    engines,
                    engine,
                    false,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
        ];
        if engine != "device" {
            let mut languages = vec![Choice::new("", l10n.stt_transcription_language_auto())];
            for (i, code) in LOCALES.iter().enumerate() {
                let code = code.replace('_', "-");
                let choice = Choice::new(
                    code.clone(),
                    locale::native_name(&code.replace('-', "_")).to_string(),
                );
                languages.push(if i == 0 { choice.separated() } else { choice });
            }
            let current = s.stt_language_code.clone().unwrap_or_default();
            if !current.is_empty() && !languages.iter().any(|c| c.value == current) {
                languages.push(Choice::new(current.clone(), current.clone()).separated());
            }
            rows.push(
                setting_row(
                    l10n.stt_transcription_language(),
                    None,
                    popup(
                        "audio-stt-language",
                        &l10n.stt_transcription_language(),
                        languages,
                        &current,
                        false,
                        window,
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
            let ms = s.voice_silence_duration;
            let store = self.store();
            let stepper = stepper_with(
                "voice-silence",
                &l10n.desktop_silence_duration(),
                l10n.desktop_seconds_value(ms as f64 / 1000.),
                Some(Rc::new(move |up, _, cx| {
                    let next = if up == 1 { ms + 100 } else { ms - 100 };
                    store.update(cx, |st, cx| {
                        st.set(
                            AppSettingsPatch {
                                voice_silence_duration: Some(next.clamp(300, 5000)),
                                ..Default::default()
                            },
                            cx,
                        )
                    });
                })),
                cx,
            );
            rows.push(
                setting_row(
                    l10n.desktop_silence_duration(),
                    Some(l10n.desktop_silence_duration_description().into()),
                    stepper,
                    cx,
                )
                .into_any_element(),
            );
        }
        let store = self.store();
        let barge = s.voice_barge_in_enabled;
        rows.push(
            setting_row(
                l10n.voice_barge_in(),
                Some(l10n.voice_barge_in_description().into()),
                Switch::new("voice-barge-in", l10n.voice_barge_in(), barge).on_click(Rc::new(
                    move |_, _, cx| {
                        store.update(cx, |st, cx| {
                            st.set(
                                AppSettingsPatch {
                                    voice_barge_in_enabled: Some(!barge),
                                    ..Default::default()
                                },
                                cx,
                            )
                        });
                    },
                )),
                cx,
            )
            .into_any_element(),
        );
        settings_section(l10n.stt_settings(), None, rows, cx).into_any_element()
    }

    fn tts_group(
        &self,
        s: &AppSettingsDto,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let server_ok = self.voice.as_ref().is_none_or(|v| v.server_tts);
        let device = s.tts_engine != "server";
        let store = self.store();
        let engines = ["device", "server"];
        let engine = Segmented::new(
            "tts-engine",
            l10n.tts_settings(),
            vec![
                Segment::new(l10n.desktop_on_this_mac()),
                Segment::new(l10n.tts_engine_server()),
            ],
            usize::from(!device),
        )
        .on_select(Rc::new(move |i, _, cx| {
            if i == 1 && !server_ok {
                return;
            }
            store.update(cx, |st, cx| {
                st.set(
                    AppSettingsPatch {
                        tts_engine: Some(engines[i].into()),
                        ..Default::default()
                    },
                    cx,
                )
            });
        }));
        let mut voices = vec![Choice::new("", l10n.tts_system_default())];
        let selected = if device {
            let language = cx.l10n().locale().to_string();
            for (i, v) in speech::voices_for(&self.device_voices, &language)
                .iter()
                .enumerate()
            {
                let label = format!("{} ({})", v.name, v.language);
                let choice = Choice::new(v.id.clone(), label);
                voices.push(if i == 0 { choice.separated() } else { choice });
            }
            s.tts_voice.clone().unwrap_or_default()
        } else {
            if let Some(list) = &self.server_voices {
                for (i, v) in list.voices.iter().enumerate() {
                    let label = if v.name.is_empty() {
                        v.id.clone()
                    } else {
                        v.name.clone()
                    };
                    let choice = Choice::new(v.id.clone(), label);
                    voices.push(if i == 0 { choice.separated() } else { choice });
                }
            }
            s.tts_server_voice_id.clone().unwrap_or_default()
        };
        let speed = s.tts_speed;
        let store = self.store();
        let speeds = Segmented::new(
            "tts-speed",
            l10n.tts_playback_speed(),
            SPEEDS
                .iter()
                .map(|v| Segment::new(l10n.tts_speed_value(*v)))
                .collect(),
            SPEEDS
                .iter()
                .position(|v| (*v - speed).abs() < 0.01)
                .unwrap_or(1),
        )
        .on_select(Rc::new(move |i, _, cx| {
            store.update(cx, |st, cx| {
                st.set(
                    AppSettingsPatch {
                        tts_speed: Some(SPEEDS[i]),
                        ..Default::default()
                    },
                    cx,
                )
            });
        }));
        let view = cx.entity().downgrade();
        // Beside the voice it plays, as System Settings' Spoken Content.
        let preview = conduit_components::views::kit::IconButton::new(
            "tts-preview",
            conduit_components::assets::IconName::Play,
            l10n.tts_preview(),
        )
        .size(26., 13.)
        .disabled(self.previewing)
        .on_click(Rc::new(move |_, window, cx| {
            let _ = view.update(cx, |v, cx| v.preview(window, cx));
        }));
        let voice_control = div()
            .flex()
            .items_center()
            .gap(px(6.))
            .child(popup(
                "audio-tts-voice",
                &l10n.tts_voice(),
                voices,
                &selected,
                false,
                window,
                cx,
            ))
            .child(preview);
        settings_section(
            l10n.tts_settings(),
            (!server_ok && !device).then(|| l10n.desktop_server_speech_unavailable().into()),
            vec![
                setting_row(l10n.desktop_speech_engine(), None, engine, cx).into_any_element(),
                setting_row(l10n.tts_voice(), None, voice_control, cx).into_any_element(),
                setting_row(l10n.tts_playback_speed(), None, speeds, cx).into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }

    fn provider_group(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let providers = self.providers.clone().unwrap_or_default();
        let mut choices = vec![Choice::new("", l10n.voice_provider_none())];
        for (i, p) in providers.connections.iter().enumerate() {
            let choice = Choice::new(p.id.clone(), p.name.clone());
            choices.push(if i == 0 { choice.separated() } else { choice });
        }
        let selected = self.provider.clone().unwrap_or_default();
        let mut rows = vec![
            setting_row(
                l10n.voice_provider_connection(),
                None,
                popup(
                    "audio-voice-provider",
                    &l10n.voice_provider_connection(),
                    choices,
                    &selected,
                    // A saved provider can still be set back to None.
                    providers.connections.is_empty() && self.provider.is_none(),
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
        ];
        let mut extra = vec![];
        if self.provider.is_some() {
            for (label, input) in [
                (
                    l10n.voice_provider_transcription_model(),
                    &self.transcription_model,
                ),
                (l10n.voice_provider_speech_model(), &self.speech_model),
                (l10n.voice(), &self.speech_voice),
                (l10n.voice_provider_realtime_model(), &self.realtime_model),
                (l10n.desktop_realtime_voice(), &self.realtime_voice),
            ] {
                rows.push(forms::field(label, input, None, None, window, cx).into_any_element());
            }
            rows.push(
                div()
                    .p(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(div().text_size(px(cx.conduit().metrics.control)).child(
                        SharedString::from(l10n.voice_provider_realtime_instructions()),
                    ))
                    .child(Textarea::new(&self.instructions))
                    .into_any_element(),
            );
        }
        // Save, once there is a connection to choose or one to forget.
        let saved = self
            .store()
            .read(cx)
            .settings()
            .direct_voice_provider
            .is_some();
        if !providers.connections.is_empty() || saved {
            let view = cx.entity().downgrade();
            extra.push(
                controls::buttons(vec![
                    Button::new("voice-provider-save", l10n.save())
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| v.save_provider(cx));
                        }))
                        .into_any_element(),
                ])
                .into_any_element(),
            );
        }
        let footer = if providers.connections.is_empty() {
            l10n.voice_provider_no_connections()
        } else if self.provider.is_some() {
            l10n.voice_provider_models_hint()
        } else {
            l10n.voice_provider_description()
        };
        let note = self.provider_saved.map(|ok| {
            let note = if ok {
                l10n.desktop_saved()
            } else {
                l10n.desktop_action_failed()
            };
            forms::form_note(note, ok, cx).into_any_element()
        });
        div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(settings_section(
                l10n.voice_provider_title(),
                Some(footer.into()),
                rows,
                cx,
            ))
            .children(note)
            .children(extra)
            .into_any_element()
    }
}

impl Render for AudioPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let s = self.store().read(cx).settings().clone();
        div()
            .flex()
            .flex_col()
            .gap(px(22.))
            .child(self.calls_group(&s, &l10n, cx))
            .child(self.stt_group(&s, &l10n, window, cx))
            .child(self.tts_group(&s, &l10n, window, cx))
            .child(self.provider_group(&l10n, window, cx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stores::app_settings::desktop_defaults;

    #[test]
    fn the_engine_follows_core_then_the_desktop_engine() {
        let mut s = desktop_defaults();
        let mut voice = VoiceSettings::default();
        assert_eq!(stt_engine(&s, Some(&voice)), "device");
        s.stt_preference = "serverOnly".into();
        voice.stt_engine = "server".into();
        assert_eq!(stt_engine(&s, Some(&voice)), "server");
        voice.stt_engine = "local".into();
        assert_eq!(stt_engine(&s, Some(&voice)), "local");
        assert_eq!(stt_engine(&s, None), "server");
    }

    #[gpui_kit::test]
    fn a_provider_the_daemon_refused_never_says_saved(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        daemon.once::<methods::SettingsSet>(Err(conduit_daemon::protocol::error(
            "rpc.invalidParams",
            "no such connection",
        )));
        let scratch = std::env::temp_dir().join(format!("conduit-audio-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) = cx.add_window_view(move |window, cx| AudioPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update(vcx, |p, cx| {
            p.provider = None;
            p.save_provider(cx);
            assert_eq!(p.provider_saved, None, "Saved before the daemon answered");
        });
        vcx.run_until_parked();
        view.read_with(vcx, |p, _| assert_eq!(p.provider_saved, Some(false)));
    }

    #[gpui_kit::test]
    fn a_provider_chosen_before_settings_load_is_kept(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-provider-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| AudioPane::new(s, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.choose("audio-voice-provider", "dc-mine", window, cx);
            p.speech_model
                .update(cx, |i, cx| i.set_value("my-speech-model", window, cx));
        });
        let mut loaded = stores
            .app_settings
            .read_with(vcx, |s, _| s.settings().clone());
        loaded.direct_voice_provider = Some(DirectVoiceProviderDto {
            profile_id: "dc-stored".into(),
            transcription_model: None,
            speech_model: Some("stored-speech-model".into()),
            speech_voice: None,
            realtime_model: None,
            realtime_voice: None,
            realtime_instructions: None,
        });
        stores.app_settings.update(vcx, |s, cx| s.adopt(loaded, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |p, cx| {
            assert_eq!(
                p.provider.as_deref(),
                Some("dc-mine"),
                "the choice was replaced"
            );
            assert_eq!(p.speech_model.read(cx).value(), "my-speech-model");
        });
    }

    #[gpui_kit::test]
    fn none_chosen_before_settings_load_stays_none(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-provider-none-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| AudioPane::new(s, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.choose("audio-voice-provider", "dc-mine", window, cx);
            p.choose("audio-voice-provider", "", window, cx);
        });
        let mut loaded = stores
            .app_settings
            .read_with(vcx, |s, _| s.settings().clone());
        loaded.direct_voice_provider = Some(DirectVoiceProviderDto {
            profile_id: "dc-stored".into(),
            transcription_model: None,
            speech_model: None,
            speech_voice: None,
            realtime_model: None,
            realtime_voice: None,
            realtime_instructions: None,
        });
        stores.app_settings.update(vcx, |s, cx| s.adopt(loaded, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |p, _| {
            assert_eq!(p.provider, None, "None was replaced by the saved provider");
        });
    }
}
