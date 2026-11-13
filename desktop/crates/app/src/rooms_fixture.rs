//! `--rooms-fixture perf`: a Hermes Group Chat's pane over a fixture
//! daemon, for the room timeline's frame times.
//!
//! A room of four bots with 2,000 rows (the most a room keeps on screen):
//! bot replies with markdown, the user's own messages, notices, routing
//! lines and pauses. Phases: warmup (4 s), idle (6 s, a new reply every
//! 2 s as the daemon's reads bring them), scroll (10 s, 24 px a frame
//! through the history), then one JSON line per phase with the frame
//! interval and the render-to-paint work, as `--chat-fixture perf` prints.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::window as cw;
use conduit_daemon::RpcError;
use conduit_daemon::protocol::{codes, error};
use conduit_protocol::{Event, HermesRoomView};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncApp, Bounds, Context, Entity, ListOffset, Window, WindowBounds, div, px, size,
};
use serde_json::{Value, json};

use crate::stores::Stores;
use crate::stores::rpc::{CallFuture, Daemon, Rpc};
use crate::views::hermes_room::HermesRoomPane;

const ROOM: &str = "perf-room";
const ROWS: usize = 2000;
const BOTS: [(&str, &str); 4] = [
    ("fern", "Fern"),
    ("moss", "Moss"),
    ("reed", "Reed"),
    ("sage", "Sage"),
];

fn item(seq: usize) -> Value {
    let (handle, name) = BOTS[seq % BOTS.len()];
    match seq % 11 {
        0 => json!({"kind": "message", "key": format!("message:{seq}"), "seq": seq, "own": true,
                    "text": format!("@{handle} what about tray {seq}?")}),
        4 => json!({"kind": "notice", "key": format!("notice:{seq}"), "seq": seq,
                    "notice": "turnCancelled", "memberId": handle, "memberName": name}),
        7 => json!({"kind": "route", "key": format!("route:{seq}:handoff"), "seq": seq,
                    "route": "handoff", "lead": name, "names": ["Moss"]}),
        10 => json!({"kind": "pause", "key": format!("pause:{seq}"), "seq": seq,
                     "discussionEventId": format!("user:{seq}"), "messageCount": 6,
                     "actionable": false}),
        n => json!({"kind": "message", "key": format!("message:{seq}"), "seq": seq,
                    "author": name, "memberId": handle, "continued": n == 2,
                    "createdAtMs": 1_767_225_600_000_i64 + seq as i64 * 60_000,
                    "text": format!("{name} here: tray **{seq}** holds `basil` and \
                                     [thyme](https://example.org/{seq}); the south bench \
                                     keeps it warm enough through the night.")}),
    }
}

/// The view as the socket's reader hands it over: parsed JSON.
fn view_json(rows: usize) -> Value {
    let members: Vec<Value> = BOTS
        .iter()
        .map(|(h, n)| json!({"memberId": h, "profile": h, "handle": h, "name": n}))
        .collect();
    json!({
        "roomId": ROOM, "loaded": true, "running": true,
        "room": {"id": ROOM, "name": "Greenhouse crew", "members": members},
        "context": {"purpose": "Plan the spring beds", "routing": "everyone"},
        "routingModes": ["everyone", "lead"],
        "items": (1..=rows).map(item).collect::<Vec<_>>(),
        "members": BOTS.iter().map(|(h, _)| json!({"memberId": h, "state": "replied"})).collect::<Vec<_>>(),
    })
}

fn view(rows: usize) -> HermesRoomView {
    serde_json::from_value(view_json(rows)).expect("a room view")
}

struct RoomsDaemon;

impl Daemon for RoomsDaemon {
    fn call_value(&self, method: &'static str, _: Value) -> CallFuture {
        let answer: Result<Value, RpcError> = match method {
            "hermes.rooms.watch" => Ok(serde_json::to_value(view(ROWS)).unwrap()),
            "hermes.rooms.unwatch" => Ok(json!({"ok": true})),
            other => Err(error(codes::METHOD_NOT_FOUND, other)),
        };
        Box::pin(async move { answer })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Warmup,
    Idle,
    Scroll,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Warmup => "warmup",
            Self::Idle => "room-idle",
            Self::Scroll => "room-scroll",
            Self::Done => "done",
        }
    }
}

#[derive(Default)]
struct Samples {
    intervals: Vec<f64>,
    work: Rc<RefCell<Vec<f64>>>,
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
    })
}

struct FixtureRoom {
    pane: Entity<HermesRoomPane>,
    started: Instant,
    last_frame: Option<Instant>,
    phase: Phase,
    samples: Vec<(Phase, Samples)>,
    jumped: bool,
}

impl FixtureRoom {
    fn phase_at(t: f64) -> Phase {
        match t {
            t if t < 4. => Phase::Warmup,
            t if t < 10. => Phase::Idle,
            t if t < 20. => Phase::Scroll,
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

impl Render for FixtureRoom {
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
            let list = self.pane.read(cx).list_state().clone();
            if !self.jumped {
                self.jumped = true;
                list.scroll_to(ListOffset {
                    item_ix: ROWS / 3,
                    offset_in_item: px(0.),
                });
            } else {
                list.scroll_by(px(24.));
            }
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
            .child(self.pane.clone())
            .child(probe)
    }
}

/// A new reply every 2 s, as the daemon's reads of an open room bring
/// them.
fn ticker(stores: Stores, cx: &mut App) {
    cx.spawn(async move |cx: &mut AsyncApp| {
        let mut rows = ROWS;
        loop {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            rows += 1;
            // Parsed off the main thread, typed on it, as a daemon event is.
            let json = cx
                .background_executor()
                .spawn(async move { view_json(rows) })
                .await;
            let event = Event::HermesRoomsChanged(serde_json::from_value(json).expect("a view"));
            cx.update(|cx| {
                stores
                    .hermes_rooms
                    .update(cx, |h, cx| h.on_event(&event, cx))
            });
        }
    })
    .detach();
}

/// Runs the fixture (`perf` is its only mode).
pub fn run(cx: &mut App) {
    let rpc = Rpc::new(RoomsDaemon);
    let scratch =
        std::env::temp_dir().join(format!("conduit-rooms-fixture-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).ok();
    let stores = crate::fixture::stores(rpc, &scratch, cx);
    stores
        .hermes_rooms
        .update(cx, |h, cx| h.show(Some(ROOM), cx));
    let bounds = Bounds::centered(None, size(px(1100.), px(900.)), cx);
    let mut options = cw::window_options("Conduit rooms fixture", bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.inactive_frame_interval = None;
    options.low_power_frame_interval = None;
    options.thermal_frame_interval = None;
    let pane_stores = stores.clone();
    let opened = cw::open_window_clear_root(options, cx, move |window, cx| {
        let pane = cx.new(|cx| HermesRoomPane::new(pane_stores, ROOM.into(), window, cx));
        cx.new(|_| FixtureRoom {
            pane,
            started: Instant::now(),
            last_frame: None,
            phase: Phase::Warmup,
            samples: vec![(Phase::Warmup, Samples::default())],
            jumped: false,
        })
    });
    if let Err(e) = opened {
        println!("{}", json!({"error": e.to_string()}));
        cx.quit();
        return;
    }
    cx.activate(true);
    ticker(stores, cx);
}

/// Whether `--rooms-fixture` was asked for.
pub fn requested(args: &[String]) -> bool {
    args.iter().any(|a| a == "--rooms-fixture")
}
