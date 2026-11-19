//! `--workspace-fixture perf`: the workspace pane over a canned daemon
//! with 2,000 prompts, its list scrolled a step every frame for 20 s, the
//! frame intervals printed as `FIXTURE workspace perf …` (the list's
//! budget: p95 within one 60 Hz refresh). A release build:
//!
//!   cargo build --release -p conduit-desktop, then run the binary in a
//!   bundle (as perf.sh does) with `--workspace-fixture perf`.

use std::time::{Duration, Instant};

use conduit_components::assets::ConduitAssets;
use conduit_components::window as cw;
use conduit_daemon::protocol::{codes, error};
use gpui_kit::prelude::*;
use gpui_kit::{App, AsyncApp, Bounds, Context, Entity, Window, div, point, px, size};
use serde_json::{Value, json};

use crate::l10n::locale;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::{CallFuture, Daemon, Rpc};
use crate::stores::settings::SettingsStore;
use crate::views::workspace::WorkspacePane;

/// How many prompts the list holds.
const ITEMS: usize = 2_000;

/// Whether the arguments ask for the fixture.
pub fn requested(args: &[String]) -> bool {
    args.iter()
        .position(|a| a == "--workspace-fixture")
        .and_then(|i| args.get(i + 1))
        .is_some_and(|m| m == "perf")
}

struct Canned;

fn page() -> Value {
    let base = 1_767_225_600_000_i64;
    json!({
        "kind": "prompts",
        "total": ITEMS,
        "hasMore": false,
        "items": (0..ITEMS).map(|i| json!({
            "kind": "prompts",
            "id": format!("p{i}"),
            "name": format!("Field checklist {i}"),
            "subtitle": format!("/field-checklist-{i}"),
            "writeAccess": true,
            "active": i % 7 != 0,
            "public": i % 11 == 0,
            "updatedAtMs": base - i as i64 * 3_600_000,
        })).collect::<Vec<_>>(),
    })
}

impl Daemon for Canned {
    fn call_value(&self, method: &'static str, _: Value) -> CallFuture {
        let answer = match method {
            "workspace.capabilities" => Ok(json!({
                "prompts": {"manage": true, "importItems": true, "exportItems": true, "share": true},
                "admin": true,
            })),
            "workspace.list" => Ok(page()),
            other => Err(error(codes::METHOD_NOT_FOUND, other)),
        };
        Box::pin(async move { answer })
    }
}

struct Perf {
    started: Instant,
    last: Option<Instant>,
    intervals: Vec<f64>,
    y: f32,
    down: bool,
}

struct FixtureView {
    pane: Entity<WorkspacePane>,
    perf: Option<Perf>,
}

impl Render for FixtureView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if let Some(perf) = &mut self.perf {
            let now = Instant::now();
            if let Some(last) = perf.last {
                perf.intervals.push((now - last).as_secs_f64() * 1000.);
            }
            perf.last = Some(now);
            let handle = self.pane.read(cx).scroll_handle().clone();
            let max = f32::from(handle.max_offset().y);
            perf.y += if perf.down { 90. } else { -90. };
            if perf.y >= max {
                perf.y = max;
                perf.down = false;
            } else if perf.y <= 0. {
                perf.y = 0.;
                perf.down = true;
            }
            handle.set_offset(point(px(0.), px(-perf.y)));
            if perf.started.elapsed() < Duration::from_secs(20) {
                window.request_animation_frame();
            }
        }
        div().size_full().flex().child(self.pane.clone())
    }
}

/// Runs the fixture, then quits.
pub fn run() {
    let scratch =
        std::env::temp_dir().join(format!("conduit-workspace-fixture-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).ok();
    let app = gpui_kit::application().with_assets(ConduitAssets);
    app.run(move |cx: &mut App| {
        gpui_kit::init(cx);
        let settings = cx.new(|_| {
            SettingsStore::load(
                scratch.join("prefs.json"),
                false,
                locale::system_languages(),
            )
        });
        settings.update(cx, |s, cx| {
            s.set_locale(Some("en".into()), cx);
            s.apply(cx);
        });
        crate::install_component_strings(cx);
        let stores = crate::fixture::stores(Rpc::new(Canned), &scratch, cx);
        let bounds = Bounds::centered(
            None,
            size(px(cw::MAIN_WINDOW_SIZE.0), px(cw::MAIN_WINDOW_SIZE.1)),
            cx,
        );
        let options = cw::window_options("Conduit workspace fixture", bounds, true, true);
        let opened = cw::open_window_clear_root(options, cx, |window, cx| {
            let pane =
                cx.new(|cx| WorkspacePane::new(stores, WorkspaceSection::Prompts, window, cx));
            cx.new(|_| FixtureView { pane, perf: None })
        });
        let Ok((_, view)) = opened else {
            println!("FIXTURE FAILED no window");
            cx.quit();
            return;
        };
        cx.activate(true);
        cx.spawn(async move |cx: &mut AsyncApp| {
            let passed = perf(&view, cx).await;
            println!("FIXTURE {}", if passed { "passed" } else { "FAILED" });
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
}

async fn perf(view: &Entity<FixtureView>, cx: &mut AsyncApp) -> bool {
    // The list loads first.
    for _ in 0..50 {
        let loaded = cx.update(|cx| {
            let pane = view.read(cx).pane.read(cx);
            pane.current()
                .is_some_and(|l| l.loaded && l.items.len() == ITEMS)
        });
        if loaded {
            break;
        }
        cx.background_executor()
            .timer(Duration::from_millis(100))
            .await;
    }
    view.update(cx, |v, cx| {
        v.perf = Some(Perf {
            started: Instant::now(),
            last: None,
            intervals: vec![],
            y: 0.,
            down: true,
        });
        cx.notify();
    });
    cx.background_executor()
        .timer(Duration::from_secs(21))
        .await;
    let mut v = cx.update(|cx| {
        view.read(cx)
            .perf
            .as_ref()
            .map(|p| p.intervals.clone())
            .unwrap_or_default()
    });
    if v.is_empty() {
        println!("FIXTURE workspace perf: no frames");
        return false;
    }
    v.sort_by(f64::total_cmp);
    let pct = |v: &[f64], p: f64| v[((v.len() as f64 - 1.) * p).round() as usize];
    let over = |t: f64| v.iter().filter(|x| **x > t).count() as f64 * 100. / v.len() as f64;
    let p95 = pct(&v, 0.95);
    println!(
        "FIXTURE workspace perf rows={ITEMS} frames={} interval p50={:.2}ms p95={p95:.2}ms p99={:.2}ms max={:.2}ms >16.7ms={:.1}%",
        v.len(),
        pct(&v, 0.5),
        pct(&v, 0.99),
        v[v.len() - 1],
        over(16.7),
    );
    p95 <= 16.8
}
