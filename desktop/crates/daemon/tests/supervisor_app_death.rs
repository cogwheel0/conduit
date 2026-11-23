//! A daemon too stuck to notice stdin closing still ends with the app,
//! however the app ends. The app here is this test binary started again in
//! an app role: it supervises a fake `conduitd` that ignores stdin EOF, and
//! the test kills it outright, as a crash or Task Manager would. The fake
//! must end with it, before it would have given up on its own and written
//! `outlived` (so a failure ends too, rather than hanging).
#![cfg(any(windows, target_os = "linux"))]

use std::io::{BufRead as _, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use conduit_daemon::supervisor::{Supervisor, SupervisorConfig, SupervisorEvent};

/// Set in the app role's environment: the test's folder.
const APP_ROLE: &str = "CONDUIT_TEST_APP_ROLE_DIR";
const TEST: &str = "a_stuck_daemon_ends_with_a_killed_app";

#[cfg(target_os = "linux")]
const FAKE_NAME: &str = "fake-conduitd";
#[cfg(target_os = "linux")]
const FAKE: &str = r#"#!/bin/sh
IFS= read -r line
echo '{"ready":true,"port":4242}'
i=0
while [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
echo outlived > "$FAKE_DIR/outlived"
"#;

#[cfg(windows)]
const FAKE_NAME: &str = "fake-conduitd.cmd";
#[cfg(windows)]
const FAKE: &str = "@echo off\r\n\
set /p line=\r\n\
echo {\"ready\":true,\"port\":4242}\r\n\
ping -n 11 127.0.0.1 >nul\r\n\
echo outlived>\"%FAKE_DIR%\\outlived\"\r\n";

#[test]
fn a_stuck_daemon_ends_with_a_killed_app() {
    if let Some(dir) = std::env::var_os(APP_ROLE) {
        run_app(Path::new(&dir));
    }
    let scratch = tempfile::Builder::new()
        .prefix("supervisor-app-death-")
        .tempdir_in(env!("CARGO_TARGET_TMPDIR"))
        .expect("a temporary folder");
    let dir = scratch.path();
    std::fs::write(dir.join(FAKE_NAME), FAKE).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(dir.join(FAKE_NAME), std::fs::Permissions::from_mode(0o755))
            .unwrap();
    }

    let mut app = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
        .env(APP_ROLE, dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .expect("start the app role");
    let mut said = vec![];
    let mut lines = BufReader::new(app.stdout.take().unwrap()).lines();
    let pid = loop {
        let line = lines
            .next()
            .unwrap_or_else(|| panic!("the app role ended first, having said {said:#?}"))
            .unwrap();
        if let Some(pid) = line.strip_prefix("daemon pid ") {
            break pid.parse::<u32>().unwrap();
        }
        said.push(line);
    };
    // Opened while the daemon runs, so its pid can't be another's.
    let daemon = Exit::watch(pid);
    app.kill().unwrap();
    app.wait().unwrap();
    daemon.wait();
    assert!(
        !dir.join("outlived").exists(),
        "conduitd ran on after the app was killed"
    );
}

/// The app's part: supervise the fake until killed.
fn run_app(dir: &Path) -> ! {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let mut config = SupervisorConfig::new(
            dir.join(FAKE_NAME),
            dir.join("userData"),
            dir.join("logs"),
            "t".repeat(43),
            "k".into(),
        );
        config.env = vec![("FAKE_DIR".into(), dir.to_string_lossy().into())];
        config.ready_timeout = Duration::from_secs(10);
        let (_supervisor, mut events) =
            Supervisor::spawn(config, &tokio::runtime::Handle::current());
        loop {
            match events.recv().await {
                Some(SupervisorEvent::Ready { pid, .. }) => {
                    println!("daemon pid {pid}");
                    break;
                }
                Some(SupervisorEvent::Fatal(reason)) => {
                    println!("the fake never got ready: {reason:?}");
                    std::process::exit(1);
                }
                Some(_) => {}
                None => std::process::exit(1),
            }
        }
        std::future::pending::<()>().await;
    });
    unreachable!()
}

/// Waits for a process that isn't this one's child to end.
#[cfg(target_os = "linux")]
struct Exit(std::os::fd::OwnedFd);

#[cfg(target_os = "linux")]
impl Exit {
    fn watch(pid: u32) -> Self {
        use std::os::fd::FromRawFd as _;
        // SAFETY: pidfd_open(2) takes a pid and flags and returns a new fd.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
        assert!(fd >= 0, "pidfd_open: {}", std::io::Error::last_os_error());
        // SAFETY: the fd was just opened and nothing else owns it.
        Self(unsafe { std::os::fd::OwnedFd::from_raw_fd(fd as libc::c_int) })
    }

    fn wait(self) {
        use std::os::fd::AsRawFd as _;
        let mut poll = libc::pollfd {
            fd: self.0.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // A pidfd reads as ready once its process has ended.
        loop {
            // SAFETY: one valid pollfd; no timeout.
            match unsafe { libc::poll(&mut poll, 1, -1) } {
                1 => return,
                _ => {
                    let e = std::io::Error::last_os_error();
                    assert_eq!(e.kind(), std::io::ErrorKind::Interrupted, "poll: {e}");
                }
            }
        }
    }
}

#[cfg(windows)]
struct Exit(windows::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl Exit {
    fn watch(pid: u32) -> Self {
        use windows::Win32::System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE};
        // SAFETY: opens a handle that only waits on the process.
        Self(unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, pid) }.expect("open conduitd"))
    }

    fn wait(self) {
        use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
        use windows::Win32::System::Threading::{INFINITE, WaitForSingleObject};
        // SAFETY: a handle opened above with SYNCHRONIZE, closed once.
        unsafe {
            assert_eq!(WaitForSingleObject(self.0, INFINITE), WAIT_OBJECT_0);
            let _ = CloseHandle(self.0);
        }
    }
}
