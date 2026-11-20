//! `--chat-fixture diagrams`: the transcript over a fixture daemon, with a
//! chat of 50 answers that each draw a Mermaid diagram or a chart (every
//! one different), scrolled from top to bottom while they are drawn for
//! the first time (`scroll-cold`), then once they are all drawn, up and
//! down again (`scroll-warm`). Frame intervals and the work in each frame
//! are printed as JSON per phase, as the `perf` fixture prints them, then
//! how many diagrams were drawn and the memory: this process's resident
//! size at the start and after each phase, and the web content processes
//! that started meanwhile (the renderer's). Run it with the display awake.

use std::path::PathBuf;
use std::rc::Rc;
use std::time::Instant;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::window as cw;
use conduit_protocol::{ChatDetail, ChatMessageDto, ChatResult, ChatSummary};
use gpui_kit::prelude::*;
use gpui_kit::{App, Bounds, Context, Entity, ListOffset, Window, WindowBounds, div, px, size};
use serde_json::{Value, json};

use crate::chat_fixture::{FixtureDaemon, summary, text_block};
use crate::stores::chat::{ChatStore, Subscribe};
use crate::stores::rpc::Rpc;
use crate::views::chat::diagrams::drawn_counts;
use crate::views::chat::rows::RowHost;
use crate::views::chat::transcript::Transcript;

/// Answers with a diagram, half Mermaid and half charts.
pub const DIAGRAMS: usize = 50;

/// Answer `n`: a sentence and its diagram (each different).
fn answer(n: usize) -> String {
    if n.is_multiple_of(2) {
        format!(
            "Stage {n} of the harbour's day, as a flow.\n\n```mermaid\ngraph LR\n  \
             A[Moor {n}] --> B[Load]\n  B --> C{{Tide {n}?}}\n  C -->|high| D[Sail]\n  \
             C -->|low| E[Wait]\n  E --> C\n```\n\nIt repeats each tide."
        )
    } else {
        let data: Vec<f64> = (0..6).map(|i| ((n * 7 + i * 3) % 11) as f64 + 1.).collect();
        format!(
            "Week {n}'s water levels.\n\n```chart\n{}\n```\n\nThe highs follow the moon.",
            json!({
                "type": if n % 4 == 1 { "bar" } else { "line" },
                "data": {"labels": ["Mon","Tue","Wed","Thu","Fri","Sat"],
                         "datasets": [{"label": format!("Week {n}"), "data": data}]},
            })
        )
    }
}

fn chat_value() -> Value {
    let messages: Vec<ChatMessageDto> = (0..DIAGRAMS * 2)
        .map(|i| {
            let assistant = i % 2 == 1;
            let content = if assistant {
                answer(i / 2)
            } else {
                format!("Show me part {} of the harbour's week.", i / 2)
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
                held: false,
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
                title: "Fifty diagrams".into(),
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

/// This process's resident size, in MB.
fn rss_mb(pid: u32) -> f64 {
    std::process::Command::new("/bin/ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .parse::<f64>()
                .ok()
        })
        .map_or(0., |kb| kb / 1024.)
}

/// The web content processes running, `(pid, MB)`.
fn web_content() -> Vec<(u32, f64)> {
    let out = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,rss=,comm="])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    out.lines()
        .filter(|l| l.contains("com.apple.WebKit.WebContent"))
        .filter_map(|l| {
            let mut parts = l.split_whitespace();
            let pid = parts.next()?.parse().ok()?;
            let rss: f64 = parts.next()?.parse().ok()?;
            Some((pid, rss / 1024.))
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Warmup,
    ScrollCold,
    Settle,
    ScrollWarm,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Warmup => "warmup",
            Self::ScrollCold => "scroll-cold",
            Self::Settle => "settle",
            Self::ScrollWarm => "scroll-warm",
            Self::Done => "done",
        }
    }
}

/// One phase's frame intervals and per-frame work, in ms.
type PhaseSamples = (Phase, Vec<f64>, Rc<std::cell::RefCell<Vec<f64>>>);

struct DiagramFixture {
    transcript: Entity<Transcript>,
    phase: Phase,
    phase_started: Instant,
    last_frame: Option<Instant>,
    samples: Vec<PhaseSamples>,
    /// Scrolling down (else up) in the warm pass.
    down: bool,
    warm_turns: u32,
    memory: Vec<Value>,
    web_before: Vec<u32>,
}

/// How far the list scrolls each frame.
const STEP: f32 = 24.;

impl DiagramFixture {
    fn enter(&mut self, phase: Phase, cx: &mut Context<Self>) {
        let pid = std::process::id();
        self.memory.push(json!({
            "after": self.phase.name(),
            "app_mb": format!("{:.0}", rss_mb(pid)),
            "web_content_mb": format!("{:.0}", web_content()
                .iter()
                .filter(|(p, _)| !self.web_before.contains(p))
                .map(|(_, mb)| mb)
                .sum::<f64>()),
            "drawn": drawn_counts().0,
        }));
        self.phase = phase;
        self.phase_started = Instant::now();
        self.samples
            .push((phase, vec![], Rc::new(std::cell::RefCell::new(vec![]))));
        if phase == Phase::Done {
            self.report();
            cx.quit();
        }
    }

    fn report(&self) {
        for (phase, intervals, work) in &self.samples {
            if !matches!(phase, Phase::ScrollCold | Phase::ScrollWarm) {
                continue;
            }
            println!(
                "{}",
                json!({
                    "phase": phase.name(),
                    "frame_interval_ms": summary(intervals),
                    "frame_work_ms": summary(&work.borrow()),
                })
            );
        }
        let (ready, pending, failed) = drawn_counts();
        println!(
            "{}",
            json!({
                "diagrams": {"ready": ready, "pending": pending, "failed": failed},
                "memory": self.memory,
            })
        );
    }
}

impl Render for DiagramFixture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let now = Instant::now();
        let in_phase = now - self.phase_started;
        let list = self.transcript.read(cx).list_state().clone();
        let count = list.item_count();
        let at_end = list.logical_scroll_top().item_ix + 3 >= count;
        let at_top = list.logical_scroll_top().item_ix == 0
            && list.logical_scroll_top().offset_in_item <= px(1.);
        match self.phase {
            Phase::Warmup if in_phase.as_secs_f64() > 3. => {
                self.transcript.update(cx, |t, _| t.stop_following());
                list.scroll_to(ListOffset {
                    item_ix: 0,
                    offset_in_item: px(0.),
                });
                self.enter(Phase::ScrollCold, cx);
            }
            Phase::ScrollCold => {
                if at_end || in_phase.as_secs_f64() > 40. {
                    self.enter(Phase::Settle, cx);
                } else {
                    list.scroll_by(px(STEP));
                }
            }
            Phase::Settle => {
                let (ready, pending, _) = drawn_counts();
                if (ready >= DIAGRAMS && pending == 0) || in_phase.as_secs_f64() > 60. {
                    self.down = false;
                    self.enter(Phase::ScrollWarm, cx);
                } else if pending == 0 {
                    // What was never on screen while it scrolled past: go
                    // back over the list (not measured).
                    list.scroll_by(px(if self.down { STEP * 4. } else { -STEP * 4. }));
                    if at_end {
                        self.down = false;
                    } else if at_top {
                        self.down = true;
                    }
                }
            }
            Phase::ScrollWarm => {
                if self.down && at_end || !self.down && at_top {
                    self.down = !self.down;
                    self.warm_turns += 1;
                }
                if self.warm_turns >= 2 || in_phase.as_secs_f64() > 40. {
                    self.enter(Phase::Done, cx);
                } else {
                    list.scroll_by(px(if self.down { STEP } else { -STEP }));
                }
            }
            _ => {}
        }
        if let Some((_, intervals, _)) = self.samples.last_mut()
            && let Some(last) = self.last_frame
        {
            intervals.push((now - last).as_secs_f64() * 1000.);
        }
        self.last_frame = Some(now);
        window.request_animation_frame();
        let render_start = Instant::now();
        let work = self.samples.last().map(|(_, _, w)| w.clone());
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
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(t.roles.content)
            .text_color(t.roles.text)
            .font_family(conduit_components::theme::UI_FONT)
            .relative()
            .child(crate::views::chat::inline_web::frame_start())
            .child(div().h(px(cw::TOOLBAR_HEIGHT)).flex_none())
            .child(self.transcript.clone())
            .child(probe)
            .child(crate::views::chat::inline_web::frame_end())
    }
}

/// Runs the fixture.
pub fn run(_shots: Option<PathBuf>, cx: &mut App) {
    let rpc = Rpc::new(FixtureDaemon { chat: chat_value() });
    let subscribe: Subscribe = Rc::new(|_, _| {});
    let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "fixture".into(), cx));
    let bounds = Bounds::centered(None, size(px(1100.), px(900.)), cx);
    let mut options = cw::window_options("Conduit diagram fixture", bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.inactive_frame_interval = None;
    options.low_power_frame_interval = None;
    options.thermal_frame_interval = None;
    let web_before: Vec<u32> = web_content().into_iter().map(|(p, _)| p).collect();
    let opened = cw::open_window_clear_root(options, cx, |_, cx| {
        let host = RowHost {
            store: store.downgrade(),
            pane: crate::views::chat::rows::RowSink::None,
            server_id: None,
            composer: None,
        };
        let transcript = cx.new(|cx| Transcript::new(store.clone(), host, cx));
        cx.new(|_| DiagramFixture {
            transcript,
            phase: Phase::Warmup,
            phase_started: Instant::now(),
            last_frame: None,
            samples: vec![(
                Phase::Warmup,
                vec![],
                Rc::new(std::cell::RefCell::new(vec![])),
            )],
            down: true,
            warm_turns: 0,
            memory: vec![],
            web_before,
        })
    });
    if let Err(e) = opened {
        println!("{}", json!({"error": e.to_string()}));
        cx.quit();
        return;
    }
    cx.activate(true);
}
