//! The supervisor against a fake `conduitd` (a shell script): bootstrap
//! line, ready line, stderr capture, exit-code handling, restart policy and
//! the stop ladder. Windows has its own (tests/supervisor_windows.rs).
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::time::Duration;

use conduit_daemon::supervisor::{
    ExitInfo, FatalReason, RestartPolicy, StopOutcome, Supervisor, SupervisorConfig,
    SupervisorEvent,
};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::timeout;

const FAKE: &str = r#"#!/bin/sh
# A stand-in for conduitd. Reads the bootstrap line, then acts on $FAKE_MODE.
IFS= read -r line
printf '%s\n' "$line" > "$FAKE_DIR/bootstrap.json"
printf '%s\n' "$*" > "$FAKE_DIR/args.txt"
echo "started" >> "$FAKE_DIR/starts.txt"
case "$FAKE_MODE" in
  exit77) echo "secure store unreadable" >&2; exit 77 ;;
  exit64) echo "bad usage" >&2; exit 64 ;;
  crash)  echo '{"ready":true,"port":4242}'; sleep 0.1; exit 3 ;;
  ready)
    echo '{"ready":true,"port":4242}'
    echo "hello from stderr" >&2
    # Stops when stdin closes, like conduitd.
    while IFS= read -r rest; do :; done
    # A burst on the way out: the last line must still reach the log
    # before the exit is reported.
    i=0; while [ $i -lt 2000 ]; do echo "closing $i" >&2; i=$((i+1)); done
    echo "stdin closed" >&2
    exit 0 ;;
  lingering)
    echo '{"ready":true,"port":4242}'
    while IFS= read -r rest; do :; done
    # Exits at once on stdin EOF, but a grandchild keeps stderr open.
    sleep 1 &
    exit 0 ;;
  term)
    trap 'echo "got TERM" >&2; exit 0' TERM
    echo '{"ready":true,"port":4242}'
    while :; do sleep 0.05; done ;;
  stubborn)
    trap '' TERM
    echo '{"ready":true,"port":4242}'
    while :; do sleep 0.05; done ;;
  silent) exec sleep 30 ;;
esac
"#;

fn setup(name: &str, mode: &str) -> (SupervisorConfig, PathBuf) {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("supervisor")
        .join(format!("{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("fake-conduitd");
    std::fs::write(&script, FAKE).unwrap();
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    // A fresh starts file per run.
    std::fs::write(dir.join("starts.txt"), "").unwrap();
    let mut config = SupervisorConfig::new(
        script,
        dir.join("userData"),
        dir.join("logs"),
        "t".repeat(43),
        "k".into(),
    );
    config.env = vec![
        ("FAKE_MODE".into(), mode.into()),
        ("FAKE_DIR".into(), dir.to_string_lossy().into()),
    ];
    config.policy = RestartPolicy {
        max_restarts: 5,
        window: Duration::from_secs(60),
        base_delay: Duration::from_millis(10),
        max_delay: Duration::from_millis(80),
    };
    // Generous: every test waits on the supervisor's events, never on these
    // running out, except where one running out is what it tests (it sets
    // its own). A shell started on a busy machine can take most of a
    // second to read its first line; a ready timeout that short killed it
    // before it said it started, and the crash test counted 5 starts of 6.
    config.ready_timeout = Duration::from_secs(10);
    config.stop_grace = Duration::from_secs(5);
    config.term_grace = Duration::from_secs(5);
    (config, dir)
}

async fn next(rx: &mut UnboundedReceiver<SupervisorEvent>) -> SupervisorEvent {
    timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("an event in time")
        .expect("the supervisor is alive")
}

async fn until(
    rx: &mut UnboundedReceiver<SupervisorEvent>,
    pred: impl Fn(&SupervisorEvent) -> bool,
) -> Vec<SupervisorEvent> {
    let mut seen = vec![];
    loop {
        let e = next(rx).await;
        let done = pred(&e);
        seen.push(e);
        if done {
            return seen;
        }
    }
}

fn starts(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("starts.txt"))
        .unwrap_or_default()
        .lines()
        .count()
}

#[tokio::test]
async fn writes_bootstrap_reports_ready_and_logs_stderr() {
    let (config, dir) = setup("ready", "ready");
    let user_data = config.user_data.clone();
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let seen = until(&mut rx, |e| matches!(e, SupervisorEvent::Ready { .. })).await;
    assert_eq!(seen[0], SupervisorEvent::Starting { attempt: 1 });
    let SupervisorEvent::Ready { port, pid } = seen.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*port, 4242);
    assert!(*pid > 0);

    let bootstrap: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("bootstrap.json")).unwrap())
            .unwrap();
    assert_eq!(bootstrap["sessionToken"], "t".repeat(43));
    assert_eq!(bootstrap["masterKey"], "k");
    assert_eq!(
        bootstrap["userDataDir"],
        user_data.to_string_lossy().as_ref()
    );
    let args = std::fs::read_to_string(dir.join("args.txt")).unwrap();
    assert_eq!(args.trim(), format!("--user-data {}", user_data.display()));

    // Closing stdin is enough for a well-behaved daemon.
    assert_eq!(sup.stop().await, StopOutcome::Graceful);
    assert_eq!(
        next(&mut rx).await,
        SupervisorEvent::Stopped(StopOutcome::Graceful)
    );
    let log = std::fs::read_to_string(dir.join("logs/conduitd.log")).unwrap();
    assert!(log.contains("hello from stderr"), "{log}");
    assert!(log.contains("stdin closed"), "{log}");
}

#[tokio::test]
async fn exit_77_is_fatal_and_never_restarted() {
    let (config, dir) = setup("exit77", "exit77");
    let (_sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let seen = until(&mut rx, |e| matches!(e, SupervisorEvent::Fatal(_))).await;
    assert!(seen.contains(&SupervisorEvent::Exited {
        exit: ExitInfo::Code(77),
        before_ready: true
    }));
    assert_eq!(
        seen.last(),
        Some(&SupervisorEvent::Fatal(FatalReason::SecureStoreUnreadable))
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(starts(&dir), 1, "no restart after 77");
    assert!(rx.try_recv().is_err());
    let log = std::fs::read_to_string(dir.join("logs/conduitd.log")).unwrap();
    assert!(log.contains("secure store unreadable"));
}

#[tokio::test]
async fn exit_64_is_fatal_and_never_restarted() {
    let (config, dir) = setup("exit64", "exit64");
    let (_sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let seen = until(&mut rx, |e| matches!(e, SupervisorEvent::Fatal(_))).await;
    assert_eq!(
        seen.last(),
        Some(&SupervisorEvent::Fatal(FatalReason::Usage))
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(starts(&dir), 1);
}

#[tokio::test]
async fn crashes_restart_five_times_then_give_up_and_retry_resets() {
    let (config, dir) = setup("crash", "crash");
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let seen = until(&mut rx, |e| matches!(e, SupervisorEvent::Fatal(_))).await;
    let delays: Vec<Duration> = seen
        .iter()
        .filter_map(|e| match e {
            SupervisorEvent::Restarting { delay, .. } => Some(*delay),
            _ => None,
        })
        .collect();
    assert_eq!(
        delays,
        [10, 20, 40, 80, 80].map(Duration::from_millis).to_vec(),
        "exponential backoff, capped"
    );
    assert_eq!(
        seen.last(),
        Some(&SupervisorEvent::Fatal(FatalReason::TooManyRestarts {
            restarts: 5
        }))
    );
    assert_eq!(starts(&dir), 6, "the first start and five restarts");
    let exits = seen
        .iter()
        .filter(|e| {
            matches!(
                e,
                // A late wake-up can see the exit before the ready line.
                SupervisorEvent::Exited {
                    exit: ExitInfo::Code(3),
                    ..
                }
            )
        })
        .count();
    assert_eq!(exits, 6);

    // A manual retry gets a fresh budget.
    sup.restart();
    let again = until(&mut rx, |e| matches!(e, SupervisorEvent::Fatal(_))).await;
    assert!(matches!(again[0], SupervisorEvent::Starting { .. }));
    assert_eq!(starts(&dir), 12);
}

#[tokio::test]
async fn stop_escalates_to_sigterm() {
    // It ignores stdin closing: SIGTERM after the grace, which it answers.
    let (mut config, _dir) = setup("term", "term");
    config.stop_grace = Duration::from_millis(300);
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until(&mut rx, |e| matches!(e, SupervisorEvent::Ready { .. })).await;
    assert_eq!(sup.stop().await, StopOutcome::Terminated);
}

#[tokio::test]
async fn stop_escalates_to_sigkill() {
    // It ignores stdin closing and SIGTERM: SIGKILL after both graces.
    let (mut config, _dir) = setup("stubborn", "stubborn");
    config.stop_grace = Duration::from_millis(300);
    config.term_grace = Duration::from_millis(300);
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let ready = until(&mut rx, |e| matches!(e, SupervisorEvent::Ready { .. })).await;
    let SupervisorEvent::Ready { pid, .. } = ready.last().unwrap() else {
        unreachable!()
    };
    let pid = *pid;
    assert_eq!(sup.stop().await, StopOutcome::Killed);
    // SAFETY: kill(pid, 0) only probes.
    let alive = unsafe { libc_kill(pid as i32, 0) } == 0;
    assert!(!alive, "the stubborn daemon is gone");
}

#[tokio::test]
async fn no_ready_line_in_time_counts_as_a_failed_start() {
    // The fake never says it is ready. Its timeout is what this tests, so
    // it is set here: 3 s, far past what a busy machine takes to start a
    // shell (800 ms was not, and killed it before it said it started).
    // Stopping it after is quick: it ignores stdin, and TERM ends it.
    let (mut config, dir) = setup("silent", "silent");
    config.ready_timeout = Duration::from_secs(3);
    config.stop_grace = Duration::from_millis(300);
    // The restart waits until stop(), so the count can't move before it is read.
    config.policy.base_delay = Duration::from_secs(3600);
    config.policy.max_delay = Duration::from_secs(3600);
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let seen = until(&mut rx, |e| matches!(e, SupervisorEvent::Restarting { .. })).await;
    assert!(seen.iter().any(|e| matches!(
        e,
        SupervisorEvent::Exited {
            before_ready: true,
            ..
        }
    )));
    assert_eq!(starts(&dir), 1);
    sup.stop().await;
}

#[tokio::test]
async fn a_missing_binary_is_fatal() {
    let (mut config, _dir) = setup("missing", "ready");
    config.binary = PathBuf::from("/nonexistent/conduitd");
    let (_sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    let seen = until(&mut rx, |e| matches!(e, SupervisorEvent::Fatal(_))).await;
    assert!(matches!(
        seen.last(),
        Some(SupervisorEvent::Fatal(FatalReason::SpawnFailed(_)))
    ));
}

unsafe extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

#[tokio::test]
async fn an_exit_with_stderr_still_open_is_graceful_and_signals_nothing() {
    // The daemon exits as soon as stdin closes, well inside the 300 ms
    // grace, while a grandchild holds stderr open for a second. Its pid is
    // reaped then: nothing may be signalled after that.
    let (config, dir) = setup("lingering", "lingering");
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until(&mut rx, |e| matches!(e, SupervisorEvent::Ready { .. })).await;
    assert_eq!(sup.stop().await, StopOutcome::Graceful);
    let log = std::fs::read_to_string(dir.join("logs/conduitd.log")).unwrap();
    assert!(!log.contains("SIGTERM"), "{log}");
    assert!(!log.contains("SIGKILL"), "{log}");
}

#[tokio::test]
async fn a_stop_after_the_daemon_exited_signals_nothing_and_a_new_one_starts() {
    // The capture's reconnect: it asks for a stop after the daemon already
    // died (here it waits to restart), then starts a fresh supervisor.
    let (mut config, dir) = setup("exited", "crash");
    config.policy.base_delay = Duration::from_secs(30);
    config.policy.max_delay = Duration::from_secs(30);
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until(&mut rx, |e| matches!(e, SupervisorEvent::Restarting { .. })).await;
    assert_eq!(sup.stop().await, StopOutcome::NotRunning);
    let log = std::fs::read_to_string(dir.join("logs/conduitd.log")).unwrap();
    assert!(!log.contains("SIGTERM"), "{log}");
    assert!(!log.contains("SIGKILL"), "{log}");
    let (config, _) = setup("exited-fresh", "ready");
    let (fresh, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until(&mut rx, |e| matches!(e, SupervisorEvent::Ready { .. })).await;
    assert_eq!(fresh.stop().await, StopOutcome::Graceful);
}
