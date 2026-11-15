//! Frame strips of transitions: a thread grabs the screen rect around the
//! moving window (one pixel a point) as fast as the window server allows,
//! from just before the trigger until the window has been still for a while;
//! identical consecutive frames are dropped as they come in. Then 16 evenly
//! spaced moments are written with their times
//! (`motion/frames/NN-name/`), with the capture rate and the intervals
//! between visible changes; `hc/compose.py` tiles them.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use conduit_protocol::NoticeLevel;
use gpui_kit::{AnyWindowHandle, AsyncApp};
use serde_json::{Value, json};

use super::grab::{self, CGRect, Frame};
use super::main_pass::{
    self, chat_store, deny_all, dock, new_chat, open_chat, pane, send, toast, tool_request,
    wait_answer,
};
use super::onboarding::in_main;
use super::{MAIN_ORIGIN, MAIN_SIZE, Run, drive, log, pause, window_rect};
use crate::AppState;
use crate::prefs::ThemeMode;

const TILES: usize = 16;
/// Still for this long after the last change: settled.
const QUIET: Duration = Duration::from_millis(700);

struct Grabbed {
    /// Every capture's time (ms from the trigger).
    times: Vec<f64>,
    /// Distinct frames: time and image.
    frames: Vec<(f64, Frame)>,
    /// When a change showed by the older whole-window rule alone, kept to
    /// compare the two rules.
    window_share_changes: Vec<f64>,
}

/// What the main thread watches while the grabber runs.
#[derive(Default)]
struct Progress {
    /// Visible changes after the trigger.
    changes: usize,
    /// When the last one was captured.
    last_change: Option<Instant>,
    /// The capture time of the newest frame compared so far: stillness is
    /// measured up to here, never past what has been looked at.
    compared_until: Option<Instant>,
}

/// Capture pace: twice a 60 Hz display, so every frame it presents is seen
/// without flooding the comparer.
const CAPTURE_INTERVAL: Duration = Duration::from_micros(8_300);

struct Grabber {
    stop: Arc<AtomicBool>,
    progress: Arc<std::sync::Mutex<Progress>>,
    thread: JoinHandle<Grabbed>,
}

/// How (every other) pixel differs from frame `a` to `b` by more than a
/// hair: the share of the window that does, and the most that do in any one
/// [`TILE`]-pixel square. A caret blink or a small spinner stays under both
/// [`CHANGE`] and [`LOCAL_CHANGE`]; a moving panel, a fade, a new word or a
/// band of highlight crossing a line does not.
fn changed(a: &[u8], b: &[u8], stride: usize, w: usize, h: usize) -> (f64, usize) {
    if a.len() != b.len() {
        return (1., usize::MAX);
    }
    let (mut n, mut diff) = (0usize, 0usize);
    let cols = w.div_ceil(TILE);
    let mut tiles = vec![0usize; cols * h.div_ceil(TILE)];
    for y in (0..h).step_by(2) {
        for x in (0..w).step_by(2) {
            let i = y * stride + x * 4;
            if i + 3 >= a.len() {
                continue;
            }
            n += 1;
            if (0..3).any(|c| a[i + c].abs_diff(b[i + c]) > 3) {
                diff += 1;
                tiles[(y / TILE) * cols + x / TILE] += 1;
            }
        }
    }
    let share = if n == 0 { 0. } else { diff as f64 / n as f64 };
    (share, tiles.into_iter().max().unwrap_or(0))
}

/// Visible change: more than this share of the window's pixels…
const CHANGE: f64 = 0.0004;
/// …or this many (of the sampled quarter) in one [`TILE`] square: a small
/// thing moving on its own (a status line's shimmer, a word fading in) is
/// a change the eye sees, though it is a sliver of the window. The share
/// alone (the older rule) let a 145 pt line's shimmer, drawn every frame,
/// register only every 150–500 ms.
const LOCAL_CHANGE: usize = 24;
const TILE: usize = 96;

/// Whether `(share, densest)` from [`changed`] is a visible change.
fn visible((share, densest): (f64, usize)) -> bool {
    share > CHANGE || densest >= LOCAL_CHANGE
}

fn start(rect: CGRect, trigger: Arc<std::sync::Mutex<Option<Instant>>>, max: Duration) -> Grabber {
    let stop = Arc::new(AtomicBool::new(false));
    let progress = Arc::new(std::sync::Mutex::new(Progress::default()));
    let (flag, prog) = (stop.clone(), progress.clone());
    // Two threads: one only captures (as fast as the window server gives
    // frames), the other compares each with the last kept one.
    let (tx, rx) = std::sync::mpsc::channel::<(Instant, Frame)>();
    let trigger_seen = trigger.clone();
    let capture = std::thread::spawn(move || {
        let began = Instant::now();
        let mut times: Vec<Instant> = vec![];
        let mut next = Instant::now();
        while !flag.load(Ordering::SeqCst) && began.elapsed() < max {
            let wait = next.saturating_duration_since(Instant::now());
            if !wait.is_zero() {
                std::thread::sleep(wait);
            }
            next = Instant::now() + CAPTURE_INTERVAL;
            let Some(frame) = Frame::of_rect(rect, false) else {
                continue;
            };
            // Capture times stay instants until the trigger is known:
            // frames before it get their real (negative) offsets.
            let now = Instant::now();
            times.push(now);
            if tx.send((now, frame)).is_err() {
                break;
            }
        }
        times
    });
    let thread = std::thread::spawn(move || {
        let after_trigger = |at: Instant| {
            trigger_seen
                .lock()
                .ok()
                .and_then(|t| *t)
                .is_some_and(|t0| at >= t0)
        };
        let mut frames: Vec<(Instant, Frame)> = vec![];
        let mut last: Option<Vec<u8>> = None;
        // The whole-window rule alone, against its own last kept frame.
        let mut last_share: Option<Vec<u8>> = None;
        let mut window_share_changes = vec![];
        for (at, frame) in rx {
            let (w, h) = frame.size();
            let Some((px, stride)) = frame.pixels() else {
                continue;
            };
            match &last_share {
                None => last_share = Some(px.clone()),
                Some(prev) if changed(prev, &px, stride, w, h).0 > CHANGE => {
                    if after_trigger(at) {
                        window_share_changes.push(at);
                    }
                    last_share = Some(px.clone());
                }
                Some(_) => {}
            }
            let new = match &last {
                None => true,
                Some(prev) => visible(changed(prev, &px, stride, w, h)),
            };
            if new {
                last = Some(px);
                if after_trigger(at)
                    && !frames.is_empty()
                    && let Ok(mut p) = prog.lock()
                {
                    p.changes += 1;
                    p.last_change = Some(at);
                }
                frames.push((at, frame));
            }
            // Stillness is measured up to the newest frame looked at.
            if let Ok(mut p) = prog.lock() {
                p.compared_until = Some(at);
            }
        }
        let times = capture.join().unwrap_or_default();
        // Milliseconds from the trigger (before it: negative).
        let t0 = trigger_seen.lock().ok().and_then(|t| *t);
        let ms = |at: Instant| match t0 {
            Some(t0) if at >= t0 => (at - t0).as_secs_f64() * 1000.,
            Some(t0) => -((t0 - at).as_secs_f64() * 1000.),
            None => 0.,
        };
        Grabbed {
            times: times.into_iter().map(ms).collect(),
            frames: frames.into_iter().map(|(at, f)| (ms(at), f)).collect(),
            window_share_changes: window_share_changes.into_iter().map(ms).collect(),
        }
    });
    Grabber {
        stop,
        progress,
        thread,
    }
}

fn percentile(v: &[f64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.;
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let i = ((s.len() - 1) as f64 * p).round() as usize;
    s[i.min(s.len() - 1)]
}

/// One transition: grab around `rect` (window-relative to `handle`, or the
/// window itself), run `trigger`, wait until still (or `max`), write.
#[allow(clippy::too_many_arguments)]
async fn strip(
    run: &mut Run,
    name: &str,
    title: &str,
    description: &str,
    rect: Option<CGRect>,
    handle: AnyWindowHandle,
    max: Duration,
    trigger: impl AsyncFnOnce(&mut AsyncApp),
    cx: &mut AsyncApp,
) {
    strip_waiting(
        run,
        name,
        title,
        description,
        rect,
        handle,
        max,
        Duration::from_millis(1500),
        trigger,
        cx,
    )
    .await
}

/// [`strip`], waiting up to `first` for the first visible change (a turn the
/// daemon holds until the last one has settled).
#[allow(clippy::too_many_arguments)]
async fn strip_waiting(
    run: &mut Run,
    name: &str,
    title: &str,
    description: &str,
    rect: Option<CGRect>,
    handle: AnyWindowHandle,
    max: Duration,
    first: Duration,
    trigger: impl AsyncFnOnce(&mut AsyncApp),
    cx: &mut AsyncApp,
) {
    let rect = match rect.or_else(|| window_rect(handle, cx).map(|r| grab::inset(r, 16.))) {
        Some(r) => r,
        None => {
            run.missing(&format!("motion · {name}"), "no window to grab");
            return;
        }
    };
    run.stack(handle, cx);
    run.ensure_key(handle, &format!("motion {name}"), cx).await;
    pause(cx, 150).await;
    let trigger_at = Arc::new(std::sync::Mutex::new(None));
    let grabber = start(rect, trigger_at.clone(), max + Duration::from_secs(2));
    pause(cx, 180).await;
    if let Ok(mut t) = trigger_at.lock() {
        *t = Some(Instant::now());
    }
    trigger(cx).await;
    // Until still: a change, then QUIET without one (or nothing at all for
    // `first`), or `max`.
    let began = Instant::now();
    while began.elapsed() < max {
        pause(cx, 50).await;
        let (changes, last, compared) = grabber
            .progress
            .lock()
            .map(|p| (p.changes, p.last_change, p.compared_until))
            .unwrap_or((0, None, None));
        // Measured on what the comparer has seen, up to `compared`.
        let settled = match (last, compared) {
            (Some(t), Some(c)) => changes > 0 && c.saturating_duration_since(t) >= QUIET,
            (None, Some(c)) => c.saturating_duration_since(began) >= first,
            _ => false,
        };
        if settled && began.elapsed() > Duration::from_millis(400) {
            break;
        }
    }
    grabber.stop.store(true, Ordering::SeqCst);
    let Ok(grabbed) = grabber.thread.join() else {
        run.problem(format!("motion {name}: the grabber thread failed"));
        return;
    };
    let n = run.notes.motion.len() + 1;
    let folder = format!("{n:02}-{name}");
    let dir = run.dir.join("motion/frames").join(&folder);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        run.problem(format!("motion {name}: {}: {e}", dir.display()));
        return;
    }

    // Nothing usable was grabbed: no strip, and the run says so.
    if grabbed.frames.is_empty() {
        run.problem(format!("motion {name}: no frame could be read"));
        return;
    }

    let times = &grabbed.times;
    let duration = times.last().copied().unwrap_or(0.) - times.first().copied().unwrap_or(0.);
    let capture_intervals: Vec<f64> = times.windows(2).map(|w| w[1] - w[0]).collect();
    // Changes after the trigger (the first frame is the before-state).
    let changes: Vec<f64> = grabbed
        .frames
        .iter()
        .skip(1)
        .map(|(t, _)| *t)
        .filter(|t| *t >= 0.)
        .collect();
    let first_change = changes.first().copied().unwrap_or(0.);
    let last_change_ms = changes.last().copied().unwrap_or(0.);
    let change_intervals: Vec<f64> = changes.windows(2).map(|w| w[1] - w[0]).collect();
    let frame_ms = 1000. / 60.;
    let long_gaps = change_intervals
        .iter()
        .filter(|i| **i > 2.2 * frame_ms)
        .count();
    // 16 moments from just before the first change to just after the last
    // (times stay relative to the trigger).
    let from = (first_change - 40.).max(-40.);
    let to = (last_change_ms + 120.).max(from + 200.);
    let mut tiles = vec![];
    for i in 0..TILES {
        let at = from + (to - from) * i as f64 / (TILES - 1) as f64;
        let pick = grabbed
            .frames
            .iter()
            .rev()
            .find(|(t, _)| *t <= at)
            .or_else(|| grabbed.frames.first());
        if let Some((t, frame)) = pick {
            let file = format!("f{i:02}.png");
            match frame.write_png(&dir.join(&file)) {
                Ok(_) => tiles.push(json!({"file": file, "ms": at, "frame_ms": t})),
                Err(e) => run.problem(format!("motion {name}: {file}: {e}")),
            }
        }
    }
    // The same by the older whole-window rule alone.
    let share_changes = grabbed.window_share_changes.clone();
    let share_intervals: Vec<f64> = share_changes.windows(2).map(|w| w[1] - w[0]).collect();
    let window_share = json!({
        "distinct_frames": share_changes.len(),
        "change_p95_ms": percentile(&share_intervals, 0.95),
        "change_max_ms": share_intervals.iter().copied().fold(0., f64::max),
        "long_gaps": share_intervals.iter().filter(|i| **i > 2.2 * frame_ms).count(),
    });
    let stats = json!({
        "captured": times.len(),
        "capture_fps": if duration > 0. { times.len() as f64 / duration * 1000. } else { 0. },
        "capture_p50_ms": percentile(&capture_intervals, 0.5),
        "capture_p95_ms": percentile(&capture_intervals, 0.95),
        "distinct_frames": changes.len(),
        "first_change_ms": first_change,
        "active_ms": last_change_ms - first_change,
        "change_p50_ms": percentile(&change_intervals, 0.5),
        "change_p95_ms": percentile(&change_intervals, 0.95),
        "change_max_ms": change_intervals.iter().copied().fold(0., f64::max),
        "long_gaps": long_gaps,
        "window_share": window_share,
    });
    let manifest = json!({
        "name": folder,
        "title": title,
        "description": description,
        "rect": [rect.x, rect.y, rect.w, rect.h],
        "tiles": tiles,
        "stats": stats,
        "changes_ms": changes,
        "changes_ms_window_share": share_changes,
    });
    // A strip without its manifest is not composed: say so, and leave it
    // out of the notes.
    if let Err(e) = std::fs::write(
        dir.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap_or_default(),
    ) {
        run.problem(format!("motion {name}: manifest.json: {e}"));
        return;
    }
    log(format!("motion {folder}: {stats}"));
    let mut row: Value = stats;
    row["name"] = json!(folder);
    row["title"] = json!(title);
    run.notes.motion.push(row);
}

fn display_rect(cx: &mut AsyncApp) -> CGRect {
    cx.update(|cx| {
        cx.primary_display()
            .map(|d| {
                let b = d.bounds();
                CGRect {
                    x: f64::from(f32::from(b.origin.x)),
                    y: f64::from(f32::from(b.origin.y)),
                    w: f64::from(f32::from(b.size.width)),
                    h: f64::from(f32::from(b.size.height)),
                }
            })
            .unwrap_or(CGRect {
                x: 0.,
                y: 0.,
                w: 1728.,
                h: 1117.,
            })
    })
}

pub async fn run(run: &mut Run, cx: &mut AsyncApp) {
    if !run.wants("motion") {
        return;
    }
    let main = run.main;
    // The strips show the motion as designed, whatever this Mac's Reduce
    // Motion says; the last two show it with Reduce Motion on.
    let system_reduce_motion = cx.update(|cx| {
        let on = cx.reduce_motion();
        cx.set_reduce_motion(false);
        on
    });
    run.mode(ThemeMode::Light, cx).await;
    super::place(main, MAIN_ORIGIN, MAIN_SIZE, cx);
    let short = cx.update(|cx| {
        let list = cx.global::<AppState>().stores.chat_list.read(cx);
        list.list
            .iter()
            .flat_map(|l| l.chats.iter())
            .find(|c| c.title == "Sourdough starter schedule")
            .map(|c| c.id.clone())
    });
    if let Some(id) = &short {
        open_chat(run, id, cx).await;
    }
    drive::unhover(main, cx);

    // Sidebar hide and show.
    let toggle = async |cx: &mut AsyncApp| {
        cx.update(|cx| {
            let layout = cx.global::<AppState>().layout.clone();
            layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        });
    };
    strip(
        run,
        "sidebar-hide",
        "Sidebar hide (View › Hide Sidebar, ⌃⌘S)",
        "The sidebar goes away and the toolbar takes the traffic lights' row.",
        None,
        main,
        Duration::from_secs(2),
        toggle,
        cx,
    )
    .await;
    strip(
        run,
        "sidebar-show",
        "Sidebar show",
        "The sidebar comes back.",
        None,
        main,
        Duration::from_secs(2),
        toggle,
        cx,
    )
    .await;

    // ⌘K open and close.
    strip(
        run,
        "palette-open",
        "⌘K palette open",
        "The palette opens over the window.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            let main = cx.update(|cx| cx.global::<AppState>().main_window);
            if let Some(main) = main {
                drive::key(main, "cmd-k", cx);
            }
        },
        cx,
    )
    .await;
    strip(
        run,
        "palette-close",
        "⌘K palette close (Esc)",
        "Esc closes the palette.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            let main = cx.update(|cx| cx.global::<AppState>().main_window);
            if let Some(main) = main {
                drive::key(main, "escape", cx);
            }
        },
        cx,
    )
    .await;
    // Make sure it is closed.
    in_main(run, cx, |mw, window, cx| {
        mw.palette.update(cx, |p, cx| {
            if p.is_open(cx) {
                p.close(window, cx)
            }
        })
    });
    pause(cx, 300).await;

    // The model picker.
    strip(
        run,
        "model-picker-open",
        "Model picker open",
        "The model picker opens under the title capsule.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            let main = cx.update(|cx| cx.global::<AppState>().main_window);
            let Some(main) = main else { return };
            let Some(p) = cx.update(pane) else { return };
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| p.open_model_picker(window, cx))
            });
        },
        cx,
    )
    .await;
    drive::key(main, "escape", cx);
    in_main(run, cx, |mw, window, cx| {
        mw.chat_pane.update(cx, |p, cx| {
            p.composer.update(cx, |c, cx| c.close_picker(window, cx))
        })
    });
    pause(cx, 400).await;

    // A toast.
    strip(
        run,
        "toast-appear",
        "Toast appear",
        "A success toast slides in.",
        None,
        main,
        Duration::from_millis(2500),
        async |cx: &mut AsyncApp| {
            toast(NoticeLevel::Success, "Exported 12 chats to Downloads.", cx);
        },
        cx,
    )
    .await;
    main_pass::clear_toasts(cx);
    pause(cx, 500).await;

    // An approval card, then its answer.
    strip(
        run,
        "approval-appear",
        "Approval card appear",
        "A tool approval docks above the composer.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            dock(tool_request("hc-motion-tool"), cx);
        },
        cx,
    )
    .await;
    strip(
        run,
        "approval-resolve",
        "Approval card resolve (Deny)",
        "The card answered (Command-Option-Delete) and gone.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            deny_all(cx);
        },
        cx,
    )
    .await;
    pause(cx, 500).await;

    // Theme switch.
    strip(
        run,
        "theme-light-to-dark",
        "Theme switch, light to dark",
        "Settings › Appearance › Dark, applied to the open window.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            cx.update(|cx| super::set_mode(ThemeMode::Dark, cx));
        },
        cx,
    )
    .await;
    run.mode = ThemeMode::Dark;
    run.mode(ThemeMode::Light, cx).await;
    pause(cx, 500).await;

    // Reasoning disclosure.
    if let Some(id) = run.env.get("OWUI_SHOWCASE_CHAT").cloned()
        && open_chat(run, &id, cx).await
    {
        cx.update(|cx| {
            if let Some(p) = pane(cx)
                && let Some(t) = p.read(cx).chat.as_ref().map(|c| c.transcript.clone())
            {
                t.update(cx, |t, cx| {
                    t.list_state().scroll_to(gpui_kit::ListOffset {
                        item_ix: 0,
                        offset_in_item: gpui_kit::px(0.),
                    });
                    cx.notify();
                });
            }
        });
        pause(cx, 600).await;
        let nodes = drive::nodes(main, cx).await;
        let header = nodes
            .iter()
            .find(|n| n.expanded == Some(false) && n.label.to_lowercase().contains("thought"))
            .or_else(|| nodes.iter().find(|n| n.expanded == Some(false)))
            .and_then(|n| n.center());
        match header {
            Some(at) => {
                drive::hover(main, at, cx);
                pause(cx, 200).await;
                strip(
                    run,
                    "reasoning-expand",
                    "Reasoning disclosure expand",
                    "Clicking \u{201c}Thought for 6 seconds\u{201d} opens the reasoning.",
                    None,
                    main,
                    Duration::from_secs(2),
                    async move |cx: &mut AsyncApp| {
                        let main = cx.update(|cx| cx.global::<AppState>().main_window);
                        if let Some(main) = main {
                            drive::click(main, at, cx).await;
                        }
                    },
                    cx,
                )
                .await;
                drive::unhover(main, cx);
            }
            None => run.missing(
                "motion · reasoning expand",
                "no collapsed reasoning header in the AccessKit tree",
            ),
        }
    }

    // Send → bubble → stream → settle, in a new chat.
    new_chat(run, cx).await;
    drive::unhover(main, cx);
    strip(run, "send-stream-settle", "Send, stream, settle (new chat)", "A first message sent from a new chat: the bubble, the answer streaming, the chat settling (title, actions).", None, main, Duration::from_secs(9), async |cx: &mut AsyncApp| {
        send("Some math, please", cx).await;
    }, cx).await;
    wait_answer(cx, Duration::from_secs(30)).await;
    pause(cx, 800).await;

    // Regenerate that answer.
    let key = cx.update(|cx| {
        let s = chat_store(cx)?;
        let s = s.read(cx);
        s.rows().iter().rev().find_map(|r| {
            let i = s.item(*r)?;
            (i.role == crate::stores::chat::Role::Assistant).then_some(i.key)
        })
    });
    if let Some(key) = key {
        strip_waiting(run, "regenerate", "Regenerate", "Regenerate on the last answer: it streams again in place, then the version arrows appear.", None, main, Duration::from_secs(25), Duration::from_secs(20), async move |cx: &mut AsyncApp| {
            cx.update(|cx| {
                if let Some(s) = chat_store(cx) {
                    s.update(cx, |s, cx| s.regenerate(&key, None, cx));
                }
            });
        }, cx).await;
        wait_answer(cx, Duration::from_secs(30)).await;
    } else {
        run.missing("motion · regenerate", "no answer to regenerate");
    }

    // A short chat growing past the window: top-anchored, then following.
    new_chat(run, cx).await;
    send("Answer with reasoning, please", cx).await;
    wait_answer(cx, Duration::from_secs(60)).await;
    pause(cx, 1200).await;
    drive::unhover(main, cx);
    strip_waiting(run, "short-chat-overflow", "Short chat overflowing", "A short chat (it starts at the top) gets an answer longer than the window: the hand-off from top-anchored to following the end.", None, main, Duration::from_secs(25), Duration::from_secs(20), async |cx: &mut AsyncApp| {
        send("Show me some code", cx).await;
    }, cx).await;
    wait_answer(cx, Duration::from_secs(30)).await;

    // Settings: open, then a tab switch.
    let display = display_rect(cx);
    let settings_rect = {
        let (w, h) = (
            f64::from(crate::views::settings::SETTINGS_SIZE.0),
            f64::from(crate::views::settings::SETTINGS_SIZE.1),
        );
        let r = CGRect {
            x: display.x + (display.w - w) / 2.,
            y: display.y + (display.h - h) / 2.,
            w,
            h,
        };
        grab::inset(r, 24.)
    };
    let main_rect = window_rect(main, cx).map(|r| grab::inset(r, 16.));
    let rect = main_rect
        .map(|m| grab::union(m, settings_rect))
        .unwrap_or(settings_rect);
    strip(
        run,
        "settings-open",
        "Settings window open (⌘,)",
        "⌘, opens the Settings window over the main window.",
        Some(rect),
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            cx.update(|cx| crate::open_settings(Some(crate::views::settings::Tab::Appearance), cx));
        },
        cx,
    )
    .await;
    let settings = cx.update(|cx| {
        cx.global::<AppState>()
            .settings_window
            .as_ref()
            .map(|(h, _)| *h)
    });
    if let Some(settings) = settings {
        let nodes = drive::nodes(settings, cx).await;
        let tab = nodes
            .iter()
            .find(|n| n.label == "Keyboard" && n.bounds.is_some())
            .and_then(|n| n.center());
        match tab {
            Some(at) => {
                strip(
                    run,
                    "settings-tab-switch",
                    "Settings tab switch",
                    "Clicking Keyboard in the Settings sidebar.",
                    None,
                    settings,
                    Duration::from_secs(2),
                    async move |cx: &mut AsyncApp| {
                        let s = cx.update(|cx| {
                            cx.global::<AppState>()
                                .settings_window
                                .as_ref()
                                .map(|(h, _)| *h)
                        });
                        if let Some(s) = s {
                            drive::click(s, at, cx).await;
                        }
                    },
                    cx,
                )
                .await;
            }
            None => run.missing(
                "motion · settings tab switch",
                "no Keyboard tab in the Settings window's AccessKit tree",
            ),
        }
        let _ = settings.update(cx, |_, window, _| window.remove_window());
        pause(cx, 500).await;
    }

    // Quick Ask: appear and hide, over the screen's top half.
    let qa_rect = CGRect {
        x: display.x,
        y: display.y + 24.,
        w: display.w,
        h: display.h * 0.62,
    };
    strip(
        run,
        "quick-ask-appear",
        "Quick Ask appear (Window › Quick Ask)",
        "The Quick Ask panel appears over other windows.",
        Some(qa_rect),
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            cx.update(crate::desktop::show_quick_ask);
        },
        cx,
    )
    .await;
    let qa = cx.update(|cx| {
        cx.try_global::<crate::desktop::Desktop>()
            .and_then(|d| d.quick_ask.as_ref().map(|(h, _)| *h))
    });
    if let Some(qa) = qa {
        strip(
            run,
            "quick-ask-hide",
            "Quick Ask hide (Esc)",
            "Esc hides the panel.",
            Some(qa_rect),
            qa,
            Duration::from_secs(2),
            async |cx: &mut AsyncApp| {
                cx.update(crate::desktop::hide_quick_ask);
            },
            cx,
        )
        .await;
    } else {
        run.missing("motion · quick ask hide", "Quick Ask did not open");
        cx.update(crate::desktop::hide_quick_ask);
    }
    pause(cx, 500).await;

    // Reduce Motion (System Settings › Accessibility › Display, which the
    // app follows): movement is instant, fades stay as plain crossfades.
    cx.update(|cx| cx.set_reduce_motion(true));
    pause(cx, 300).await;
    strip(
        run,
        "reduce-motion-sidebar",
        "Sidebar hide, Reduce Motion on",
        "With Reduce Motion the sidebar goes at once, without sliding.",
        None,
        main,
        Duration::from_secs(2),
        toggle,
        cx,
    )
    .await;
    toggle(cx).await;
    pause(cx, 400).await;
    strip(
        run,
        "reduce-motion-palette",
        "⌘K palette open, Reduce Motion on",
        "With Reduce Motion the palette only crossfades, without travel.",
        None,
        main,
        Duration::from_secs(2),
        async |cx: &mut AsyncApp| {
            let main = cx.update(|cx| cx.global::<AppState>().main_window);
            if let Some(main) = main {
                drive::key(main, "cmd-k", cx);
            }
        },
        cx,
    )
    .await;
    in_main(run, cx, |mw, window, cx| {
        mw.palette.update(cx, |p, cx| {
            if p.is_open(cx) {
                p.close(window, cx)
            }
        })
    });
    cx.update(|cx| cx.set_reduce_motion(system_reduce_motion));
    pause(cx, 400).await;
    let _ = main_pass::ax_dump;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A white `w`×`h` frame (4 bytes a pixel) with `ink` pixels darkened.
    fn frame(w: usize, h: usize, ink: &[(usize, usize, u8)]) -> Vec<u8> {
        let mut px = vec![255u8; w * h * 4];
        for (x, y, v) in ink {
            let i = (y * w + x) * 4;
            px[i..i + 3].copy_from_slice(&[*v, *v, *v]);
        }
        px
    }

    #[test]
    fn a_small_line_changing_counts_and_a_caret_blink_does_not() {
        let (w, h) = (1312, 892);
        let blank = frame(w, h, &[]);
        // A caret: 2 px wide, 18 tall.
        let caret: Vec<_> = (0..18)
            .flat_map(|y| [(400, 300 + y, 0), (401, 300 + y, 0)])
            .collect();
        assert!(!visible(changed(&blank, &frame(w, h, &caret), w * 4, w, h)));
        // A band of highlight moving over a status line: 70 sampled pixels
        // (20 × 14) a few levels darker.
        let band: Vec<_> = (0..14)
            .flat_map(|y| (0..20).map(move |x| (420 + x, 360 + y, 200)))
            .collect();
        let line = changed(&blank, &frame(w, h, &band), w * 4, w, h);
        assert!(line.0 < CHANGE, "under the whole-window rule: {line:?}");
        assert!(visible(line), "{line:?}");
    }
}
