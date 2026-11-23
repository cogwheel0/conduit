//! One app per profile on Windows and Linux (AppKit does it on the Mac): the
//! first launch listens, and a later one hands its arguments (`conduit://`
//! links, files) to it and exits.
//!
//! * Linux: an abstract socket ([`crate::abstract_socket`]) named for the
//!   service, the profile and the user's id. A peer running as another user
//!   is refused, whichever end it is.
//! * Windows: a named pipe named for the service, the profile and the
//!   session. Only this user may open it (its security descriptor), remote
//!   clients are refused, and each end checks the other's account and
//!   session before a launch's arguments, which can carry tokens, cross.
//!
//! The message is one line of JSON, `{"args":[…],"expires":<ms>}`, answered
//! `ok` once the
//! app has queued the launch. An empty list is a plain second launch: the
//! app comes forward. Each handoff has one deadline, whichever end waits.

use std::io;
use std::path::Path;
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::io::{
    AsyncBufReadExt as _, AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _,
};
use tokio::time::Instant;

/// The longest message a launch may send.
const MAX_MESSAGE: u64 = 1 << 20;
/// How long a whole handoff may take, at either end.
pub const HANDOFF_TIMEOUT: Duration = Duration::from_secs(5);
/// Launches the app takes at once; more are refused until one ends.
#[cfg(any(target_os = "linux", windows))]
const MAX_WORKERS: usize = 4;

/// What the app does with a launch's arguments: whether it queued them.
#[cfg(any(target_os = "linux", windows))]
type OnLaunch = std::sync::Arc<dyn Fn(Vec<String>) -> bool + Send + Sync>;

/// How long a launch must still wait for its `ok` to be queued: room for
/// the answer to reach it before it gives up.
const QUEUE_MARGIN: Duration = Duration::from_millis(500);

#[derive(Serialize, Deserialize)]
struct Message {
    args: Vec<String>,
    /// When the launch stops waiting for `ok`: ms since the Unix epoch, on
    /// the wall clock both ends share (a tokio instant is each process's
    /// own).
    expires: u64,
}

/// `time` as ms since the Unix epoch.
fn unix_ms(time: SystemTime) -> u64 {
    time.duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// Whether a launch that stops waiting at `expires` is still waiting at
/// `now` (both ms since the epoch), with room for the app's answer. One its
/// sender has given up on, or is about to, is dropped: the sender has said
/// it wasn't handed over, and a launch run again would open its link or
/// file twice.
fn still_waiting(expires: u64, now: u64) -> bool {
    expires.saturating_sub(now) >= QUEUE_MARGIN.as_millis() as u64
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

fn timed_out() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "the handoff ran out of time")
}

/// Hands `args` over `stream` and waits for the app's `ok`, all by
/// `deadline`.
pub async fn hand_over<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    args: &[String],
    deadline: Instant,
) -> io::Result<()> {
    let left = deadline.saturating_duration_since(Instant::now());
    let expires = unix_ms(SystemTime::now() + left);
    tokio::time::timeout_at(deadline, async {
        let mut line = serde_json::to_vec(&Message {
            args: args.to_vec(),
            expires,
        })?;
        line.push(b'\n');
        stream.write_all(&line).await?;
        stream.flush().await?;
        let mut answer = String::new();
        tokio::io::BufReader::new((&mut *stream).take(16))
            .read_line(&mut answer)
            .await?;
        if answer.trim_end() == "ok" {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the running app did not take the launch",
            ))
        }
    })
    .await
    .map_err(|_| timed_out())?
}

/// Takes one launch from `stream` by `deadline`: its arguments go to
/// `on_launch`, and the launch hears `ok` only if `on_launch` queued them.
pub async fn take_launch<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    deadline: Instant,
    on_launch: &(dyn Fn(Vec<String>) -> bool + Send + Sync),
) -> io::Result<()> {
    tokio::time::timeout_at(deadline, async {
        let mut line = Vec::new();
        tokio::io::BufReader::new((&mut *stream).take(MAX_MESSAGE))
            .read_until(b'\n', &mut line)
            .await?;
        if line.last() != Some(&b'\n') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "a launch's message was cut short or too long",
            ));
        }
        let message: Message = serde_json::from_slice(&line)?;
        // A frame read once the budget is gone, or once its sender is about
        // to give up, is dropped, never queued. (A ready read finishes
        // before `timeout_at` looks.)
        if Instant::now() >= deadline || !still_waiting(message.expires, unix_ms(SystemTime::now()))
        {
            return Err(timed_out());
        }
        if !on_launch(message.args) {
            return Err(io::Error::other("the app could not take the launch"));
        }
        stream.write_all(b"ok\n").await?;
        stream.flush().await
    })
    .await
    .map_err(|_| timed_out())?
}

/// What a launch is.
#[cfg(any(target_os = "linux", windows))]
pub enum Claim {
    /// The app: [`Listener::serve`] hands it later launches' arguments.
    First(Listener),
    /// The running app took this launch's arguments; this one exits.
    Forwarded,
    /// This user's app holds the profile but did not take the launch in
    /// time (hung, or its queue full). Another app on the same profile must
    /// not start, so this launch ends.
    Busy,
    /// The profile's name is held, and who holds it can't be told: it may
    /// be this user's app, so this launch ends too.
    Unidentified(io::Error),
    /// This launch holds the profile's name but can't listen on it (the
    /// runtime refused its end). It ends: unclaimed, it would let a later
    /// launch open the profile beside it.
    NotListening(io::Error),
}

/// Who holds the profile's name, from a launch's try to reach it.
#[cfg_attr(not(target_os = "linux"), cfg(test))]
#[derive(Debug, PartialEq, Eq)]
enum Holder {
    /// This user's app: the launch is handed to it.
    Ours,
    /// Another user's: not this profile's app, so the launch runs on its own.
    Theirs,
    /// Still starting (bound, not listening yet): try again.
    Starting,
    /// It has no room for the launch now.
    Busy,
    /// It can't be told; it may be this user's app.
    Unknown,
}

/// Who holds the name, from what reaching it gave: the holder's user id, or
/// why there was none. Only a holder known to be another user's lets a
/// launch run on its own.
#[cfg_attr(not(target_os = "linux"), cfg(test))]
fn holder(reached: Result<u32, io::ErrorKind>, this_uid: u32, out_of_time: bool) -> Holder {
    match reached {
        Ok(uid) if uid == this_uid => Holder::Ours,
        Ok(_) => Holder::Theirs,
        Err(io::ErrorKind::WouldBlock) => Holder::Busy,
        Err(io::ErrorKind::ConnectionRefused) if out_of_time => Holder::Busy,
        Err(io::ErrorKind::ConnectionRefused) => Holder::Starting,
        Err(_) => Holder::Unknown,
    }
}

/// The first launch's end, until it serves: already the runtime's, so the
/// launch told it holds the profile can take later launches.
#[cfg(target_os = "linux")]
pub struct Listener(tokio::net::UnixListener);

#[cfg(windows)]
pub struct Listener {
    name: String,
    first: tokio::net::windows::named_pipe::NamedPipeServer,
    access: pipe::OwnerOnly,
}

/// Claims `service`'s instance for `profile`, or hands `args` to the
/// launch that has it. An error (another user holds the name, the system
/// refused) leaves the caller to run on its own: it is not this user's app.
#[cfg(any(target_os = "linux", windows))]
pub fn claim(service: &str, profile: &Path, args: &[String]) -> io::Result<Claim> {
    let runtime = crate::runtime::shared();
    #[cfg(target_os = "linux")]
    {
        let name = instance_name(service, profile, crate::abstract_socket::this_uid());
        match crate::abstract_socket::bind(&name) {
            Ok(bound) => {
                let _in_runtime = runtime.enter();
                Ok(
                    match bound
                        .set_nonblocking(true)
                        .and_then(|()| tokio::net::UnixListener::from_std(bound))
                    {
                        Ok(listener) => Claim::First(Listener(listener)),
                        Err(e) => Claim::NotListening(e),
                    },
                )
            }
            Err(e) if e.kind() == io::ErrorKind::AddrInUse => {
                runtime.block_on(forward_linux(&name, args, Instant::now() + HANDOFF_TIMEOUT))
            }
            Err(e) => Err(e),
        }
    }
    #[cfg(windows)]
    {
        let name = pipe::path(&instance_name(service, profile, pipe::this_session()?));
        let access = pipe::OwnerOnly::new()?;
        let created = {
            let _in_runtime = runtime.enter();
            pipe::create(&name, true, &access)
        };
        match created {
            Ok(first) => Ok(Claim::First(Listener {
                name,
                first,
                access,
            })),
            Err(e) if e.raw_os_error() == Some(pipe::ERROR_ACCESS_DENIED) => runtime.block_on(
                forward_windows(&name, args, Instant::now() + HANDOFF_TIMEOUT),
            ),
            Err(e) => Err(e),
        }
    }
}

/// Hands `args` to the launch bound to `name`, by `deadline`. It may be
/// between binding and listening, so a refused connection is tried again
/// until then; a full queue is no answer at once.
#[cfg(target_os = "linux")]
async fn forward_linux(name: &str, args: &[String], deadline: Instant) -> io::Result<Claim> {
    use crate::abstract_socket::{connect, peer_uid, this_uid};
    let stream = loop {
        let reached = connect(name).and_then(|stream| Ok((peer_uid(&stream)?, stream)));
        let who = holder(
            reached
                .as_ref()
                .map(|(uid, _)| *uid)
                .map_err(io::Error::kind),
            this_uid(),
            Instant::now() >= deadline,
        );
        match (who, reached) {
            (Holder::Ours, Ok((_, stream))) => break stream,
            (Holder::Theirs, _) => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "another user holds this app's instance name",
                ));
            }
            (Holder::Starting, _) => tokio::time::sleep(Duration::from_millis(20)).await,
            (Holder::Busy, _) => return Ok(Claim::Busy),
            (_, Err(e)) => return Ok(Claim::Unidentified(e)),
            (_, Ok(_)) => return Ok(Claim::Unidentified(io::Error::other("no holder"))),
        }
    };
    let handed = async {
        stream.set_nonblocking(true)?;
        let mut stream = tokio::net::UnixStream::from_std(stream)?;
        hand_over(&mut stream, args, deadline).await
    };
    Ok(match handed.await {
        Ok(()) => Claim::Forwarded,
        Err(e) => {
            log::warn!("single instance: the running app did not take the launch: {e}");
            Claim::Busy
        }
    })
}

#[cfg(windows)]
async fn forward_windows(name: &str, args: &[String], deadline: Instant) -> io::Result<Claim> {
    use tokio::net::windows::named_pipe::ClientOptions;
    let mut client = loop {
        match ClientOptions::new().open(name) {
            Ok(client) => break client,
            Err(e) if e.raw_os_error() == Some(pipe::ERROR_PIPE_BUSY) => {
                if Instant::now() >= deadline {
                    return Ok(Claim::Busy);
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            // Held (the first pipe end was refused), by whom can't be told.
            Err(e) => return Ok(Claim::Unidentified(e)),
        }
    };
    match pipe::check_server(&client) {
        Ok(()) => {}
        // Known to be another account's, or another session's.
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => return Err(e),
        Err(e) => return Ok(Claim::Unidentified(e)),
    }
    Ok(match hand_over(&mut client, args, deadline).await {
        Ok(()) => Claim::Forwarded,
        Err(e) => {
            log::warn!("single instance: the running app did not take the launch: {e}");
            Claim::Busy
        }
    })
}

#[cfg(any(target_os = "linux", windows))]
impl Listener {
    /// Hands each later launch's arguments to `on_launch`, which answers
    /// whether the app queued them, for as long as the process runs.
    pub fn serve(self, on_launch: impl Fn(Vec<String>) -> bool + Send + Sync + 'static) {
        let on_launch: OnLaunch = std::sync::Arc::new(on_launch);
        crate::runtime::shared().spawn(self.accept_forever(on_launch));
    }

    #[cfg(target_os = "linux")]
    async fn accept_forever(self, on_launch: OnLaunch) {
        use crate::abstract_socket::{peer_uid, this_uid};
        let listener = self.0;
        let workers = std::sync::Arc::new(tokio::sync::Semaphore::new(MAX_WORKERS));
        let mut failures: u32 = 0;
        loop {
            let stream = match listener.accept().await {
                Ok((stream, _)) => {
                    failures = 0;
                    stream
                }
                Err(e) => {
                    failures = failures.saturating_add(1);
                    if failures == 1 {
                        log::warn!("single instance: a launch couldn't be taken ({e}); waiting");
                    }
                    tokio::time::sleep(accept_backoff(failures)).await;
                    continue;
                }
            };
            let deadline = Instant::now() + HANDOFF_TIMEOUT;
            if !matches!(peer_uid(&stream), Ok(uid) if uid == this_uid()) {
                log::warn!("single instance: refused a launch from another user");
                continue;
            }
            spawn_worker(stream, deadline, &workers, &on_launch);
        }
    }

    #[cfg(windows)]
    async fn accept_forever(self, on_launch: OnLaunch) {
        let workers = std::sync::Arc::new(tokio::sync::Semaphore::new(MAX_WORKERS));
        let mut waiting = self.first;
        loop {
            let connected = waiting.connect().await;
            // The launch's budget runs from its connection, not from when the
            // next end exists (that may take retries).
            let deadline = Instant::now() + HANDOFF_TIMEOUT;
            // The next end is made before this one is let go: there is never
            // a moment with no pipe, when a launch could take the name. Until
            // it can be made, this end is held, and making it is tried again.
            let next = retry_until_made(|| pipe::create(&self.name, false, &self.access)).await;
            let pipe = std::mem::replace(&mut waiting, next);
            if let Err(e) = connected {
                log::warn!("single instance: {e}");
                continue;
            }
            if let Err(e) = pipe::check_client(&pipe) {
                log::warn!("single instance: refused a launch: {e}");
                continue;
            }
            spawn_worker(pipe, deadline, &workers, &on_launch);
        }
    }
}

/// How long to wait before accepting again after `failures` accepts in a
/// row failed (out of descriptors, say): the launch stays queued, so trying
/// again at once would only spin. The wait doubles from 10 ms up to 1 s; the
/// listener, and the profile's claim, stay.
#[cfg_attr(not(target_os = "linux"), cfg(test))]
fn accept_backoff(failures: u32) -> Duration {
    const FIRST: Duration = Duration::from_millis(10);
    const MAX: Duration = Duration::from_secs(1);
    let doubled = 1u32
        .checked_shl(failures.saturating_sub(1))
        .unwrap_or(u32::MAX);
    FIRST.saturating_mul(doubled).min(MAX)
}

/// The longest wait before the pipe's next end is tried again.
#[cfg(any(windows, test))]
const MAX_RETRY_WAIT: Duration = Duration::from_secs(60);

/// What `make` makes, tried again after a wait that doubles up to a minute
/// until it is made: the pipe's next end, which the app must have before it
/// lets the connected one go.
#[cfg(any(windows, test))]
async fn retry_until_made<T>(mut make: impl FnMut() -> io::Result<T>) -> T {
    let mut wait = Duration::from_secs(1);
    loop {
        match make() {
            Ok(made) => return made,
            Err(e) => {
                log::warn!("single instance: the pipe's next end failed ({e}); again in {wait:?}");
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(MAX_RETRY_WAIT);
            }
        }
    }
}

/// Takes one launch on its own task, by `deadline` (its connection's); with
/// every worker busy, the launch is dropped (it hears nothing, and says the
/// app is busy).
#[cfg(any(target_os = "linux", windows))]
fn spawn_worker<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    mut stream: S,
    deadline: Instant,
    workers: &std::sync::Arc<tokio::sync::Semaphore>,
    on_launch: &OnLaunch,
) {
    let Ok(permit) = workers.clone().try_acquire_owned() else {
        log::warn!("single instance: too many launches at once; dropped one");
        return;
    };
    let on_launch = on_launch.clone();
    tokio::spawn(async move {
        let _permit = permit;
        if let Err(e) = take_launch(&mut stream, deadline, &*on_launch).await {
            log::warn!("single instance: {e}");
        }
    });
}

#[cfg(windows)]
mod pipe {
    use std::io;
    use std::os::windows::io::AsRawHandle as _;

    use tokio::net::windows::named_pipe::{NamedPipeClient, NamedPipeServer, ServerOptions};
    use windows::Win32::Foundation::{CloseHandle, HANDLE, HLOCAL, LocalFree};
    use windows::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        SDDL_REVISION_1,
    };
    use windows::Win32::Security::{
        EqualSid, GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
        TOKEN_USER, TokenUser,
    };
    use windows::Win32::System::Pipes::{
        GetNamedPipeClientProcessId, GetNamedPipeClientSessionId, GetNamedPipeServerProcessId,
        GetNamedPipeServerSessionId,
    };
    use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;
    use windows::Win32::System::Threading::{
        GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow;
    use windows::core::{PCWSTR, PWSTR};

    /// What `CreateNamedPipeW` says when the first instance is someone
    /// else's, and what opening one says while every end is busy.
    pub const ERROR_ACCESS_DENIED: i32 = 5;
    pub const ERROR_PIPE_BUSY: i32 = 231;

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

    /// A security descriptor that lets only this user open the pipe.
    pub struct OwnerOnly(PSECURITY_DESCRIPTOR);

    // SAFETY: the descriptor is plain memory this value owns, only read.
    unsafe impl Send for OwnerOnly {}
    // SAFETY: as above.
    unsafe impl Sync for OwnerOnly {}

    impl OwnerOnly {
        pub fn new() -> io::Result<Self> {
            let user = token_user(unsafe { GetCurrentProcess() })?;
            let mut sid_text = PWSTR::null();
            // SAFETY: the SID lives in `user`; the string is freed below.
            unsafe { ConvertSidToStringSidW(sid_of(&user), &mut sid_text) }
                .map_err(io::Error::other)?;
            // SAFETY: a NUL-terminated string from the call above.
            let sid = unsafe { sid_text.to_string() };
            // SAFETY: allocated by ConvertSidToStringSidW.
            unsafe { LocalFree(Some(HLOCAL(sid_text.0.cast()))) };
            let sid = sid.map_err(io::Error::other)?;
            // A protected DACL: full access for this user, nobody else.
            let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid})")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let mut descriptor = PSECURITY_DESCRIPTOR::default();
            // SAFETY: `sddl` is NUL-terminated; the descriptor is freed on drop.
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    PCWSTR::from_raw(sddl.as_ptr()),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    None,
                )
            }
            .map_err(io::Error::other)?;
            Ok(Self(descriptor))
        }
    }

    impl Drop for OwnerOnly {
        fn drop(&mut self) {
            // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
            unsafe { LocalFree(Some(HLOCAL(self.0.0))) };
        }
    }

    /// One server end; `first` refuses when the pipe exists already.
    pub fn create(name: &str, first: bool, access: &OwnerOnly) -> io::Result<NamedPipeServer> {
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: access.0.0,
            bInheritHandle: false.into(),
        };
        // SAFETY: `attributes` and the descriptor it points to outlive the
        // call, which only reads them.
        unsafe {
            ServerOptions::new()
                .first_pipe_instance(first)
                .reject_remote_clients(true)
                .create_with_security_attributes_raw(name, (&raw mut attributes).cast())
        }
    }

    /// A process's token user (a `TOKEN_USER` and the SID after it).
    fn token_user(process: HANDLE) -> io::Result<Vec<u64>> {
        let mut token = HANDLE::default();
        // SAFETY: `process` is a process handle with query access.
        unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) }.map_err(io::Error::other)?;
        let mut len = 0u32;
        // SAFETY: the first call only asks for the size.
        let _ = unsafe { GetTokenInformation(token, TokenUser, None, 0, &mut len) };
        // u64 words keep the TOKEN_USER aligned.
        let mut buffer = vec![0u64; (len as usize).div_ceil(8)];
        // SAFETY: `buffer` holds `len` bytes.
        let read = unsafe {
            GetTokenInformation(
                token,
                TokenUser,
                Some(buffer.as_mut_ptr().cast()),
                len,
                &mut len,
            )
        };
        // SAFETY: the token handle this function opened.
        let _ = unsafe { CloseHandle(token) };
        read.map_err(io::Error::other)?;
        Ok(buffer)
    }

    fn sid_of(user: &[u64]) -> windows::Win32::Security::PSID {
        // SAFETY: `user` holds a TOKEN_USER (token_user).
        unsafe { (*user.as_ptr().cast::<TOKEN_USER>()).User.Sid }
    }

    /// Whether process `pid` runs as this user.
    fn is_this_user(pid: u32) -> io::Result<bool> {
        // SAFETY: plain process query; the handle is closed below.
        let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }
            .map_err(io::Error::other)?;
        let theirs = token_user(process);
        // SAFETY: the handle this function opened.
        let _ = unsafe { CloseHandle(process) };
        let theirs = theirs?;
        let mine = token_user(unsafe { GetCurrentProcess() })?;
        // SAFETY: both SIDs live in their buffers.
        Ok(unsafe { EqualSid(sid_of(&theirs), sid_of(&mine)) }.is_ok())
    }

    fn refused(what: &str) -> io::Error {
        io::Error::new(io::ErrorKind::PermissionDenied, what.to_string())
    }

    /// The running app's end is this user's, in this session; then it may
    /// take the foreground (Windows gives it to this launch).
    pub fn check_server(client: &NamedPipeClient) -> io::Result<()> {
        let handle = HANDLE(client.as_raw_handle());
        let (mut session, mut pid) = (0, 0);
        // SAFETY: a connected pipe handle; the outputs are valid for writes.
        unsafe { GetNamedPipeServerSessionId(handle, &mut session) }.map_err(io::Error::other)?;
        // SAFETY: as above.
        unsafe { GetNamedPipeServerProcessId(handle, &mut pid) }.map_err(io::Error::other)?;
        if session != this_session()? || !is_this_user(pid)? {
            return Err(refused("another account holds this app's instance name"));
        }
        // SAFETY: no preconditions; failing only means no foreground.
        let _ = unsafe { AllowSetForegroundWindow(pid) };
        Ok(())
    }

    /// A launch that connected is this user's, in this session.
    pub fn check_client(server: &NamedPipeServer) -> io::Result<()> {
        let handle = HANDLE(server.as_raw_handle());
        let (mut session, mut pid) = (0, 0);
        // SAFETY: a connected pipe handle; the outputs are valid for writes.
        unsafe { GetNamedPipeClientSessionId(handle, &mut session) }.map_err(io::Error::other)?;
        // SAFETY: as above.
        unsafe { GetNamedPipeClientProcessId(handle, &mut pid) }.map_err(io::Error::other)?;
        if session != this_session()? || !is_this_user(pid)? {
            return Err(refused("a launch from another account or session"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Accepting fails again and again (no descriptors left): the waits
    /// between tries double, and stop growing at a second.
    #[test]
    fn failed_accepts_wait_longer_each_time() {
        let waits: Vec<_> = [1, 2, 3, 7, 8, 40, u32::MAX]
            .map(accept_backoff)
            .into_iter()
            .map(|wait| wait.as_millis())
            .collect();
        assert_eq!(waits, [10, 20, 40, 640, 1_000, 1_000, 1_000]);
    }

    /// A launch's line, as `hand_over` writes it, that stops waiting at
    /// `expires`.
    fn frame(args: &[&str], expires: u64) -> Vec<u8> {
        let mut line = serde_json::to_vec(&Message {
            args: args.iter().map(|a| a.to_string()).collect(),
            expires,
        })
        .unwrap();
        line.push(b'\n');
        line
    }

    /// A launch is queued only with time to spare before it stops waiting.
    #[test]
    fn a_launch_is_queued_only_while_its_sender_still_waits() {
        assert!(still_waiting(10_000, 9_000));
        assert!(still_waiting(10_000, 9_500), "500 ms left");
        assert!(!still_waiting(10_000, 9_501), "less than 500 ms left");
        assert!(!still_waiting(10_000, 10_000));
        assert!(!still_waiting(10_000, 20_000), "long gone");
    }

    /// The app reaches a launch's line late (it was busy, or suspended)
    /// though within its own deadline, which ran from the accept: the
    /// sender has given up by its own clock, so the launch is dropped, never
    /// queued, and a launch run again opens its link once.
    #[tokio::test(start_paused = true)]
    async fn a_launch_its_sender_gave_up_on_is_dropped_never_queued() {
        let now = unix_ms(SystemTime::now());
        // The app's own deadline, from its accept, is 5 s ahead in both: the
        // sender's clock started first, before it connected.
        for (expires, case) in [
            (now - 1_000, "its sender gave up a second ago"),
            (
                now + 300,
                "its sender gives up in 300 ms, inside the margin",
            ),
        ] {
            let (mut app, mut launch) = tokio::io::duplex(1024);
            launch
                .write_all(&frame(&["conduit://chat/c1"], expires))
                .await
                .unwrap();
            let queued = std::sync::atomic::AtomicBool::new(false);
            let taken = take_launch(&mut app, deadline(), &|_| {
                queued.store(true, std::sync::atomic::Ordering::SeqCst);
                true
            })
            .await;
            assert_eq!(taken.unwrap_err().kind(), io::ErrorKind::TimedOut, "{case}");
            assert!(!queued.load(std::sync::atomic::Ordering::SeqCst), "{case}");
            drop(app);
            let mut answer = Vec::new();
            launch.read_to_end(&mut answer).await.unwrap();
            assert!(answer.is_empty(), "no ok: {case}");
        }
    }

    /// A launch whose frame is read once its budget is gone (the app was
    /// slow to get to it) is dropped: it hears no `ok`, and its arguments
    /// are never queued, since it has given up and said so.
    #[tokio::test(start_paused = true)]
    async fn a_launch_read_after_its_deadline_is_dropped_never_queued() {
        let (mut app, mut launch) = tokio::io::duplex(1024);
        launch
            .write_all(&frame(&["conduit://chat/c1"], u64::MAX))
            .await
            .unwrap();
        let deadline = Instant::now();
        tokio::time::advance(Duration::from_millis(1)).await;
        let queued = std::sync::atomic::AtomicBool::new(false);
        let taken = take_launch(&mut app, deadline, &|_| {
            queued.store(true, std::sync::atomic::Ordering::SeqCst);
            true
        })
        .await;
        assert_eq!(taken.unwrap_err().kind(), io::ErrorKind::TimedOut);
        assert!(!queued.load(std::sync::atomic::Ordering::SeqCst));
        drop(app);
        let mut answer = Vec::new();
        launch.read_to_end(&mut answer).await.unwrap();
        assert!(answer.is_empty(), "no ok");
    }

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

    /// Each launch's arguments the app was handed.
    type Handed = std::sync::Arc<std::sync::Mutex<Vec<Vec<String>>>>;

    /// What the app was handed, and whether it queues launches.
    fn app(queues: bool) -> (Handed, impl Fn(Vec<String>) -> bool + Send + Sync) {
        let got = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let seen = got.clone();
        (got, move |args| {
            seen.lock().unwrap().push(args);
            queues
        })
    }

    fn deadline() -> Instant {
        Instant::now() + HANDOFF_TIMEOUT
    }

    #[tokio::test(start_paused = true)]
    async fn a_second_launch_hands_its_links_and_files_to_the_first() {
        let (mut launch, mut first) = tokio::io::duplex(4096);
        let args = vec![
            "conduit://chat/7b0c".to_string(),
            "file:///home/avery/notes%20v2.md".to_string(),
        ];
        let (got, on_launch) = app(true);
        let (sent, taken) = tokio::join!(
            hand_over(&mut launch, &args, deadline()),
            take_launch(&mut first, deadline(), &on_launch)
        );
        sent.expect("the app answers");
        taken.expect("the app takes it");
        assert_eq!(*got.lock().unwrap(), vec![args]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_plain_second_launch_arrives_with_nothing_to_open() {
        let (mut launch, mut first) = tokio::io::duplex(4096);
        let (got, on_launch) = app(true);
        let (sent, taken) = tokio::join!(
            hand_over(&mut launch, &[], deadline()),
            take_launch(&mut first, deadline(), &on_launch)
        );
        sent.unwrap();
        taken.unwrap();
        assert_eq!(*got.lock().unwrap(), vec![Vec::<String>::new()]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_message_that_is_not_a_launch_is_refused() {
        for bytes in [
            &b"GET / HTTP/1.1\r\n\r\n"[..],
            b"{\"args\":[1]}\n",
            b"{\"args\":[\"x\"]}",
            b"{\"args\":[\"x\"]}\n",
        ] {
            let (mut other, mut first) = tokio::io::duplex(4096);
            other.write_all(bytes).await.unwrap();
            other.shutdown().await.unwrap();
            let (got, on_launch) = app(true);
            assert!(
                take_launch(&mut first, deadline(), &on_launch)
                    .await
                    .is_err(),
                "{:?}",
                String::from_utf8_lossy(bytes)
            );
            assert!(got.lock().unwrap().is_empty());
        }
    }

    /// The app hears a launch but can't queue it (it is quitting): the
    /// launch is not told it was taken.
    #[tokio::test(start_paused = true)]
    async fn a_launch_the_app_could_not_queue_is_not_acknowledged() {
        let (mut launch, mut first) = tokio::io::duplex(4096);
        let (_, on_launch) = app(false);
        let (sent, taken) = tokio::join!(
            async {
                let sent = hand_over(&mut launch, &["conduit://new".into()], deadline()).await;
                drop(launch);
                sent
            },
            take_launch(&mut first, deadline(), &on_launch)
        );
        assert!(taken.is_err());
        assert!(sent.is_err(), "no ok for a launch the app dropped");
    }

    /// A launch that never finishes its line frees the app's worker at the
    /// deadline, and no later.
    #[tokio::test(start_paused = true)]
    async fn a_stalled_launch_frees_its_worker_by_the_deadline() {
        let (mut stalled, mut first) = tokio::io::duplex(4096);
        stalled
            .write_all(b"{\"args\":[\"conduit://new\"")
            .await
            .unwrap();
        let (got, on_launch) = app(true);
        let started = Instant::now();
        tokio::select! {
            taken = take_launch(&mut first, deadline(), &on_launch) => {
                assert_eq!(taken.unwrap_err().kind(), io::ErrorKind::TimedOut);
            }
            () = tokio::time::sleep(HANDOFF_TIMEOUT * 3) => {
                panic!("a stalled launch held its worker past its deadline");
            }
        }
        assert_eq!(Instant::now() - started, HANDOFF_TIMEOUT);
        assert!(got.lock().unwrap().is_empty());
        drop(stalled);
    }

    /// The handoff has one deadline: an app that takes the whole message
    /// 2 s in (the pipe holds less than a message) and then never answers
    /// costs the launch that one 5 s wait, not 5 s for the message and
    /// another 5 s for the answer from 2 s on.
    #[tokio::test(start_paused = true)]
    async fn the_handoff_has_one_deadline() {
        let (mut launch, mut first) = tokio::io::duplex(8);
        let slow_app = async move {
            tokio::time::sleep(Duration::from_secs(2)).await;
            let mut line = Vec::new();
            tokio::io::BufReader::new(&mut first)
                .read_until(b'\n', &mut line)
                .await
                .unwrap();
            assert_eq!(line.last(), Some(&b'\n'), "the whole message came");
            // No answer, ever.
            std::future::pending::<()>().await;
        };
        let args = ["conduit://settings".to_string()];
        let started = Instant::now();
        tokio::select! {
            sent = hand_over(&mut launch, &args, deadline()) => {
                assert_eq!(sent.unwrap_err().kind(), io::ErrorKind::TimedOut);
            }
            () = slow_app => panic!("the app's end closed"),
            () = tokio::time::sleep(HANDOFF_TIMEOUT * 3) => {
                panic!("the handoff waited past its deadline");
            }
        }
        assert_eq!(Instant::now() - started, HANDOFF_TIMEOUT);
    }

    /// A launch runs on its own only beside a holder known to be another
    /// user's. One it can't identify (reaching it failed, other than busy)
    /// may be this user's app, so the launch ends, as for a busy one.
    #[test]
    fn only_a_holder_known_to_be_another_users_lets_a_launch_run_alone() {
        use io::ErrorKind::{ConnectionRefused, OutOfMemory, PermissionDenied, WouldBlock};
        let me = 1000;
        for (reached, out_of_time, expected) in [
            (Ok(me), false, Holder::Ours),
            (Ok(1001), false, Holder::Theirs),
            (Err(WouldBlock), false, Holder::Busy),
            (Err(ConnectionRefused), false, Holder::Starting),
            (Err(ConnectionRefused), true, Holder::Busy),
            (Err(OutOfMemory), false, Holder::Unknown),
            (Err(PermissionDenied), false, Holder::Unknown),
            (Err(io::ErrorKind::Other), true, Holder::Unknown),
        ] {
            assert_eq!(holder(reached, me, out_of_time), expected, "{reached:?}");
        }
    }

    /// The pipe's next end that fails to be made is tried again, waiting
    /// longer each time, until it is made: the app never stops listening
    /// (which would let a later launch become a second app).
    #[tokio::test(start_paused = true)]
    async fn the_pipes_next_end_is_tried_until_it_is_made() {
        let mut tries = 0;
        let started = Instant::now();
        let made = retry_until_made(|| {
            tries += 1;
            if tries < 4 {
                Err(io::Error::other("no pipe"))
            } else {
                Ok(7)
            }
        })
        .await;
        assert_eq!((made, tries), (7, 4));
        assert_eq!(Instant::now() - started, Duration::from_secs(1 + 2 + 4));
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
        listener.serve(move |args| tx.send(args).is_ok());
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

    /// The profile's app holds the name but its queue is full: the launch
    /// is busy at once, never a second app on the profile, and never a
    /// wait for an accept.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_full_queue_on_the_profiles_app_is_busy_at_once() {
        let service = format!("app.example.conduit-test.{:016x}", rand::random::<u64>());
        let profile = Path::new("/srv/conduit-test/profile");
        let name = instance_name(&service, profile, crate::abstract_socket::this_uid());
        let (_listener, _queued) = crate::abstract_socket::tests::full_listener(&name);
        assert!(matches!(
            claim(&service, profile, &["conduit://new".into()]).unwrap(),
            Claim::Busy
        ));
    }
}
