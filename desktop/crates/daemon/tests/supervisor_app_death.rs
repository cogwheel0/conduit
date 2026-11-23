//! A daemon too stuck to notice stdin closing still ends with the app,
//! however the app ends (Windows: the job; Linux: the parent-death signal).
//!
//! One binary, three roles, so no wait here needs a clock:
//!
//! * **The test** listens on loopback, starts the app role and, once that
//!   says its daemon is ready, kills it outright, as a crash or Task Manager
//!   would. Then it asks the daemon, over the connection the daemon made,
//!   whether it is still there.
//! * **The app** supervises this binary as its `conduitd`, then waits to be
//!   killed.
//! * **The daemon** connects to the test, answers the bootstrap line with
//!   the ready line, and then ignores stdin, as a stuck daemon would. It
//!   answers the test's question only if it is still running.
//!
//! A daemon that ended with the app can't answer: the test reads the end of
//! the connection. One that ran on answers `outlived`, and the test fails.
//!
//! No libtest harness (`harness = false`): the supervisor starts the daemon
//! with `--user-data`, which libtest would refuse, and libtest's own output
//! on stdout would run into the roles' lines.

fn main() {
    // The Mac relies on stdin EOF alone.
    #[cfg(any(windows, target_os = "linux"))]
    roles::main();
}

#[cfg(any(windows, target_os = "linux"))]
mod roles {
    use std::io::{BufRead as _, BufReader, Read as _, Write as _};
    use std::net::{Shutdown, TcpListener, TcpStream};
    use std::process::{Command, Stdio};

    use conduit_daemon::supervisor::{Supervisor, SupervisorConfig, SupervisorEvent};

    const ROLE: &str = "CONDUIT_TEST_ROLE";
    const PORT: &str = "CONDUIT_TEST_PORT";
    const DIR: &str = "CONDUIT_TEST_DIR";

    pub fn main() {
        match std::env::var(ROLE).as_deref() {
            Ok("app") => run_app(),
            Ok("daemon") => run_daemon(),
            _ => a_stuck_daemon_ends_with_a_killed_app(),
        }
    }

    fn a_stuck_daemon_ends_with_a_killed_app() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let scratch = tempfile::Builder::new()
            .prefix("supervisor-app-death-")
            .tempdir_in(env!("CARGO_TARGET_TMPDIR"))
            .expect("a temporary folder");
        let mut app = Command::new(std::env::current_exe().unwrap())
            .env(ROLE, "app")
            .env(PORT, port.to_string())
            .env(DIR, scratch.path())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .spawn()
            .expect("start the app role");
        // Its one line, or its end if the daemon never got ready.
        let said = BufReader::new(app.stdout.take().unwrap()).lines().next();
        let pid = match &said {
            Some(Ok(line)) => line.strip_prefix("daemon ready, pid "),
            _ => None,
        }
        .unwrap_or_else(|| panic!("the app role said {said:?}"))
        .to_string();
        let mut daemon = connection_of(&listener, &pid);

        app.kill().unwrap();
        app.wait().unwrap();
        // A write or read error means the connection is gone with the daemon.
        let _ = daemon.write_all(b"?");
        let mut answer = String::new();
        let _ = daemon.read_to_string(&mut answer);
        assert_eq!(answer, "", "conduitd ran on after the app was killed");
        println!("a_stuck_daemon_ends_with_a_killed_app ... ok");
    }

    /// The connection the daemon with `pid` made. Each daemon connects and
    /// says its pid before its ready line, so the ready one's connection is
    /// already queued (with any from a start that failed before it).
    fn connection_of(listener: &TcpListener, pid: &str) -> TcpStream {
        loop {
            let (connection, _) = listener.accept().unwrap();
            let mut said = String::new();
            let _ = BufReader::new(connection.try_clone().unwrap()).read_line(&mut said);
            if said.trim_end() == pid {
                return connection;
            }
        }
    }

    /// The app's part: supervise this binary as the daemon until killed.
    fn run_app() {
        let dir = std::path::PathBuf::from(std::env::var_os(DIR).unwrap());
        let port = std::env::var(PORT).unwrap();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let mut config = SupervisorConfig::new(
                std::env::current_exe().unwrap(),
                dir.join("userData"),
                dir.join("logs"),
                "t".repeat(43),
                "k".into(),
            );
            config.env = vec![(ROLE.into(), "daemon".into()), (PORT.into(), port)];
            let (_supervisor, mut events) =
                Supervisor::spawn(config, &tokio::runtime::Handle::current());
            let pid = loop {
                match events.recv().await {
                    Some(SupervisorEvent::Ready { pid, .. }) => break pid,
                    Some(SupervisorEvent::Fatal(reason)) => {
                        println!("the daemon never got ready: {reason:?}");
                        std::process::exit(1);
                    }
                    Some(_) => {}
                    None => std::process::exit(1),
                }
            };
            println!("daemon ready, pid {pid}");
            std::future::pending::<()>().await;
        });
    }

    /// The daemon's part: ready, then deaf to stdin.
    fn run_daemon() {
        let port: u16 = std::env::var(PORT).unwrap().parse().unwrap();
        let mut test = TcpStream::connect(("127.0.0.1", port)).unwrap();
        writeln!(test, "{}", std::process::id()).unwrap();
        let mut bootstrap = String::new();
        std::io::stdin().read_line(&mut bootstrap).unwrap();
        println!(r#"{{"ready":true,"port":4242}}"#);
        // Only the test's question (or the test ending) ends it now.
        let mut asked = [0u8; 1];
        if matches!(test.read(&mut asked), Ok(1)) {
            let _ = test.write_all(b"outlived");
            let _ = test.shutdown(Shutdown::Write);
        }
    }
}
