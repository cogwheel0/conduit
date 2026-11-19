//! `--calendar-fixture perf` and `--tasks-fixture perf`: the Calendar pane's
//! agenda (60 days, about 2,000 rows) and the Scheduled Tasks list (2,000
//! tasks) over a canned daemon, each list scrolled a step every frame for
//! 20 s, the frame intervals printed as `FIXTURE calendar perf …` or
//! `FIXTURE tasks perf …` (the lists' budget: p95 within one 60 Hz
//! refresh). A release build, in a bundle (as the perf script runs it).

use std::time::{Duration, Instant};

use conduit_components::assets::ConduitAssets;
use conduit_components::window as cw;
use conduit_daemon::protocol::{codes, error};
use conduit_protocol::{
    AutomationList, AutomationScheduleDto, AutomationSummary, CalendarAgenda, CalendarAgendaDay,
    CalendarDto, CalendarItemDto, CalendarRowTimeDto, CalendarWallTime, Capabilities,
};
use gpui_kit::component::VirtualListScrollHandle;
use gpui_kit::prelude::*;
use gpui_kit::{AnyView, App, AsyncApp, Bounds, Context, Entity, Window, div, point, px, size};
use serde_json::Value;

use crate::l10n::locale;
use crate::stores::rpc::{CallFuture, Daemon, Rpc};
use crate::stores::settings::SettingsStore;
use crate::views::calendar::CalendarPane;
use crate::views::tasks::TasksPane;

const DAYS: i64 = 60;
const PER_DAY: i64 = 32;
const TASKS: usize = 2_000;

/// Which list the arguments ask for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Which {
    Calendar,
    Tasks,
}

pub fn requested(args: &[String]) -> Option<Which> {
    let perf = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .is_some_and(|m| m == "perf")
    };
    if perf("--calendar-fixture") {
        Some(Which::Calendar)
    } else if perf("--tasks-fixture") {
        Some(Which::Tasks)
    } else {
        None
    }
}

fn wall(day: i64, hour: i64) -> CalendarWallTime {
    // From 1 November 2026, by day of the month (and on into December).
    let (month, day) = if day < 30 {
        (11, day + 1)
    } else {
        (12, day - 29)
    };
    CalendarWallTime {
        year: 2026,
        month,
        day,
        hour,
        minute: 0,
    }
}

fn agenda() -> CalendarAgenda {
    let calendar = |id: &str, name: &str, color: &str| CalendarDto {
        id: id.into(),
        name: name.into(),
        color: Some(color.into()),
        is_default: id == "c1",
        scheduled: false,
        owned: true,
        writable: true,
        can_make_default: id != "c1",
        visible: true,
    };
    CalendarAgenda {
        available: true,
        failure: None,
        stale: false,
        first_day: Some(wall(0, 0)),
        end_day: Some(wall(DAYS, 0)),
        day_count: DAYS,
        today: Some(wall(0, 0)),
        calendars: vec![
            calendar("c1", "Allotment", "#22c55e"),
            calendar("c2", "Workshop", "#3b82f6"),
        ],
        filterable: true,
        scheduled_tasks: false,
        can_create: true,
        days: (0..DAYS)
            .map(|d| CalendarAgendaDay {
                day: wall(d, 0),
                items: (0..PER_DAY)
                    .map(|i| {
                        let hour = 6 + i % 16;
                        CalendarItemDto {
                            key: format!("e{d}-{i}|"),
                            kind: "event".into(),
                            id: format!("e{d}-{i}"),
                            calendar_id: if i % 3 == 0 { "c2" } else { "c1" }.into(),
                            title: format!("Bed {i} watering round"),
                            location: (i % 4 == 0).then(|| "North beds".into()),
                            color: Some(if i % 3 == 0 { "#3b82f6" } else { "#22c55e" }.into()),
                            recurring: i % 5 == 0,
                            all_day: false,
                            cancelled: false,
                            start: wall(d, hour),
                            end: Some(wall(d, hour + 1)),
                            last_day: Some(wall(d, 0)),
                            time: CalendarRowTimeDto {
                                kind: "range".into(),
                                start: Some(wall(d, hour)),
                                end: Some(wall(d, hour + 1)),
                            },
                            invited: i % 7 == 0,
                            answer: (i % 7 == 0).then(|| "tentative".into()),
                            editable: true,
                            automation_id: None,
                            run_id: None,
                            result_chat_id: None,
                            result_channel_id: None,
                            scheduled_state: None,
                        }
                    })
                    .collect(),
            })
            .collect(),
    }
}

fn tasks() -> AutomationList {
    let base = 1_767_225_600_000_i64;
    AutomationList {
        available: true,
        failure: None,
        stale: false,
        query: String::new(),
        status: "all".into(),
        total: TASKS as i64,
        has_more: false,
        items: (0..TASKS)
            .map(|i| AutomationSummary {
                id: format!("t{i}"),
                name: format!("Garden digest {i}"),
                active: i % 6 != 0,
                schedule: AutomationScheduleDto {
                    kind: if i % 2 == 0 { "daily" } else { "weekly" }.into(),
                    year: 0,
                    month: 0,
                    day: 0,
                    hour: (i % 24) as i64,
                    minute: 0,
                    days: vec!["MO".into(), "TH".into()],
                    rrule: String::new(),
                },
                next_run_at: (i % 6 != 0).then_some(base + i as i64 * 3_600_000),
                last_run_at: Some(base - i as i64 * 3_600_000),
                last_run_failed: i % 9 == 0,
                agent: None,
            })
            .collect(),
    }
}

struct Canned;

impl Daemon for Canned {
    fn call_value(&self, method: &'static str, _: Value) -> CallFuture {
        let answer = match method {
            "calendar.agenda" => {
                serde_json::to_value(agenda()).map_err(|e| error(codes::DECODE, e.to_string()))
            }
            "automations.list" => {
                serde_json::to_value(tasks()).map_err(|e| error(codes::DECODE, e.to_string()))
            }
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
    pane: AnyView,
    scroll: VirtualListScrollHandle,
    perf: Option<Perf>,
}

impl Render for FixtureView {
    fn render(&mut self, window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        if let Some(perf) = &mut self.perf {
            let now = Instant::now();
            if let Some(last) = perf.last {
                perf.intervals.push((now - last).as_secs_f64() * 1000.);
            }
            perf.last = Some(now);
            let max = f32::from(self.scroll.max_offset().y);
            perf.y += if perf.down { 90. } else { -90. };
            if perf.y >= max {
                perf.y = max;
                perf.down = false;
            } else if perf.y <= 0. {
                perf.y = 0.;
                perf.down = true;
            }
            self.scroll.set_offset(point(px(0.), px(-perf.y)));
            if perf.started.elapsed() < Duration::from_secs(20) {
                window.request_animation_frame();
            }
        }
        div().size_full().flex().child(self.pane.clone())
    }
}

/// Runs the fixture, then quits.
pub fn run(which: Which) {
    let scratch =
        std::env::temp_dir().join(format!("conduit-calendar-fixture-{}", std::process::id()));
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
        stores.session.update(cx, |s, _| {
            s.system_capabilities = Some(Capabilities {
                calendar: true,
                automations: true,
                scheduled_tasks: true,
                ..Default::default()
            })
        });
        let bounds = Bounds::centered(
            None,
            size(px(cw::MAIN_WINDOW_SIZE.0), px(cw::MAIN_WINDOW_SIZE.1)),
            cx,
        );
        let options = cw::window_options("Conduit list fixture", bounds, true, true);
        let opened = cw::open_window_clear_root(options, cx, |window, cx| {
            let (pane, scroll): (AnyView, VirtualListScrollHandle) = match which {
                Which::Calendar => {
                    let pane = cx.new(|cx| CalendarPane::new(stores.clone(), window, cx));
                    let scroll = pane.read(cx).scroll_handle().clone();
                    (pane.into(), scroll)
                }
                Which::Tasks => {
                    let pane = cx.new(|cx| TasksPane::new(stores.clone(), window, cx));
                    let scroll = pane.read(cx).scroll_handle().clone();
                    (pane.into(), scroll)
                }
            };
            cx.new(|_| FixtureView {
                pane,
                scroll,
                perf: None,
            })
        });
        let Ok((_, view)) = opened else {
            println!("FIXTURE FAILED no window");
            cx.quit();
            return;
        };
        cx.activate(true);
        let stores = stores.clone();
        cx.spawn(async move |cx: &mut AsyncApp| {
            // The list loads first.
            for _ in 0..50 {
                let loaded = cx.update(|cx| match which {
                    Which::Calendar => stores.calendar.read(cx).agenda.is_some(),
                    Which::Tasks => stores.tasks.read(cx).list.is_some(),
                });
                if loaded {
                    break;
                }
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
            }
            let passed = perf(&view, which, cx).await;
            println!("FIXTURE {}", if passed { "passed" } else { "FAILED" });
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
}

async fn perf(view: &Entity<FixtureView>, which: Which, cx: &mut AsyncApp) -> bool {
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
    let name = match which {
        Which::Calendar => "calendar",
        Which::Tasks => "tasks",
    };
    let rows = match which {
        Which::Calendar => (DAYS * (PER_DAY + 1)) as usize,
        Which::Tasks => TASKS,
    };
    if v.is_empty() {
        println!("FIXTURE {name} perf: no frames");
        return false;
    }
    v.sort_by(f64::total_cmp);
    let pct = |v: &[f64], p: f64| v[((v.len() as f64 - 1.) * p).round() as usize];
    let over = |t: f64| v.iter().filter(|x| **x > t).count() as f64 * 100. / v.len() as f64;
    let p95 = pct(&v, 0.95);
    println!(
        "FIXTURE {name} perf rows={rows} frames={} interval p50={:.2}ms p95={p95:.2}ms p99={:.2}ms max={:.2}ms >16.7ms={:.1}%",
        v.len(),
        pct(&v, 0.5),
        pct(&v, 0.99),
        v[v.len() - 1],
        over(16.7),
    );
    p95 <= 16.8
}
