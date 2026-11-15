//! A streaming answer released at a steady rate.
//!
//! Text reaches the window in lumps: the daemon sends a snapshot every
//! 16–100 ms, a model writes a word or a whole line at once, and a span that
//! has not closed yet is held back ([`streaming_cut`]). Drawn as it comes,
//! the answer stalls and then jumps. Instead each answer's text keeps a
//! [`Pace`]: what has arrived is released a few characters every display
//! frame (the 16 ms tick), at a rate that follows the backlog, so the text
//! moves on every frame while there is anything to show.
//!
//! * **Rate:** the rate text has been arriving at (smoothed over about
//!   [`ARRIVAL_SMOOTHING`]), plus what it takes to keep about [`DELAY`] of
//!   it in hand ([`CATCH_UP`]), never under [`MIN_RATE`]. A steady stream
//!   is drawn at its own speed a little behind; one that comes a line at a
//!   time is drawn at its average speed, steadily, rather than in a burst
//!   and a wait for each line.
//! * **End of the answer:** what is left is out within [`DRAIN`] of the
//!   turn ending; a backlog over [`MAX_BACKLOG`] (a replayed turn) is let go
//!   at once.
//! * **Markup:** a release never ends inside a span that has not closed
//!   ([`streaming_cut`] of what is shown): a span the stream has already
//!   closed is let out whole in that frame rather than held while the rate
//!   crosses it. Code inside an open fence goes out character by character.
//! * **Only appends:** what is shown only grows (TextView then parses the
//!   new tail alone, and fades only it in, word by word).

use std::time::{Duration, Instant};

use super::markdown::{stable_chunks, streaming_cut};

/// How long the rate text arrives at is averaged over (seconds).
pub const ARRIVAL_SMOOTHING: f32 = 0.3;
/// How much of the arrival rate the release keeps in hand (seconds): what
/// arrives in lumps is spread over the gaps between them.
pub const DELAY: f32 = 0.15;
/// How quickly the release closes the gap to [`DELAY`] (seconds).
pub const CATCH_UP: f32 = 0.25;
/// The slowest release, in characters a second (a short tail still moves on
/// every frame or two).
pub const MIN_RATE: f32 = 60.;
/// After the turn ends, everything shows within this.
pub const DRAIN: Duration = Duration::from_millis(250);
/// …or within this while the answer's suggestions are still on their way
/// (they come 300-400 ms after the turn). It lowers only the floor of the
/// release rate: a backlog left at the turn's end is not rushed out ahead
/// of them, while text arriving fast still goes out at its own rate (the
/// common case: the last words then land about 100 ms after the turn).
pub const DRAIN_AWAITING: Duration = Duration::from_millis(400);
/// A backlog this long (characters) is shown at once.
pub const MAX_BACKLOG: usize = 6_000;
/// A frame's worth of time at most per step: a stalled frame never releases
/// a lump.
const MAX_STEP: f32 = 0.05;
/// Text at most this long when a pace starts is released from its start
/// (an answer seen from its first words); longer text (a chat reopened mid-
/// answer) shows at once and only what follows is paced.
pub const FRESH: usize = 400;

/// One text's release.
#[derive(Clone, Debug, PartialEq)]
pub struct Pace {
    /// Bytes of the text released so far.
    shown: usize,
    /// The part of a character owed from earlier frames.
    carry: f32,
    last: Instant,
    /// What had arrived at the last step (bytes), and the smoothed rate it
    /// arrives at (characters a second).
    arrived: usize,
    arrival_rate: f32,
    /// When the turn ended, once it has.
    ended: Option<Instant>,
    /// Where a stable chunk of the text starts at or before what was last
    /// looked at: open spans never cross it, so markup is read from here
    /// rather than from the top of a long answer every frame.
    base: usize,
    /// The end of what is shown, to tell text that grew from text replaced.
    seen: Seen,
}

/// The last few bytes of what was shown, and where they end.
#[derive(Clone, Debug, Default, PartialEq)]
struct Seen {
    len: usize,
    tail: String,
}

impl Seen {
    const TAIL: usize = 64;

    fn of(md: &str, len: usize) -> Self {
        let from = floor_boundary(md, len.saturating_sub(Self::TAIL));
        Self {
            len,
            tail: md[from..len].to_string(),
        }
    }

    /// Whether `md` still starts with what was shown.
    fn holds(&self, md: &str) -> bool {
        let from = self.len - self.tail.len();
        md.len() >= self.len
            && md.is_char_boundary(from)
            && md.is_char_boundary(self.len)
            && md[from..self.len] == self.tail
    }
}

impl Pace {
    /// A pace for text whose first `target` bytes are ready at `now`.
    pub fn new(md: &str, target: usize, now: Instant) -> Self {
        let target = floor_boundary(md, target.min(md.len()));
        let shown = if target <= FRESH { 0 } else { target };
        Self {
            shown,
            carry: 0.,
            last: now,
            arrived: shown,
            arrival_rate: 0.,
            ended: None,
            base: 0,
            seen: Seen::of(md, shown),
        }
    }

    /// How much of `md` may be drawn: all of it once `done`, else up to a
    /// span that has not closed ([`streaming_cut`], read from the last
    /// stable chunk on), and never less than is shown.
    pub fn target(&mut self, md: &str, done: bool) -> usize {
        if done {
            return md.len();
        }
        // Replaced text: the last text's chunk start means nothing in it
        // (and may fall inside a character).
        if !self.extends(md) {
            self.base = 0;
        }
        let base = self.chunk_base(md, md.len());
        (base + streaming_cut(&md[base..])).max(self.shown.min(md.len()))
    }

    /// Whether `md` still starts with what is shown (else it was replaced).
    pub fn extends(&self, md: &str) -> bool {
        self.seen.holds(md)
    }

    /// The start of a stable chunk of `md` at or before `upto`, moved on
    /// from the last one found (chunks only grow at the end).
    fn chunk_base(&mut self, md: &str, upto: usize) -> usize {
        if !md.is_char_boundary(self.base) {
            self.base = 0;
        }
        if upto < self.base {
            return chunk_start(&md[..upto]);
        }
        self.base += chunk_start(&md[self.base..upto]);
        self.base
    }

    /// How much of the text is shown (bytes, on a char boundary).
    pub fn shown(&self) -> usize {
        self.shown
    }

    /// Everything up to `target` is out.
    pub fn caught_up(&self, target: usize) -> bool {
        self.shown >= target
    }

    /// Text that does not start with what is shown (replaced outright):
    /// show `target` at once from here on.
    pub fn reset(&mut self, md: &str, target: usize) {
        self.shown = floor_boundary(md, target.min(md.len()));
        self.arrived = self.shown;
        self.carry = 0.;
        self.base = 0;
        self.seen = Seen::of(md, self.shown);
    }

    /// Moves on to `now`: releases toward `target` (the end of what may be
    /// drawn of `md`; all of it once `done`, within [`DRAIN`]). Returns how
    /// much is shown.
    pub fn step(&mut self, md: &str, target: usize, done: bool, now: Instant) -> usize {
        self.step_within(md, target, done, DRAIN, now)
    }

    /// [`Self::step`], with everything out within `drain` of the turn's end.
    pub fn step_within(
        &mut self,
        md: &str,
        target: usize,
        done: bool,
        drain: Duration,
        now: Instant,
    ) -> usize {
        let target = floor_boundary(md, target.min(md.len())).max(self.shown.min(md.len()));
        self.shown = floor_boundary(md, self.shown.min(target));
        let dt = now
            .saturating_duration_since(self.last)
            .as_secs_f32()
            .min(MAX_STEP);
        self.last = now;
        if done && self.ended.is_none() {
            self.ended = Some(now);
        }
        // What came in since the last step, into the smoothed arrival rate.
        let arrived = floor_boundary(md, self.arrived.min(target));
        let new = md[arrived..target].chars().count() as f32;
        self.arrived = target;
        let keep = 1. - (dt / ARRIVAL_SMOOTHING).min(1.);
        self.arrival_rate = self.arrival_rate * keep + new / ARRIVAL_SMOOTHING;
        let backlog = md[self.shown..target].chars().count();
        if backlog == 0 {
            self.carry = 0.;
            return self.shown;
        }
        if backlog > MAX_BACKLOG {
            self.shown = target;
            self.carry = 0.;
            self.seen = Seen::of(md, self.shown);
            return self.shown;
        }
        let v = self.arrival_rate;
        let mut rate = (v + (backlog as f32 - v * DELAY) / CATCH_UP).max(MIN_RATE);
        if let Some(ended) = self.ended {
            let left = (ended + drain)
                .saturating_duration_since(now)
                .as_secs_f32()
                .max(1. / 60.);
            rate = rate.max(backlog as f32 / left);
        }
        self.carry += rate * dt;
        let whole = self.carry.floor();
        self.carry -= whole;
        if whole < 1. {
            return self.shown;
        }
        let p = advance(md, self.shown, whole as usize, target);
        if p < target {
            let base = self.chunk_base(md, p);
            self.shown = clean_end(md, base, p, target).max(self.shown);
        } else {
            self.shown = target;
        }
        self.seen = Seen::of(md, self.shown);
        self.shown
    }
}

/// `n` characters on from `from`, at most `to`.
fn advance(md: &str, from: usize, n: usize, to: usize) -> usize {
    md[from..to]
        .char_indices()
        .nth(n)
        .map_or(to, |(i, _)| from + i)
}

/// The largest char boundary of `md` at or before `at`.
fn floor_boundary(md: &str, at: usize) -> usize {
    let mut at = at.min(md.len());
    while !md.is_char_boundary(at) {
        at -= 1;
    }
    at
}

/// Where a release reaching `p` may end: `p` itself when nothing is open
/// there, else (`p` is inside a span the stream has closed by `target`) the
/// first place after it where everything is closed again. Spans never cross
/// a stable chunk, so only the text from `base` (a chunk's start at or
/// before `p`) is looked at.
fn clean_end(md: &str, base: usize, p: usize, target: usize) -> usize {
    if p >= target {
        return target;
    }
    let open = |e: usize| base + streaming_cut(&md[base..e]) < e;
    if !open(p) {
        return p;
    }
    // Places a span can close: after its delimiter, a line break, or the
    // next character (a list or heading marker waits only for one); and
    // after the first character of a line (a code block's box mounts with
    // its first character of code).
    let mut tries = 0;
    let next = advance(md, p, 1, target);
    let tail = &md[p..target];
    let mut candidates = std::iter::once(next).chain(
        tail.char_indices()
            .flat_map(move |(i, c)| {
                let after = (matches!(c, '*' | '_' | '~' | '`' | '$' | ')' | ']' | '\n'))
                    .then_some(p + i + c.len_utf8());
                let first = (c == '\n')
                    .then(|| {
                        tail[i + 1..]
                            .char_indices()
                            .find(|(_, d)| !d.is_whitespace())
                            .map(|(j, d)| p + i + 1 + j + d.len_utf8())
                    })
                    .flatten();
                after.into_iter().chain(first)
            })
            .filter(move |e| *e > next),
    );
    loop {
        let Some(e) = candidates.next() else {
            return target;
        };
        if e >= target {
            return target;
        }
        tries += 1;
        if tries > 64 {
            return target;
        }
        if !open(e) {
            return e;
        }
    }
}

/// Where the last stable chunk of `md` starts (see [`stable_chunks`]).
fn chunk_start(md: &str) -> usize {
    let chunks = stable_chunks(md);
    md.len() - chunks.last().map_or(0, |c| c.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: Duration = Duration::from_micros(16_667);

    /// Frame-by-frame release of `md` arriving as `arrivals` (time in ms,
    /// bytes available), until `end_ms` (the turn ending at `done_ms`).
    /// Returns (ms, shown) for every frame.
    fn run(md: &str, arrivals: &[(u64, usize)], done_ms: u64, end_ms: u64) -> Vec<(f32, usize)> {
        let t0 = Instant::now();
        let mut pace = Pace::new(md, 0, t0);
        let mut out = vec![];
        let mut k = 0;
        loop {
            let now = t0 + FRAME * k;
            let ms = (now - t0).as_secs_f32() * 1000.;
            if ms > end_ms as f32 {
                break;
            }
            let have = arrivals
                .iter()
                .filter(|(at, _)| (*at as f32) <= ms)
                .map(|(_, n)| *n)
                .max()
                .unwrap_or(0);
            let have = floor_boundary(md, have);
            let target = streaming_cut(&md[..have]);
            let done = ms >= done_ms as f32;
            let target = if done { md.len() } else { target };
            let shown = pace.step(md, target, done, now);
            out.push((ms, shown));
            k += 1;
        }
        out
    }

    /// The longest time nothing new showed while something was waiting.
    fn longest_hold(frames: &[(f32, usize)], md_len: usize) -> f32 {
        let mut hold = 0f32;
        let mut since = frames[0].0;
        let mut last = frames[0].1;
        for (ms, shown) in frames {
            if *shown != last {
                hold = hold.max(ms - since);
                since = *ms;
                last = *shown;
            } else if *shown >= md_len {
                since = *ms;
            }
        }
        hold
    }

    fn words(n: usize) -> String {
        (0..n).map(|i| format!("word{i} ")).collect()
    }

    #[test]
    fn a_word_every_thirty_ms_moves_on_every_frame_or_two() {
        let md = words(60);
        // A word (6–7 bytes) every 30 ms, in 90 ms lumps as the server
        // batches them.
        let arrivals: Vec<(u64, usize)> =
            (1..=20u64).map(|k| (k * 90, (k as usize) * 21)).collect();
        let frames = run(&md, &arrivals, 1_900, 2_400);
        let streaming: Vec<_> = frames
            .iter()
            .filter(|(ms, _)| *ms > 120. && *ms < 1_800.)
            .cloned()
            .collect();
        let hold = longest_hold(&streaming, md.len());
        assert!(hold <= 50., "a hold of {hold} ms");
        // Never far behind: about a fifth of a second of the stream.
        for (ms, shown) in &streaming {
            let have = arrivals
                .iter()
                .filter(|(at, _)| (*at as f32) <= *ms)
                .map(|(_, n)| *n)
                .max()
                .unwrap_or(0);
            assert!(have - shown <= 70, "{ms}: {shown} of {have}");
        }
    }

    #[test]
    fn a_code_block_mounts_with_its_first_character_then_streams() {
        let md = "Here:\n\n```python\ndef orbit(period_hours: float) -> float:\n    return 360 / period_hours\n```\n";
        let opener = md.find("def").unwrap();
        let second = md.find("float:\n").unwrap() + "float:\n".len();
        // The opener, then the first line a few characters at a time, then
        // the next line whole.
        let mut arrivals: Vec<(u64, usize)> = vec![(0, opener)];
        arrivals.extend((1..=10).map(|k| (200 + k as u64 * 20, opener + k * 4)));
        arrivals.push((600, md.len() - 4));
        let frames = run(md, &arrivals, 1_000, 1_300);
        // Never the box alone: the prose, then the box with code in it.
        for (ms, shown) in &frames {
            let s = &md[..*shown];
            assert!(!s.contains("```") || *shown > opener, "{ms}: {s:?}");
        }
        let mounted = frames.iter().find(|(_, s)| *s > opener).unwrap();
        assert!(
            mounted.0 >= 220. && mounted.0 < 260.,
            "mounts as code comes: {mounted:?}"
        );
        // Then the first line moves on as it comes, never held for its end.
        let line: Vec<_> = frames
            .iter()
            .filter(|(ms, _)| *ms > 260. && *ms < 420.)
            .map(|(_, s)| *s)
            .collect();
        assert!(
            line.windows(2).filter(|w| w[1] > w[0]).count() >= 6,
            "{line:?}"
        );
        assert!(
            line.iter().any(|s| *s > opener + 4 && *s < second),
            "{line:?}"
        );
        // The next line, landing whole at 600 ms, goes out over several
        // frames, not in one.
        let jumps: Vec<usize> = frames
            .windows(2)
            .filter(|w| w[1].0 > 600. && w[1].0 < 800.)
            .map(|w| w[1].1 - w[0].1)
            .filter(|d| *d > 0)
            .collect();
        assert!(jumps.len() >= 5, "{jumps:?}");
        assert!(jumps.iter().all(|d| *d <= 16), "{jumps:?}");
    }

    #[test]
    fn code_arriving_a_line_at_a_time_is_drawn_steadily_not_in_bursts() {
        // A 40-character line every 250 ms (as a model writes code), for
        // three seconds.
        let line = "    value = compute(alpha, beta) + 1\n";
        let md: String = std::iter::repeat_n(line, 12).collect();
        let arrivals: Vec<(u64, usize)> = (0..12)
            .map(|k| (k as u64 * 250, (k + 1) * line.len()))
            .collect();
        let frames = run(&md, &arrivals, 3_200, 3_600);
        let streaming: Vec<_> = frames
            .iter()
            .filter(|(ms, _)| *ms > 400. && *ms < 2_900.)
            .cloned()
            .collect();
        let hold = longest_hold(&streaming, md.len());
        assert!(hold <= 50., "a hold of {hold} ms");
        // About the stream's own pace each frame, never a whole line.
        let steps: Vec<usize> = streaming.windows(2).map(|w| w[1].1 - w[0].1).collect();
        let largest = steps.iter().copied().max().unwrap_or(0);
        assert!(
            largest <= line.len() / 3,
            "{largest} bytes in one frame: {steps:?}"
        );
        // Even: the stream's ~2.7 characters a frame, held, rather than a
        // burst that dwindles to a character a frame before the next line.
        let steady = steps.iter().filter(|d| **d >= 2).count();
        assert!(
            steady * 10 >= steps.len() * 8,
            "{steady} of {}: {steps:?}",
            steps.len()
        );
    }

    #[test]
    fn the_end_of_the_turn_is_never_kept_waiting() {
        let md = words(200);
        // Everything arrives at once just as the turn ends.
        let frames = run(&md, &[(0, md.len())], 0, 600);
        let at = frames
            .iter()
            .find(|(_, shown)| *shown == md.len())
            .map(|(ms, _)| *ms)
            .unwrap();
        assert!(at <= DRAIN.as_millis() as f32 + 20., "all shown at {at} ms");
        // …and it still moved on frame by frame, not in one jump.
        let steps = frames.iter().filter(|(ms, _)| *ms <= at).count();
        assert!(steps >= 10, "{steps} frames");
    }

    #[test]
    fn awaiting_the_suggestions_the_last_words_take_a_little_longer() {
        let md = words(60);
        let t0 = Instant::now();
        let mut pace = Pace::new(&md, 0, t0);
        let mut at = None;
        for k in 1..60u32 {
            let now = t0 + FRAME * k;
            if pace.step_within(&md, md.len(), true, DRAIN_AWAITING, now) == md.len() {
                at = Some((now - t0).as_millis());
                break;
            }
        }
        let at = at.expect("all out");
        // Later than the plain drain, never past the longer one.
        assert!(
            at > DRAIN.as_millis() && at <= DRAIN_AWAITING.as_millis() + 20,
            "{at}"
        );
    }

    #[test]
    fn a_span_the_stream_has_closed_goes_out_whole_never_raw() {
        let md = "Plain words then **a bold phrase here** and `some code` done.";
        let frames = run(md, &[(0, md.len())], 10_000, 1_500);
        for (_, shown) in &frames {
            let s = &md[..*shown];
            assert_eq!(streaming_cut(s), s.len(), "raw markup shown: {s:?}");
        }
        assert_eq!(frames.last().unwrap().1, md.len());
        // Crossing the bold phrase costs no hold.
        assert!(longest_hold(&frames, md.len()) <= 34., "{frames:?}");
    }

    #[test]
    fn math_still_open_waits_and_shows_whole_once_closed() {
        let md = "The speed is $v = \\sqrt{GM/r}$ for a circle.";
        let open = md.find('$').unwrap() + 4;
        let frames = run(md, &[(0, open), (300, md.len())], 10_000, 900);
        for (ms, shown) in &frames {
            let s = &md[..*shown];
            assert_eq!(streaming_cut(s), s.len(), "{ms}: {s:?}");
            if *ms < 300. {
                assert!(!s.contains('$'), "{ms}: {s:?}");
            }
        }
        assert_eq!(frames.last().unwrap().1, md.len());
    }

    #[test]
    fn what_is_shown_only_grows_and_lands_on_char_boundaries() {
        let md = "Café — naïve 東京 emoji 🙂 and more text to show here.";
        let mut arrivals: Vec<(u64, usize)> = (0..md.len())
            .step_by(5)
            .map(|n| (n as u64 * 8, n))
            .collect();
        arrivals.push((md.len() as u64 * 8, md.len()));
        let frames = run(md, &arrivals, 10_000, 1_200);
        let mut last = 0;
        for (_, shown) in frames {
            assert!(shown >= last);
            assert!(md.is_char_boundary(shown));
            last = shown;
        }
        assert_eq!(last, md.len());
    }

    #[test]
    fn a_long_text_already_there_shows_at_once_and_a_huge_backlog_is_let_go() {
        let t0 = Instant::now();
        let md = words(200);
        let pace = Pace::new(&md, md.len(), t0);
        assert_eq!(pace.shown(), md.len());
        let short = Pace::new(&md, 30, t0);
        assert_eq!(short.shown(), 0);
        let huge = "x".repeat(MAX_BACKLOG + 10);
        let mut pace = Pace::new(&huge, 0, t0);
        assert_eq!(pace.step(&huge, huge.len(), false, t0 + FRAME), huge.len());
    }

    #[test]
    fn a_long_answer_is_read_from_its_last_chunk_and_a_replaced_one_is_noticed() {
        let t0 = Instant::now();
        // About 6 KB of closed paragraphs, then an open bold run.
        let mut md: String = (0..60)
            .map(|i| format!("Paragraph {i} has a few plain words in it.\n\n"))
            .collect::<String>()
            .repeat(2);
        md.push_str("And then **bold");
        let mut pace = Pace::new(&md, streaming_cut(&md), t0);
        let target = pace.target(&md, false);
        assert_eq!(
            target,
            streaming_cut(&md),
            "the same cut as over the whole text"
        );
        assert!(pace.base > 0, "read from a chunk, not the top");
        assert!(pace.extends(&format!("{md} words** done")));
        assert!(!pace.extends("Something else entirely."));
    }

    #[test]
    fn replaced_text_is_never_cut_at_the_last_texts_chunk() {
        let t0 = Instant::now();
        let md: String = (0..120)
            .map(|i| format!("Paragraph {i} has a few plain words in it.\n\n"))
            .collect();
        let mut pace = Pace::new(&md, streaming_cut(&md), t0);
        pace.target(&md, false);
        let base = pace.base;
        assert!(base > 1);
        // Replaced mid-pace: a two-byte letter straddles the old chunk start.
        let replaced = format!("{}é and more words", "a".repeat(base - 1));
        assert!(!replaced.is_char_boundary(base));
        assert!(!pace.extends(&replaced));
        let target = pace.target(&replaced, false);
        assert!(replaced.is_char_boundary(target));
        pace.reset(&replaced, target);
        assert_eq!(pace.target(&replaced, false), target);
    }

    #[test]
    fn a_stalled_frame_releases_no_lump() {
        let t0 = Instant::now();
        let md = words(100);
        let mut pace = Pace::new(&md, 0, t0);
        pace.step(&md, 60, false, t0 + FRAME);
        let before = pace.shown();
        // 400 ms with no frame, then one.
        let after = pace.step(&md, 60, false, t0 + Duration::from_millis(417));
        assert!(after - before <= 20, "{before} → {after}");
    }
}
