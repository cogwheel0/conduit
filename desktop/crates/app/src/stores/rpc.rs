//! The seam every store calls the daemon through.
//!
//! Stores hold an [`Rpc`], not the socket client: in the app it wraps the
//! process's one [`RpcClient`]; in tests a [`fake::FakeDaemon`] answers from
//! a script and records what it was asked. Calls are typed by the generated
//! method markers (`rpc.call::<methods::AccountsList>(&NoParams)`), and the
//! futures borrow nothing, so a store can await them in `cx.spawn`.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use conduit_daemon::protocol::{RpcMethod, codes, error};
use conduit_daemon::{RpcClient, RpcError};
use serde_json::Value;

/// A boxed, `'static` call.
pub type CallFuture = Pin<Box<dyn Future<Output = Result<Value, RpcError>> + Send>>;

/// Something that answers JSON-RPC calls by name.
pub trait Daemon: Send + Sync + 'static {
    fn call_value(&self, method: &'static str, params: Value) -> CallFuture;
}

impl Daemon for RpcClient {
    fn call_value(&self, method: &'static str, params: Value) -> CallFuture {
        Box::pin(RpcClient::call_value(self, method, params))
    }
}

/// A cheap, cloneable handle to the daemon.
#[derive(Clone)]
pub struct Rpc(Arc<dyn Daemon>);

impl Rpc {
    pub fn new(daemon: impl Daemon) -> Self {
        Self(Arc::new(daemon))
    }

    /// Calls `M` with `params` and decodes its result.
    pub fn call<M: RpcMethod>(
        &self,
        params: &M::Params,
    ) -> impl Future<Output = Result<M::Result, RpcError>> + Send + 'static + use<M>
    where
        M::Result: Send + 'static,
    {
        let call = serde_json::to_value(params)
            .map(|p| self.0.call_value(M::NAME, p))
            .map_err(|e| error(codes::INVALID_PARAMS, format!("{}: {e}", M::NAME)));
        async move {
            let value = call?.await?;
            serde_json::from_value::<M::Result>(value)
                .map_err(|e| error(codes::DECODE, format!("{}: {e}", M::NAME)))
        }
    }
}

/// A scripted daemon for store tests.
#[cfg(test)]
pub mod fake {
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;

    use super::*;

    type Handler = Box<dyn Fn(&Value) -> Result<Value, RpcError> + Send + Sync>;

    #[derive(Default)]
    struct State {
        /// One-shot answers, used before the standing handler.
        queued: HashMap<&'static str, VecDeque<Result<Value, RpcError>>>,
        handlers: HashMap<&'static str, Handler>,
        calls: Vec<(&'static str, Value)>,
    }

    /// Answers each method from its queue, else its handler, else
    /// `rpc.methodNotFound`. Every call is recorded.
    #[derive(Clone, Default)]
    pub struct FakeDaemon(Arc<Mutex<State>>);

    impl FakeDaemon {
        pub fn new() -> Self {
            Self::default()
        }

        pub fn rpc(&self) -> Rpc {
            Rpc::new(self.clone())
        }

        /// Answers every `method` call with `f(params)`.
        pub fn on<M: RpcMethod>(
            &self,
            f: impl Fn(&Value) -> Result<Value, RpcError> + Send + Sync + 'static,
        ) -> &Self {
            self.0.lock().unwrap().handlers.insert(M::NAME, Box::new(f));
            self
        }

        /// Answers every `method` call with `result`.
        pub fn returns<M: RpcMethod>(&self, result: M::Result) -> &Self {
            let value = serde_json::to_value(result).unwrap();
            self.on::<M>(move |_| Ok(value.clone()))
        }

        /// Answers the next `method` call with `result`, once.
        pub fn once<M: RpcMethod>(&self, result: Result<M::Result, RpcError>) -> &Self {
            let value = result.map(|r| serde_json::to_value(r).unwrap());
            self.0
                .lock()
                .unwrap()
                .queued
                .entry(M::NAME)
                .or_default()
                .push_back(value);
            self
        }

        /// The params of every `method` call so far.
        pub fn calls<M: RpcMethod>(&self) -> Vec<Value> {
            self.0
                .lock()
                .unwrap()
                .calls
                .iter()
                .filter(|(m, _)| *m == M::NAME)
                .map(|(_, p)| p.clone())
                .collect()
        }

        /// Method names in call order.
        pub fn log(&self) -> Vec<&'static str> {
            self.0
                .lock()
                .unwrap()
                .calls
                .iter()
                .map(|(m, _)| *m)
                .collect()
        }
    }

    impl Daemon for FakeDaemon {
        fn call_value(&self, method: &'static str, params: Value) -> CallFuture {
            let mut state = self.0.lock().unwrap();
            state.calls.push((method, params.clone()));
            let answer = match state.queued.get_mut(method).and_then(VecDeque::pop_front) {
                Some(answer) => answer,
                None => match state.handlers.get(method) {
                    Some(handler) => handler(&params),
                    None => Err(error(codes::METHOD_NOT_FOUND, method)),
                },
            };
            Box::pin(async move { answer })
        }
    }
}
