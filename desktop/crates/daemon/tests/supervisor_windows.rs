//! The supervisor's stop path on Windows, against a fake `conduitd` (a
//! batch file): stdin EOF stops a well-behaved daemon, and one that ignores
//! it is terminated with no SIGTERM step (Windows has none).
#![cfg(windows)]

use std::path::PathBuf;
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

fn setup(name: &str, mode: &str) -> (SupervisorConfig, PathBuf) {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("supervisor-windows")
        .join(format!("{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
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
    (config, dir)
}

async fn until_ready(rx: &mut UnboundedReceiver<SupervisorEvent>) {
    loop {
        let event = rx.recv().await.expect("the supervisor is alive");
        if matches!(event, SupervisorEvent::Ready { port: 4242, .. }) {
            return;
        }
    }
}

#[tokio::test]
async fn closing_stdin_stops_a_well_behaved_daemon() {
    let (config, dir) = setup("graceful", "ready");
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until_ready(&mut rx).await;
    assert_eq!(sup.stop().await, StopOutcome::Graceful);
    let log = std::fs::read_to_string(dir.join("logs/conduitd.log")).unwrap();
    assert!(log.contains("stdin closed"), "{log}");
}

#[tokio::test]
async fn a_daemon_ignoring_stdin_is_terminated_without_a_sigterm_step() {
    let (mut config, dir) = setup("stubborn", "stubborn");
    config.stop_grace = Duration::from_millis(300);
    let (sup, mut rx) = Supervisor::spawn(config, &tokio::runtime::Handle::current());
    until_ready(&mut rx).await;
    assert_eq!(sup.stop().await, StopOutcome::Killed);
    let log = std::fs::read_to_string(dir.join("logs/conduitd.log")).unwrap();
    assert!(log.contains("terminating it"), "{log}");
    assert!(!log.contains("SIGTERM"), "{log}");
}
