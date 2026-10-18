//! The accept loop both listeners run on.
//!
//! axum's own `serve` runs hyper without a timer, which turns hyper's header
//! timeout off, and accepts every connection that arrives. This loop drives
//! hyper itself, so that:
//!
//! - an HTTP/1 client has `header_read_timeout` to send a request's headers,
//!   and to start the next request on a kept-alive connection;
//! - any connection must start its first request within `header_read_timeout`
//!   too, which catches clients that connect and send nothing;
//! - a connection with no request in progress for `idle_timeout` is closed;
//! - HTTP/2 clients are pinged, and dropped when they stop answering;
//! - at most `max_connections` are open at once;
//! - on shutdown, requests in progress get `drain_deadline` to finish, and
//!   connections still open after that are dropped.

use std::future::Future;
use std::net::SocketAddr;
use std::pin::pin;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::Request;
use axum::Router;
use hyper::body::Incoming;
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use hyper_util::server::conn::auto;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{watch, Notify, OwnedSemaphorePermit, Semaphore};
use tower_service::Service;

use crate::config::ConnectionLimits;

type Builder = auto::Builder<TokioExecutor>;

pub(crate) async fn serve(
    listener: TcpListener,
    router: Router,
    limits: ConnectionLimits,
    shutdown: impl Future<Output = ()>,
) {
    let builder = Arc::new(builder(&limits));
    let max = usize::try_from(limits.max_connections)
        .unwrap_or(usize::MAX)
        .min(Semaphore::MAX_PERMITS);
    let slots = Arc::new(Semaphore::new(max));
    let (stop, stopped) = watch::channel(false);
    let mut shutdown = pin!(shutdown);

    loop {
        // A slot first, then a connection: over the cap, new connections
        // wait in the kernel's accept queue rather than in this process.
        let slot = tokio::select! {
            () = &mut shutdown => break,
            slot = slots.clone().acquire_owned() => slot.expect("the semaphore is never closed"),
        };
        let (stream, peer) = tokio::select! {
            () = &mut shutdown => break,
            accepted = listener.accept() => match accepted {
                Ok(accepted) => accepted,
                Err(err) => {
                    accept_failed(err).await;
                    continue;
                }
            },
        };
        tokio::spawn(connection(
            builder.clone(),
            router.clone(),
            stream,
            peer,
            limits,
            stopped.clone(),
            slot,
        ));
    }

    drop(listener);
    let _ = stop.send(true);
    // Every connection holds a slot until it closes, so once all of them are
    // free the drain is over. Connections drop themselves at the deadline; the
    // extra second lets their tasks wind down.
    let all = u32::try_from(max).unwrap_or(u32::MAX);
    let _ = tokio::time::timeout(
        limits.drain_deadline + Duration::from_secs(1),
        slots.acquire_many(all),
    )
    .await;
}

fn builder(limits: &ConnectionLimits) -> Builder {
    let mut builder = auto::Builder::new(TokioExecutor::new());
    builder
        .http1()
        .timer(TokioTimer::new())
        .header_read_timeout(limits.header_read_timeout);
    builder
        .http2()
        .timer(TokioTimer::new())
        .keep_alive_interval(limits.keep_alive_interval)
        .keep_alive_timeout(limits.keep_alive_timeout);
    builder
}

async fn connection(
    builder: Arc<Builder>,
    router: Router,
    stream: TcpStream,
    peer: SocketAddr,
    limits: ConnectionLimits,
    mut stopped: watch::Receiver<bool>,
    _slot: OwnedSemaphorePermit,
) {
    let activity = Arc::new(Activity::new());
    let service = {
        let activity = activity.clone();
        hyper::service::service_fn(move |mut request: Request<Incoming>| {
            request.extensions_mut().insert(ConnectInfo(peer));
            let busy = activity.begin();
            let response = router.clone().call(request.map(Body::new));
            async move {
                let response = response.await;
                drop(busy);
                response
            }
        })
    };
    let mut conn = pin!(builder.serve_connection(TokioIo::new(stream), service));

    tokio::select! {
        // Closed by the client, or by hyper (a header timeout, a dead
        // HTTP/2 peer, a protocol error). Nothing about it is logged.
        _ = conn.as_mut() => return,
        () = activity.idle(limits.header_read_timeout, limits.idle_timeout) => {}
        _ = stopped.wait_for(|stop| *stop) => {}
    }
    // HTTP/1 finishes the request in progress, if any, then closes; HTTP/2
    // sends GOAWAY and finishes its open streams. Neither may take longer than
    // the deadline.
    conn.as_mut().graceful_shutdown();
    let _ = tokio::time::timeout(limits.drain_deadline, conn).await;
}

/// The relay itself is fine, but cannot take a connection right now; most
/// likely it is out of file descriptors. Waiting gives some a chance to close.
async fn accept_failed(err: std::io::Error) {
    use std::io::ErrorKind;
    if matches!(
        err.kind(),
        ErrorKind::ConnectionRefused | ErrorKind::ConnectionAborted | ErrorKind::ConnectionReset
    ) {
        return;
    }
    tracing::error!("cannot accept connections: {err}");
    tokio::time::sleep(Duration::from_secs(1)).await;
}

/// Whether a connection has a request in progress, and since when it has not.
struct Activity {
    state: Mutex<ActivityState>,
    /// Woken when the last request in progress finishes.
    finished: Notify,
}

struct ActivityState {
    in_progress: usize,
    /// When the last request finished, or when the connection opened.
    since: Instant,
    started_any: bool,
}

/// A request in progress on a connection, for as long as it lives.
struct Busy(Arc<Activity>);

impl Activity {
    fn new() -> Self {
        Self {
            state: Mutex::new(ActivityState {
                in_progress: 0,
                since: Instant::now(),
                started_any: false,
            }),
            finished: Notify::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, ActivityState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn begin(self: &Arc<Self>) -> Busy {
        let mut state = self.lock();
        state.in_progress += 1;
        state.started_any = true;
        Busy(self.clone())
    }

    /// Resolves once the connection has gone `first` without starting a
    /// request, or `between` with nothing in progress after one finished.
    async fn idle(&self, first: Duration, between: Duration) {
        loop {
            let deadline = {
                let state = self.lock();
                (state.in_progress == 0)
                    .then(|| state.since + if state.started_any { between } else { first })
            };
            // A request finishing moves the deadline, so look again then.
            // `notify_one` keeps a wakeup for a waiter that has not arrived
            // yet, so one that lands before the await is not lost.
            match deadline {
                Some(deadline) if deadline <= Instant::now() => return,
                Some(deadline) => tokio::select! {
                    () = tokio::time::sleep_until(deadline.into()) => {}
                    () = self.finished.notified() => {}
                },
                None => self.finished.notified().await,
            }
        }
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        let mut state = self.0.lock();
        state.in_progress -= 1;
        if state.in_progress == 0 {
            state.since = Instant::now();
            drop(state);
            self.0.finished.notify_one();
        }
    }
}
