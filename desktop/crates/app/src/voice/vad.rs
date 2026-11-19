//! Where dictation ends: an energy endpointer over 16 kHz audio.
//!
//! The phone runs Silero VAD in its app layer. The Mac does without a
//! model: speech is louder than the room, so a 20 ms frame counts as speech
//! when it stands clear of the noise floor -- the quietest frame of the
//! last three seconds, which the gaps between words reach while someone
//! talks and a steady hum never leaves -- and above an absolute floor, so a
//! dead-silent input never "hears" its own dither. Once speech has been heard, the configured pause of non-speech
//! ends the dictation (Settings › Audio's silence duration, 0.3–5 s). A
//! recognizer that is still producing words counts as speech too
//! ([`Endpointer::note_words`]), so a quiet talker is not cut off.
//!
//! Everything is counted in samples, not wall time: a file fed faster than
//! real time ends exactly where it would live.

use super::pcm;

/// 20 ms frames.
const FRAME: usize = 320;
const FRAME_MS: u32 = 20;
/// A frame this far above the floor is speech.
const MARGIN_DB: f32 = 12.0;
/// Under this, nothing is speech, however quiet the room.
const ABSOLUTE_DB: f32 = -52.0;
/// Speech must last this long to count (a click or a cough does not).
const ONSET_MS: u32 = 100;
/// How far back the noise floor looks, in frames (3 s).
const FLOOR_WINDOW: usize = 150;

/// What the endpointer concluded from the audio so far.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Nothing decided: keep listening.
    Listening,
    /// The pause after speech was long enough: dictation is over.
    EndOfSpeech,
    /// No speech came within the wait: dictation is over, empty.
    NothingHeard,
    /// The longest dictation (ten minutes) is reached.
    Limit,
}

pub struct Endpointer {
    pause_ms: u32,
    no_speech_ms: u32,
    limit_ms: u32,
    pending: Vec<f32>,
    /// The last [`FLOOR_WINDOW`] frames' levels, oldest first.
    recent: std::collections::VecDeque<f32>,
    onset_ms: u32,
    heard: bool,
    quiet_ms: u32,
    elapsed_ms: u32,
    last_db: f32,
}

impl Endpointer {
    /// Ends `pause_ms` after speech; gives up after `no_speech_ms` with
    /// none, and stops at `limit_ms` whatever happens.
    pub fn new(pause_ms: u32, no_speech_ms: u32, limit_ms: u32) -> Self {
        Self {
            pause_ms: pause_ms.clamp(300, 5_000),
            no_speech_ms,
            limit_ms,
            pending: Vec::with_capacity(FRAME * 4),
            recent: std::collections::VecDeque::with_capacity(FLOOR_WINDOW),
            onset_ms: 0,
            heard: false,
            quiet_ms: 0,
            elapsed_ms: 0,
            last_db: -120.0,
        }
    }

    /// Whether speech has been heard yet.
    pub fn heard(&self) -> bool {
        self.heard
    }

    /// The last frame's level, dBFS.
    pub fn level_db(&self) -> f32 {
        self.last_db
    }

    /// How much audio has gone by, in milliseconds.
    pub fn elapsed_ms(&self) -> u32 {
        self.elapsed_ms
    }

    /// The recognizer produced new words: speech, whatever the meter says.
    pub fn note_words(&mut self) {
        self.heard = true;
        self.quiet_ms = 0;
    }

    /// Takes more 16 kHz audio.
    pub fn push(&mut self, samples: &[f32]) -> Verdict {
        self.pending.extend_from_slice(samples);
        let mut verdict = Verdict::Listening;
        let mut start = 0;
        while start + FRAME <= self.pending.len() {
            let db = pcm::level_db(&self.pending[start..start + FRAME]);
            start += FRAME;
            let v = self.frame(db);
            if v != Verdict::Listening && verdict == Verdict::Listening {
                verdict = v;
            }
        }
        self.pending.drain(..start);
        verdict
    }

    fn frame(&mut self, db: f32) -> Verdict {
        self.last_db = db;
        self.elapsed_ms += FRAME_MS;
        if self.recent.len() == FLOOR_WINDOW {
            self.recent.pop_front();
        }
        self.recent.push_back(db);
        let floor = self.recent.iter().copied().fold(f32::INFINITY, f32::min);
        // The first 200 ms only measure the room.
        let speech = self.recent.len() >= 10 && db > (floor + MARGIN_DB).max(ABSOLUTE_DB);
        if speech {
            self.onset_ms += FRAME_MS;
            if self.onset_ms >= ONSET_MS {
                self.heard = true;
            }
            if self.heard {
                self.quiet_ms = 0;
            }
        } else {
            self.onset_ms = 0;
            self.quiet_ms += FRAME_MS;
        }
        if self.elapsed_ms >= self.limit_ms {
            Verdict::Limit
        } else if self.heard && self.quiet_ms >= self.pause_ms {
            Verdict::EndOfSpeech
        } else if !self.heard && self.elapsed_ms >= self.no_speech_ms {
            Verdict::NothingHeard
        } else {
            Verdict::Listening
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `ms` of a 200 Hz tone at `amplitude`, or of faint noise when 0.
    fn audio(ms: u32, amplitude: f32) -> Vec<f32> {
        let n = (16 * ms) as usize;
        let mut seed = 7u32;
        (0..n)
            .map(|i| {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                let noise = ((seed >> 16) as f32 / 32_768.0 - 1.0) * 0.001;
                let tone = (std::f32::consts::TAU * 200.0 * i as f32 / 16_000.0).sin();
                tone * amplitude + noise
            })
            .collect()
    }

    fn feed(e: &mut Endpointer, samples: &[f32]) -> Vec<(u32, Verdict)> {
        let mut out = vec![];
        for piece in samples.chunks(1_600) {
            let v = e.push(piece);
            if v != Verdict::Listening {
                out.push((e.elapsed_ms(), v));
            }
        }
        out
    }

    #[test]
    fn speech_then_the_pause_ends_it() {
        let mut e = Endpointer::new(1_000, 90_000, 600_000);
        let mut input = audio(500, 0.0);
        input.extend(audio(1_500, 0.3));
        input.extend(audio(3_000, 0.0));
        let verdicts = feed(&mut e, &input);
        assert!(e.heard());
        let (at, verdict) = verdicts[0];
        assert_eq!(verdict, Verdict::EndOfSpeech);
        // 0.5 s room + 1.5 s speech + the 1 s pause, within a chunk.
        assert!((3_000..=3_100).contains(&at), "ended at {at} ms");
    }

    #[test]
    fn a_pause_shorter_than_the_setting_does_not_end_it() {
        let mut e = Endpointer::new(1_500, 90_000, 600_000);
        let mut input = audio(300, 0.0);
        for _ in 0..3 {
            input.extend(audio(800, 0.3));
            input.extend(audio(1_000, 0.0));
        }
        assert!(feed(&mut e, &input).is_empty());
        assert!(e.heard());
    }

    #[test]
    fn a_click_is_not_speech() {
        let mut e = Endpointer::new(500, 2_000, 600_000);
        let mut input = audio(300, 0.0);
        input.extend(audio(40, 0.8));
        input.extend(audio(2_000, 0.0));
        let verdicts = feed(&mut e, &input);
        assert!(!e.heard());
        assert_eq!(verdicts[0].1, Verdict::NothingHeard);
    }

    #[test]
    fn a_noisy_room_raises_the_floor() {
        let mut e = Endpointer::new(800, 5_000, 600_000);
        // A steady hum at -20 dBFS is the room, not speech...
        let hum = audio(3_000, 0.14);
        assert!(feed(&mut e, &hum).is_empty());
        assert!(!e.heard());
        // ...and a voice well over it is.
        assert!(feed(&mut e, &audio(600, 0.9)).is_empty());
        assert!(e.heard());
    }

    #[test]
    fn words_from_the_recognizer_count_as_speech() {
        let mut e = Endpointer::new(600, 90_000, 600_000);
        feed(&mut e, &audio(400, 0.0));
        e.note_words();
        assert!(e.heard());
        let verdicts = feed(&mut e, &audio(800, 0.0));
        assert_eq!(verdicts[0].1, Verdict::EndOfSpeech);
    }

    #[test]
    fn the_limit_stops_it() {
        let mut e = Endpointer::new(5_000, 90_000, 1_000);
        let verdicts = feed(&mut e, &audio(1_200, 0.3));
        assert_eq!(verdicts[0], (1_000, Verdict::Limit));
    }
}
