//! One app per profile on Windows and Linux (AppKit does it on the Mac): the
//! first launch listens, and a later one hands its arguments (`conduit://`
//! links, files) to it and exits.
//!
//! * Linux: an abstract socket ([`crate::abstract_socket`]) named for the
//!   service, the profile and the user's id. A peer running as another user
//!   is refused, whichever end it is.
//! * Windows: a named pipe named for the service, the profile and the
//!   session, refused to remote clients. The pipe's default access lets
//!   other users only read it, and each end checks the other's session.
//!
//! The message is one line of JSON, `{"args":[…]}`, answered `ok`. An empty
//! list is a plain second launch: the app comes forward.

use std::io::{self, BufRead as _, Read, Write};
use std::path::Path;
#[cfg(any(target_os = "linux", windows))]
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// The longest message a launch may send.
const MAX_MESSAGE: u64 = 1 << 20;
/// How long either end waits for the other.
#[cfg(any(target_os = "linux", windows))]
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Serialize, Deserialize)]
struct Message {
    args: Vec<String>,
}

/// The name every launch of one profile shares: `<service>.<profile
/// hash>.<id>`, where `id` is the user's (Linux) or the session's
/// (Windows). Short enough for an abstract socket's 107 bytes.
pub fn instance_name(service: &str, profile: &Path, id: u32) -> String {
    format!(
        "{service}.{:016x}.{id}",
        fnv1a(profile.as_os_str().as_encoded_bytes())
    )
}

/// FNV-1a: stable across builds (std's hasher makes no such promise).
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, b| {
        (hash ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// Sends `args` and waits for the app's answer.
pub fn send(stream: &mut (impl Read + Write), args: &[String]) -> io::Result<()> {
    let mut line = serde_json::to_vec(&Message {
        args: args.to_vec(),
    })?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()?;
    let mut answer = String::new();
    io::BufReader::new(stream.take(16)).read_line(&mut answer)?;
    if answer.trim_end() == "ok" {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the running app did not take the launch",
        ))
    }
}

/// Reads one launch's arguments and answers it.
pub fn receive(stream: &mut (impl Read + Write)) -> io::Result<Vec<String>> {
    let mut line = Vec::new();
    io::BufReader::new((&mut *stream).take(MAX_MESSAGE)).read_until(b'\n', &mut line)?;
    if line.last() != Some(&b'\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "a launch's message was cut short or too long",
        ));
    }
    let message: Message = serde_json::from_slice(&line)?;
    stream.write_all(b"ok\n")?;
    stream.flush()?;
    Ok(message.args)
}

/// What a launch is.
#[cfg(any(target_os = "linux", windows))]
pub enum Claim {
    /// The app: [`Listener::serve`] hands it later launches' arguments.
    First(Listener),
    /// The running app took this launch's arguments; this one exits.
    Forwarded,
}

/// The first launch's end, until it serves.
#[cfg(target_os = "linux")]
pub struct Listener(std::os::unix::net::UnixListener);

#[cfg(windows)]
pub struct Listener {
    name: String,
    first: pipe::Pipe,
}

/// Claims `service`'s instance for `profile`, or hands `args` to the
/// launch that has it.
#[cfg(any(target_os = "linux", windows))]
pub fn claim(service: &str, profile: &Path, args: &[String]) -> io::Result<Claim> {
    #[cfg(target_os = "linux")]
    {
        let name = instance_name(service, profile, crate::abstract_socket::this_uid());
        match crate::abstract_socket::bind(&name) {
            Ok(listener) => Ok(Claim::First(Listener(listener))),
            Err(e) if e.kind() == io::ErrorKind::AddrInUse => {
                let stream = connect_linux(&name)?;
                exchange(stream, args)?;
                Ok(Claim::Forwarded)
            }
            Err(e) => Err(e),
        }
    }
    #[cfg(windows)]
    {
        let name = pipe::path(&instance_name(service, profile, pipe::this_session()?));
        match pipe::Pipe::create(&name, true) {
            Ok(first) => Ok(Claim::First(Listener { name, first })),
            Err(e) if e.raw_os_error() == Some(pipe::ERROR_ACCESS_DENIED) => {
                let client = pipe::open(&name)?;
                exchange(client, args)?;
                Ok(Claim::Forwarded)
            }
            Err(e) => Err(e),
        }
    }
}

/// The running app may be between binding and listening: a refused
/// connection is tried again for a moment.
#[cfg(target_os = "linux")]
fn connect_linux(name: &str) -> io::Result<std::os::unix::net::UnixStream> {
    use crate::abstract_socket::{connect, peer_uid, this_uid};
    let deadline = std::time::Instant::now() + EXCHANGE_TIMEOUT;
    let stream = loop {
        match connect(name) {
            Ok(stream) => break stream,
            Err(e)
                if e.kind() == io::ErrorKind::ConnectionRefused
                    && std::time::Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(e) => return Err(e),
        }
    };
    if peer_uid(&stream)? != this_uid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "another user holds this app's instance name",
        ));
    }
    stream.set_read_timeout(Some(EXCHANGE_TIMEOUT))?;
    stream.set_write_timeout(Some(EXCHANGE_TIMEOUT))?;
    Ok(stream)
}

/// [`send`] on its own thread, given [`EXCHANGE_TIMEOUT`]: a running app
/// that hangs never hangs the launch.
#[cfg(any(target_os = "linux", windows))]
fn exchange(mut stream: impl Read + Write + Send + 'static, args: &[String]) -> io::Result<()> {
    let (tx, rx) = std::sync::mpsc::channel();
    let args = args.to_vec();
    std::thread::spawn(move || {
        let _ = tx.send(send(&mut stream, &args));
    });
    rx.recv_timeout(EXCHANGE_TIMEOUT).unwrap_or_else(|_| {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "the running app did not answer",
        ))
    })
}

#[cfg(any(target_os = "linux", windows))]
impl Listener {
    /// Hands each later launch's arguments to `on_launch`, on a thread of
    /// its own, for as long as the process runs.
    pub fn serve(self, on_launch: impl Fn(Vec<String>) + Send + Sync + 'static) {
        let on_launch = std::sync::Arc::new(on_launch);
        let spawned = std::thread::Builder::new()
            .name("conduit-instance".into())
            .spawn(move || self.accept_forever(on_launch));
        if let Err(e) = spawned {
            log::error!("single instance: no listener thread: {e}");
        }
    }

    #[cfg(target_os = "linux")]
    fn accept_forever(self, on_launch: std::sync::Arc<dyn Fn(Vec<String>) + Send + Sync>) {
        use crate::abstract_socket::{peer_uid, this_uid};
        for stream in self.0.incoming() {
            let Ok(mut stream) = stream else { continue };
            if !matches!(peer_uid(&stream), Ok(uid) if uid == this_uid()) {
                log::warn!("single instance: refused a launch from another user");
                continue;
            }
            let on_launch = on_launch.clone();
            std::thread::spawn(move || {
                let _ = stream.set_read_timeout(Some(EXCHANGE_TIMEOUT));
                let _ = stream.set_write_timeout(Some(EXCHANGE_TIMEOUT));
                match receive(&mut stream) {
                    Ok(args) => on_launch(args),
                    Err(e) => log::warn!("single instance: {e}"),
                }
            });
        }
    }

    #[cfg(windows)]
    fn accept_forever(self, on_launch: std::sync::Arc<dyn Fn(Vec<String>) + Send + Sync>) {
        let mut waiting = self.first;
        loop {
            if let Err(e) = waiting.wait_for_client() {
                log::warn!("single instance: {e}");
            }
            // The next end is made before this one is used: there is never
            // a moment with no pipe, when a launch could take the name.
            let next = match pipe::Pipe::create(&self.name, false) {
                Ok(next) => next,
                Err(e) => {
                    log::error!("single instance: stopped listening: {e}");
                    return;
                }
            };
            let connected = std::mem::replace(&mut waiting, next);
            if !connected.client_is_this_session() {
                log::warn!("single instance: refused a launch from another session");
                continue;
            }
            let on_launch = on_launch.clone();
            std::thread::spawn(move || {
                let mut file = connected.into_file();
                match receive(&mut file) {
                    Ok(args) => on_launch(args),
                    Err(e) => log::warn!("single instance: {e}"),
                }
            });
        }
    }
}

#[cfg(windows)]
mod pipe {
    use std::io;
    use std::os::windows::io::{AsRawHandle as _, FromRawHandle as _, OwnedHandle};

    use windows::Win32::Foundation::{ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED, HANDLE};
    use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientSessionId,
        GetNamedPipeServerProcessId, GetNamedPipeServerSessionId, PIPE_READMODE_BYTE,
        PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };
    use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;
    use windows::Win32::System::Threading::GetCurrentProcessId;
    use windows::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow;
    use windows::core::PCWSTR;

    /// What `CreateNamedPipeW` says when the first instance is someone
    /// else's.
    pub const ERROR_ACCESS_DENIED: i32 = 5;

    pub fn path(name: &str) -> String {
        format!(r"\\.\pipe\{name}")
    }

    pub fn this_session() -> io::Result<u32> {
        let mut session = 0;
        // SAFETY: `session` is valid for the write.
        unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) }
            .map_err(io::Error::other)?;
        Ok(session)
    }

    /// One server end of the pipe.
    pub struct Pipe(OwnedHandle);

    impl Pipe {
        /// A new end; `first` refuses when the pipe exists already.
        pub fn create(name: &str, first: bool) -> io::Result<Self> {
            let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
            let mut mode = PIPE_ACCESS_DUPLEX;
            if first {
                mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
            }
            // SAFETY: `wide` is NUL-terminated and outlives the call; a
            // failed call returns INVALID_HANDLE_VALUE, checked below.
            let handle = unsafe {
                CreateNamedPipeW(
                    PCWSTR::from_raw(wide.as_ptr()),
                    mode,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                    PIPE_UNLIMITED_INSTANCES,
                    4096,
                    4096,
                    0,
                    None,
                )
            };
            if handle.is_invalid() {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: a valid handle this end now owns.
            Ok(Self(unsafe { OwnedHandle::from_raw_handle(handle.0) }))
        }

        fn handle(&self) -> HANDLE {
            HANDLE(self.0.as_raw_handle())
        }

        /// Blocks until a launch connects.
        pub fn wait_for_client(&self) -> io::Result<()> {
            // SAFETY: a valid pipe handle; no overlapped I/O.
            match unsafe { ConnectNamedPipe(self.handle(), None) } {
                Ok(()) => Ok(()),
                Err(e) if e.code() == ERROR_PIPE_CONNECTED.to_hresult() => Ok(()),
                Err(e) => Err(io::Error::other(e)),
            }
        }

        pub fn client_is_this_session(&self) -> bool {
            let mut session = 0;
            // SAFETY: a connected pipe handle; `session` is valid for the write.
            let theirs = unsafe { GetNamedPipeClientSessionId(self.handle(), &mut session) };
            theirs.is_ok() && this_session().is_ok_and(|mine| mine == session)
        }

        pub fn into_file(self) -> std::fs::File {
            std::fs::File::from(self.0)
        }
    }

    /// Opens the running app's pipe, checks it is this session's, and lets
    /// that app take the foreground (Windows gives it to this launch, which
    /// the user just started).
    pub fn open(name: &str) -> io::Result<std::fs::File> {
        let deadline = std::time::Instant::now() + super::EXCHANGE_TIMEOUT;
        let file = loop {
            match std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(name)
            {
                Ok(file) => break file,
                Err(e)
                    if e.raw_os_error() == Some(ERROR_PIPE_BUSY.0 as i32)
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                Err(e) => return Err(e),
            }
        };
        let handle = HANDLE(file.as_raw_handle());
        let mut session = 0;
        // SAFETY: a connected pipe handle; `session` is valid for the write.
        unsafe { GetNamedPipeServerSessionId(handle, &mut session) }.map_err(io::Error::other)?;
        if session != this_session()? {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "another session holds this app's instance name",
            ));
        }
        let mut pid = 0;
        // SAFETY: as above.
        if unsafe { GetNamedPipeServerProcessId(handle, &mut pid) }.is_ok() {
            // SAFETY: no preconditions; failing only means no foreground.
            let _ = unsafe { AllowSetForegroundWindow(pid) };
        }
        Ok(file)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_instance_is_one_per_service_profile_and_user() {
        let profile = Path::new("/home/avery/.local/share/conduit");
        let name = instance_name("app.example.conduit", profile, 1000);
        assert_eq!(name, instance_name("app.example.conduit", profile, 1000));
        assert!(name.starts_with("app.example.conduit."));
        assert!(name.len() <= 107, "fits an abstract socket name");
        for other in [
            instance_name("app.example.conduit.dev", profile, 1000),
            instance_name("app.example.conduit", Path::new("/tmp/profile-b"), 1000),
            instance_name("app.example.conduit", profile, 1001),
        ] {
            assert_ne!(other, name);
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_second_launch_hands_its_links_and_files_to_the_first() {
        let (mut app, mut launch) = std::os::unix::net::UnixStream::pair().unwrap();
        let args = vec![
            "conduit://chat/7b0c".to_string(),
            "file:///home/avery/notes%20v2.md".to_string(),
        ];
        let served = std::thread::spawn(move || receive(&mut app));
        send(&mut launch, &args).expect("the app answers");
        assert_eq!(served.join().unwrap().unwrap(), args);
    }

    #[cfg(unix)]
    #[test]
    fn a_plain_second_launch_arrives_with_nothing_to_open() {
        let (mut app, mut launch) = std::os::unix::net::UnixStream::pair().unwrap();
        let served = std::thread::spawn(move || receive(&mut app));
        send(&mut launch, &[]).expect("the app answers");
        assert_eq!(served.join().unwrap().unwrap(), Vec::<String>::new());
    }

    #[cfg(unix)]
    #[test]
    fn a_message_that_is_not_a_launch_is_refused() {
        for bytes in [
            &b"GET / HTTP/1.1\r\n\r\n"[..],
            b"{\"args\":[1]}\n",
            b"{\"args\":[\"x\"]}",
        ] {
            let (mut app, mut other) = std::os::unix::net::UnixStream::pair().unwrap();
            other.write_all(bytes).unwrap();
            other.shutdown(std::net::Shutdown::Write).unwrap();
            assert!(
                receive(&mut app).is_err(),
                "{:?}",
                String::from_utf8_lossy(bytes)
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_launch_the_app_never_answers_is_not_taken() {
        let (app, mut launch) = std::os::unix::net::UnixStream::pair().unwrap();
        drop(app);
        assert!(send(&mut launch, &["conduit://new".into()]).is_err());
    }

    /// Two launches of one profile in this process: the second finds the
    /// first and hands it its arguments.
    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn a_second_claim_hands_its_arguments_to_the_first() {
        let service = format!("app.example.conduit-test.{:016x}", rand::random::<u64>());
        let profile = Path::new("/srv/conduit-test/profile");
        let Claim::First(listener) = claim(&service, profile, &[]).unwrap() else {
            panic!("the first launch is the app");
        };
        let (tx, rx) = std::sync::mpsc::channel();
        listener.serve(move |args| {
            let _ = tx.send(args);
        });
        let args = vec!["conduit://settings".to_string()];
        assert!(matches!(
            claim(&service, profile, &args).unwrap(),
            Claim::Forwarded
        ));
        assert_eq!(rx.recv().unwrap(), args);
        // Another profile is an app of its own.
        assert!(matches!(
            claim(&service, Path::new("/srv/conduit-test/other"), &[]).unwrap(),
            Claim::First(_)
        ));
    }
}
