//! Read aloud, in place: while an answer of this chat is read, the
//! sentence being said gets a soft fill and its word a strong one, in the
//! answer's own text (the fills Find in Chat uses; they paint behind the
//! glyphs, so nothing moves, and nothing animates either way).
//!
//! * **Where the words are.** What is read is the answer's text without its
//!   markup (core's `readAloudTextOf`), split into sentences; what is drawn
//!   is the rendered markdown. [`align`] walks the two together: each
//!   spoken word is looked for, a little way ahead, in the rendered text of
//!   the answer's text blocks, in order. A word not found (an emoji the
//!   voice skips, a code block's text) is left out; the next one still
//!   lands.
//! * **The word.** The Mac's voices say which word they are on; server
//!   speech is estimated from its position (core's `estimateSpokenWord`).
//!   Both come as UTF-16 offsets in the sentence.
//! * **Seeking.** A double-click on a word of the answer being read moves
//!   the reading to its sentence (a single click is the text's own; the
//!   playback bar's marks take single clicks).
//! * Find in Chat owns the fills while its bar is open.

use std::ops::Range;

use conduit_components::ActiveConduitTheme as _;
use gpui_kit::base::text::{RangeHighlight, RenderedText};
use gpui_kit::component::text::TextViewState;
use gpui_kit::{App, Context, Entity};

use super::Transcript;
use super::find::{find_fills, find_ranges};
use crate::stores::speech::SpeechStore;
use crate::views::chat::rows::{RowView, shown_answer_id};

/// How far ahead (in bytes of rendered text) a spoken word is looked for
/// before it is taken as one the text doesn't show.
const LOOKAHEAD: usize = 240;

/// A spoken word, and where it is drawn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WordAt {
    /// UTF-16 offsets in its sentence.
    pub start: usize,
    pub end: usize,
    /// Which of the answer's text blocks it is in.
    pub part: usize,
    /// Bytes of that block's rendered text.
    pub range: Range<usize>,
}

/// Each sentence's words, found in `parts` (the rendered text of an
/// answer's text blocks, in order).
pub fn align(sentences: &[String], parts: &[&str]) -> Vec<Vec<WordAt>> {
    let mut part = 0;
    let mut at = 0;
    sentences
        .iter()
        .map(|sentence| {
            let mut found = vec![];
            for (start, end, word) in words(sentence) {
                let mut p = part;
                let mut from = at;
                let mut hit = None;
                // This block from where the last word ended, then the
                // start of the next.
                while p < parts.len() && hit.is_none() {
                    let text = parts[p];
                    let from_ok = from.min(text.len());
                    let to = floor_char(text, (from_ok + LOOKAHEAD + word.len()).min(text.len()));
                    let window = &text[floor_char(text, from_ok)..to];
                    if let Some(r) = find_ranges(window, &word).into_iter().next() {
                        let base = floor_char(text, from_ok);
                        hit = Some((p, base + r.start..base + r.end));
                    } else if p == part {
                        p += 1;
                        from = 0;
                    } else {
                        break;
                    }
                }
                if let Some((p, range)) = hit {
                    part = p;
                    at = range.end;
                    found.push(WordAt {
                        start,
                        end,
                        part: p,
                        range,
                    });
                }
            }
            found
        })
        .collect()
}

/// `sentence`'s words, as UTF-16 offsets and the text matched (the word
/// without the punctuation around it); words of punctuation only are left
/// out.
fn words(sentence: &str) -> Vec<(usize, usize, String)> {
    let mut out = vec![];
    let mut utf16 = 0;
    let mut current: Option<(usize, String)> = None;
    for c in sentence.chars() {
        if c.is_whitespace() {
            if let Some((start, w)) = current.take() {
                push_word(&mut out, start, &w);
            }
        } else {
            match &mut current {
                Some((_, w)) => w.push(c),
                None => current = Some((utf16, c.to_string())),
            }
        }
        utf16 += c.len_utf16();
    }
    if let Some((start, w)) = current {
        push_word(&mut out, start, &w);
    }
    out
}

fn push_word(out: &mut Vec<(usize, usize, String)>, start: usize, w: &str) {
    let lead: usize = w
        .chars()
        .take_while(|c| !c.is_alphanumeric())
        .map(char::len_utf16)
        .sum();
    let core: String = w.trim_matches(|c: char| !c.is_alphanumeric()).to_string();
    if core.is_empty() {
        return;
    }
    let s = start + lead;
    let e = s + core.encode_utf16().count();
    out.push((s, e, core));
}

fn floor_char(s: &str, mut i: usize) -> usize {
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// The word of `words` the voice is on: the one `utf16` falls in, else the
/// next after it.
pub fn word_at(words: &[WordAt], utf16: usize) -> Option<&WordAt> {
    words
        .iter()
        .find(|w| w.start <= utf16 && utf16 < w.end)
        .or_else(|| words.iter().find(|w| w.start >= utf16))
}

/// The fills for sentence `words` with `word` the one being said, per
/// block: the sentence soft, the word strong, never overlapping.
pub fn fills(
    words: &[WordAt],
    word: Option<&WordAt>,
    soft: gpui_kit::Hsla,
    strong: gpui_kit::Hsla,
) -> Vec<(usize, Vec<RangeHighlight>)> {
    let mut by_part: Vec<(usize, Range<usize>)> = vec![];
    for w in words {
        match by_part.last_mut() {
            Some((p, r)) if *p == w.part => r.end = w.range.end,
            _ => by_part.push((w.part, w.range.clone())),
        }
    }
    by_part
        .into_iter()
        .map(|(part, span)| {
            let mut out = vec![];
            match word.filter(|w| w.part == part && span.start <= w.range.start) {
                Some(w) => {
                    if span.start < w.range.start {
                        out.push(RangeHighlight::new(span.start..w.range.start, soft));
                    }
                    out.push(RangeHighlight::new(w.range.clone(), strong));
                    if w.range.end < span.end {
                        out.push(RangeHighlight::new(w.range.end..span.end, soft));
                    }
                }
                None => out.push(RangeHighlight::new(span, soft)),
            }
            (part, out)
        })
        .collect()
}

/// The reading this transcript shows, while it does.
#[derive(Default)]
pub(super) struct Reader {
    /// The answer read (its shown version's id) and the reading's number.
    message: String,
    reading: i64,
    /// The answer's text blocks, as aligned, and their texts then.
    parts: Vec<Entity<TextViewState>>,
    texts: Vec<RenderedText>,
    words: Vec<Vec<WordAt>>,
    /// What is painted now: the sentence and the word, and in which
    /// appearance.
    painted: Option<(i64, Option<i64>, bool)>,
    /// The reading followed, to repaint in another appearance.
    speech: Option<gpui_kit::WeakEntity<SpeechStore>>,
}

impl Transcript {
    /// The sentence and word marked now, and the dark flag they were
    /// painted for (the E2E pass checks them).
    pub fn reading_painted(&self) -> Option<(i64, Option<i64>)> {
        self.reader
            .as_ref()
            .and_then(|r| r.painted)
            .map(|(s, w, _)| (s, w))
    }

    /// How many of the reading's words were found in the drawn text.
    pub fn reading_words(&self) -> usize {
        self.reader
            .as_ref()
            .map_or(0, |r| r.words.iter().map(Vec::len).sum())
    }

    /// Follows `speech`'s reading of an answer in this chat (None: none
    /// is), marking its sentence and word in place.
    pub fn follow_reading(&mut self, speech: Option<&Entity<SpeechStore>>, cx: &mut Context<Self>) {
        let Some(speech) = speech else {
            self.clear_reading(cx);
            return;
        };
        let (message, reading, sentence, word, sentences) = {
            let s = speech.read(cx);
            let p = s.progress();
            match p.message_id.clone() {
                Some(m) if s.is_active() => (
                    m,
                    p.reading,
                    p.sentence,
                    p.word_start,
                    s.sentences().to_vec(),
                ),
                _ => {
                    self.clear_reading(cx);
                    return;
                }
            }
        };
        // Find in Chat owns the fills while it is open.
        if self.find.is_some() || sentences.is_empty() {
            return;
        }
        let parts = self.reading_parts(&message, cx);
        let texts: Vec<RenderedText> = parts.iter().map(|s| s.read(cx).rendered_text()).collect();
        let stale = self
            .reader
            .as_ref()
            .is_none_or(|r| r.message != message || r.reading != reading || r.texts != texts);
        if stale {
            self.clear_reading(cx);
            let strs: Vec<&str> = texts.iter().map(RenderedText::as_str).collect();
            let words = align(&sentences, &strs);
            self.reader = Some(Reader {
                message,
                reading,
                parts,
                texts,
                words,
                painted: None,
                speech: Some(speech.downgrade()),
            });
        }
        let dark = cx.conduit().dark;
        let Some(reader) = &mut self.reader else {
            return;
        };
        if reader.painted == Some((sentence, word, dark)) {
            return;
        }
        reader.painted = Some((sentence, word, dark));
        let t = cx.conduit().clone();
        let (soft, strong) = find_fills(&t);
        let words = usize::try_from(sentence)
            .ok()
            .and_then(|s| reader.words.get(s))
            .cloned()
            .unwrap_or_default();
        let current = word.and_then(|w| word_at(&words, w.max(0) as usize).cloned());
        let fills = fills(&words, current.as_ref(), soft, strong);
        for (i, state) in reader.parts.clone().into_iter().enumerate() {
            let mine = fills.iter().find(|(p, _)| *p == i).map(|(_, f)| f.clone());
            state.update(cx, |s, cx| match mine {
                Some(f) => {
                    if s.set_range_highlights(f, cx).is_err() {
                        s.clear_range_highlights(cx);
                    }
                }
                None => s.clear_range_highlights(cx),
            });
        }
    }

    /// Before a frame: repaints the marks in the appearance's colours.
    pub(super) fn refresh_reading(&mut self, cx: &mut Context<Self>) {
        let dark = cx.conduit().dark;
        let Some(reader) = &self.reader else {
            return;
        };
        if reader.painted.is_none_or(|(_, _, d)| d == dark) {
            return;
        }
        if let Some(speech) = reader.speech.as_ref().and_then(|s| s.upgrade()) {
            self.follow_reading(Some(&speech), cx);
        }
    }

    /// Clears the reading's fills.
    fn clear_reading(&mut self, cx: &mut Context<Self>) {
        let Some(reader) = self.reader.take() else {
            return;
        };
        if self.find.is_some() {
            return;
        }
        for state in reader.parts {
            state.update(cx, |s, cx| s.clear_range_highlights(cx));
        }
    }

    /// The text blocks of the answer `message` (its shown version's id).
    fn reading_parts(
        &mut self,
        message: &str,
        cx: &mut Context<Self>,
    ) -> Vec<Entity<TextViewState>> {
        let ix = {
            let store = self.store.read(cx);
            store.rows().iter().position(|row| {
                store
                    .item(*row)
                    .is_some_and(|item| shown_answer_id(&item) == message)
            })
        };
        let Some(ix) = ix else {
            return vec![];
        };
        match self.find_row_view(ix, cx) {
            Some((_, RowView::Assistant(row))) => row
                .update(cx, |r, cx| r.find_texts(cx))
                .into_iter()
                .map(|(_, state)| state)
                .collect(),
            _ => vec![],
        }
    }

    /// A double-click in the answer being read: the sentence of the word
    /// it selected, if any.
    pub(super) fn reading_sentence_at_selection(&self, cx: &App) -> Option<usize> {
        let reader = self.reader.as_ref()?;
        for (part, state) in reader.parts.iter().enumerate() {
            let state = state.read(cx);
            let Some(source) = state.selected_source_range() else {
                continue;
            };
            let offset = state.rendered_text().range_for_source(source)?.start;
            return reader.words.iter().position(|words| {
                words
                    .iter()
                    .any(|w| w.part == part && w.range.start <= offset && offset < w.range.end)
            });
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn spoken_words_land_on_the_drawn_ones_across_blocks() {
        let sentences = s(&[
            "The harbour lights come on.",
            "A boat drifts past the buoy.",
            "Gulls settle on the pier.",
        ]);
        // Bold and a link drawn as plain words; the third sentence in the
        // next block.
        let parts = [
            "The harbour lights come on. A boat drifts past the buoy.",
            "Gulls settle on the pier.",
        ];
        let words = align(&sentences, &parts);
        assert_eq!(words.len(), 3);
        assert_eq!(words[0].len(), 5);
        let boat = &words[1][1];
        assert_eq!(&parts[0][boat.range.clone()], "boat");
        // "boat" is UTF-16 2..6 in its sentence.
        assert_eq!((boat.start, boat.end), (2, 6));
        assert!(words[2].iter().all(|w| w.part == 1));
        assert_eq!(&parts[1][words[2][0].range.clone()], "Gulls");
    }

    #[test]
    fn a_word_the_text_does_not_show_is_left_out_and_the_next_still_lands() {
        let sentences = s(&["Tea 🍵 is ready, really."]);
        let parts = ["Tea is ready, really."];
        let words = align(&sentences, &parts);
        let got: Vec<&str> = words[0]
            .iter()
            .map(|w| &parts[0][w.range.clone()])
            .collect();
        assert_eq!(got, vec!["Tea", "is", "ready", "really"]);
        // UTF-16: the emoji is two units, so "is" starts at 7.
        assert_eq!(words[0][1].start, 7);
    }

    #[test]
    fn the_word_said_is_the_one_its_offset_falls_in() {
        let sentences = s(&["One two three."]);
        let parts = ["One two three."];
        let words = &align(&sentences, &parts)[0];
        assert_eq!(word_at(words, 4).map(|w| w.start), Some(4));
        assert_eq!(word_at(words, 5).map(|w| w.start), Some(4));
        // Between words: the next.
        assert_eq!(word_at(words, 3).map(|w| w.start), Some(4));
        assert_eq!(word_at(words, 99), None);
    }

    #[test]
    fn the_sentence_is_soft_around_its_strong_word() {
        let soft = gpui_kit::black();
        let strong = gpui_kit::white();
        let sentences = s(&["One two three."]);
        let parts = ["Intro. One two three."];
        let words = &align(&sentences, &parts)[0];
        let fill = fills(words, word_at(words, 4), soft, strong);
        assert_eq!(fill.len(), 1);
        let ranges: Vec<_> = fill[0]
            .1
            .iter()
            .map(|h| (h.range(), h.background() == strong))
            .collect();
        assert_eq!(
            ranges,
            vec![(7..11, false), (11..14, true), (14..20, false)]
        );
    }
}
