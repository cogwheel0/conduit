//! `--chat-fixture perf | a11y [--shots <dir>]`: the chat view over a
//! fixture daemon, without conduitd.
//!
//! The window holds the real [`Transcript`] and [`ChatComposer`] over a
//! [`ChatStore`] and a [`ComposerStore`] whose daemon answers from memory:
//! a 10,000-message chat and one model.
//!
//! * `perf`: a 32K-character answer streams into the chat as `turn.blocks`
//!   snapshots at 60 Hz, first while the transcript follows the tail, then
//!   while it scrolls through the history. Frame intervals (vsync to vsync)
//!   and the work in each frame are printed as JSON per phase. Run it with
//!   the display awake.
//! * `a11y`: activates accessibility, reads GPUI's AccessKit tree and prints
//!   the labelled articles and controls as JSON (`tests/chat_a11y.rs`
//!   checks them).
//! * `perf-a11y`: `perf` with accessibility active, as with VoiceOver on.
//! * `shots --shots <dir> [--dark]`: the same answer streamed to fixed
//!   lengths and scrolled to fixed places, each shot taken once the text,
//!   its fades and the view have come to rest, so two builds' shots can be
//!   compared pixel for pixel (`fixture-shot-<name>-<light|dark>.png`).

use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::window as cw;
use conduit_daemon::RpcError;
use conduit_daemon::protocol::{codes, error};
use conduit_protocol::{
    ChatDetail, ChatMessageDto, ChatResult, ChatSummary, ComposerOptions, Event, ModelList,
    ModelSummary, TurnBlocks,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncApp, Bounds, Context, Entity, ListOffset, Window, WindowBounds, div, px, size,
};
use serde_json::{Value, json};

use crate::stores::chat::{ChatStore, Subscribe, empty_block};
use crate::stores::composer::ComposerStore;
use crate::stores::rpc::{CallFuture, Daemon, Rpc};
use crate::views::chat::composer::ChatComposer;
use crate::views::chat::rows::RowHost;
use crate::views::chat::transcript::Transcript;

/// Messages in the fixture chat.
pub const MESSAGES: usize = 10_000;
/// The streamed answer's length.
pub const ANSWER_CHARS: usize = 32 * 1024;

/// A daemon that answers from memory.
pub(crate) struct FixtureDaemon {
    pub(crate) chat: Value,
}

impl Daemon for FixtureDaemon {
    fn call_value(&self, method: &'static str, _: Value) -> CallFuture {
        let answer: Result<Value, RpcError> = match method {
            "chats.get" => Ok(self.chat.clone()),
            "models.list" | "models.select" => Ok(serde_json::to_value(ModelList {
                models: vec![
                    ModelSummary {
                        id: "fixture-model".into(),
                        name: "Fixture model".into(),
                        description: None,
                        pinned: true,
                        capabilities: vec![],
                        connection: None,
                        logo: None,
                        agent: None,
                    },
                    ModelSummary {
                        id: "fixture-model-2".into(),
                        name: "Second fixture model".into(),
                        description: None,
                        pinned: false,
                        capabilities: vec![],
                        connection: None,
                        logo: None,
                        agent: None,
                    },
                ],
                selected_id: Some("fixture-model".into()),
                ..Default::default()
            })
            .unwrap()),
            "composer.options" => Ok(serde_json::to_value(ComposerOptions {
                web_search: true,
                image_generation: true,
                ..Default::default()
            })
            .unwrap()),
            other => Err(error(codes::METHOD_NOT_FOUND, other)),
        };
        Box::pin(async move { answer })
    }
}

pub(crate) fn text_block(markdown: String) -> conduit_protocol::MessageBlockDto {
    conduit_protocol::MessageBlockDto {
        markdown: Some(markdown),
        ..empty_block(conduit_protocol::MessageBlockKind::Text)
    }
}

/// A plausible answer paragraph `n`.
fn paragraph(n: usize) -> String {
    match n % 9 {
        3 => {
            format!("```rust\nfn orbit_{n}(period: f64) -> f64 {{\n    360.0 / period\n}}\n```\n\n")
        }
        6 => format!("The period is $T_{n} = 2\\pi\\sqrt{{r^3/GM}}$ for orbit {n}.\n\n"),
        _ => format!(
            "Paragraph {n}: a steady stream of words about orbits, tides and clockwork, \
             with **bold**, `code` and a [link](https://example.org/{n}).\n\n"
        ),
    }
}

/// The streamed answer, `ANSWER_CHARS` long.
fn long_answer() -> String {
    let mut out = String::new();
    let mut n = 0;
    while out.len() < ANSWER_CHARS {
        if n % 15 == 0 {
            out.push_str(&format!("## Part {}\n\n", n / 15 + 1));
        }
        out.push_str(&paragraph(n));
        n += 1;
    }
    out.truncate(ANSWER_CHARS);
    out
}

fn chat_value() -> Value {
    let messages: Vec<ChatMessageDto> = (0..MESSAGES)
        .map(|i| {
            let assistant = i % 2 == 1;
            let content = if assistant {
                format!("{}{}", paragraph(i), paragraph(i + 1))
            } else {
                format!("Question {i}: how long is a day on moon {i}?")
            };
            ChatMessageDto {
                sibling_ids: vec![],
                parent_id: None,
                slot: None,
                merged: None,
                retry_without_effort: false,
                comparison: vec![],
                mergeable_ids: vec![],
                id: format!("m{i}"),
                role: if assistant { "assistant" } else { "user" }.into(),
                content: content.clone(),
                timestamp_ms: 1_700_000_000_000 + i as i64,
                model: assistant.then(|| "Fixture model".into()),
                model_name: None,
                streaming: false,
                error_code: None,
                versions: vec![],
                sources: vec![],
                usage: None,
                rating: None,
                files: vec![],
                blocks: if assistant {
                    vec![text_block(content)]
                } else {
                    vec![]
                },
                queued: None,
            }
        })
        .collect();
    serde_json::to_value(ChatResult {
        chat: Some(ChatDetail {
            hermes: None,
            abilities: Default::default(),
            temporary: false,
            share_id: None,
            read_only: false,
            summary: ChatSummary {
                unread: false,
                read_only: false,
                id: "fixture".into(),
                title: "A long synthetic chat".into(),
                updated_at_ms: 1_700_000_000_000,
                pinned: false,
                archived: false,
                folder_id: None,
                model: None,
                tags: vec![],
                shared: false,
                menu: crate::fixture::owui_chat_menu(),
            },
            messages,
            system_prompt: None,
            tasks: vec![],
        }),
    })
    .unwrap()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Warmup,
    Idle,
    Stream,
    StreamScroll,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Warmup => "warmup",
            Self::Idle => "idle",
            Self::Stream => "stream-follow",
            Self::StreamScroll => "stream-scroll",
            Self::Done => "done",
        }
    }
}

#[derive(Default)]
pub(crate) struct Samples {
    pub(crate) intervals: Vec<f64>,
    /// Render through paint of the window's tree, per frame.
    pub(crate) work: Rc<std::cell::RefCell<Vec<f64>>>,
}

pub(crate) fn summary(v: &[f64]) -> Value {
    let mut v = v.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    let pct = |p: f64| {
        if n == 0 {
            0.
        } else {
            v[((n as f64 - 1.) * p).round() as usize]
        }
    };
    let over = |t: f64| v.iter().filter(|x| **x > t).count() as f64 * 100. / n.max(1) as f64;
    json!({
        "n": n,
        "p50": format!("{:.2}", pct(0.5)),
        "p95": format!("{:.2}", pct(0.95)),
        "p99": format!("{:.2}", pct(0.99)),
        "max": format!("{:.2}", v.last().copied().unwrap_or(0.)),
        "over_16_7_pct": format!("{:.1}", over(16.7)),
        "over_33_pct": format!("{:.1}", over(33.)),
    })
}

/// The fixture window's root.
struct FixtureChat {
    store: Entity<ChatStore>,
    transcript: Entity<Transcript>,
    composer: Entity<ChatComposer>,
    perf: bool,
    started: Instant,
    last_frame: Option<Instant>,
    phase: Phase,
    samples: Vec<(Phase, Samples)>,
    jumped: bool,
}

impl FixtureChat {
    fn phase_at(&self, t: f64) -> Phase {
        match t {
            t if t < 4. => Phase::Warmup,
            t if t < 10. => Phase::Idle,
            t if t < 20. => Phase::Stream,
            t if t < 30. => Phase::StreamScroll,
            _ => Phase::Done,
        }
    }

    fn report(&self) {
        for (phase, s) in &self.samples {
            if *phase == Phase::Warmup {
                continue;
            }
            println!(
                "{}",
                json!({
                    "phase": phase.name(),
                    "frame_interval_ms": summary(&s.intervals),
                    "frame_work_ms": summary(&s.work.borrow()),
                })
            );
        }
    }
}

impl Render for FixtureChat {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.perf {
            let now = Instant::now();
            let t = (now - self.started).as_secs_f64();
            let phase = self.phase_at(t);
            if phase != self.phase {
                self.phase = phase;
                self.samples.push((phase, Samples::default()));
                if phase == Phase::Done {
                    self.report();
                    cx.quit();
                }
            }
            if let Some((_, s)) = self.samples.last_mut()
                && let Some(last) = self.last_frame
            {
                s.intervals.push((now - last).as_secs_f64() * 1000.);
            }
            self.last_frame = Some(now);
            if phase == Phase::StreamScroll {
                let list = self.transcript.read(cx).list_state().clone();
                if !self.jumped {
                    self.jumped = true;
                    // Follow off (and the eased follow) before scrolling, or
                    // it snaps back.
                    self.transcript.update(cx, |t, _| t.stop_following());
                    let count = list.item_count();
                    list.scroll_to(ListOffset {
                        item_ix: count.saturating_sub(60),
                        offset_in_item: px(0.),
                    });
                } else {
                    list.scroll_by(px(24.));
                }
            }
            window.request_animation_frame();
        }
        // Painted last: the time from this render to the end of paint.
        let render_start = Instant::now();
        let work = self.samples.last().map(|(_, s)| s.work.clone());
        let probe = gpui_kit::canvas(
            |_, _, _| {},
            move |_, _, _, _| {
                if let Some(work) = &work {
                    work.borrow_mut()
                        .push(render_start.elapsed().as_secs_f64() * 1000.);
                }
            },
        )
        .absolute()
        .size(px(1.));
        let t = cx.conduit().clone();
        let _ = &self.store;
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(t.roles.content)
            .text_color(t.roles.text)
            .font_family(conduit_components::theme::UI_FONT)
            .relative()
            .child(div().h(px(cw::TOOLBAR_HEIGHT)).flex_none())
            .child(self.transcript.clone())
            .child(
                div()
                    .flex_none()
                    .flex()
                    .justify_center()
                    .px(px(32.))
                    .pb(px(16.))
                    .child(
                        div()
                            .w_full()
                            .max_w(px(conduit_components::views::shell::CHAT_COLUMN + 40.))
                            .child(self.composer.clone()),
                    ),
            )
            .child(probe)
    }
}

fn ticker(store: Entity<ChatStore>, cx: &mut App) {
    let answer = long_answer();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let started = Instant::now();
        // Streams after the warm-up and the idle baseline, for twenty seconds,
        // wrapping around.
        cx.background_executor()
            .timer(Duration::from_secs(10))
            .await;
        let mut revealed = 0usize;
        loop {
            let t = started.elapsed().as_secs_f64();
            if t > 30. {
                break;
            }
            // ~32K over ten seconds: about 55 characters a frame.
            revealed = (revealed + 55).min(answer.len());
            while !answer.is_char_boundary(revealed) {
                revealed += 1;
            }
            if revealed >= answer.len() {
                revealed = 0;
            }
            let markdown = answer[..revealed.max(1)].to_string();
            let event = Event::TurnBlocks(TurnBlocks {
                chat_id: "fixture".into(),
                message_id: "live".into(),
                blocks: vec![text_block(markdown)],
                tasks: None,
            });
            store.update(cx, |s, cx| s.on_event(&event, cx));
            cx.background_executor()
                .timer(Duration::from_micros(16_667))
                .await;
        }
    })
    .detach();
}

/// Runs the fixture: `mode` is `perf`, `shots`, `diagrams` or `a11y`.
pub fn run(
    mode: String,
    shots: Option<PathBuf>,
    settings: Entity<crate::stores::settings::SettingsStore>,
    cx: &mut App,
) {
    // English labels whatever the Mac's languages: the AccessKit test reads
    // them, as the shell fixture's does.
    cx.set_global(crate::l10n::L10n::new("en"));
    crate::install_component_strings(cx);
    if mode == "diagrams" {
        return crate::diagram_fixture::run(shots, cx);
    }
    let dark = std::env::args().any(|a| a == "--dark");
    if mode == "shots" {
        settings.update(cx, |s, cx| {
            s.set_appearance(
                |a| {
                    a.mode = if dark {
                        crate::prefs::ThemeMode::Dark
                    } else {
                        crate::prefs::ThemeMode::Light
                    }
                },
                cx,
            )
        });
    }
    let rpc = Rpc::new(FixtureDaemon { chat: chat_value() });
    let subscribe: Subscribe = Rc::new(|_, _| {});
    let store = cx.new(|cx| ChatStore::new(rpc.clone(), subscribe, "fixture".into(), cx));
    let composer_store = cx.new(|_| ComposerStore::new(rpc, None));
    composer_store.update(cx, |c, cx| c.refresh_models(cx));
    // `perf-a11y`: the perf run with accessibility active, as with
    // VoiceOver on (the window builds and sends its AccessKit tree each frame).
    let perf = mode == "perf" || mode == "perf-a11y";
    let bounds = Bounds::centered(None, size(px(1100.), px(900.)), cx);
    let mut options = cw::window_options("Conduit chat fixture", bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    if perf {
        options.inactive_frame_interval = None;
        options.low_power_frame_interval = None;
        options.thermal_frame_interval = None;
    }
    let opened = cw::open_window_clear_root(options, cx, |window, cx| {
        let host = RowHost {
            store: store.downgrade(),
            pane: crate::views::chat::rows::RowSink::None,
            server_id: None,
            composer: Some(composer_store.downgrade()),
        };
        let transcript = cx.new(|cx| Transcript::new(store.clone(), host, cx));
        let composer = cx.new(|cx| ChatComposer::new(composer_store.clone(), window, cx));
        composer.update(cx, |c, _| c.new_chat = false);
        cx.new(|_| FixtureChat {
            store: store.clone(),
            transcript,
            composer,
            perf,
            started: Instant::now(),
            last_frame: None,
            phase: Phase::Warmup,
            samples: vec![(Phase::Warmup, Samples::default())],
            jumped: false,
        })
    });
    let (handle, view) = match opened {
        Ok(v) => v,
        Err(e) => {
            println!("{}", json!({"error": e.to_string()}));
            cx.quit();
            return;
        }
    };
    cx.activate(true);
    if perf {
        if mode == "perf-a11y"
            && let Some(ptr) = handle
                .update(cx, |_, window, _| cw::macos::ns_window_ptr(window))
                .ok()
                .flatten()
        {
            // SAFETY: this process's live NSWindow, on the main thread.
            unsafe { conduit_components::capture::activate_accessibility(ptr) };
        }
        ticker(store, cx);
        return;
    }
    if mode == "shots" {
        let dir = shots.unwrap_or_else(|| PathBuf::from("."));
        shots_run(
            handle,
            view,
            store,
            dir,
            if dark { "dark" } else { "light" },
            cx,
        );
        return;
    }
    // a11y: one finished answer to read, then the tree.
    cx.spawn(async move |cx: &mut AsyncApp| {
        cx.background_executor().timer(Duration::from_secs(2)).await;
        let event = Event::TurnBlocks(TurnBlocks {
            chat_id: "fixture".into(),
            message_id: "live".into(),
            blocks: vec![text_block("The answer, *finished*.".into())],
            tasks: None,
        });
        store.update(cx, |s, cx| s.on_event(&event, cx));
        let done = Event::TurnFinished(conduit_protocol::TurnFinished {
            chat_id: "fixture".into(),
            message_id: "live".into(),
            ok: true,
            code: None,
            queued: false,
        });
        store.update(cx, |s, cx| s.on_event(&done, cx));
        cx.background_executor().timer(Duration::from_secs(1)).await;
        let ptr = cx.update(|cx| {
            handle
                .update(cx, |_, window, _| cw::macos::ns_window_ptr(window))
                .ok()
                .flatten()
        });
        if let Some(ptr) = ptr {
            // SAFETY: this process's live NSWindow, on the main thread.
            unsafe { conduit_components::capture::activate_accessibility(ptr) };
        }
        let mut tree = None;
        for _ in 0..30 {
            cx.background_executor()
                .timer(Duration::from_millis(150))
                .await;
            tree = cx.update(|cx| {
                handle
                    .update(cx, |_, window, _| {
                        window.refresh();
                        window.debug_a11y_tree_json()
                    })
                    .ok()
                    .flatten()
            });
            if tree.as_ref().is_some_and(|t| t.contains("\"Article\"")) {
                break;
            }
        }
        if let Some(dir) = &shots {
            std::fs::create_dir_all(dir).ok();
            crate::smoke::shoot(handle, dir.join("fixture-a11y.png"), cx).await;
        }
        let (mut articles, mut controls) = (vec![], vec![]);
        if let Some(nodes) = tree
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .and_then(|t| t.get("nodes").cloned())
            .and_then(|n| n.as_object().cloned())
        {
            for node in nodes.values() {
                let aria = node.get("aria").cloned().unwrap_or(Value::Null);
                let role = aria
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let label = aria
                    .get("label")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if role == "Article" {
                    articles.push(label);
                } else if !role.is_empty() && role != "GenericContainer" {
                    controls.push(json!({"role": role, "label": label}));
                }
            }
        }
        // The model picker: what VoiceOver is told as ↓ moves its highlight
        // (and wraps from the last model to the first).
        let composer = cx.update(|cx| view.read(cx).composer.clone());
        let _ = cx.update(|cx| {
            handle.update(cx, |_, window, cx| {
                composer.update(cx, |c, cx| c.open_picker(window, cx))
            })
        });
        let mut picker = vec![];
        for step in 0..3 {
            if step > 0 {
                let _ = cx.update(|cx| {
                    handle.update(cx, |_, window, cx| {
                        composer.update(cx, |c, cx| c.menu_key("down", window, cx))
                    })
                });
            }
            cx.background_executor()
                .timer(Duration::from_millis(400))
                .await;
            let tree = cx.update(|cx| {
                handle
                    .update(cx, |_, window, _| {
                        window.refresh();
                        window.debug_a11y_tree_json()
                    })
                    .ok()
                    .flatten()
            });
            let options: Vec<Value> = tree
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .and_then(|t| t.get("nodes").cloned())
                .and_then(|n| n.as_object().cloned())
                .map(|nodes| {
                    let mut options: Vec<(i64, Value)> = nodes
                        .values()
                        .filter_map(|node| {
                            let aria = node.get("aria")?;
                            (aria.get("role")?.as_str()? == "ListBoxOption").then(|| {
                                let at = aria
                                    .get("position_in_set")
                                    .and_then(Value::as_i64)
                                    .unwrap_or(0);
                                (
                                    at,
                                    json!({
                                        "label": aria.get("label"),
                                        "selected": aria.get("selected"),
                                        "toggled": aria.get("toggled"),
                                    }),
                                )
                            })
                        })
                        .collect();
                    options.sort_by_key(|(at, _)| *at);
                    options.into_iter().map(|(_, o)| o).collect()
                })
                .unwrap_or_default();
            picker.push(options);
        }
        println!(
            "{}",
            json!({"articles": articles, "controls": controls, "picker": picker})
        );
        cx.update(|cx| cx.quit());
    })
    .detach();
}

/// `shots`: the answer streamed to fixed lengths, then scrolled to fixed
/// places (some further than the transcript keeps laid out), a shot of the
/// window at rest after each.
fn shots_run(
    handle: gpui_kit::AnyWindowHandle,
    view: Entity<FixtureChat>,
    store: Entity<ChatStore>,
    dir: PathBuf,
    mode: &'static str,
    cx: &mut App,
) {
    std::fs::create_dir_all(&dir).ok();
    let answer = long_answer();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let rest =
            |ms: u64, cx: &mut AsyncApp| cx.background_executor().timer(Duration::from_millis(ms));
        let shoot = |name: &str, cx: &mut AsyncApp| {
            let path = dir.join(format!("fixture-shot-{name}-{mode}.png"));
            let number = handle
                .update(cx, |_, window, _| cw::macos::window_number(window))
                .ok()
                .flatten();
            let path = path.to_string_lossy().to_string();
            match number.map(|n| conduit_components::capture::capture_window(n, &path)) {
                Some(Ok((w, h))) => println!("SHOT {path} ({w}x{h})"),
                Some(Err(e)) => println!("SHOT FAILED {path}: {e}"),
                None => println!("SHOT FAILED {path}: no window"),
            }
        };
        rest(2_000, cx).await;
        // Streamed as the perf run streams it (about 55 characters a frame).
        let mut revealed = 0usize;
        for target in [8 * 1024, 16 * 1024, 24 * 1024, ANSWER_CHARS] {
            while revealed < target {
                revealed = (revealed + 55).min(target);
                while !answer.is_char_boundary(revealed) {
                    revealed += 1;
                }
                let event = Event::TurnBlocks(TurnBlocks {
                    chat_id: "fixture".into(),
                    message_id: "live".into(),
                    blocks: vec![text_block(answer[..revealed].to_string())],
                    tasks: None,
                });
                store.update(cx, |s, cx| s.on_event(&event, cx));
                rest(16, cx).await;
            }
            rest(2_500, cx).await;
            shoot(&format!("follow-{:02}k", target / 1024), cx);
        }
        let transcript = cx.update(|cx| view.read(cx).transcript.clone());
        let list = cx.update(|cx| transcript.read(cx).list_state().clone());
        cx.update(|cx| transcript.update(cx, |t, _| t.stop_following()));
        // Jumps up (each further than the transcript keeps laid out), one
        // back down, the answer's top, and its end again.
        for (name, dy) in [
            ("up-0400", -400.),
            ("up-2400", -2_000.),
            ("up-6000", -3_600.),
            ("down-5000", 1_000.),
        ] {
            cx.update(|cx| transcript.update(cx, |t, cx| t.scroll_by(px(dy), cx)));
            rest(1_500, cx).await;
            shoot(name, cx);
        }
        let live = list.item_count().saturating_sub(1);
        list.scroll_to(ListOffset {
            item_ix: live,
            offset_in_item: px(0.),
        });
        cx.update(|cx| view.update(cx, |_, cx| cx.notify()));
        rest(1_500, cx).await;
        shoot("answer-top", cx);
        cx.update(|cx| transcript.update(cx, |t, cx| t.scroll_to_end(cx)));
        rest(2_000, cx).await;
        shoot("end", cx);
        cx.update(|cx| cx.quit());
    })
    .detach();
}

/// Whether `--chat-fixture` was asked for: `(mode, shots)`.
pub fn requested(args: &[String]) -> Option<(String, Option<PathBuf>)> {
    let at = args.iter().position(|a| a == "--chat-fixture")?;
    let mode = args.get(at + 1).cloned().unwrap_or_else(|| "a11y".into());
    let shots = args
        .iter()
        .position(|a| a == "--shots")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from);
    Some((mode, shots))
}
