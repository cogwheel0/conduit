//! Runs `conduitd`: spawn with `--user-data`, write the one bootstrap line on
//! stdin, wait for `{"ready":true,"port":N}` on stdout, copy stderr into
//! rotating logs, watch the child, restart it within limits, and stop it
//! gracefully.
//!
//! * **Restarts:** at most [`RestartPolicy::max_restarts`] in
//!   [`RestartPolicy::window`], with exponential backoff, and **never** after
//!   exit 64 (EX_USAGE: started wrong) or 77 (EX_NOPERM: the secure store
//!   cannot be opened with this master key).
//! * **Stop:** close stdin (the daemon's stop signal), SIGTERM after
//!   [`SupervisorConfig::stop_grace`], SIGKILL after
//!   [`SupervisorConfig::term_grace`] more.
//! * **Watching:** a task owns the child and reports its exit at once, so a
//!   dead daemon shows up as an exit rather than as calls that hang.
//!
//! Closing stdin is also what happens when the app dies, so the daemon never
//! outlives it.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::process::{ChildStdin, Command};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};
use tokio::time::{sleep, timeout};

use crate::logs::RotatingLog;

/// When to restart a daemon that exited.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RestartPolicy {
    pub max_restarts: usize,
    pub window: Duration,
    pub base_delay: Duration,
    pub max_delay: Duration,
}

impl Default for RestartPolicy {
    fn default() -> Self {
        Self {
            max_restarts: 5,
            window: Duration::from_secs(60),
            base_delay: Duration::from_millis(500),
            max_delay: Duration::from_secs(8),
        }
    }
}

/// How the daemon ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitInfo {
    Code(i32),
    Signal(i32),
    Unknown,
}

impl ExitInfo {
    fn from_status(status: ExitStatus) -> Self {
        use std::os::unix::process::ExitStatusExt as _;
        match (status.code(), status.signal()) {
            (Some(code), _) => Self::Code(code),
            (None, Some(sig)) => Self::Signal(sig),
            _ => Self::Unknown,
        }
    }
}

impl std::fmt::Display for ExitInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Code(c) => write!(f, "exit code {c}"),
            Self::Signal(s) => write!(f, "signal {s}"),
            Self::Unknown => f.write_str("unknown exit"),
        }
    }
}

/// Why the supervisor stopped restarting.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FatalReason {
    /// Exit 64: bad arguments. A restart would fail the same way.
    Usage,
    /// Exit 77: the secure store does not open with this master key (for
    /// example data another build left behind). The app offers "Reset local
    /// data".
    SecureStoreUnreadable,
    /// [`RestartPolicy::max_restarts`] restarts within the window.
    TooManyRestarts { restarts: usize },
    /// The binary could not be started at all.
    SpawnFailed(String),
}

/// What the restart policy decided about one exit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Restart(Duration),
    Fatal(FatalReason),
}

impl RestartPolicy {
    /// Decides about `exit` at `now`; `recent` holds the restart times this
    /// policy granted, and is updated.
    pub fn decide(&self, recent: &mut VecDeque<Instant>, now: Instant, exit: ExitInfo) -> Decision {
        match exit {
            ExitInfo::Code(64) => return Decision::Fatal(FatalReason::Usage),
            ExitInfo::Code(77) => return Decision::Fatal(FatalReason::SecureStoreUnreadable),
            _ => {}
        }
        while recent
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) > self.window)
        {
            recent.pop_front();
        }
        if recent.len() >= self.max_restarts {
            return Decision::Fatal(FatalReason::TooManyRestarts {
                restarts: recent.len(),
            });
        }
        let factor = 1u32 << recent.len().min(16);
        let delay = self.base_delay.saturating_mul(factor).min(self.max_delay);
        recent.push_back(now);
        Decision::Restart(delay)
    }
}

/// How a stop ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopOutcome {
    /// Exited after stdin closed.
    Graceful,
    /// Needed SIGTERM.
    Terminated,
    /// Needed SIGKILL.
    Killed,
    /// Nothing was running.
    NotRunning,
}

/// What the supervisor reports, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum SupervisorEvent {
    Starting {
        attempt: u32,
    },
    Ready {
        port: u16,
        pid: u32,
    },
    Exited {
        exit: ExitInfo,
        before_ready: bool,
    },
    Restarting {
        delay: Duration,
        restarts_in_window: usize,
    },
    Fatal(FatalReason),
    Stopped(StopOutcome),
}

pub struct SupervisorConfig {
    pub binary: PathBuf,
    pub user_data: PathBuf,
    /// Where `conduitd.log` (the daemon's stderr) rotates.
    pub log_dir: PathBuf,
    pub session_token: String,
    /// Base64 of 32 bytes.
    pub master_key: String,
    /// Extra environment for the child (tests).
    pub env: Vec<(String, String)>,
    pub ready_timeout: Duration,
    pub stop_grace: Duration,
    pub term_grace: Duration,
    pub policy: RestartPolicy,
}

impl SupervisorConfig {
    pub fn new(
        binary: PathBuf,
        user_data: PathBuf,
        log_dir: PathBuf,
        session_token: String,
        master_key: String,
    ) -> Self {
        Self {
            binary,
            user_data,
            log_dir,
            session_token,
            master_key,
            env: vec![],
            ready_timeout: Duration::from_secs(30),
            stop_grace: Duration::from_secs(5),
            term_grace: Duration::from_secs(2),
            policy: RestartPolicy::default(),
        }
    }

    fn bootstrap_line(&self) -> String {
        let mut line = serde_json::json!({
            "sessionToken": self.session_token,
            "masterKey": self.master_key,
            "userDataDir": self.user_data.to_string_lossy(),
        })
        .to_string();
        line.push('\n');
        line
    }
}

enum Cmd {
    Stop(oneshot::Sender<StopOutcome>),
    Restart,
}

/// A handle to the supervisor task. Dropping every handle stops the daemon.
#[derive(Clone)]
pub struct Supervisor {
    cmds: mpsc::UnboundedSender<Cmd>,
}

type SharedLog = Arc<Mutex<Option<RotatingLog>>>;

fn log_line(log: &SharedLog, line: &str) {
    if let Ok(mut guard) = log.lock()
        && let Some(log) = guard.as_mut()
    {
        let _ = log.write_line(line.as_bytes());
        let _ = log.flush();
    }
}

impl Supervisor {
    /// Starts supervising on `rt`. Events arrive on the returned receiver.
    pub fn spawn(
        config: SupervisorConfig,
        rt: &Handle,
    ) -> (Self, mpsc::UnboundedReceiver<SupervisorEvent>) {
        let (cmds, cmd_rx) = mpsc::unbounded_channel();
        let (events, event_rx) = mpsc::unbounded_channel();
        rt.spawn(run(config, cmd_rx, events));
        (Self { cmds }, event_rx)
    }

    /// Tries again after a [`SupervisorEvent::Fatal`], with a fresh restart
    /// budget. Ignored while a daemon runs.
    pub fn restart(&self) {
        let _ = self.cmds.send(Cmd::Restart);
    }

    /// Stops the daemon (stdin EOF → SIGTERM → SIGKILL) and stops
    /// supervising.
    pub async fn stop(&self) -> StopOutcome {
        let (tx, rx) = oneshot::channel();
        if self.cmds.send(Cmd::Stop(tx)).is_err() {
            return StopOutcome::NotRunning;
        }
        rx.await.unwrap_or(StopOutcome::NotRunning)
    }

    /// [`Self::stop`] for a thread that is not running tokio (app quit).
    pub fn stop_blocking(&self) -> StopOutcome {
        let (tx, rx) = oneshot::channel();
        if self.cmds.send(Cmd::Stop(tx)).is_err() {
            return StopOutcome::NotRunning;
        }
        rx.blocking_recv().unwrap_or(StopOutcome::NotRunning)
    }
}

struct Running {
    pid: u32,
    stdin: Option<ChildStdin>,
    ready: oneshot::Receiver<u16>,
    exit: oneshot::Receiver<ExitInfo>,
}

async fn launch(config: &SupervisorConfig, log: &SharedLog) -> std::io::Result<Running> {
    std::fs::create_dir_all(&config.user_data)?;
    let mut cmd = Command::new(&config.binary);
    cmd.arg("--user-data")
        .arg(&config.user_data)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in &config.env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn()?;
    let pid = child.id().unwrap_or_default();
    log_line(log, &format!("[supervisor] started conduitd pid {pid}"));

    let mut stdin = child.stdin.take();
    if let Some(stdin) = stdin.as_mut() {
        // A failed write means the child already died; its exit says why.
        let line = config.bootstrap_line();
        if stdin.write_all(line.as_bytes()).await.is_ok() {
            let _ = stdin.flush().await;
        }
    }

    let (ready_tx, ready) = oneshot::channel();
    if let Some(stdout) = child.stdout.take() {
        let log = log.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            let mut ready_tx = Some(ready_tx);
            while let Ok(Some(line)) = lines.next_line().await {
                match (ready_tx.is_some(), parse_ready(&line)) {
                    (true, Some(port)) => {
                        if let Some(tx) = ready_tx.take() {
                            let _ = tx.send(port);
                        }
                    }
                    // Nothing else may reach stdout; keep what does.
                    _ => log_line(&log, &format!("[stdout] {line}")),
                }
            }
        });
    }
    if let Some(stderr) = child.stderr.take() {
        let log = log.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                log_line(&log, &line);
            }
        });
    }
    let (exit_tx, exit) = oneshot::channel();
    tokio::spawn(async move {
        let info = match child.wait().await {
            Ok(status) => ExitInfo::from_status(status),
            Err(_) => ExitInfo::Unknown,
        };
        let _ = exit_tx.send(info);
    });
    Ok(Running {
        pid,
        stdin,
        ready,
        exit,
    })
}

/// The port from `{"ready":true,"port":N}`.
pub fn parse_ready(line: &str) -> Option<u16> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    if v.get("ready")?.as_bool()? {
        let port = v.get("port")?.as_u64()?;
        u16::try_from(port).ok().filter(|p| *p != 0)
    } else {
        None
    }
}

fn signal(pid: u32, sig: i32) {
    if pid == 0 {
        return;
    }
    // SAFETY: plain kill(2). The child is not reaped until its watcher
    // reports the exit, so the pid cannot have been reused while we wait.
    unsafe {
        libc::kill(pid as libc::pid_t, sig);
    }
}

async fn stop_running(
    running: &mut Running,
    config: &SupervisorConfig,
    log: &SharedLog,
) -> StopOutcome {
    drop(running.stdin.take());
    if timeout(config.stop_grace, &mut running.exit).await.is_ok() {
        log_line(log, "[supervisor] conduitd stopped after stdin closed");
        return StopOutcome::Graceful;
    }
    log_line(
        log,
        "[supervisor] conduitd ignored stdin EOF; sending SIGTERM",
    );
    signal(running.pid, libc::SIGTERM);
    if timeout(config.term_grace, &mut running.exit).await.is_ok() {
        return StopOutcome::Terminated;
    }
    log_line(
        log,
        "[supervisor] conduitd ignored SIGTERM; sending SIGKILL",
    );
    signal(running.pid, libc::SIGKILL);
    let _ = timeout(Duration::from_secs(2), &mut running.exit).await;
    StopOutcome::Killed
}

/// Waits for an exit already under way (or forces it).
async fn reap(running: &mut Running) -> ExitInfo {
    match timeout(Duration::from_secs(2), &mut running.exit).await {
        Ok(Ok(info)) => info,
        _ => {
            signal(running.pid, libc::SIGKILL);
            timeout(Duration::from_secs(2), &mut running.exit)
                .await
                .ok()
                .and_then(Result::ok)
                .unwrap_or(ExitInfo::Unknown)
        }
    }
}

enum AfterFatal {
    Restart,
    Stop,
}

async fn wait_after_fatal(cmds: &mut mpsc::UnboundedReceiver<Cmd>) -> AfterFatal {
    match cmds.recv().await {
        Some(Cmd::Restart) => AfterFatal::Restart,
        Some(Cmd::Stop(tx)) => {
            let _ = tx.send(StopOutcome::NotRunning);
            AfterFatal::Stop
        }
        None => AfterFatal::Stop,
    }
}

async fn run(
    config: SupervisorConfig,
    mut cmds: mpsc::UnboundedReceiver<Cmd>,
    events: mpsc::UnboundedSender<SupervisorEvent>,
) {
    let log: SharedLog = Arc::new(Mutex::new(
        RotatingLog::standard(&config.log_dir, "conduitd").ok(),
    ));
    let emit = |e: SupervisorEvent| {
        let _ = events.send(e);
    };
    let mut recent: VecDeque<Instant> = VecDeque::new();
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        emit(SupervisorEvent::Starting { attempt });
        let mut running = match launch(&config, &log).await {
            Ok(r) => r,
            Err(e) => {
                log_line(&log, &format!("[supervisor] cannot start conduitd: {e}"));
                emit(SupervisorEvent::Fatal(FatalReason::SpawnFailed(format!(
                    "{}: {e}",
                    config.binary.display()
                ))));
                match wait_after_fatal(&mut cmds).await {
                    AfterFatal::Restart => {
                        recent.clear();
                        continue;
                    }
                    AfterFatal::Stop => {
                        emit(SupervisorEvent::Stopped(StopOutcome::NotRunning));
                        return;
                    }
                }
            }
        };

        // Until the ready line.
        let mut before_ready = true;
        let exit = loop {
            tokio::select! {
                port = &mut running.ready, if before_ready => match port {
                    Ok(port) => {
                        before_ready = false;
                        emit(SupervisorEvent::Ready { port, pid: running.pid });
                    }
                    // stdout closed without a ready line: it is exiting.
                    Err(_) => break reap(&mut running).await,
                },
                info = &mut running.exit => break info.unwrap_or(ExitInfo::Unknown),
                _ = sleep(config.ready_timeout), if before_ready => {
                    log_line(&log, "[supervisor] no ready line in time; killing conduitd");
                    signal(running.pid, libc::SIGKILL);
                    break reap(&mut running).await;
                }
                cmd = cmds.recv() => match cmd {
                    Some(Cmd::Restart) => {}
                    Some(Cmd::Stop(tx)) => {
                        let outcome = stop_running(&mut running, &config, &log).await;
                        let _ = tx.send(outcome);
                        emit(SupervisorEvent::Stopped(outcome));
                        return;
                    }
                    None => {
                        let outcome = stop_running(&mut running, &config, &log).await;
                        emit(SupervisorEvent::Stopped(outcome));
                        return;
                    }
                },
            }
        };
        log_line(&log, &format!("[supervisor] conduitd ended: {exit}"));
        emit(SupervisorEvent::Exited { exit, before_ready });

        match config.policy.decide(&mut recent, Instant::now(), exit) {
            Decision::Restart(delay) => {
                emit(SupervisorEvent::Restarting {
                    delay,
                    restarts_in_window: recent.len(),
                });
                tokio::select! {
                    _ = sleep(delay) => {}
                    cmd = cmds.recv() => match cmd {
                        Some(Cmd::Restart) => {}
                        Some(Cmd::Stop(tx)) => {
                            let _ = tx.send(StopOutcome::NotRunning);
                            emit(SupervisorEvent::Stopped(StopOutcome::NotRunning));
                            return;
                        }
                        None => return,
                    }
                }
            }
            Decision::Fatal(reason) => {
                emit(SupervisorEvent::Fatal(reason));
                match wait_after_fatal(&mut cmds).await {
                    AfterFatal::Restart => recent.clear(),
                    AfterFatal::Stop => {
                        emit(SupervisorEvent::Stopped(StopOutcome::NotRunning));
                        return;
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> RestartPolicy {
        RestartPolicy {
            max_restarts: 5,
            window: Duration::from_secs(60),
            base_delay: Duration::from_millis(500),
            max_delay: Duration::from_secs(8),
        }
    }

    #[test]
    fn never_restarts_after_64_or_77() {
        let mut recent = VecDeque::new();
        let now = Instant::now();
        assert_eq!(
            policy().decide(&mut recent, now, ExitInfo::Code(64)),
            Decision::Fatal(FatalReason::Usage)
        );
        assert_eq!(
            policy().decide(&mut recent, now, ExitInfo::Code(77)),
            Decision::Fatal(FatalReason::SecureStoreUnreadable)
        );
        assert!(recent.is_empty());
    }

    #[test]
    fn five_restarts_a_minute_with_backoff() {
        let p = policy();
        let mut recent = VecDeque::new();
        let t0 = Instant::now();
        let delays: Vec<Decision> = (0..6)
            .map(|i| p.decide(&mut recent, t0 + Duration::from_secs(i), ExitInfo::Code(1)))
            .collect();
        assert_eq!(
            delays,
            vec![
                Decision::Restart(Duration::from_millis(500)),
                Decision::Restart(Duration::from_secs(1)),
                Decision::Restart(Duration::from_secs(2)),
                Decision::Restart(Duration::from_secs(4)),
                Decision::Restart(Duration::from_secs(8)),
                Decision::Fatal(FatalReason::TooManyRestarts { restarts: 5 }),
            ]
        );
        // A minute after the first restart, budget comes back.
        assert_eq!(
            p.decide(
                &mut recent,
                t0 + Duration::from_secs(61),
                ExitInfo::Signal(9)
            ),
            Decision::Restart(Duration::from_secs(8))
        );
        assert_eq!(
            p.decide(
                &mut recent,
                t0 + Duration::from_secs(200),
                ExitInfo::Code(70)
            ),
            Decision::Restart(Duration::from_millis(500))
        );
    }

    #[test]
    fn ready_line_parsing() {
        assert_eq!(parse_ready(r#"{"ready":true,"port":51234}"#), Some(51234));
        assert_eq!(parse_ready(" {\"ready\":true,\"port\":1}\n"), Some(1));
        assert_eq!(parse_ready(r#"{"ready":false,"port":5}"#), None);
        assert_eq!(parse_ready(r#"{"ready":true,"port":0}"#), None);
        assert_eq!(parse_ready(r#"{"ready":true,"port":70000}"#), None);
        assert_eq!(parse_ready("starting"), None);
    }
}
