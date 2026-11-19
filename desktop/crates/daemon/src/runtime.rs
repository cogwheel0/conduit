//! The tokio runtime the supervisor, the RPC connection and HTTP calls run
//! on. It owns its own worker threads, so the UI thread never runs tokio.

use std::sync::OnceLock;

use tokio::runtime::{Builder, Handle, Runtime};

/// A process-wide runtime with two named workers, started on first use.
pub fn shared() -> Handle {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("conduit-daemon-io")
            .enable_all()
            .build()
            .expect("start the daemon I/O runtime")
    })
    .handle()
    .clone()
}
