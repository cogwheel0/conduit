//! `--channel-fixture perf [--shots <dir>]`: a channel's timeline over a
//! fixture daemon, without conduitd.
//!
//! The window holds the real [`ChannelTimeline`] over a [`ChannelStore`]
//! whose daemon answers from memory: a channel with [`MESSAGES`] messages
//! (runs from several people, markdown with code, lists and quotes,
//! reactions, pins, threads), all loaded.
//!
//! Phases, each printed as JSON (frame intervals vsync to vsync, and the
//! work in each frame): `idle`; `post-follow`, a new message every 250 ms
//! from someone else while the end is in view (`channels.message` deltas,
//! as the daemon sends them); `scroll`, the view scrolled up through the
//! history 24 points a frame. Run it with the display awake.

use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::window as cw;
use conduit_daemon::RpcError;
use conduit_daemon::protocol::{codes, error};
use conduit_protocol::{ChannelMessageDto, ChannelMessagesChanged, Event};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncApp, Bounds, Context, Entity, WeakEntity, Window, WindowBounds, div, px, size,
};
use serde_json::{Value, json};

use crate::stores::channel::{ChannelStore, Subscribe};
use crate::stores::rpc::{CallFuture, Daemon, Rpc};
use crate::views::channels::timeline::{ChannelTimeline, Source};

/// Messages in the fixture channel.
pub const MESSAGES: usize = 2_000;

const PEOPLE: [(&str, &str); 5] = [
    ("u1", "Juniper Hale"),
    ("u2", "Robin Achebe"),
    ("u3", "Sasha Lindqvist"),
    ("u4", "Tomás Ferreira"),
    ("me", "You"),
];

fn text(n: usize) -> String {
    match n % 9 {
        0 => format!("Morning! Trail {n} is clear past the second bridge."),
        1 => format!(
            "Packing list for hike {n}:\n\n- water filter\n- spare socks\n- **map** and compass\n- snacks for the ridge"
        ),
        2 => format!(
            "```python\ndef pace(km, minutes):\n    return minutes / km  # {n}\n```\nAbout twelve minutes a kilometre."
        ),
        3 => {
            "> Bring layers, the wind picks up after noon.\n\nAgreed, it was cold last time.".into()
        }
        4 => format!(
            "Who has the van keys for round {n}? I can drive the second shift if needed, and pick up the trail mix on the way. Let me know before Friday so I can plan the route around the market."
        ),
        5 => "👍 sounds good".into(),
        6 => format!("Photos from stop {n} are in the shared folder, *finally*."),
        7 => "1. Meet at eight\n2. Start at nine\n3. Lunch at the lake".into(),
        _ => format!("Short one, {n}."),
    }
}

fn message(n: usize, at: i64) -> ChannelMessageDto {
    // Runs of two to four messages from one person.
    let (id, name) = PEOPLE[(n / 3) % PEOPLE.len()];
    let body = text(n);
    serde_json::from_value(json!({
        "id": format!("m{n}"),
        "channelId": "fixture",
        "user": {"id": id, "name": name},
        "content": body,
        "display": body,
        "createdAtMs": at,
        "senderKey": id,
        "mine": id == "me",
        "pinned": n.is_multiple_of(97),
        "replyCount": if n.is_multiple_of(41) { 3 } else { 0 },
        "reactions": if n.is_multiple_of(7) {
            json!([{"name": "👍", "count": 2, "names": ["Juniper Hale", "Robin Achebe"]},
                   {"name": "🎉", "count": 1, "mine": true}])
        } else { json!([]) },
    }))
    .unwrap()
}

fn history() -> Value {
    let now = chrono::Local::now().timestamp_millis();
    let start = now - (MESSAGES as i64) * 90_000;
    let mut messages: Vec<ChannelMessageDto> = (0..MESSAGES)
        .map(|n| message(n, start + n as i64 * 90_000))
        .collect();
    messages.reverse();
    json!({"channelId": "fixture", "messages": messages, "hasOlder": false})
}

struct FixtureDaemon {
    history: Value,
}

impl Daemon for FixtureDaemon {
    fn call_value(&self, method: &'static str, _: Value) -> CallFuture {
        let answer: Result<Value, RpcError> = match method {
            "channels.messages" => Ok(self.history.clone()),
            "channels.open" => Ok(json!({
                "channel": {"id": "fixture", "name": "trail-crew", "title": "trail-crew", "kind": "group"},
                "canManageMembers": true,
            })),
            "channels.typing" | "channels.focus" | "channels.react" => Ok(json!({"ok": true})),
            other => Err(error(codes::METHOD_NOT_FOUND, other)),
        };
        Box::pin(async move { answer })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Warmup,
    Idle,
    PostFollow,
    Scroll,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Warmup => "warmup",
            Self::Idle => "idle",
            Self::PostFollow => "post-follow",
            Self::Scroll => "scroll",
            Self::Done => "done",
        }
    }
}

#[derive(Default)]
struct Samples {
    intervals: Vec<f64>,
    work: Rc<std::cell::RefCell<Vec<f64>>>,
}

fn summary(v: &[f64]) -> Value {
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

struct FixtureChannel {
    timeline: Entity<ChannelTimeline>,
    started: Instant,
    last_frame: Option<Instant>,
    phase: Phase,
    samples: Vec<(Phase, Samples)>,
}

impl FixtureChannel {
    fn phase_at(t: f64) -> Phase {
        match t {
            t if t < 4. => Phase::Warmup,
            t if t < 10. => Phase::Idle,
            t if t < 20. => Phase::PostFollow,
            t if t < 30. => Phase::Scroll,
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

impl Render for FixtureChannel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let now = Instant::now();
        let phase = Self::phase_at((now - self.started).as_secs_f64());
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
        if phase == Phase::Scroll {
            self.timeline.read(cx).list_state().scroll_by(px(-24.));
        }
        window.request_animation_frame();
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
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(t.roles.content)
            .text_color(t.roles.text)
            .font_family(conduit_components::theme::UI_FONT)
            .relative()
            .child(div().h(px(cw::TOOLBAR_HEIGHT)).flex_none())
            .child(self.timeline.clone())
            .child(div().h(px(96.)).flex_none())
            .child(probe)
    }
}

/// Posts from someone else, every 250 ms, while the end is in view.
fn ticker(store: Entity<ChannelStore>, cx: &mut App) {
    cx.spawn(async move |cx: &mut AsyncApp| {
        let started = Instant::now();
        cx.background_executor()
            .timer(Duration::from_secs(10))
            .await;
        let mut n = MESSAGES;
        while started.elapsed().as_secs_f64() < 20. {
            let at = chrono::Local::now().timestamp_millis();
            let event = Event::ChannelsMessage(ChannelMessagesChanged {
                channel_id: "fixture".into(),
                parent_id: None,
                upserts: vec![message(n, at)],
                removed: vec![],
                full: false,
                has_older: None,
            });
            store.update(cx, |s, cx| s.on_event(&event, cx));
            n += 1;
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
        }
    })
    .detach();
}

/// Runs the fixture (`mode`: `perf`).
pub fn run(mode: String, _shots: Option<PathBuf>, cx: &mut App) {
    let rpc = Rpc::new(FixtureDaemon { history: history() });
    let subscribe: Subscribe = Rc::new(|_, _| {});
    let store = cx.new(|cx| ChannelStore::new(rpc, subscribe, "fixture".into(), cx));
    let bounds = Bounds::centered(None, size(px(1100.), px(900.)), cx);
    let mut options = cw::window_options("Conduit channel fixture", bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.inactive_frame_interval = None;
    options.low_power_frame_interval = None;
    options.thermal_frame_interval = None;
    let opened = cw::open_window_clear_root(options, cx, |_, cx| {
        let timeline = {
            let store = store.clone();
            cx.new(|cx| ChannelTimeline::new(store, WeakEntity::new_invalid(), Source::Channel, cx))
        };
        cx.new(|_| FixtureChannel {
            timeline,
            started: Instant::now(),
            last_frame: None,
            phase: Phase::Warmup,
            samples: vec![(Phase::Warmup, Samples::default())],
        })
    });
    if let Err(e) = opened {
        println!("{}", json!({"error": e.to_string()}));
        cx.quit();
        return;
    }
    cx.activate(true);
    if mode == "perf" {
        ticker(store, cx);
    }
}

/// Whether `--channel-fixture` was asked for: `(mode, shots)`.
pub fn requested(args: &[String]) -> Option<(String, Option<PathBuf>)> {
    let at = args.iter().position(|a| a == "--channel-fixture")?;
    let mode = args.get(at + 1).cloned().unwrap_or_else(|| "perf".into());
    let shots = args
        .iter()
        .position(|a| a == "--shots")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from);
    Some((mode, shots))
}
