//! `--terminal-fixture perf`: the console under a flood of output, with no
//! daemon, for the frame-time budget (p95 ≤ 16.7 ms).
//!
//! A thread feeds the console's emulator as the shell's socket does (the
//! same [`crate::views::terminal::emulator::Feeder`], parsing off the UI
//! thread), as fast as it parses: first `yes` (`y` lines), then dense
//! coloured lines (one SGR run per word, as `ls --color` or a test runner
//! writes). The window repaints every frame meanwhile. Each phase prints one
//! JSON line with the frame interval and the render-to-paint work, as
//! `--chat-fixture perf` does; then the app quits.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::window as cw;
use gpui_kit::prelude::*;
use gpui_kit::{App, Bounds, Context, Entity, Window, WindowBounds, div, px, size};
use serde_json::json;

use crate::chat_fixture::{Samples, summary};
use crate::views::terminal::console::{self, Console};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Warmup,
    Idle,
    Yes,
    Colours,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Warmup => "warmup",
            Self::Idle => "idle",
            Self::Yes => "yes",
            Self::Colours => "colours",
            Self::Done => "done",
        }
    }

    fn at(t: f64) -> Self {
        match t {
            t if t < 3. => Self::Warmup,
            t if t < 6. => Self::Idle,
            t if t < 16. => Self::Yes,
            t if t < 26. => Self::Colours,
            _ => Self::Done,
        }
    }

    fn code(self) -> u8 {
        self as u8
    }
}

/// One coloured line: eight words, each in its own colour and style.
fn colour_line(n: usize) -> String {
    let mut line = String::new();
    for w in 0..8 {
        let colour = 31 + (n + w) % 7;
        let bold = if (n + w).is_multiple_of(3) { "1;" } else { "" };
        line.push_str(&format!("\x1b[{bold}{colour}mword{n:05}-{w}\x1b[0m "));
    }
    line.push_str("\r\n");
    line
}

struct FixtureTerminal {
    console: Entity<Console>,
    started: Instant,
    last_frame: Option<Instant>,
    phase: Phase,
    shared_phase: Arc<AtomicU8>,
    samples: Vec<(Phase, Samples)>,
}

impl FixtureTerminal {
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

impl Render for FixtureTerminal {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let now = Instant::now();
        let phase = Phase::at((now - self.started).as_secs_f64());
        if phase != self.phase {
            self.phase = phase;
            self.shared_phase.store(phase.code(), Ordering::Release);
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
        // The console repaints what the feed parsed, every frame.
        self.console.update(cx, |_, cx| cx.notify());
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
            .relative()
            .flex()
            .flex_col()
            .bg(t.roles.content)
            .child(div().h(px(cw::TOOLBAR_HEIGHT)).flex_none())
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(console::view(&self.console, &t, window, cx)),
            )
            .child(probe)
    }
}

/// Feeds the console's emulator from a thread, by phase.
fn feed(console: &Entity<Console>, phase: Arc<AtomicU8>, cx: &App) {
    let mut feeder = console.read(cx).emulator().feeder();
    std::thread::spawn(move || {
        let yes = "y\r\n".repeat(2048);
        let mut n = 0usize;
        loop {
            match phase.load(Ordering::Acquire) {
                p if p == Phase::Done.code() => return,
                p if p == Phase::Yes.code() => {
                    feeder.feed(yes.as_bytes());
                }
                p if p == Phase::Colours.code() => {
                    let mut chunk = String::with_capacity(8192);
                    while chunk.len() < 8192 {
                        chunk.push_str(&colour_line(n));
                        n += 1;
                    }
                    feeder.feed(chunk.as_bytes());
                }
                _ => std::thread::sleep(Duration::from_millis(5)),
            }
            // Let the UI thread at the lock between chunks, as a socket's
            // reads do.
            std::thread::yield_now();
        }
    });
}

pub fn run(cx: &mut App) {
    let bounds = Bounds::centered(None, size(px(1100.), px(800.)), cx);
    let mut options = cw::window_options("Conduit terminal fixture", bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.inactive_frame_interval = None;
    options.low_power_frame_interval = None;
    options.thermal_frame_interval = None;
    let shared = Arc::new(AtomicU8::new(Phase::Warmup.code()));
    let opened = cw::open_window_clear_root(options, cx, {
        let shared = shared.clone();
        move |_, cx| {
            let console = cx.new(Console::new);
            cx.new(|_| FixtureTerminal {
                console,
                started: Instant::now(),
                last_frame: None,
                phase: Phase::Warmup,
                shared_phase: shared,
                samples: vec![(Phase::Warmup, Samples::default())],
            })
        }
    });
    match opened {
        Ok((_, view)) => {
            let console = view.read(cx).console.clone();
            feed(&console, shared, cx);
            cx.activate(true);
        }
        Err(e) => {
            println!("{}", json!({"error": e.to_string()}));
            cx.quit();
        }
    }
}

/// Whether `--terminal-fixture` was asked for.
pub fn requested(args: &[String]) -> bool {
    args.iter().any(|a| a == "--terminal-fixture")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phases_run_in_order_and_lines_are_coloured() {
        assert_eq!(Phase::at(1.), Phase::Warmup);
        assert_eq!(Phase::at(10.), Phase::Yes);
        assert_eq!(Phase::at(20.), Phase::Colours);
        assert_eq!(Phase::at(30.), Phase::Done);
        let line = colour_line(3);
        assert_eq!(line.matches("\x1b[0m").count(), 8);
        assert!(line.ends_with("\r\n"));
    }
}
