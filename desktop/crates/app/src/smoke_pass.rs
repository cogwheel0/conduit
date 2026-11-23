//! `--smoke <file>`: the app's smoke pass off the Mac (Windows, and Linux
//! under Xvfb), which CI's install smoke runs; the Mac's is `--shots`
//! ([`crate::smoke`]). It checks what `--shots` checks, without the
//! captures: the app starts its `conduitd` and connects (the handshake), the
//! daemon answers a diagnostics export, Settings opens, and the app quits
//! through its own Quit, after which the daemon must exit 0 on stdin EOF.
//!
//! `SMOKE` lines go to the file as they come, never to stdout (a Windows
//! release build has no console), and the exit code is the verdict: 0 with
//! `SMOKE passed` last, else 1 with a `SMOKE FAILED` line for each reason.
//! Like every scripted run it uses a profile of its own (`CONDUIT_USER_DATA`,
//! or a fresh one) and the harness's key service, so on Linux it needs a
//! Secret Service to connect.

use std::cell::RefCell;
use std::fmt::Display;
use std::io::Write as _;
use std::path::Path;
use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_daemon::supervisor::{ExitInfo, StopOutcome};
use conduit_protocol::{NoParams, methods::SystemExportDiagnostics};
use gpui_kit::{App, AsyncApp};

use crate::AppState;
use crate::stores::connection::Status;
use crate::stores::session::Route;
use crate::views::settings::Tab;

/// The pass's report and verdict.
pub struct SmokeReport {
    file: std::fs::File,
    failed: bool,
    ended: bool,
    stopped: Option<StopOutcome>,
}

impl SmokeReport {
    /// Starts the report at `path`, over whatever is there.
    pub fn create(path: &Path) -> std::io::Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        Ok(Self {
            file: std::fs::File::create(path)?,
            failed: false,
            ended: false,
            stopped: None,
        })
    }

    pub fn say(&mut self, what: impl Display) {
        // A line the disk refuses changes no verdict: the exit code has it.
        let _ = writeln!(self.file, "SMOKE {what}");
    }

    pub fn fail(&mut self, why: impl Display) {
        self.failed = true;
        self.say(format_args!("FAILED {why}"));
    }

    /// The pass got to its end and quits the app.
    pub fn quitting(&mut self) {
        self.ended = true;
        self.say("quitting");
    }

    /// How the app's quit stopped the daemon (`None`: none was running).
    pub fn daemon_stopped(&mut self, outcome: Option<StopOutcome>) {
        self.stopped = outcome;
    }

    /// The verdict, once the app has quit: the launch's exit code.
    pub fn finish(&mut self) -> i32 {
        if !self.ended {
            self.fail("the app quit before the pass ended");
        }
        match self.stopped {
            Some(StopOutcome::Graceful(ExitInfo::Code(0))) => {
                self.say("daemon stopped after stdin closed")
            }
            Some(StopOutcome::Graceful(exit)) => {
                self.fail(format_args!("daemon exited with {exit} after stdin closed"))
            }
            Some(outcome) => self.fail(format_args!(
                "the daemon did not stop gracefully: {outcome:?}"
            )),
            None => self.fail("the app's quit stopped no daemon"),
        }
        if self.failed {
            1
        } else {
            self.say("passed");
            0
        }
    }
}

/// Runs the pass, then quits through the app's Quit.
pub fn run(report: Rc<RefCell<SmokeReport>>, cx: &mut App) {
    let started = Instant::now();
    cx.spawn(async move |cx: &mut AsyncApp| {
        check(&report, started, cx).await;
        report.borrow_mut().quitting();
        cx.update(crate::views::sheet::quit);
    })
    .detach();
}

async fn check(report: &RefCell<SmokeReport>, started: Instant, cx: &mut AsyncApp) {
    if cx.update(crate::windows::front_window).is_none() {
        report.borrow_mut().fail("no window");
        return;
    }
    let status = wait_for(|s| *s == Status::Connected, Duration::from_secs(90), cx).await;
    report.borrow_mut().say(format_args!(
        "status {status:?} after {:?}",
        started.elapsed()
    ));
    if status != Status::Connected {
        report.borrow_mut().fail("never connected");
        return;
    }
    let lines = cx.update(|cx| {
        let route = current_route(cx);
        let c = cx.global::<AppState>().connection.read(cx);
        let mut lines = vec![];
        if let Some(h) = &c.handshake {
            lines.push(format!(
                "handshake daemon={} protocol={} platform={} needsOnboarding={:?}",
                h.daemon_version, h.protocol_version, h.platform, h.needs_onboarding
            ));
        }
        lines.push(format!("route {route:?} daemon {:?}", c.daemon));
        let menus: Vec<String> = cx
            .get_menus()
            .unwrap_or_default()
            .iter()
            .map(|m| m.name.to_string())
            .collect();
        lines.push(format!("menus {menus:?}"));
        lines
    });
    for line in lines {
        report.borrow_mut().say(line);
    }
    // The daemon's diagnostics export: a call past the handshake.
    let export = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .client
            .call::<SystemExportDiagnostics>(&NoParams)
    });
    match export.await {
        Ok(d) if Path::new(&d.path).is_file() => report.borrow_mut().say(format_args!(
            "diagnostics {} bytes, zip exists",
            d.size_bytes
        )),
        Ok(d) => report
            .borrow_mut()
            .fail(format_args!("diagnostics zip missing: {}", d.path)),
        Err(e) => report.borrow_mut().fail(format_args!("diagnostics: {e}")),
    }
    // Settings › About: the version and the Updates section.
    cx.update(|cx| crate::open_settings(Some(Tab::About), cx));
    let settings = cx.update(|cx| {
        let window = cx
            .global::<AppState>()
            .settings_window
            .as_ref()
            .map(|(handle, _)| *handle);
        window.is_some_and(|handle| handle.update(cx, |_, _, _| ()).is_ok())
    });
    if settings {
        let updater = cx.update(|cx| crate::updates::available(cx));
        report.borrow_mut().say(format_args!(
            "version {} build {} updater {updater}",
            crate::VERSION,
            crate::BUILD.unwrap_or("-"),
        ));
    } else {
        report.borrow_mut().fail("settings window did not open");
    }
}

/// Waits, up to `timeout`, for a status `want` accepts; answers the last.
pub(crate) async fn wait_for(
    want: impl Fn(&Status) -> bool,
    timeout: Duration,
    cx: &mut AsyncApp,
) -> Status {
    let deadline = Instant::now() + timeout;
    loop {
        let status = cx.update(current_status);
        if want(&status) || Instant::now() > deadline {
            return status;
        }
        cx.background_executor()
            .timer(Duration::from_millis(200))
            .await;
    }
}

/// The window's status, as the main window derives it.
pub fn current_status(cx: &mut App) -> Status {
    let state = cx.global::<AppState>();
    let session = state.stores.session.read(cx);
    let routed = session.route(cx) != Route::Unknown;
    let error = session.error.as_ref().map(|e| e.to_string());
    state.connection.read(cx).status(routed, error.as_deref())
}

pub fn current_route(cx: &mut App) -> Route {
    let session = cx.global::<AppState>().stores.session.clone();
    session.read(cx).route(cx)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report() -> (SmokeReport, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let report = SmokeReport::create(&dir.path().join("out/smoke.txt")).unwrap();
        (report, dir)
    }

    fn written(dir: &tempfile::TempDir) -> String {
        std::fs::read_to_string(dir.path().join("out/smoke.txt")).unwrap()
    }

    /// A pass passes only when it got to its end with nothing failed and the
    /// app's own quit stopped the daemon through stdin EOF; the file says so
    /// last, line by line as the CI scripts read it.
    #[test]
    fn a_pass_passes_only_with_a_clean_quit() {
        let (mut ok, dir) = report();
        ok.say("status Connected after 2s");
        ok.quitting();
        ok.daemon_stopped(Some(StopOutcome::Graceful(ExitInfo::Code(0))));
        assert_eq!(ok.finish(), 0);
        assert_eq!(
            written(&dir),
            "SMOKE status Connected after 2s\nSMOKE quitting\n\
             SMOKE daemon stopped after stdin closed\nSMOKE passed\n"
        );

        for (outcome, why) in [
            // A crash on the way out, inside the stdin grace.
            (
                Some(StopOutcome::Graceful(ExitInfo::Code(3))),
                "SMOKE FAILED daemon exited with exit code 3 after stdin closed\n",
            ),
            (
                Some(StopOutcome::Graceful(ExitInfo::Signal(11))),
                "SMOKE FAILED daemon exited with signal 11 after stdin closed\n",
            ),
            (
                Some(StopOutcome::Killed),
                "SMOKE FAILED the daemon did not stop gracefully: Killed\n",
            ),
            (
                Some(StopOutcome::NotRunning),
                "SMOKE FAILED the daemon did not stop gracefully: NotRunning\n",
            ),
            (None, "SMOKE FAILED the app's quit stopped no daemon\n"),
        ] {
            let (mut report, dir) = report();
            report.quitting();
            report.daemon_stopped(outcome);
            assert_eq!(report.finish(), 1, "{outcome:?}");
            assert!(written(&dir).ends_with(why), "{}", written(&dir));
        }
    }

    /// The app quitting before the pass ended (a window closed, a crash in a
    /// quit path) is a failure, however the daemon stopped; and a failed
    /// check fails the pass even after a clean quit.
    #[test]
    fn an_unfinished_or_failed_pass_fails() {
        let (mut early, dir) = report();
        early.daemon_stopped(Some(StopOutcome::Graceful(ExitInfo::Code(0))));
        assert_eq!(early.finish(), 1);
        assert!(
            written(&dir).contains("SMOKE FAILED the app quit before the pass ended\n"),
            "{}",
            written(&dir)
        );

        let (mut failed, dir) = report();
        failed.fail("never connected");
        failed.quitting();
        failed.daemon_stopped(Some(StopOutcome::Graceful(ExitInfo::Code(0))));
        assert_eq!(failed.finish(), 1);
        assert!(!written(&dir).contains("SMOKE passed"), "{}", written(&dir));
    }
}
