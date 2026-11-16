//! Record Audio into a note: the microphone through dictation's voice engine
//! (`voice::Session`: 16 kHz mono, metered), kept whole until Stop, then
//! written as a WAV file the daemon keeps for the note
//! (`notes.addRecording`), uploads and attaches. Nothing ends it but Stop
//! (or the ten-minute limit the phone has too): no pause detection, since
//! a recording is not dictation.
//!
//! A dev build's `CONDUIT_DICTATION_INPUT` WAV stands in for the
//! microphone (the E2E), as it does for dictation.

use std::path::PathBuf;
use std::time::Instant;

use futures::StreamExt as _;
use gpui_kit::{Context, EventEmitter, Task, WeakEntity};

use crate::voice::{self, EndReason, InputOverride, Session, SessionConfig, SessionEvent};

/// The longest recording, as the phone's.
const LIMIT_MS: u32 = 600_000;

#[derive(Clone, Debug, PartialEq)]
pub enum RecorderEvent {
    /// Stopped: the audio is at this path (a WAV file).
    Saved(PathBuf),
    /// The microphone is refused, or there is none.
    Denied,
    Failed(String),
    /// Cancelled: nothing kept.
    Cancelled,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Phase {
    Starting,
    Recording {
        since: Instant,
    },
    /// Stopped; writing the file.
    Saving,
}

pub struct Recorder {
    pub phase: Phase,
    /// The meter, 0..1.
    pub level: f32,
    session: Option<Session>,
    _run: Option<Task<()>>,
}

impl EventEmitter<RecorderEvent> for Recorder {}

impl Recorder {
    /// Starts recording (after the microphone's permission).
    pub fn start(input: Option<InputOverride>, cx: &mut Context<Self>) -> Self {
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx| {
            if input.is_none() && !crate::stores::dictation::microphone_allowed().await {
                let _ = this.update(cx, |_, cx| cx.emit(RecorderEvent::Denied));
                return;
            }
            let (tx, mut rx) = futures::channel::mpsc::unbounded();
            let config = SessionConfig {
                // Never the pause: only Stop ends a recording.
                pause_ms: LIMIT_MS,
                no_speech_ms: LIMIT_MS,
                limit_ms: LIMIT_MS,
                keep_pcm: true,
                final_wait: std::time::Duration::from_millis(0),
            };
            let session = Session::spawn(config, voice::input(input.as_ref()), None, tx);
            if this
                .update(cx, |r, cx| {
                    r.session = Some(session);
                    cx.notify();
                })
                .is_err()
            {
                return;
            }
            while let Some(event) = rx.next().await {
                let done = this
                    .update(cx, |r, cx| r.on_event(event, cx))
                    .unwrap_or(true);
                if done {
                    break;
                }
            }
        });
        Self {
            phase: Phase::Starting,
            level: 0.,
            session: None,
            _run: Some(task),
        }
    }

    /// Returns whether the recording is over.
    fn on_event(&mut self, event: SessionEvent, cx: &mut Context<Self>) -> bool {
        match event {
            SessionEvent::Started => {
                self.phase = Phase::Recording {
                    since: Instant::now(),
                };
            }
            SessionEvent::Level(level) => self.level = level,
            SessionEvent::Chunk(_) | SessionEvent::Partial(_) => {}
            SessionEvent::Ended { reason, pcm, .. } => {
                self.session = None;
                if reason == EndReason::Cancelled {
                    cx.emit(RecorderEvent::Cancelled);
                    return true;
                }
                self.phase = Phase::Saving;
                cx.notify();
                let pcm = pcm.unwrap_or_default();
                if pcm.is_empty() {
                    cx.emit(RecorderEvent::Failed("nothing was recorded".into()));
                    return true;
                }
                let name = format!("recording_{}.wav", chrono::Local::now().timestamp_millis());
                let path = std::env::temp_dir()
                    .join("conduit-note-recordings")
                    .join(name);
                let written = path
                    .parent()
                    .map(std::fs::create_dir_all)
                    .unwrap_or(Ok(()))
                    .and_then(|_| std::fs::write(&path, voice::pcm::wav(&pcm)));
                match written {
                    Ok(()) => cx.emit(RecorderEvent::Saved(path)),
                    Err(e) => cx.emit(RecorderEvent::Failed(e.to_string())),
                }
                return true;
            }
            SessionEvent::Failed(error) => {
                self.session = None;
                match error {
                    voice::SessionError::Input(voice::InputError::Denied) => {
                        cx.emit(RecorderEvent::Denied)
                    }
                    other => cx.emit(RecorderEvent::Failed(format!("{other:?}"))),
                }
                return true;
            }
        }
        cx.notify();
        false
    }

    /// Stop: keep what was recorded.
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        match &self.session {
            Some(session) => session.stop(),
            None => self.end_unstarted(cx),
        }
    }

    /// Cancel: keep nothing.
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        match &self.session {
            Some(session) => session.cancel(),
            None => self.end_unstarted(cx),
        }
    }

    /// Stop or Cancel before the microphone is set up (its permission
    /// still asked): the recording never starts, and says so.
    fn end_unstarted(&mut self, cx: &mut Context<Self>) {
        if self.phase == Phase::Starting && self._run.take().is_some() {
            cx.emit(RecorderEvent::Cancelled);
        }
    }

    /// How long it has recorded.
    pub fn elapsed(&self) -> std::time::Duration {
        match self.phase {
            Phase::Recording { since } => since.elapsed(),
            _ => std::time::Duration::ZERO,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;

    /// Stop while the microphone is still being set up ends the recording
    /// before it starts: nothing goes on recording after Stop.
    #[gpui_kit::test]
    fn stop_before_the_microphone_is_ready_records_nothing(cx: &mut TestAppContext) {
        let heard = Rc::new(RefCell::new(vec![]));
        let recorder = cx.new(|cx| Recorder::start(Some(InputOverride::Denied), cx));
        let h = heard.clone();
        cx.update(|cx| {
            cx.subscribe(&recorder, move |_, e: &RecorderEvent, _| {
                h.borrow_mut().push(e.clone())
            })
            .detach()
        });
        recorder.update(cx, |r, cx| r.stop(cx));
        cx.run_until_parked();
        assert_eq!(*heard.borrow(), vec![RecorderEvent::Cancelled]);
        assert!(recorder.read_with(cx, |r, _| r.session.is_none()));
    }
}
