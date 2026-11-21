//! The supervisor's stop path on Windows, against a fake `conduitd` (a
//! batch file): stdin EOF stops a well-behaved daemon, and one that ignores
//! it is terminated with no SIGTERM step (Windows has none).
#![cfg(windows)]

use std::time::Duration;

use conduit_daemon::supervisor::{
    RestartPolicy, StopOutcome, Supervisor, SupervisorConfig, SupervisorEvent,
};
use tokio::sync::mpsc::UnboundedReceiver;

// `more` reads stdin to its end, so it returns when the supervisor closes
// stdin. The stubborn mode spins in cmd itself: a child process (ping,
// timeout) would outlive the terminated batch.
const FAKE: &str = "@echo off\r\n\
set /p line=\r\n\
echo {\"ready\":true,\"port\":4242}\r\n\
if \"%FAKE_MODE%\"==\"stubborn\" goto spin\r\n\
more >nul\r\n\
echo stdin closed 1>&2\r\n\
exit /b 0\r\n\
:spin\r\n\
goto spin\r\n";

/// A config for a fake in `mode`, in a new folder of the test's own (removed
/// when the returned guard drops): never one an earlier run left a log in.
fn setup(name: &str, mode: &str) -> (SupervisorConfig, tempfile::TempDir) {
    let scratch = tempfile::Builder::new()
        .prefix(&format!("supervisor-{name}-"))
        .tempdir_in(env!("CARGO_TARGET_TMPDIR"))
        .expect("a temporary folder");
    let dir = scratch.path();
    let script = dir.join("fake-conduitd.cmd");
    std::fs::write(&script, FAKE).unwrap();
    let mut config = SupervisorConfig::new(
        script,
        dir.join("userData"),
        dir.join("logs"),
        "t".repeat(43),
        "k".into(),
    );
    config.env = vec![("FAKE_MODE".into(), mode.into())];
    config.policy = RestartPolicy {
        max_restarts: 5,
        window: Duration::from_secs(60),
        base_delay: Duration::from_millis(10),
        max_delay: Duration::from_millis(80),
    };
    config.ready_timeout = Duration::from_secs(10);
    config.stop_grace = Duration::from_secs(5);
    (config, scratch)
}

/// Waits for the fake's ready line; a start that fails for good fails the
/// test with its reason instead of waiting on.
async fn until_ready(rx: &mut UnboundedReceiver<SupervisorEvent>) {
    loop {
        match rx.recv().await.expect("the supervisor is alive") {
            SupervisorEvent::Ready { port: 4242, .. } => return,
            SupervisorEvent::Fatal(reason) => panic!("the fake never got ready: {reason:?}"),
            _ => {}
        }
    }
}

#[tokio::test]
async fn closing_stdin_stops_a_well_behaved_daemon() {
    let (config, dir) = setup("graceful", "ready");
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until_ready(&mut rx).await;
    assert_eq!(sup.stop().await, StopOutcome::Graceful);
    let log = std::fs::read_to_string(dir.path().join("logs/conduitd.log")).unwrap();
    assert!(log.contains("stdin closed"), "{log}");
}

#[tokio::test]
async fn a_daemon_ignoring_stdin_is_terminated_without_a_sigterm_step() {
    let (mut config, dir) = setup("stubborn", "stubborn");
    config.stop_grace = Duration::from_millis(300);
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until_ready(&mut rx).await;
    assert_eq!(sup.stop().await, StopOutcome::Killed);
    let log = std::fs::read_to_string(dir.path().join("logs/conduitd.log")).unwrap();
    assert!(log.contains("terminating it"), "{log}");
    assert!(!log.contains("SIGTERM"), "{log}");
}
