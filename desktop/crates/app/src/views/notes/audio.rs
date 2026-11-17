//! A note's recordings play in the note, as mobile's audio player plays
//! them (`audio_player_dialog.dart`): Play and Pause, a scrubber to seek
//! (a click or a drag), the time played and the recording's length; at the
//! end, Play starts it over. A recording still waiting to upload plays from
//! this Mac (the daemon's `/recordings/{id}?noteId=`), one on the server
//! through the daemon's `/files`. One plays at a time: playing another
//! stops the first, and leaving the note stops it.
//!
//! The scrubber moves by the clip's clock; with Reduce Motion it moves in
//! whole seconds instead of gliding.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_daemon::http::HttpClient;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Bounds, Context, ElementId, Entity, MouseButton, MouseDownEvent,
    MouseMoveEvent, Pixels, Role, SharedString, Task, div, px,
};

use crate::shell::speech_engine::{ClipOutput, av_clip, muted};

/// Where a recording's bytes come from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioSource {
    /// A file on the active account's server.
    File { server_id: String, file_id: String },
    /// One of a note's recordings still waiting to upload.
    Waiting { note_id: String, id: String },
}

/// What the player for one recording shows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Phase {
    Loading,
    Ready,
    /// It could not be fetched, or does not play here.
    Failed,
}

/// The player's state for the recording it holds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlayerState {
    pub phase: Phase,
    pub playing: bool,
    pub position: Duration,
    pub duration: Duration,
}

impl PlayerState {
    /// How far in, from 0 to 1.
    pub fn fraction(&self) -> f32 {
        if self.duration.is_zero() {
            0.
        } else {
            (self.position.as_secs_f32() / self.duration.as_secs_f32()).clamp(0., 1.)
        }
    }

    /// "0:12 / 1:30", as mobile's player shows the two times.
    pub fn time(&self) -> String {
        format!(
            "{} / {}",
            crate::views::chat::speech_bar::clock(self.position.as_millis() as i64),
            crate::views::chat::speech_bar::clock(self.duration.as_millis() as i64)
        )
    }
}

struct Current {
    key: String,
    /// The account in charge when its load started: it is played for that
    /// account only.
    account: Option<String>,
    phase: Phase,
    clip: Option<Box<dyn ClipOutput>>,
    /// It ran to its end: shown at its length, and Play starts over.
    ended: bool,
    /// Pause was pressed: it stopped where the user left it, not at its end.
    paused: bool,
    /// Play was pressed while it loaded.
    play_when_ready: bool,
    _load: Option<Task<()>>,
    _tick: Option<Task<()>>,
}

/// The note's one player.
#[derive(Default)]
pub struct NoteAudio {
    current: Option<Current>,
}

/// How often the time and scrubber move while playing.
fn tick(reduce_motion: bool) -> Duration {
    if reduce_motion {
        Duration::from_secs(1)
    } else {
        Duration::from_millis(100)
    }
}

impl NoteAudio {
    pub fn new() -> Self {
        Self::default()
    }

    /// The state of recording `key` when it is the one held.
    pub fn state(&self, key: &str) -> Option<PlayerState> {
        let c = self.current.as_ref().filter(|c| c.key == key)?;
        let (playing, position, duration) = match &c.clip {
            Some(clip) => {
                let duration = clip.duration();
                let position = if c.ended {
                    duration
                } else {
                    clip.position().min(duration)
                };
                (clip.is_playing(), position, duration)
            }
            None => (false, Duration::ZERO, Duration::ZERO),
        };
        Some(PlayerState {
            phase: c.phase,
            playing,
            position,
            duration,
        })
    }

    /// The key of the recording held, if any.
    pub fn current_key(&self) -> Option<&str> {
        self.current.as_ref().map(|c| c.key.as_str())
    }

    /// The account the recording held was started under (None when none
    /// was in charge, or nothing is held).
    pub fn current_account(&self) -> Option<&str> {
        self.current.as_ref().and_then(|c| c.account.as_deref())
    }

    /// Play or Pause for recording `key` from `source`: the one held plays
    /// or pauses (from the start once it ended); another stops it and
    /// loads, then plays, for `account` (the one in charge now).
    pub fn toggle(
        &mut self,
        key: &str,
        source: AudioSource,
        http: Option<HttpClient>,
        account: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if let Some(c) = self.current.as_mut().filter(|c| c.key == key) {
            match (&mut c.clip, c.phase) {
                (Some(clip), Phase::Ready) => {
                    if clip.is_playing() {
                        clip.pause();
                        c.paused = true;
                    } else {
                        if c.ended {
                            clip.seek(Duration::ZERO);
                            c.ended = false;
                        }
                        c.paused = false;
                        clip.play();
                    }
                    self.start_ticking(cx);
                }
                (_, Phase::Loading) => c.play_when_ready = !c.play_when_ready,
                // Failed: try again.
                _ => self.load(key, source, http, account, cx),
            }
            cx.notify();
            return;
        }
        self.load(key, source, http, account, cx);
    }

    fn load(
        &mut self,
        key: &str,
        source: AudioSource,
        http: Option<HttpClient>,
        account: Option<String>,
        cx: &mut Context<Self>,
    ) {
        self.stop(cx);
        let key = key.to_string();
        let (tx, rx) = futures::channel::oneshot::channel();
        match http {
            Some(http) => {
                conduit_daemon::runtime::shared().spawn(async move {
                    let result = match &source {
                        AudioSource::File { server_id, file_id } => {
                            http.file(server_id, file_id).await
                        }
                        AudioSource::Waiting { note_id, id } => {
                            http.note_recording(note_id, id).await
                        }
                    };
                    let _ = tx.send(result.map(|f| f.bytes.to_vec()).map_err(|e| e.to_string()));
                });
            }
            None => {
                let _ = tx.send(Err("the daemon is not running".to_string()));
            }
        }
        let loading = key.clone();
        let load = cx.spawn(async move |this, cx| {
            let bytes = rx
                .await
                .unwrap_or_else(|_| Err("the download was dropped".into()));
            let _ = this.update(cx, |s: &mut Self, cx| {
                let Some(c) = s.current.as_mut().filter(|c| c.key == loading) else {
                    return;
                };
                match bytes.ok().and_then(|b| av_clip(&b, 1.0, muted())) {
                    Some(mut clip) => {
                        // Play was pressed again while it loaded: it waits,
                        // paused at its start.
                        c.paused = !c.play_when_ready;
                        if c.play_when_ready {
                            clip.play();
                        }
                        c.clip = Some(clip);
                        c.phase = Phase::Ready;
                        s.start_ticking(cx);
                    }
                    None => {
                        log::warn!("note recording: it does not play here");
                        c.phase = Phase::Failed;
                    }
                }
                cx.notify();
            });
        });
        self.current = Some(Current {
            key,
            account,
            phase: Phase::Loading,
            clip: None,
            ended: false,
            paused: false,
            // Mobile's player starts playing once loaded.
            play_when_ready: true,
            _load: Some(load),
            _tick: None,
        });
        cx.notify();
    }

    /// Moves recording `key` to `fraction` of its length.
    pub fn seek(&mut self, key: &str, fraction: f32, cx: &mut Context<Self>) {
        let Some(c) = self.current.as_mut().filter(|c| c.key == key) else {
            return;
        };
        let Some(clip) = c.clip.as_mut() else {
            return;
        };
        let to = clip.duration().mul_f32(fraction.clamp(0., 1.));
        clip.seek(to);
        c.ended = false;
        cx.notify();
    }

    /// Moves recording `key` by `by` seconds (← and →).
    pub fn nudge(&mut self, key: &str, by: f32, cx: &mut Context<Self>) {
        let Some(state) = self.state(key) else {
            return;
        };
        if state.duration.is_zero() {
            return;
        }
        let at = (state.position.as_secs_f32() + by).max(0.) / state.duration.as_secs_f32();
        self.seek(key, at, cx);
    }

    /// Stops and lets go of the recording held.
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        if let Some(mut c) = self.current.take()
            && let Some(clip) = c.clip.as_mut()
        {
            clip.stop();
        }
        cx.notify();
    }

    /// Moves the time and scrubber while it plays; notices the end.
    fn start_ticking(&mut self, cx: &mut Context<Self>) {
        let Some(c) = self.current.as_mut() else {
            return;
        };
        if c._tick.is_some() {
            return;
        }
        let key = c.key.clone();
        c._tick = Some(cx.spawn(async move |this, cx| {
            loop {
                let every = cx.update(|cx| tick(cx.reduce_motion()));
                cx.background_executor().timer(every).await;
                let go_on = this
                    .update(cx, |s: &mut Self, cx| {
                        let Some(c) = s.current.as_mut().filter(|c| c.key == key) else {
                            return false;
                        };
                        let Some(clip) = c.clip.as_ref() else {
                            return true;
                        };
                        if !clip.is_playing() {
                            // Not paused: it ran to its end, and shows whole.
                            if !c.paused {
                                c.ended = true;
                            }
                            c._tick = None;
                            cx.notify();
                            return false;
                        }
                        cx.notify();
                        true
                    })
                    .unwrap_or(false);
                if !go_on {
                    break;
                }
            }
        }));
    }
}

/// The words a player uses (localized by the caller).
pub struct PlayerWords {
    pub play: SharedString,
    pub pause: SharedString,
    pub position: SharedString,
    pub failed: SharedString,
    pub loading: SharedString,
}

/// The player's scrubber and time, under a recording's name: drawn once the
/// recording is held.
pub fn progress(
    id: &str,
    key: &str,
    state: PlayerState,
    audio: &Entity<NoteAudio>,
    words: &PlayerWords,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    match state.phase {
        Phase::Failed => {
            return div()
                .id(SharedString::from(format!("{id}-failed")))
                .role(Role::Status)
                .text_size(px(m.small))
                .text_color(r.danger)
                .child(words.failed.clone())
                .into_any_element();
        }
        Phase::Loading => {
            return div()
                .id(SharedString::from(format!("{id}-loading")))
                .role(Role::Status)
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(words.loading.clone())
                .into_any_element();
        }
        Phase::Ready => {}
    }
    let fraction = state.fraction();
    let bounds: Rc<Cell<Option<Bounds<Pixels>>>> = Rc::new(Cell::new(None));
    let seek_to = {
        let (audio, key, bounds) = (audio.downgrade(), key.to_string(), bounds.clone());
        move |x: Pixels, cx: &mut App| {
            let Some(b) = bounds.get() else { return };
            let w = f32::from(b.size.width);
            if w <= 0. {
                return;
            }
            let at = (f32::from(x - b.origin.x) / w).clamp(0., 1.);
            let _ = audio.update(cx, |a, cx| a.seek(&key, at, cx));
        }
    };
    let on_down = {
        let seek_to = seek_to.clone();
        move |e: &MouseDownEvent, _: &mut gpui_kit::Window, cx: &mut App| {
            seek_to(e.position.x, cx);
            cx.stop_propagation();
        }
    };
    let on_drag = move |e: &MouseMoveEvent, _: &mut gpui_kit::Window, cx: &mut App| {
        if e.pressed_button == Some(MouseButton::Left) {
            seek_to(e.position.x, cx);
        }
    };
    let keys = {
        let (audio, key) = (audio.downgrade(), key.to_string());
        move |e: &gpui_kit::KeyDownEvent, _: &mut gpui_kit::Window, cx: &mut App| {
            let by = match e.keystroke.key.as_str() {
                "left" => -5.,
                "right" => 5.,
                _ => return,
            };
            let _ = audio.update(cx, |a, cx| a.nudge(&key, by, cx));
            cx.stop_propagation();
        }
    };
    let probe = {
        let bounds = bounds.clone();
        gpui_kit::canvas(
            move |b: Bounds<Pixels>, _, _| bounds.set(Some(b)),
            |_, _, _, _| {},
        )
        .absolute()
        .size_full()
    };
    let track = with_alpha(r.text, if t.dark { 0.18 } else { 0.12 });
    let knob = 10.;
    div()
        .w_full()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(
            div()
                .id(ElementId::Name(format!("{id}-scrubber").into()))
                .role(Role::Slider)
                .aria_label(words.position.clone())
                .aria_value(SharedString::from(state.time()))
                .aria_numeric_value(f64::from(state.position.as_secs_f32()))
                .aria_min_numeric_value(0.)
                .aria_max_numeric_value(f64::from(state.duration.as_secs_f32()))
                .aria_numeric_value_step(5.)
                .tab_index(0)
                .relative()
                .flex_1()
                .h(px(16.))
                .cursor_pointer()
                .on_mouse_down(MouseButton::Left, on_down)
                .on_mouse_move(on_drag)
                .on_key_down(keys)
                .child(probe)
                .child(
                    div()
                        .absolute()
                        .left_0()
                        .right_0()
                        .top(px(6.))
                        .h(px(4.))
                        .rounded(px(2.))
                        .bg(track)
                        .child(
                            div()
                                .h_full()
                                .rounded(px(2.))
                                .bg(r.text_subtle)
                                .w(gpui_kit::relative(fraction)),
                        ),
                )
                .child(
                    div()
                        .absolute()
                        .top(px(3.))
                        .left(gpui_kit::relative(fraction))
                        .ml(px(-knob / 2.))
                        .size(px(knob))
                        .rounded_full()
                        .bg(r.text)
                        .border_1()
                        .border_color(r.content),
                ),
        )
        .child(
            div()
                .id(ElementId::Name(format!("{id}-time").into()))
                .flex_none()
                .min_w(px(72.))
                .text_right()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(state.time())),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_time_reads_as_mobile_shows_it() {
        let state = PlayerState {
            phase: Phase::Ready,
            playing: true,
            position: Duration::from_millis(12_400),
            duration: Duration::from_secs(90),
        };
        assert_eq!(state.time(), "0:12 / 1:30");
        assert!((state.fraction() - 12.4 / 90.).abs() < 1e-4);
        let empty = PlayerState {
            duration: Duration::ZERO,
            ..state
        };
        assert_eq!(empty.fraction(), 0.);
    }

    #[test]
    fn reduce_motion_steps_the_clock_by_whole_seconds() {
        assert_eq!(tick(true), Duration::from_secs(1));
        assert!(tick(false) < Duration::from_millis(250));
    }
}
