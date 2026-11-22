//! Linux abstract Unix sockets: names the kernel keeps, not files, so they
//! need no folder (and no `HOME`), and they go away with the process that
//! bound them. Any user can bind any name, so a name's holder is checked by
//! its peer credentials before it is trusted.

use std::io;
use std::os::fd::AsRawFd;
use std::os::linux::net::SocketAddrExt as _;
use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};

/// Binds (and listens on) `name`; `AddrInUse` while another process holds it.
pub fn bind(name: &str) -> io::Result<UnixListener> {
    UnixListener::bind_addr(&SocketAddr::from_abstract_name(name.as_bytes())?)
}

pub fn connect(name: &str) -> io::Result<UnixStream> {
    UnixStream::connect_addr(&SocketAddr::from_abstract_name(name.as_bytes())?)
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
