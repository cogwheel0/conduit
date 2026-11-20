//! An answer's typed blocks, drawn (the protocol's message blocks):
//!
//! * `status`: the last line of the timeline, or "Exploring/Explored …"
//!   for a run of Hermes tools (`summary`); opens to every line, its
//!   queries and the pages it found;
//! * `reasoning`: a quiet disclosure, titled per [`ReasoningTitle`] with
//!   the duration; the body is markdown;
//! * `toolCalls`: one card per call, arguments and result pretty-printed
//!   when they are JSON;
//! * `codeInterpreter`: the code, then its output as markdown;
//!   `codeExecution`: the code, its output as plain text, and its error;
//! * `details`: a plain disclosure; `error`: a banner;
//! * `files`: images inline (through the daemon's `/files`), other files
//!   as chips that open in their app (PDFs are staged first);
//! * `sources` and `followUps` are drawn by the row (the pill in the
//!   action row once finished; follow-ups under the last answer only).
//!
//! Text-bearing blocks keep one `TextViewState` each, keyed by kind and
//! ordinal so a new block in front (a status line arriving) does not
//! reset the text after it.

use std::collections::HashSet;
use std::rc::Rc;
use std::time::Instant;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, MONO_FONT, with_alpha};
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::Button;
use conduit_components::views::markdown::CodeBlock;
use conduit_protocol::{
    ChatFileDto, MessageBlockDto, MessageBlockKind, MessageStatusDto, ReasoningTitle, StatusPhrase,
    ToolCallDto,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, Context, Div, ElementId, FontWeight, Role,
    SharedString, Stateful, Transformation, Window, div, img, percentage, px, relative,
};

use super::lazy_chunk::LazyChunk;
use super::markdown::{chat_text, chat_text_live, decode_data_image, stable_chunks, streaming_cut};
use super::pace::Pace;
use super::rows::AssistantRow;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::files::{
    FileRef, OpenWith, file_image_state, open_attachment, retry_file_image,
};

/// How long every chunk of an answer stays laid out for Find in Chat's
/// reveal: a little longer than TextView keeps a reveal it cannot show.
const REVEAL_LAYOUT: std::time::Duration = std::time::Duration::from_millis(1_500);

/// Longest argument or result drawn in full (the rest is cut, with an
/// ellipsis; copying the answer still has all of it).
const MAX_TOOL_TEXT: usize = 20_000;

/// An activity line's height ("Searched 3 sites", "Thought for 6 seconds",
/// "Used Tide Table · Port Wren", "Ran code"): every one the same, so a
/// run of them reads on one pitch.
pub const ACTIVITY_ROW: f32 = 22.;
/// Between activity lines in one run.
pub const ACTIVITY_GAP: f32 = 4.;

/// A tool's name as people read it: `tide_table` → "Tide Table". Core's
/// rule (`WorkspaceToolContent.formatToolName`, which the workspace's tool
/// editor uses): `-` and `_` become spaces and every word starts upper
/// case; nothing else changes, so a name already in words stays as written.
/// Runs of spaces close up.
pub fn tool_display_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut word_start = true;
    for c in name.trim().chars() {
        let c = if c == '-' || c == '_' { ' ' } else { c };
        if c.is_whitespace() {
            if !out.is_empty() && !out.ends_with(' ') {
                out.push(' ');
            }
            word_start = true;
            continue;
        }
        if word_start && c.is_alphanumeric() {
            out.extend(c.to_uppercase());
        } else {
            out.push(c);
        }
        word_start = !c.is_alphanumeric();
    }
    out.trim_end().to_string()
}

/// Whether `title` is a tool's id rather than words (`get_current_timestamp`,
/// `search`): one token of ASCII letters, digits, `_`, `-`, `.` or `:`. An
/// Open WebUI tool approval is titled with the tool's id.
pub fn is_tool_id(title: &str) -> bool {
    let t = title.trim();
    !t.is_empty()
        && t.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
}

/// What follows "Ran code ·" on a code run's line, and whether it is code:
/// the run's first comment as words when one leads it (within its first
/// few lines), else its first line of code (drawn in the mono face).
pub fn code_summary(code: &str) -> Option<(String, bool)> {
    // A shebang or an encoding line is neither a description nor the code.
    let lines: Vec<&str> = code
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("#!") && !l.contains("-*-"))
        .collect();
    for line in lines.iter().take(5) {
        // A comment is its marker then a space (`# `, `// `, `-- `, or the
        // marker doubled), so `#include` or `--flag` is still code.
        let words = ["#", "//", "--"]
            .iter()
            .find_map(|mark| line.strip_prefix(mark))
            .map(|rest| rest.trim_start_matches(['#', '/', '-']))
            .filter(|rest| rest.starts_with(' '))
            .map(str::trim);
        if let Some(words) = words.filter(|w| !w.is_empty()) {
            return Some((words.to_string(), false));
        }
    }
    lines.first().map(|l| (l.to_string(), true))
}

/// The part of an activity line after its "·": words, or a fragment of
/// code in the mono face.
#[derive(Clone, Debug, PartialEq)]
pub struct LineDetail {
    pub text: String,
    pub mono: bool,
}

impl LineDetail {
    fn words(text: String) -> Option<Self> {
        (!text.trim().is_empty()).then_some(Self { text, mono: false })
    }
}

/// "8 seconds", "3 minutes", for "Thought for …".
pub fn reasoning_duration(seconds: i64, l10n: &L10n) -> String {
    if seconds < 60 {
        l10n.desktop_reasoning_seconds(seconds.max(0))
    } else {
        l10n.desktop_reasoning_minutes((seconds + 30) / 60)
    }
}

/// A reasoning block's header.
pub fn reasoning_title(block: &MessageBlockDto, l10n: &L10n) -> String {
    match block.title {
        Some(ReasoningTitle::Thinking) => l10n.thinking(),
        Some(ReasoningTitle::ThoughtFor) => l10n.thought_for_duration(&reasoning_duration(
            block.duration_seconds.unwrap_or(0),
            l10n,
        )),
        Some(ReasoningTitle::Summary) => block
            .summary
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| l10n.thoughts()),
        Some(ReasoningTitle::Thoughts) | Some(ReasoningTitle::Unknown) | None => {
            if block.pending == Some(true) {
                l10n.thinking()
            } else {
                l10n.thoughts()
            }
        }
    }
}

/// The status row's one line: the summary of a Hermes tool run, else the
/// last status.
pub fn status_line(block: &MessageBlockDto, l10n: &L10n) -> Option<String> {
    let pending = block.pending == Some(true);
    if let Some(summary) = block.summary.as_ref().filter(|s| !s.trim().is_empty()) {
        return Some(if pending {
            l10n.markdown_details_group_pending_title(summary)
        } else {
            l10n.markdown_details_group_complete_title(summary)
        });
    }
    block
        .statuses
        .as_ref()?
        .last()
        .map(|s| status_text(s, l10n))
        .filter(|d| !d.trim().is_empty())
}

/// What a status line reads: core's own lines in this language
/// ([`StatusPhrase`]), else the server's words as they came.
pub fn status_text(status: &MessageStatusDto, l10n: &L10n) -> String {
    let query = status.query.as_deref().filter(|q| !q.trim().is_empty());
    match (status.phrase, query, status.count) {
        (Some(StatusPhrase::KnowledgeSearch), Some(q), _) => {
            l10n.desktop_status_searching_knowledge(q)
        }
        (Some(StatusPhrase::Searching), _, _) => l10n.desktop_status_searching(),
        (Some(StatusPhrase::Querying), _, _) => l10n.desktop_status_querying(),
        (Some(StatusPhrase::SourcesRetrieved), _, Some(n)) => l10n.desktop_status_sources(n),
        (Some(StatusPhrase::Processing), _, _) => l10n.desktop_status_processing(),
        _ => status.description.clone(),
    }
}

/// What a tool call's line names after its tool ("Port Wren"): the first
/// string among its JSON arguments, else the first value as JSON; empty
/// when the arguments are not a JSON object.
pub fn tool_argument(arguments: &str) -> String {
    serde_json::from_str::<serde_json::Value>(arguments)
        .ok()
        .and_then(|v| {
            v.as_object().and_then(|o| {
                o.values()
                    .find_map(|v| v.as_str().map(str::to_string))
                    .or_else(|| o.values().next().map(|v| v.to_string()))
            })
        })
        .unwrap_or_default()
}

/// One activity line's row: [`ACTIVITY_ROW`] high, its parts centred. A
/// focusable line wraps it: the keyboard outline grows outward from the
/// wrapper (its margin cancels its border and padding), so the row's own
/// height must be on this child, or the line would take 8 pt less than it
/// draws whenever Full Keyboard Access is on (r2's uneven 30/26/22 pitch).
fn activity_line() -> Div {
    div()
        .h(px(ACTIVITY_ROW))
        .min_w_0()
        .flex()
        .items_center()
        .gap(px(5.))
}

/// JSON pretty-printed; a JSON string unwrapped; anything else as it is.
pub fn pretty(text: &str) -> String {
    let trimmed = text.trim();
    let out = match serde_json::from_str::<serde_json::Value>(trimmed) {
        Ok(serde_json::Value::String(s)) => match serde_json::from_str::<serde_json::Value>(&s) {
            Ok(v @ (serde_json::Value::Object(_) | serde_json::Value::Array(_))) => {
                serde_json::to_string_pretty(&v).unwrap_or(s)
            }
            _ => s,
        },
        Ok(v) => serde_json::to_string_pretty(&v).unwrap_or_else(|_| trimmed.to_string()),
        Err(_) => trimmed.to_string(),
    };
    if out.len() > MAX_TOOL_TEXT {
        let mut cut = MAX_TOOL_TEXT;
        while !out.is_char_boundary(cut) {
            cut -= 1;
        }
        format!("{}\n…", &out[..cut])
    } else {
        out
    }
}

/// A spinner (rotating loader) while something runs.
/// What an error block says: the server's own words, or a plain sentence.
pub fn error_text(block: &MessageBlockDto, l10n: &L10n) -> String {
    let typed = match block.r#type.as_deref() {
        Some("directToolsUnsupported") => Some(l10n.direct_model_tools_unsupported()),
        // A polling-only server may still be writing it (the core's English
        // stays out of the window).
        Some("heldReplyStillRunning") => Some(l10n.held_reply_still_running()),
        // A relay to one of the user's Tether devices that failed.
        Some("tetherInterrupted") => Some(l10n.tether_relay_interrupted()),
        Some("tetherUnavailable") => Some(l10n.tether_relay_unavailable()),
        Some("tetherBusy") => Some(l10n.tether_relay_busy()),
        Some(t) => apple_error_text(t, l10n),
        None => None,
    };
    typed.unwrap_or_else(|| {
        block
            .error
            .clone()
            .filter(|e| !e.trim().is_empty())
            .unwrap_or_else(|| l10n.desktop_something_went_wrong())
    })
}

/// Apple's on-device engine's failure (the daemon's `appleFailure.*` and
/// `appleUnavailable.*` types) in this language; None for another type,
/// whose block keeps the words it came with.
pub fn apple_error_text(kind: &str, l10n: &L10n) -> Option<String> {
    Some(match kind {
        "appleUnavailable.systemTooOld" => l10n.desktop_apple_error_system_too_old(),
        "appleUnavailable.deviceNotEligible" => l10n.desktop_apple_mac_not_eligible(),
        "appleUnavailable.appleIntelligenceNotEnabled" => {
            l10n.desktop_apple_error_intelligence_off()
        }
        "appleUnavailable.modelNotReady" => l10n.desktop_apple_error_model_not_ready(),
        "appleUnavailable.notOffered" => l10n.desktop_apple_error_pcc_not_offered(),
        "appleUnavailable.other" => l10n.desktop_apple_error_unavailable(),
        "appleFailure.contextExceeded" => l10n.desktop_apple_error_context_exceeded(),
        "appleFailure.notReady" => l10n.desktop_apple_error_not_ready(),
        "appleFailure.guardrail" => l10n.desktop_apple_error_guardrail(),
        "appleFailure.refusal" => l10n.desktop_apple_error_refusal(),
        "appleFailure.unsupported" => l10n.desktop_apple_error_unsupported(),
        "appleFailure.decoding" => l10n.desktop_apple_error_decoding(),
        "appleFailure.busy" => l10n.desktop_apple_error_busy(),
        "appleFailure.timedOut" => l10n.desktop_apple_error_timed_out(),
        "appleFailure.invalidRequest" => l10n.desktop_apple_error_invalid_request(),
        "appleFailure.invalidSchema" => l10n.desktop_apple_error_invalid_schema(),
        "appleFailure.invalidToolSchema" => l10n.desktop_apple_error_invalid_tool_schema(),
        "appleFailure.invalidStream" => l10n.desktop_apple_error_invalid_stream(),
        "appleFailure.failed" => l10n.desktop_apple_error_failed(),
        _ => return None,
    })
}

pub fn spinner(id: impl Into<ElementId>, size: f32, color: gpui_kit::Hsla) -> AnyElement {
    icon(IconName::LoaderCircle, size, color)
        .with_animation(
            id,
            Animation::new(std::time::Duration::from_millis(900)).repeat(),
            |svg, delta| svg.with_transformation(Transformation::rotate(percentage(delta))),
        )
        .into_any_element()
}

/// An opened disclosure's body, under its line: indented behind a rule.
fn disclosure_body(t: &ConduitTheme) -> Div {
    div()
        .ml(px(2.))
        .pl(px(12.))
        .border_l_2()
        .border_color(t.roles.border)
}

/// A labelled box of monospace text.
fn mono_box(label: &str, content: String, t: &ConduitTheme) -> Div {
    let r = t.roles;
    div()
        .flex()
        .flex_col()
        .gap(px(4.))
        .child(
            div()
                .text_size(px(t.metrics.caption))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(SharedString::from(label.to_string())),
        )
        .child(
            div()
                .px(px(10.))
                .py(px(8.))
                .rounded(px(6.))
                // The code blocks' fill: raised in both modes.
                .bg(conduit_components::theme::composite(
                    r.raised,
                    t.surfaces.panel,
                ))
                .border_1()
                .border_color(r.border)
                .font_family(MONO_FONT)
                .text_size(px(t.metrics.code - 0.5))
                .line_height(relative(1.5))
                .text_color(r.text)
                .child(SharedString::from(content)),
        )
}

/// What a card's status icon shows.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Run {
    Running,
    Done,
    Failed,
}

/// The key of the `k`th embed of block `i` (an Embeds block).
fn embed_id(i: usize, k: usize) -> String {
    format!("e{i}.{k}")
}

/// The key of the `k`th embed tool call `j` of block `i` showed.
fn tool_embed_id(i: usize, j: usize, k: usize) -> String {
    format!("t{i}.{j}.{k}")
}

/// The keys of every embed `blocks` draw, as [`AssistantRow::render_block`]
/// names them: the row keeps those views and lets the others go (their
/// pages and MCP Apps with them).
pub(super) fn embed_ids(blocks: &[MessageBlockDto]) -> std::collections::HashSet<String> {
    let mut ids = std::collections::HashSet::new();
    for (i, block) in blocks.iter().enumerate() {
        match block.kind {
            MessageBlockKind::Embeds => {
                let n = block.embeds.as_ref().map_or(0, Vec::len);
                ids.extend((0..n).map(|k| embed_id(i, k)));
            }
            MessageBlockKind::ToolCalls => {
                for (j, call) in block.calls.iter().flatten().enumerate() {
                    if call.done && !call.pending {
                        ids.extend((0..call.shown_embeds.len()).map(|k| tool_embed_id(i, j, k)));
                    }
                }
            }
            _ => {}
        }
    }
    ids
}

impl AssistantRow {
    /// The one fix a Hermes failure's card offers here: the first of the
    /// daemon's that this chat can perform, with what pressing it does.
    fn hermes_error_action(
        &self,
        error: &conduit_protocol::HermesErrorDto,
        key: &str,
        l10n: &L10n,
        cx: &App,
    ) -> Option<(String, super::hermes_blocks::Run)> {
        let idle = !self.item.streaming;
        let store = self.host.store.clone();
        let pane = self.host.pane.clone();
        let key = key.to_string();
        for action in &error.actions {
            let Some(label) = super::hermes_blocks::action_label(action, error, l10n) else {
                continue;
            };
            let run: super::hermes_blocks::Run = match action.as_str() {
                "retry" if idle && self.flags.can_branch => {
                    let (store, key) = (store.clone(), key.clone());
                    std::rc::Rc::new(move |_, cx| {
                        let _ = store.update(cx, |s, cx| s.regenerate(&key, None, cx));
                    })
                }
                "switchModel" if idle && self.flags.can_branch => {
                    let model = error.switch_to.as_ref()?.model_id.clone();
                    let (store, key) = (store.clone(), key.clone());
                    std::rc::Rc::new(move |_, cx| {
                        let _ =
                            store.update(cx, |s, cx| s.regenerate(&key, Some(model.clone()), cx));
                    })
                }
                "continueReply" if idle && self.flags.can_follow_up => {
                    let pane = pane.clone();
                    std::rc::Rc::new(move |window, cx| pane.send("continue".into(), window, cx))
                }
                "compact" if self.flags.abilities.hermes_context => {
                    let chat = store.upgrade()?.read(cx).chat_id().to_string();
                    std::rc::Rc::new(move |window, cx| {
                        crate::views::hermes_context_sheet::open(chat.clone(), window, cx)
                    })
                }
                "openBilling" => {
                    let url = error.billing_url.clone()?;
                    std::rc::Rc::new(move |_, cx| super::markdown::open_web_link(&url, cx))
                }
                "openProviderSettings" => {
                    let url = error.provider_settings_url.clone()?;
                    std::rc::Rc::new(move |_, cx| super::markdown::open_web_link(&url, cx))
                }
                "newChat" => std::rc::Rc::new(|window, cx| {
                    window.dispatch_action(Box::new(crate::actions::NewChat), cx)
                }),
                _ => continue,
            };
            return Some((label, run));
        }
        None
    }

    /// How much of text block `ordinal` (`md`) to draw while the answer
    /// streams, and for a moment after: what has arrived, released at a
    /// steady rate ([`Pace`]). Moves the release on when `advance` (once a
    /// frame, from the drawing); `None` when the text is not paced (an
    /// answer opened finished, a regenerate's old answer, Reduce Motion).
    pub(super) fn paced_len(
        &mut self,
        ordinal: usize,
        md: &str,
        advance: bool,
        now: Instant,
        reduce_motion: bool,
    ) -> Option<(usize, bool)> {
        // A regenerate's old answer (also drawn while it crossfades out)
        // shows as it is, and never touches the new answer's paces.
        if self.item.stale {
            return None;
        }
        if reduce_motion || (!self.item.streaming && !self.paces.contains_key(&ordinal)) {
            self.paces.remove(&ordinal);
            return None;
        }
        let done = !self.item.streaming;
        let drain = if self.awaits_suggestions(now) {
            super::pace::DRAIN_AWAITING
        } else {
            super::pace::DRAIN
        };
        let pace = self.paces.entry(ordinal).or_insert_with(|| {
            let target = if done { md.len() } else { streaming_cut(md) };
            Pace::new(md, target, now)
        });
        let target = pace.target(md, done);
        if !pace.extends(md) {
            // Replaced outright: shown at once, as TextView shows it.
            pace.reset(md, target);
        }
        let n = if advance {
            pace.step_within(md, target, done, drain, now)
        } else {
            pace.shown()
        };
        let pending = !pace.caught_up(target);
        if advance && done && !pending {
            self.paces.remove(&ordinal);
        }
        Some((n, pending))
    }

    /// The text of block `ordinal` as drawn (see [`Self::paced_len`]),
    /// whether it is paced, and whether more is waiting to be released.
    fn shown_text<'a>(
        &mut self,
        ordinal: usize,
        md: &'a str,
        advance: bool,
        now: Instant,
        reduce_motion: bool,
    ) -> (&'a str, bool, bool) {
        match self.paced_len(ordinal, md, advance, now, reduce_motion) {
            Some((n, pending)) => (&md[..n], true, pending),
            None => (md, false, false),
        }
    }

    /// What of a streaming text to draw under `key`: all but a span that
    /// has not closed ([`streaming_cut`]), and never less than the row
    /// already drew of the same text (so the TextView only ever appends).
    fn held<'a>(&self, key: &str, md: &'a str) -> &'a str {
        let mut cut = streaming_cut(md);
        if let Some((drawn, _)) = self.texts.get(key)
            && md.starts_with(drawn.as_str())
        {
            cut = cut.max(drawn.len());
        }
        &md[..cut]
    }

    /// The answer's text states in reading order, keyed as [`Self::render_block`]
    /// draws them (one per text block, or one per chunk of a long one), made
    /// for any not drawn yet: Find in Chat searches rows off screen too.
    pub(crate) fn find_texts(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Vec<(
        String,
        gpui_kit::Entity<gpui_kit::component::text::TextViewState>,
    )> {
        // Text and alert bodies, in the answer's order (Find walks them
        // as drawn).
        let mut texts: Vec<(bool, usize, String)> = vec![];
        let (mut text_n, mut alert_n) = (0, 0);
        for b in &self.item.blocks {
            match b.kind {
                MessageBlockKind::Text => {
                    texts.push((false, text_n, b.markdown.clone().unwrap_or_default()));
                    text_n += 1;
                }
                MessageBlockKind::Alert => {
                    texts.push((true, alert_n, b.markdown.clone().unwrap_or_default()));
                    alert_n += 1;
                }
                _ => {}
            }
        }
        let now = cx.background_executor().now();
        let reduce_motion = cx.reduce_motion();
        let mut out = vec![];
        for (alert, ordinal, md) in texts.iter() {
            if *alert {
                if !md.trim().is_empty() {
                    let key = format!("alert{ordinal}");
                    let state = self.ensure_text(&key, md, cx);
                    out.push((key, state));
                }
                continue;
            }
            let ordinal = *ordinal;
            // The same text the row draws: never more (the pace releases it).
            let (md, paced, _) = self.shown_text(ordinal, md, false, now, reduce_motion);
            let streaming = self.item.streaming && !paced;
            let chunks = stable_chunks(md);
            let parts: Vec<(String, String)> = if chunks.len() == 1 {
                let key = format!("text{ordinal}");
                let md = if streaming { self.held(&key, md) } else { md };
                vec![(key, md.to_string())]
            } else {
                let last = chunks.len() - 1;
                chunks
                    .iter()
                    .enumerate()
                    .map(|(k, chunk)| {
                        let key = format!("text{ordinal}.{k}");
                        let mut chunk = chunk.trim_end();
                        if streaming && k == last {
                            chunk = self.held(&key, chunk);
                        }
                        (key, chunk.to_string())
                    })
                    .collect()
            };
            for (key, md) in parts {
                let state = self.ensure_text(&key, &md, cx);
                out.push((key, state));
            }
        }
        out
    }

    /// A settled chunk of a long answer, held while it is far from the
    /// view ([`LazyChunk`]) only while nothing depends on its live layout:
    /// nothing in it changes height on its own, it has no focus, the answer
    /// has no selection (`selected`: being made or made), Find is not
    /// revealing a match in this answer, and it has no link or code block
    /// while Full Keyboard Access is on. Its place drops a height measured
    /// for another text.
    fn lazy_chunk(
        &mut self,
        state: &gpui_kit::Entity<gpui_kit::component::text::TextViewState>,
        md: &str,
        selected: bool,
        text: impl FnOnce() -> AnyElement + 'static,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> LazyChunk {
        let place = self.places.entry(state.entity_id()).or_default().clone();
        let facts = place.text_facts(md);
        let now = cx.background_executor().now();
        let revealing = self.revealing_until.is_some_and(|until| now < until);
        let keyboard = conduit_components::views::focus::full_keyboard_access(cx);
        let s = state.read(cx);
        // Its height is only kept from a layout of this text, for the
        // parse that drew it.
        let rendered = s.rendered_text();
        let settled = (rendered.source() == md).then_some(rendered);
        let may_hold = !revealing
            && !selected
            && !s.focus_handle().contains_focused(window, cx)
            && !facts.media
            && !(keyboard && facts.stops);
        LazyChunk::new(place, text).holdable(may_hold, settled)
    }

    /// Whether any text of this answer has a selection, being made or made
    /// (the drag ended): its chunks then stay laid out, so the selection
    /// keeps every one of them and Copy takes all of its text. Worked out
    /// once per frame, however many long text blocks ask.
    fn has_selection(&mut self, cx: &App) -> bool {
        if let Some(known) = self.selection_now {
            return known;
        }
        let selected = self.texts.values().any(|(_, state)| {
            let s = state.read(cx);
            s.is_selecting() || !s.selected_text().is_empty()
        });
        self.selection_now = Some(selected);
        selected
    }

    /// Forgets the places of text states this row no longer has.
    fn prune_places(&mut self) {
        let leaving = self.leaving_texts().count();
        if self.places.len() <= self.texts.len() + leaving + 8 {
            return;
        }
        let live: HashSet<gpui_kit::EntityId> = self
            .texts
            .values()
            .map(|(_, s)| s.entity_id())
            .chain(self.leaving_texts().map(|s| s.entity_id()))
            .collect();
        self.places.retain(|id, _| live.contains(id));
    }

    /// Lays out every chunk of the answer for a moment: Find in Chat is
    /// revealing a match in it, which only a laid-out chunk can scroll to.
    pub fn reveal_text(&mut self, cx: &mut Context<Self>) {
        self.revealing_until = Some(cx.background_executor().now() + REVEAL_LAYOUT);
        // A comparison's columns draw their own text.
        for view in self.column_views() {
            view.update(cx, |r, cx| r.reveal_text(cx));
        }
        cx.notify();
    }

    /// Draws block `i`.
    pub(super) fn render_block(
        &mut self,
        i: usize,
        ordinal: usize,
        block: &MessageBlockDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let key = self.item.key.clone();
        Some(match block.kind {
            MessageBlockKind::Text => {
                // No caret appended while streaming: each snapshot must
                // extend the last one for TextView to parse only the new
                // tail (`set_text` appends then; anything else is a full
                // reparse of the whole answer every frame).
                let md = block.markdown.as_deref().unwrap_or_default();
                // Released at a steady rate while it streams (already free
                // of open spans), else held back at an open span.
                let now = cx.background_executor().now();
                let (md, paced, pending) =
                    self.shown_text(ordinal, md, true, now, cx.reduce_motion());
                if pending {
                    window.request_animation_frame();
                }
                let (held, live) = text_mode(self.item.streaming, paced);
                // A long answer is drawn in stable chunks, so streaming
                // re-lays out only the last one, and the earlier ones far
                // from the view are not laid out at all (`LazyChunk`).
                let chunks = stable_chunks(md);
                let last = chunks.len() - 1;
                let growing = self.item.streaming || pending;
                let views: Vec<AnyElement> = if chunks.len() == 1 {
                    let state_key = format!("text{ordinal}");
                    let md = if held { self.held(&state_key, md) } else { md };
                    let state = self.text_state(&state_key, md, window, cx);
                    vec![chat_text_live(&state, key.clone().into(), live).into_any_element()]
                } else {
                    let selected = self.has_selection(cx);
                    let views = chunks
                        .iter()
                        .enumerate()
                        .map(|(k, chunk)| {
                            let state_key = format!("text{ordinal}.{k}");
                            let mut chunk = chunk.trim_end();
                            // Earlier chunks end at a closed paragraph.
                            if held && k == last {
                                chunk = self.held(&state_key, chunk);
                            }
                            let state = self.text_state(&state_key, chunk, window, cx);
                            let tail = live && k == last;
                            if growing && k == last {
                                return chat_text_live(&state, key.clone().into(), tail)
                                    .into_any_element();
                            }
                            // Made only if it is laid out.
                            let text = {
                                let (state, key) = (state.clone(), key.clone());
                                move || chat_text_live(&state, key.into(), tail).into_any_element()
                            };
                            self.lazy_chunk(&state, chunk, selected, text, window, cx)
                                .into_any_element()
                        })
                        .collect();
                    self.prune_places();
                    views
                };
                div()
                    .w_full()
                    .flex()
                    .flex_col()
                    .gap(px(m.body * 0.8))
                    .text_size(px(m.body))
                    .line_height(relative(m.leading))
                    .text_color(r.text)
                    .children(views)
                    .into_any_element()
            }
            MessageBlockKind::Reasoning => {
                let title = reasoning_title(block, &l10n);
                let pending = block.pending == Some(true);
                let x = format!("x{i}");
                let expanded = self.shows(&x, cx);
                let body = expanded
                    .then(|| block.body.clone().filter(|b| !b.trim().is_empty()))
                    .flatten()
                    .map(|b| {
                        let state = self.text_state(&format!("reasoning{ordinal}"), &b, window, cx);
                        chat_text(&state, key.clone().into())
                    });
                // No gap: the space above the body opens with it (reveal).
                div()
                    .id(ElementId::Name(format!("reasoning-{key}-{i}").into()))
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .id(ElementId::Name(
                                format!("reasoning-toggle-{key}-{i}").into(),
                            ))
                            .role(Role::Button)
                            .aria_label(SharedString::from(title.clone()))
                            .aria_expanded(self.expanded.contains(&x))
                            .flex()
                            .cursor_pointer()
                            // The phone's quiet line: "Thought for 2 seconds ›".
                            .child(
                                activity_line()
                                    .when(pending, |d| {
                                        d.child(spinner(
                                            ElementId::Name(
                                                format!("reasoning-spin-{key}-{i}").into(),
                                            ),
                                            12.,
                                            r.text_subtle,
                                        ))
                                    })
                                    .child(
                                        div()
                                            .text_size(px(m.body))
                                            .text_color(r.text_subtle)
                                            .child(SharedString::from(title)),
                                    )
                                    .child(self.chevron_for(&x, &t, cx)),
                            )
                            .on_click(cx.listener({
                                let x = x.clone();
                                move |this, _, _, cx| this.toggle(&x, cx)
                            }))
                            .keyboard_outline(4., cx),
                    )
                    .when_some(body, |d, body| {
                        d.child(
                            self.reveal(
                                &x,
                                disclosure_body(&t)
                                    .text_size(px(m.control))
                                    .line_height(relative(1.55))
                                    .text_color(r.text_subtle)
                                    .child(body),
                                cx,
                            ),
                        )
                    })
                    .into_any_element()
            }
            MessageBlockKind::ToolCalls => {
                let calls = block.calls.clone().unwrap_or_default();
                // What a finished call showed (HTML, a page, an MCP App)
                // goes under the group, as the phone shows it even with
                // the group closed.
                let embeds: Vec<AnyElement> = calls
                    .iter()
                    .enumerate()
                    .filter(|(_, call)| call.done && !call.pending)
                    .flat_map(|(j, call)| {
                        call.shown_embeds
                            .iter()
                            .enumerate()
                            .map(move |(k, e)| (tool_embed_id(i, j, k), e.clone()))
                    })
                    .map(|(id, embed)| self.embed_view(&id, &embed, true, cx).into_any_element())
                    .collect();
                div()
                    .flex()
                    .flex_col()
                    .gap(px(ACTIVITY_GAP))
                    .children(
                        calls
                            .iter()
                            .enumerate()
                            .map(|(j, call)| self.tool_call(i, j, call, &l10n, &t, cx)),
                    )
                    .when(!embeds.is_empty(), |d| {
                        d.child(
                            div()
                                .pt(px(4.))
                                .flex()
                                .flex_col()
                                .gap(px(8.))
                                .children(embeds),
                        )
                    })
                    .into_any_element()
            }
            MessageBlockKind::Embeds => {
                let embeds = block.embeds.clone().unwrap_or_default();
                div()
                    .w_full()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .children(embeds.iter().enumerate().map(|(k, embed)| {
                        self.embed_view(&embed_id(i, k), embed, false, cx)
                            .into_any_element()
                    }))
                    .into_any_element()
            }
            MessageBlockKind::Alert => {
                let kind = block.r#type.clone().unwrap_or_default();
                let (label, glyph, color) = alert_style(&kind, &l10n, &t);
                let md = block.markdown.clone().unwrap_or_default();
                let body = (!md.trim().is_empty()).then(|| {
                    let state = self.text_state(&format!("alert{ordinal}"), &md, window, cx);
                    div()
                        .text_size(px(m.body))
                        .line_height(relative(m.leading))
                        .text_color(r.text)
                        .child(chat_text(&state, key.clone().into()))
                });
                div()
                    .id(ElementId::Name(format!("alert-{key}-{i}").into()))
                    .role(Role::Note)
                    .aria_label(SharedString::from(label.clone()))
                    .w_full()
                    .flex()
                    .gap(px(12.))
                    .child(div().w(px(3.)).flex_none().rounded(px(1.5)).bg(color))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .py(px(2.))
                            .flex()
                            .flex_col()
                            .gap(px(4.))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(6.))
                                    .child(icon(glyph, 16., color))
                                    .child(
                                        div()
                                            .text_size(px(m.body))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(color)
                                            .child(SharedString::from(label)),
                                    ),
                            )
                            .children(body),
                    )
                    .into_any_element()
            }
            MessageBlockKind::CodeInterpreter => {
                let x = format!("x{i}");
                let expanded = self.shows(&x, cx);
                let pending = block.pending == Some(true);
                let language = block
                    .language
                    .clone()
                    .filter(|l| !l.is_empty())
                    .unwrap_or_else(|| "python".into());
                let code = block.code.clone().unwrap_or_default();
                let output = expanded
                    .then(|| block.output.clone().filter(|o| !o.trim().is_empty()))
                    .flatten()
                    .map(|o| {
                        let state = self.text_state(&format!("output{ordinal}"), &o, window, cx);
                        chat_text(&state, key.clone().into())
                    });
                let title = if pending {
                    l10n.desktop_running_code()
                } else {
                    l10n.desktop_ran_code()
                };
                let body = div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(CodeBlock::new(code.clone()).lang(Some(language.to_lowercase())))
                    .when_some(output, |d, o| {
                        d.child(
                            div()
                                .flex()
                                .flex_col()
                                .gap(px(4.))
                                .child(
                                    div()
                                        .text_size(px(m.caption))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(r.text_subtle)
                                        .child(SharedString::from(l10n.output())),
                                )
                                .child(div().text_size(px(m.control)).child(o)),
                        )
                    });
                // "Ran code · Average daily lag" from a leading comment, else
                // the first line in the mono face; never code as the title.
                let detail = code_summary(&code).map(|(text, mono)| LineDetail { text, mono });
                self.card(
                    format!("code-run-{key}-{i}"),
                    x,
                    IconName::SquareTerminal,
                    title,
                    detail,
                    if pending { Run::Running } else { Run::Done },
                    expanded,
                    Some(body.into_any_element()),
                    &t,
                    cx,
                )
                .into_any_element()
            }
            MessageBlockKind::CodeExecution => {
                let x = format!("x{i}");
                let expanded = self.shows(&x, cx);
                let name = block
                    .name
                    .clone()
                    .filter(|n| !n.trim().is_empty())
                    .unwrap_or_default();
                let failed = block.is_error == Some(true);
                let pending = block.pending == Some(true);
                // The phone's plain line: what happened, then the run's name.
                let title = if failed {
                    l10n.desktop_code_failed()
                } else if pending {
                    l10n.desktop_running_code()
                } else {
                    l10n.desktop_ran_code()
                };
                let code = block.code.clone().unwrap_or_default();
                let output = block.output.clone().filter(|o| !o.trim().is_empty());
                let error = block.error.clone().filter(|e| !e.trim().is_empty());
                let body = div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .when(!code.is_empty(), |d| {
                        d.child(CodeBlock::new(code.clone()).lang(block.language.clone()))
                    })
                    .when_some(output, |d, o| d.child(mono_box(&l10n.output(), o, &t)))
                    .when_some(error, |d, e| {
                        d.child(mono_box(&l10n.desktop_tool_result(), e, &t))
                    })
                    .children(
                        block
                            .files
                            .as_ref()
                            .map(|f| self.files(i, f, &l10n, &t, window, cx)),
                    );
                // The run's own name ("Average daily lag"), else what the
                // code says of itself.
                let detail = LineDetail::words(name)
                    .or_else(|| code_summary(&code).map(|(text, mono)| LineDetail { text, mono }));
                self.card(
                    format!("code-exec-{key}-{i}"),
                    x,
                    IconName::SquareTerminal,
                    title,
                    detail,
                    if failed {
                        Run::Failed
                    } else if pending {
                        Run::Running
                    } else {
                        Run::Done
                    },
                    expanded,
                    Some(body.into_any_element()),
                    &t,
                    cx,
                )
                .into_any_element()
            }
            MessageBlockKind::Details => {
                let x = format!("x{i}");
                let expanded = self.shows(&x, cx);
                let summary = block
                    .summary
                    .clone()
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or_else(|| l10n.desktop_details());
                let body = expanded
                    .then(|| block.body.clone().filter(|b| !b.trim().is_empty()))
                    .flatten()
                    .map(|b| {
                        let state = self.text_state(&format!("details{ordinal}"), &b, window, cx);
                        div()
                            .text_size(px(m.control))
                            .child(chat_text(&state, key.clone().into()))
                            .into_any_element()
                    });
                let pending = block.pending == Some(true);
                self.card(
                    format!("details-{key}-{i}"),
                    x,
                    IconName::List,
                    summary,
                    None,
                    if pending { Run::Running } else { Run::Done },
                    expanded,
                    body,
                    &t,
                    cx,
                )
                .into_any_element()
            }
            MessageBlockKind::Error if block.hermes_error.is_some() => {
                let error = block.hermes_error.clone().unwrap_or_else(|| unreachable!());
                let action = self.hermes_error_action(&error, &key, &l10n, cx);
                super::hermes_blocks::error_card(
                    &format!("{key}-{i}"),
                    &error,
                    block.error.as_deref().unwrap_or_default(),
                    action,
                    &l10n,
                    &t,
                )
            }
            MessageBlockKind::ChangedFiles => {
                let files = block.changed_files.clone().unwrap_or_default();
                let store = self.host.store.upgrade()?;
                // Paths from the chat's working directory, in a Hermes
                // chat (an Open WebUI chat's turns can run in several).
                let directory = (self.flags.abilities.hermes_context)
                    .then(|| {
                        store
                            .read(cx)
                            .hermes
                            .read(cx)
                            .work
                            .as_ref()
                            .and_then(|w| w.working_directory.clone())
                    })
                    .flatten();
                let open: super::hermes_blocks::OpenDiff = {
                    let files = files.clone();
                    let directory = directory.clone();
                    std::rc::Rc::new(move |index, window, cx| {
                        crate::views::hermes_diff_sheet::open(
                            files.clone(),
                            index,
                            directory.clone(),
                            window,
                            cx,
                        )
                    })
                };
                super::hermes_blocks::changed_files(
                    &format!("{key}-{i}"),
                    &files,
                    directory.as_deref(),
                    open,
                    &l10n,
                    &t,
                    window,
                    cx,
                )?
            }
            MessageBlockKind::Error => {
                let text = error_text(block, &l10n);
                div()
                    .id(ElementId::Name(format!("error-{key}-{i}").into()))
                    .role(Role::Alert)
                    .aria_label(SharedString::from(text.clone()))
                    .w_full()
                    .px(px(12.))
                    .py(px(9.))
                    .flex()
                    .items_start()
                    .gap(px(8.))
                    .rounded(t.card_radius())
                    .border_1()
                    .border_color(with_alpha(r.danger, 0.45))
                    .bg(with_alpha(r.danger, if t.dark { 0.14 } else { 0.07 }))
                    .child(
                        div()
                            .pt(px(2.))
                            .child(icon(IconName::CircleAlert, 14., r.danger)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(px(m.control))
                            .line_height(relative(1.45))
                            .text_color(r.text)
                            .child(SharedString::from(text)),
                    )
                    // The way out: ask for the answer again, in place (the
                    // failed one stays as an earlier version).
                    .when(self.flags.can_regenerate() && !self.item.streaming, |d| {
                        let store = self.host.store.clone();
                        let regen = key.clone();
                        d.child(
                            div().flex_none().mt(px(-3.)).mb(px(-3.)).child(
                                Button::new(
                                    ElementId::Name(format!("error-retry-{key}-{i}").into()),
                                    l10n.retry(),
                                )
                                .icon(IconName::RotateCcw)
                                .on_click(std::rc::Rc::new(
                                    move |_, _, cx| {
                                        let _ = store
                                            .update(cx, |s, cx| s.regenerate(&regen, None, cx));
                                    },
                                )),
                            ),
                        )
                    })
                    .into_any_element()
            }
            MessageBlockKind::Status => {
                let line = status_line(block, &l10n)?;
                let pending = block.pending == Some(true);
                let x = format!("x{i}");
                let expanded = self.shows(&x, cx);
                let statuses = block.statuses.clone().unwrap_or_default();
                let can_open = statuses.len() > 1
                    || statuses
                        .iter()
                        .any(|s| !s.queries.is_empty() || !s.links.is_empty());
                // The header already says the last step: opened, the
                // timeline lists it only when its line differs, and keeps
                // its queries and pages under it either way.
                let last = statuses.len().saturating_sub(1);
                let header_line = line.clone();
                let timeline = expanded.then(|| {
                    disclosure_body(&t).flex().flex_col().gap(px(6.)).children(
                        statuses.iter().enumerate().map(|(n, s)| {
                            let said = status_text(s, &l10n);
                            let repeats = n == last && said == header_line;
                            let indent = if repeats { 0. } else { 18. };
                            div()
                                .flex()
                                .flex_col()
                                .gap(px(3.))
                                .when(!repeats, |d| {
                                    d.child(
                                        div()
                                            .flex()
                                            .items_center()
                                            .gap(px(6.))
                                            .text_size(px(m.control))
                                            .text_color(r.text_subtle)
                                            .child(icon(
                                                if s.done {
                                                    IconName::Check
                                                } else {
                                                    IconName::Circle
                                                },
                                                12.,
                                                r.text_faint,
                                            ))
                                            .child(SharedString::from(said)),
                                    )
                                })
                                .when(!s.queries.is_empty(), |d| {
                                    d.child(
                                        div()
                                            .pl(px(indent))
                                            .flex()
                                            .flex_wrap()
                                            .gap(px(4.))
                                            .children(s.queries.iter().map(|q| {
                                                div()
                                                    .px(px(7.))
                                                    .py(px(2.))
                                                    .rounded_full()
                                                    .bg(with_alpha(r.text, 0.06))
                                                    .text_size(px(m.small))
                                                    .text_color(r.text_subtle)
                                                    .child(SharedString::from(q.clone()))
                                            })),
                                    )
                                })
                                .children(s.links.iter().enumerate().map(|(k, link)| {
                                    let url = link.url.clone();
                                    div()
                                        .id(ElementId::Name(
                                            format!("status-link-{key}-{i}-{n}-{k}").into(),
                                        ))
                                        .role(Role::Link)
                                        .aria_label(SharedString::from(link.label.clone()))
                                        .pl(px(indent))
                                        .truncate()
                                        .text_size(px(m.small))
                                        .text_color(r.link)
                                        .when(url.is_some(), |d| d.cursor_pointer())
                                        .child(SharedString::from(link.label.clone()))
                                        .on_click(move |_, _, cx| {
                                            if let Some(u) = &url {
                                                super::markdown::open_web_link(u, cx)
                                            }
                                        })
                                }))
                        }),
                    )
                });
                // No gap: the space above the timeline opens with it.
                div()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .id(ElementId::Name(format!("status-{key}-{i}").into()))
                            .role(if can_open { Role::Button } else { Role::Status })
                            .aria_label(SharedString::from(line.clone()))
                            .when(can_open, |d| d.aria_expanded(self.expanded.contains(&x)))
                            .flex()
                            .items_center()
                            .gap(px(5.))
                            .h(px(ACTIVITY_ROW))
                            .text_size(px(m.body))
                            .text_color(r.text_subtle)
                            .when(can_open, |d| d.cursor_pointer())
                            .when(pending, |d| {
                                d.child(spinner(
                                    ElementId::Name(format!("status-spin-{key}-{i}").into()),
                                    12.,
                                    r.text_subtle,
                                ))
                            })
                            .child(SharedString::from(line))
                            .when(can_open, |d| d.child(self.chevron_for(&x, &t, cx)))
                            .on_click(cx.listener({
                                let x = x.clone();
                                move |this, _, _, cx| {
                                    if can_open {
                                        this.toggle(&x, cx)
                                    }
                                }
                            })),
                    )
                    .children(timeline.map(|body| self.reveal(&x, body, cx)))
                    .into_any_element()
            }
            MessageBlockKind::Files => {
                let files = block.files.clone().unwrap_or_default();
                if files.is_empty() {
                    return None;
                }
                self.files(i, &files, &l10n, &t, window, cx)
                    .into_any_element()
            }
            // Drawn by the row itself.
            MessageBlockKind::Sources | MessageBlockKind::FollowUps | MessageBlockKind::Unknown => {
                return None;
            }
        })
    }

    /// A tool call, a code run or a details block, as the phone draws them:
    /// one quiet line ("Used Get Current Timestamp ›", "Used Tide Table ·
    /// Port Wren ›") that opens to what ran, with a spinner while it runs
    /// and the line in red if it failed.
    #[allow(clippy::too_many_arguments)]
    fn card(
        &self,
        id: String,
        toggle_key: String,
        _leading: IconName,
        title: String,
        detail: Option<LineDetail>,
        run: Run,
        expanded: bool,
        body: Option<AnyElement>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let r = t.roles;
        let m = t.metrics;
        let label = match &detail {
            Some(d) => format!("{title}, {}", d.text),
            None => title.clone(),
        };
        let spin_id = ElementId::Name(format!("{id}-spin").into());
        let tone = if run == Run::Failed {
            r.danger
        } else {
            r.text_subtle
        };
        // No gap: the space above the body opens with it (reveal).
        div()
            .id(ElementId::Name(id.clone().into()))
            .w_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .id(ElementId::Name(format!("{id}-toggle").into()))
                    .role(Role::Button)
                    .aria_label(SharedString::from(label))
                    .aria_expanded(self.expanded.contains(&toggle_key))
                    .max_w_full()
                    .flex()
                    .cursor_pointer()
                    .child(
                        activity_line()
                            .when(run == Run::Running, |d| {
                                d.child(spinner(spin_id, 12., r.text_subtle))
                            })
                            .when(run == Run::Failed, |d| {
                                d.child(icon(IconName::CircleAlert, 13., r.danger))
                            })
                            .child(
                                div()
                                    .flex_none()
                                    .text_size(px(m.body))
                                    .text_color(tone)
                                    .child(SharedString::from(title)),
                            )
                            .when_some(detail, |d, detail| {
                                // "·" then the detail: words in the line's
                                // own face, code in the mono face, never one
                                // run into the other.
                                d.child(
                                    div()
                                        .flex_none()
                                        .text_size(px(m.body))
                                        .text_color(r.text_faint)
                                        .child("\u{b7}"),
                                )
                                .child(
                                    div()
                                        .min_w_0()
                                        .truncate()
                                        .text_color(r.text_subtle)
                                        .map(|d| {
                                            if detail.mono {
                                                d.font_family(MONO_FONT).text_size(px(m.code))
                                            } else {
                                                d.text_size(px(m.body))
                                            }
                                        })
                                        .child(SharedString::from(detail.text)),
                                )
                            })
                            .child(self.chevron_for(&toggle_key, t, cx)),
                    )
                    .on_click(cx.listener({
                        let key = toggle_key.clone();
                        move |this, _, _, cx| this.toggle(&key, cx)
                    }))
                    .keyboard_outline(4., cx),
            )
            .when_some(body.filter(|_| expanded), |d, body| {
                d.child(self.reveal(
                    &toggle_key,
                    disclosure_body(t).flex().flex_col().gap(px(8.)).child(body),
                    cx,
                ))
            })
    }

    fn tool_call(
        &self,
        i: usize,
        j: usize,
        call: &ToolCallDto,
        l10n: &L10n,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let key = &self.item.key;
        let x = format!("x{i}.{j}");
        let expanded = self.shows(&x, cx);
        let raw = call.name.trim();
        // The tool by its name in words ("Tide Table"); its id stays in the
        // opened body.
        let name = if raw.is_empty() {
            l10n.desktop_unnamed_tool()
        } else {
            tool_display_name(raw)
        };
        let running = call.pending || (!call.done && call.result.is_empty());
        let title = if running {
            l10n.desktop_tool_running(&name)
        } else {
            l10n.desktop_tool_used(&name)
        };
        let detail = LineDetail::words(tool_argument(&call.arguments));
        let r = t.roles;
        let m = t.metrics;
        let body = expanded.then(|| {
            div()
                .flex()
                .flex_col()
                .gap(px(8.))
                .when(!raw.is_empty(), |d| {
                    d.child(
                        div()
                            .font_family(MONO_FONT)
                            .text_size(px(m.code - 0.5))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(raw.to_string())),
                    )
                })
                .when(!call.arguments.trim().is_empty(), |d| {
                    d.child(mono_box(
                        &l10n.desktop_tool_input(),
                        pretty(&call.arguments),
                        t,
                    ))
                })
                .when(!call.result.trim().is_empty(), |d| {
                    d.child(mono_box(
                        &l10n.desktop_tool_result(),
                        pretty(&call.result),
                        t,
                    ))
                })
                .into_any_element()
        });
        self.card(
            format!("tool-{key}-{i}-{j}"),
            x,
            if name.contains("search") {
                IconName::Globe
            } else {
                IconName::Wrench
            },
            title,
            detail,
            if call.is_error {
                Run::Failed
            } else if running {
                Run::Running
            } else {
                Run::Done
            },
            expanded,
            body,
            t,
            cx,
        )
        .into_any_element()
    }

    /// Images inline, other files as chips.
    pub(super) fn files(
        &self,
        i: usize,
        files: &[ChatFileDto],
        l10n: &L10n,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        file_list(
            &format!("{}-{i}", self.item.key),
            files,
            self.host.server_id.as_deref(),
            l10n,
            t,
            window,
            cx,
        )
    }
}

/// A GitHub-style alert's label, glyph and colour, as the phone draws it
/// (`block_renderer.dart`): blue note, green tip, purple important, amber
/// warning, red caution. They are what the text means, so they keep their
/// hues in the monochrome palette, as the danger red does.
pub fn alert_style(
    kind: &str,
    l10n: &L10n,
    t: &ConduitTheme,
) -> (String, IconName, gpui_kit::Hsla) {
    let r = t.roles;
    match kind {
        "tip" => (l10n.alert_tip(), IconName::Lightbulb, r.success),
        "important" => (
            l10n.alert_important(),
            IconName::CircleAlert,
            if t.dark {
                gpui_kit::hsla(270. / 360., 0.65, 0.72, 1.)
            } else {
                gpui_kit::hsla(270. / 360., 0.55, 0.48, 1.)
            },
        ),
        "warning" => (l10n.alert_warning(), IconName::TriangleAlert, r.warning),
        "caution" => (l10n.alert_caution(), IconName::OctagonAlert, r.danger),
        // Blue, as on the phone (the palette's info tone is teal, too
        // close to the tip's green).
        _ => (
            l10n.alert_note(),
            IconName::Info,
            if t.dark {
                gpui_kit::hsla(212. / 360., 0.85, 0.66, 1.)
            } else {
                gpui_kit::hsla(212. / 360., 0.80, 0.45, 1.)
            },
        ),
    }
}

/// The largest an inline image is drawn (it keeps its proportions); a
/// click opens it full size in Quick Look.
const IMAGE_MAX: (f32, f32) = (480., 400.);

/// `size` scaled down (never up) to fit [`IMAGE_MAX`].
pub fn fit_image(width: f32, height: f32) -> (f32, f32) {
    if width <= 0. || height <= 0. {
        return (0., 0.);
    }
    let scale = (IMAGE_MAX.0 / width).min(IMAGE_MAX.1 / height).min(1.);
    ((width * scale).round(), (height * scale).round())
}

/// Files on a message: images inline, other files as chips that open in
/// their app (PDFs and the rest go through the daemon's staging folder).
///
/// A server image is a quiet tile while it loads, then the picture at its
/// own proportions; one that cannot be loaded becomes a full-width tile
/// with its name and Retry.
pub fn file_list(
    id: &str,
    files: &[ChatFileDto],
    server_id: Option<&str>,
    l10n: &L10n,
    t: &ConduitTheme,
    window: &mut Window,
    cx: &mut App,
) -> Div {
    let r = t.roles;
    let m = t.metrics;
    let mut children: Vec<AnyElement> = Vec::with_capacity(files.len());
    // The message's pictures, for the viewer to step through.
    let gallery: Vec<(usize, crate::views::image_viewer::ViewerImage)> = files
        .iter()
        .enumerate()
        .filter(|(_, f)| f.image)
        .filter_map(|(n, f)| {
            let name = f.name.clone();
            let image = match (&f.data_url, server_id, &f.id) {
                (Some(url), _, _) => crate::views::image_viewer::ViewerImage::Data {
                    image: std::sync::Arc::new(decode_data_image(url)?),
                    name,
                },
                (None, Some(s), Some(id)) => crate::views::image_viewer::ViewerImage::File {
                    file: FileRef {
                        server_id: s.to_string(),
                        file_id: id.clone(),
                    },
                    name,
                },
                _ => return None,
            };
            Some((n, image))
        })
        .collect();
    let images: Vec<crate::views::image_viewer::ViewerImage> =
        gallery.iter().map(|(_, i)| i.clone()).collect();
    for (n, f) in files.iter().enumerate() {
        let file_ref = match (server_id, &f.id) {
            (Some(s), Some(id)) => Some(FileRef {
                server_id: s.to_string(),
                file_id: id.clone(),
            }),
            _ => None,
        };
        let name = f.name.clone();
        let element_id = ElementId::Name(format!("file-{id}-{n}").into());
        if f.image {
            let state = match (&f.data_url, &file_ref) {
                (Some(url), _) => match decode_data_image(url) {
                    Some(image) => ImageState::Ready(
                        gpui_kit::ImageSource::Image(std::sync::Arc::new(image)),
                        None,
                    ),
                    None => ImageState::Failed,
                },
                (None, Some(file)) => match file_image_state(file, window, cx) {
                    Some(Ok(image)) => {
                        let size = image.size(0);
                        // Dark: a chart or diagram drawn on white is redrawn
                        // in the window's tones (see `diagram`).
                        let image = if t.dark {
                            super::diagram::themed(&image, r.raised, r.text).unwrap_or(image)
                        } else {
                            image
                        };
                        ImageState::Ready(
                            gpui_kit::ImageSource::Render(image),
                            Some(fit_image(size.width.0 as f32, size.height.0 as f32)),
                        )
                    }
                    Some(Err(_)) => ImageState::Failed,
                    None => ImageState::Loading,
                },
                (None, None) => ImageState::Failed,
            };
            let open = gallery.iter().position(|(k, _)| *k == n).map(|start| {
                let images = images.clone();
                std::rc::Rc::new(move |cx: &mut App| {
                    crate::views::image_viewer::open(images.clone(), start, cx)
                }) as OpenImage
            });
            // Open Image, Copy Image and Save Image…, as an answer's
            // other pictures have them (`remote_image`).
            let menu = gallery.iter().find(|(k, _)| *k == n).map(|(_, image)| {
                Rc::new(super::remote_image::file_image_menu(
                    &format!("file-{id}-{n}"),
                    image,
                    l10n,
                )) as ImageMenu
            });
            children.push(image_tile(
                element_id,
                &name,
                state,
                file_ref.clone(),
                open,
                menu,
                l10n,
                t,
            ));
            continue;
        }
        if is_video(f)
            && let Some(file) = file_ref.clone()
        {
            children.push(super::video::video_tile(
                element_id,
                file,
                f.name.clone(),
                window,
                cx,
            ));
            continue;
        }
        let open = file_ref.clone();
        let open_name = name.clone();
        children.push(
            div()
                .id(element_id)
                .role(Role::Button)
                .aria_label(SharedString::from(l10n.desktop_open_file(&name)))
                .h(px(36.))
                .max_w(px(260.))
                .pl(px(6.))
                .pr(px(10.))
                .flex()
                .items_center()
                .gap(px(8.))
                .rounded(t.card_radius())
                .border_1()
                .border_color(r.border)
                .bg(conduit_components::views::kit::raised_fill(t))
                .when(open.is_some(), |d| {
                    d.cursor_pointer().hover(|s| s.bg(r.hover))
                })
                .child(icon(IconName::FileText, 16., r.text_subtle))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(m.small))
                        .text_color(r.text)
                        .child(SharedString::from(name)),
                )
                .on_click(move |_, _, cx| {
                    if let Some(f) = &open {
                        open_attachment(f.clone(), &open_name, OpenWith::DefaultApp, cx).detach();
                    }
                })
                .into_any_element(),
        );
    }
    div().flex().flex_wrap().gap(px(6.)).children(children)
}

/// What an inline image can show.
enum ImageState {
    /// Still loading, or the daemon is not running yet.
    Loading,
    /// Ready, with the size to draw it at (a data URL decodes later and
    /// sizes itself, within [`IMAGE_MAX`]).
    Ready(gpui_kit::ImageSource, Option<(f32, f32)>),
    Failed,
}

/// What VoiceOver calls an inline image: its name read as words
/// ("high-water.png" → "High water"), as a caption would say it. The role
/// already says "image", and the file name is its description. `None` for
/// a name that is no words (a hash, a number), which keeps the old label.
/// (Messages carry no caption or alt text for their files.)
pub fn image_label(name: &str) -> Option<String> {
    let stem = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() && ext.len() <= 5 => stem,
        _ => name,
    };
    let words: Vec<&str> = stem
        .split(|c: char| c == '-' || c == '_' || c == '.' || c.is_whitespace())
        .filter(|w| !w.is_empty())
        .collect();
    let wordy = words
        .iter()
        .any(|w| w.chars().filter(|c| c.is_alphabetic()).count() >= 3)
        && words.iter().all(|w| {
            let hexish = w.len() >= 8 && w.chars().all(|c| c.is_ascii_hexdigit());
            !hexish && w.chars().all(|c| c.is_alphanumeric())
        });
    if !wordy {
        return None;
    }
    let text = words.join(" ");
    let mut chars = text.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

/// Shows an image in the viewer.
type OpenImage = std::rc::Rc<dyn Fn(&mut App)>;

/// A picture's context menu.
type ImageMenu = Rc<dyn Fn(&gpui_kit::MouseDownEvent, &mut Window, &mut App)>;

/// Whether `file` is a video (by its type, else its name), which plays
/// inline.
pub fn is_video(file: &ChatFileDto) -> bool {
    if let Some(t) = &file.content_type {
        return t.to_ascii_lowercase().starts_with("video/");
    }
    let name = file.name.to_ascii_lowercase();
    [".mp4", ".mov", ".m4v", ".webm"]
        .iter()
        .any(|ext| name.ends_with(ext))
}

/// One inline image in its state. `open` shows it in the viewer.
#[allow(clippy::too_many_arguments)]
fn image_tile(
    element_id: ElementId,
    name: &str,
    state: ImageState,
    file: Option<FileRef>,
    open: Option<OpenImage>,
    menu: Option<ImageMenu>,
    l10n: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let label = SharedString::from(
        image_label(name).unwrap_or_else(|| l10n.desktop_attachment_image(name)),
    );
    let file_name = SharedString::from(name.to_string());
    match state {
        ImageState::Ready(source, size) => {
            let picture = match size {
                Some((w, h)) => img(source).w(px(w)).h(px(h)),
                None => img(source).max_w(px(IMAGE_MAX.0)).max_h(px(IMAGE_MAX.1)),
            };
            div()
                .id(element_id)
                .role(Role::Image)
                .aria_label(label)
                .aria_description(file_name)
                .flex_none()
                .rounded(t.card_radius())
                .overflow_hidden()
                .border_1()
                // Dark: a hairline on the ramp's top step, so a picture's
                // edge reads on the #000 column (the palette's #1E1E1E
                // border did not).
                .border_color(if t.dark {
                    conduit_components::theme::dark_step(t.surfaces.panel, r.text, 3)
                } else {
                    r.border
                })
                .when(open.is_some(), |d| d.cursor_pointer())
                .child(picture)
                .on_click(move |_, _, cx| {
                    if let Some(open) = &open {
                        open(cx);
                    }
                })
                .when_some(menu, |d, menu| {
                    d.on_mouse_down(gpui_kit::MouseButton::Right, move |e, window, cx| {
                        menu(e, window, cx)
                    })
                })
                .into_any_element()
        }
        ImageState::Loading => div()
            .id(element_id)
            .role(Role::Image)
            .aria_label(label)
            .aria_description(file_name)
            .w(px(IMAGE_MAX.0 * 0.6))
            .h(px(IMAGE_MAX.0 * 0.3))
            .rounded(t.card_radius())
            .bg(t.roles.raised)
            .border_1()
            .border_color(r.border)
            .into_any_element(),
        ImageState::Failed => {
            let retry_id = ElementId::Name(format!("{element_id}-retry").into());
            div()
                .id(element_id)
                .role(Role::Group)
                .aria_label(SharedString::from(format!(
                    "{}, {}",
                    l10n.desktop_attachment_image(name),
                    l10n.desktop_image_load_failed()
                )))
                .w_full()
                .min_h(px(52.))
                .px(px(12.))
                .py(px(8.))
                .flex()
                .items_center()
                .gap(px(10.))
                .rounded(t.card_radius())
                .border_1()
                .border_color(r.border)
                .bg(t.roles.raised)
                .child(icon(IconName::ImageOff, 18., r.text_subtle).flex_none())
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .truncate()
                                .text_size(px(m.control))
                                .text_color(r.text)
                                .child(SharedString::from(name.to_string())),
                        )
                        .child(
                            div()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(l10n.desktop_image_load_failed())),
                        ),
                )
                .when_some(file, |d, file| {
                    d.child(
                        Button::new(retry_id, l10n.retry()).on_click(std::rc::Rc::new(
                            move |_, window, cx| {
                                retry_file_image(&file, cx);
                                window.refresh();
                            },
                        )),
                    )
                })
                .into_any_element()
        }
    }
}

/// How a text block of a message (`streaming`: still being written) is
/// drawn this frame, its text `paced` or not: `held` (an open span or a
/// half-written fence at the end is held back, unless pacing already
/// released only text free of them) and `live` (the message is still being
/// written, so a diagram whose fence has not closed stays code: pacing
/// never makes it final).
fn text_mode(streaming: bool, paced: bool) -> (bool, bool) {
    (streaming && !paced, streaming)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stores::chat::empty_block;

    /// A paced answer that is still streaming keeps its open diagram fence
    /// as code; only a finished message's diagram is drawn as final.
    #[test]
    fn pacing_never_makes_a_streaming_answers_diagram_final() {
        // Still streaming, paced: nothing held back, but still live.
        assert_eq!(text_mode(true, true), (false, true));
        // Still streaming, not paced: held back, live.
        assert_eq!(text_mode(true, false), (true, true));
        // Finished: final.
        assert_eq!(text_mode(false, false), (false, false));
        assert_eq!(text_mode(false, true), (false, false));
    }

    #[test]
    fn a_held_reply_on_a_polling_only_server_is_worded_here() {
        let l10n = L10n::new("en");
        let mut block = empty_block(MessageBlockKind::Error);
        block.error = Some("The server is still working on it (core's own English).".into());
        block.r#type = Some("heldReplyStillRunning".into());
        assert_eq!(error_text(&block, &l10n), l10n.held_reply_still_running());
    }

    #[test]
    fn a_failed_relay_to_a_users_device_is_worded_here() {
        let l10n = L10n::new("en");
        for (kind, words) in [
            ("tetherInterrupted", l10n.tether_relay_interrupted()),
            ("tetherUnavailable", l10n.tether_relay_unavailable()),
            ("tetherBusy", l10n.tether_relay_busy()),
        ] {
            let mut block = empty_block(MessageBlockKind::Error);
            block.error = Some("Tether's own English, from the server.".into());
            block.r#type = Some(kind.into());
            assert_eq!(error_text(&block, &l10n), words);
        }
    }

    #[test]
    fn inline_images_keep_their_proportions_and_never_grow() {
        // The showcase chart: 960 × 480 fits the width.
        assert_eq!(fit_image(960., 480.), (480., 240.));
        // A tall screenshot fits the height.
        assert_eq!(fit_image(400., 1600.), (100., 400.));
        // A small image keeps its size.
        assert_eq!(fit_image(120., 80.), (120., 80.));
        assert_eq!(fit_image(0., 80.), (0., 0.));
    }

    #[test]
    fn images_are_named_in_words_not_by_their_file_name() {
        assert_eq!(image_label("high-water.png").as_deref(), Some("High water"));
        assert_eq!(
            image_label("tide_chart 2026.jpeg").as_deref(),
            Some("Tide chart 2026")
        );
        // A name that is no words keeps the generic label.
        assert_eq!(image_label("3f9a2c7e4b1d.png"), None);
        assert_eq!(image_label("0042.png"), None);
        assert_eq!(
            image_label("c3d1e8a0-77aa-4f2b-9d1e-2b7c0f5e9a11.webp"),
            None
        );
    }

    #[test]
    fn reasoning_headers_follow_the_title_kind() {
        let l10n = L10n::new("en");
        let mut b = empty_block(MessageBlockKind::Reasoning);
        b.title = Some(ReasoningTitle::ThoughtFor);
        b.duration_seconds = Some(8);
        assert_eq!(reasoning_title(&b, &l10n), "Thought for 8 seconds");
        b.duration_seconds = Some(0);
        assert_eq!(reasoning_title(&b, &l10n), "Thought for less than a second");
        b.duration_seconds = Some(150);
        assert_eq!(reasoning_title(&b, &l10n), "Thought for 3 minutes");
        b.title = Some(ReasoningTitle::Thinking);
        assert_eq!(reasoning_title(&b, &l10n), "Thinking…");
        b.title = Some(ReasoningTitle::Summary);
        b.summary = Some("Checked the units".into());
        assert_eq!(reasoning_title(&b, &l10n), "Checked the units");
        let de = L10n::new("de");
        b.title = Some(ReasoningTitle::ThoughtFor);
        b.duration_seconds = Some(1);
        assert_eq!(reasoning_title(&b, &de), "Gedacht für 1 Sekunde");
    }

    /// Core's own English (the phone's words) is what the window says in
    /// English, and every other language has its own words for it: the
    /// status lines, Apple's failures, the call refusals and the Hermes
    /// cadences.
    #[test]
    fn core_words_read_in_every_language() {
        use conduit_protocol::{CallRefusal, HermesCadenceDto, HermesCadenceKind};

        use crate::views::chat::call::refusal_text;
        use crate::views::panes::hermes_jobs::cadence_text;

        let status = |phrase, count: Option<i64>, query: Option<&str>| MessageStatusDto {
            description: "server words".into(),
            phrase: Some(phrase),
            count,
            query: query.map(String::from),
            action: None,
            done: true,
            queries: vec![],
            links: vec![],
            details: vec![],
        };
        let statuses = [
            status(StatusPhrase::KnowledgeSearch, None, Some("tide tables")),
            status(StatusPhrase::Searching, None, None),
            status(StatusPhrase::Querying, None, None),
            status(StatusPhrase::SourcesRetrieved, Some(0), None),
            status(StatusPhrase::SourcesRetrieved, Some(1), None),
            status(StatusPhrase::SourcesRetrieved, Some(4), None),
            status(StatusPhrase::Processing, None, None),
        ];
        let apple = [
            "appleUnavailable.systemTooOld",
            "appleUnavailable.deviceNotEligible",
            "appleUnavailable.appleIntelligenceNotEnabled",
            "appleUnavailable.modelNotReady",
            "appleUnavailable.notOffered",
            "appleUnavailable.other",
            "appleFailure.contextExceeded",
            "appleFailure.notReady",
            "appleFailure.guardrail",
            "appleFailure.refusal",
            "appleFailure.unsupported",
            "appleFailure.decoding",
            "appleFailure.busy",
            "appleFailure.timedOut",
            "appleFailure.invalidRequest",
            "appleFailure.invalidSchema",
            "appleFailure.invalidToolSchema",
            "appleFailure.invalidStream",
            "appleFailure.failed",
        ];
        let refusals = [
            CallRefusal::ModelRequired,
            CallRefusal::HermesLoading,
            CallRefusal::HermesUnavailable,
            CallRefusal::DirectUnavailable,
            CallRefusal::SignInRequired,
            CallRefusal::BackendUnsupported,
        ];
        let cadence =
            |kind, every: Option<i64>, minute: Option<i64>, weekday, day| HermesCadenceDto {
                kind,
                every,
                hour: Some(17),
                minute,
                weekday,
                day,
            };
        let cadences = [
            cadence(HermesCadenceKind::None, None, None, None, None),
            cadence(HermesCadenceKind::EveryMinute, None, None, None, None),
            cadence(HermesCadenceKind::EveryMinutes, Some(15), None, None, None),
            cadence(HermesCadenceKind::EveryHour, None, Some(0), None, None),
            cadence(HermesCadenceKind::EveryHour, None, Some(5), None, None),
            cadence(HermesCadenceKind::EveryHours, Some(6), Some(0), None, None),
            cadence(HermesCadenceKind::EveryHours, Some(6), Some(30), None, None),
            cadence(HermesCadenceKind::Daily, None, Some(45), None, None),
            cadence(HermesCadenceKind::Weekdays, None, Some(45), None, None),
            cadence(HermesCadenceKind::Weekends, None, Some(45), None, None),
            cadence(HermesCadenceKind::Weekly, None, Some(45), Some(4), None),
            cadence(HermesCadenceKind::Monthly, None, Some(45), None, Some(22)),
        ];
        let said = |l: &L10n| -> Vec<String> {
            let mut out: Vec<String> = statuses.iter().map(|s| status_text(s, l)).collect();
            out.extend(apple.iter().map(|k| apple_error_text(k, l).expect(k)));
            out.extend(refusals.iter().map(|r| refusal_text(*r, l).expect("known")));
            out.extend(cadences.iter().map(|c| cadence_text(c, l).expect("known")));
            out
        };
        let en = said(&L10n::new("en"));
        // The phone's (core's) English, word for word.
        for (got, want) in en.iter().zip([
            "Searching Knowledge for “tide tables”",
            "Searching",
            "Querying",
            "No sources found",
            "Retrieved 1 source",
            "Retrieved 4 sources",
            "Processing",
        ]) {
            assert_eq!(got, want);
        }
        let english_cadences = &en[en.len() - cadences.len()..];
        assert_eq!(english_cadences[2], "Every 15 minutes");
        assert_eq!(english_cadences[4], "Every hour at :05");
        assert_eq!(english_cadences[6], "Every 6 hours at :30");
        assert!(english_cadences[10].starts_with("Every Thursday at "));
        assert!(english_cadences[11].starts_with("Monthly on the 22nd at "));
        for locale in crate::l10n::LOCALES.iter().filter(|l| **l != "en") {
            let words = said(&L10n::new(locale));
            for (i, (got, english)) in words.iter().zip(&en).enumerate() {
                assert!(!got.trim().is_empty(), "{locale} #{i}");
                assert!(!got.contains('{'), "{locale} #{i}: {got}");
                assert_ne!(got, english, "{locale} #{i} is still English");
            }
        }
        // No phrase, or one without what it needs, keeps the server's words.
        let no_query = status(StatusPhrase::KnowledgeSearch, None, None);
        assert_eq!(status_text(&no_query, &L10n::new("de")), "server words");
        let bare = MessageStatusDto {
            phrase: None,
            description: "Searched the web".into(),
            ..status(StatusPhrase::Searching, None, None)
        };
        assert_eq!(status_text(&bare, &L10n::new("de")), "Searched the web");
        assert_eq!(apple_error_text("serverOverloaded", &L10n::new("de")), None);
    }

    #[test]
    fn status_rows_read_the_last_line_or_the_tool_summary() {
        let l10n = L10n::new("en");
        let mut b = empty_block(MessageBlockKind::Status);
        b.statuses = Some(vec![
            conduit_protocol::MessageStatusDto {
                description: "Searching the web".into(),
                phrase: None,
                count: None,
                query: None,
                action: None,
                done: true,
                queries: vec![],
                links: vec![],
                details: vec![],
            },
            conduit_protocol::MessageStatusDto {
                description: "Read 3 pages".into(),
                phrase: None,
                count: None,
                query: None,
                action: None,
                done: true,
                queries: vec![],
                links: vec![],
                details: vec![],
            },
        ]);
        assert_eq!(status_line(&b, &l10n).as_deref(), Some("Read 3 pages"));
        b.summary = Some("terminal (2), search".into());
        b.pending = Some(true);
        assert_eq!(
            status_line(&b, &l10n).as_deref(),
            Some("Exploring terminal (2), search")
        );
        b.pending = Some(false);
        assert_eq!(
            status_line(&b, &l10n).as_deref(),
            Some("Explored terminal (2), search")
        );
    }

    #[test]
    fn tools_are_named_in_words_by_cores_rule() {
        assert_eq!(tool_display_name("tide_table"), "Tide Table");
        assert_eq!(
            tool_display_name("get_current_timestamp"),
            "Get Current Timestamp"
        );
        assert_eq!(tool_display_name("web-search"), "Web Search");
        // Words already: kept, only the first letters raised.
        assert_eq!(tool_display_name("Station weather"), "Station Weather");
        // Nothing but separators and the case of word starts changes.
        assert_eq!(tool_display_name("getWeather"), "GetWeather");
        assert_eq!(tool_display_name("server.read_file"), "Server.Read File");
        assert_eq!(tool_display_name("  __x__y "), "X Y");
        assert_eq!(tool_display_name(""), "");
    }

    #[test]
    fn approval_titles_that_are_tool_ids_are_told_apart_from_words() {
        assert!(is_tool_id("get_current_timestamp"));
        assert!(is_tool_id("search"));
        assert!(is_tool_id("files:read"));
        assert!(!is_tool_id("Run the clock tool"));
        assert!(!is_tool_id("Open WebUI"));
        assert!(!is_tool_id("  "));
    }

    #[test]
    fn code_runs_are_summed_up_by_a_comment_or_their_first_line() {
        assert_eq!(
            code_summary("# Average daily lag\nlags = [46, 43]\nprint(lags)"),
            Some(("Average daily lag".into(), false))
        );
        // A comment after an import still names the run.
        assert_eq!(
            code_summary("import math\n\n// Sum the lags\nlet x = 1;"),
            Some(("Sum the lags".into(), false))
        );
        // No comment: the first line, as code.
        assert_eq!(
            code_summary("lags = [46, 43, 41]\nprint(round(sum(lags) / len(lags), 1))"),
            Some(("lags = [46, 43, 41]".into(), true))
        );
        // A shebang or an encoding line is skipped.
        assert_eq!(
            code_summary("#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\nprint(1)"),
            Some(("print(1)".into(), true))
        );
        // `#include` and `--flag` are code, not comments.
        assert_eq!(
            code_summary("#include <stdio.h>\nint main(void);"),
            Some(("#include <stdio.h>".into(), true))
        );
        assert_eq!(
            code_summary("--verbose\n## Fetch the tides\nrun()"),
            Some(("Fetch the tides".into(), false))
        );
        assert_eq!(code_summary("\n  \n"), None);
    }

    #[test]
    fn a_tool_line_names_its_first_string_argument() {
        assert_eq!(
            tool_argument("{\"station\":\"Port Wren\",\"days\":7}"),
            "Port Wren"
        );
        assert_eq!(tool_argument("{\"days\":7}"), "7");
        assert_eq!(tool_argument("not json"), "");
        assert_eq!(tool_argument(""), "");
    }

    #[test]
    fn tool_text_is_pretty_printed_when_it_is_json() {
        assert_eq!(
            pretty("{\"q\":\"rust\",\"n\":2}"),
            "{\n  \"q\": \"rust\",\n  \"n\": 2\n}"
        );
        // A JSON string holding JSON is unwrapped once.
        assert_eq!(pretty("\"{\\\"ok\\\":true}\""), "{\n  \"ok\": true\n}");
        assert_eq!(pretty("\"plain\""), "plain");
        assert_eq!(pretty("not json"), "not json");
        let long = "x".repeat(MAX_TOOL_TEXT + 10);
        assert!(pretty(&long).ends_with('…'));
    }
}
