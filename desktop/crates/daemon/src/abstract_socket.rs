//! Linux abstract Unix sockets: names the kernel keeps, not files, so they
//! need no folder (and no `HOME`), and they go away with the process that
//! bound them. Any user can bind any name, so a name's holder is checked by
//! its peer credentials before it is trusted.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd as _, OwnedFd};
use std::os::linux::net::SocketAddrExt as _;
use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};

/// Binds (and listens on) `name`; `AddrInUse` while another process holds it.
pub fn bind(name: &str) -> io::Result<UnixListener> {
    UnixListener::bind_addr(&SocketAddr::from_abstract_name(name.as_bytes())?)
}

/// Connects to `name` without waiting: a listener whose queue is full
/// answers `WouldBlock` at once. A blocking connect would wait until it
/// accepts, which a lock's listener never does, and anyone can fill a
/// queue. The stream blocks again once connected.
pub fn connect(name: &str) -> io::Result<UnixStream> {
    let (addr, len) = abstract_address(name)?;
    // SAFETY: plain socket creation; the descriptor is owned below.
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` is a new descriptor nothing else owns.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    // SAFETY: `addr` is a valid sockaddr_un of `len` bytes for the call.
    let connected = unsafe { libc::connect(fd.as_raw_fd(), (&raw const addr).cast(), len) };
    if connected != 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = UnixStream::from(fd);
    stream.set_nonblocking(false)?;
    Ok(stream)
}

/// `name` as an abstract `sockaddr_un`: a NUL, then the name's bytes.
fn abstract_address(name: &str) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
    // SAFETY: an all-zero sockaddr_un is valid.
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let bytes = name.as_bytes();
    if bytes.len() + 1 > addr.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "an abstract socket name of at most 107 bytes",
        ));
    }
    for (slot, byte) in addr.sun_path[1..].iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    let len = std::mem::offset_of!(libc::sockaddr_un, sun_path) + 1 + bytes.len();
    Ok((addr, len as libc::socklen_t))
}

/// The user id of the process at the other end of `socket`.
pub fn peer_uid(socket: &impl AsRawFd) -> io::Result<u32> {
    let mut cred = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for writes of the sizes given, and
    // the descriptor is a socket that outlives the call.
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut cred).cast(),
            &mut len,
        )
    };
    if result == 0 {
        Ok(cred.uid)
    } else {
        Err(io::Error::last_os_error())
    }
}

/// The user id this process runs as.
pub fn this_uid() -> u32 {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { libc::getuid() }
}

/// Whether `name`'s holder runs as this user; `None` when that can't be
/// told (it is between binding and listening, or its queue is full).
pub fn holder_is_this_user(name: &str) -> Option<bool> {
    let stream = connect(name).ok()?;
    Some(peer_uid(&stream).ok()? == this_uid())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A listener on `name` that never accepts, with its queue full: Linux
    /// queues one connection past a backlog of 0, and refuses the next.
    pub(crate) fn full_listener(name: &str) -> (OwnedFd, Vec<UnixStream>) {
        let (addr, len) = abstract_address(name).unwrap();
        // SAFETY: plain socket calls on a descriptor owned below.
        let fd = unsafe {
            let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            assert!(fd >= 0, "{}", io::Error::last_os_error());
            OwnedFd::from_raw_fd(fd)
        };
        // SAFETY: `addr` is a valid sockaddr_un of `len` bytes.
        unsafe {
            assert_eq!(libc::bind(fd.as_raw_fd(), (&raw const addr).cast(), len), 0);
            assert_eq!(libc::listen(fd.as_raw_fd(), 0), 0);
        }
        let mut queued = vec![];
        loop {
            match connect(name) {
                Ok(stream) => queued.push(stream),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("filling the queue: {e}"),
            }
            assert!(queued.len() <= 8, "the queue never filled");
        }
        (fd, queued)
    }

    /// A holder whose queue is full (filled by anyone) is unknown, at once:
    /// the probe never waits for an accept that does not come.
    #[test]
    fn a_full_queue_leaves_the_holder_unknown_at_once() {
        let name = format!("conduit-test.{:016x}", rand::random::<u64>());
        let (_listener, _queued) = full_listener(&name);
        assert_eq!(holder_is_this_user(&name), None);
        assert_eq!(
            connect(&name).map(|_| ()).map_err(|e| e.kind()),
            Err(io::ErrorKind::WouldBlock)
        );
    }

    #[test]
    fn a_holder_with_room_is_known() {
        let name = format!("conduit-test.{:016x}", rand::random::<u64>());
        let _listener = bind(&name).unwrap();
        assert_eq!(holder_is_this_user(&name), Some(true));
    }
}
