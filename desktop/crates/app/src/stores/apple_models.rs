//! Apple's on-device model (`apple.*`): this window's part in it.
//!
//! The chat runs in the daemon, in the core's Direct engine and its Apple
//! adapter, as on the phone. The model is a Swift API, so it runs here:
//! each `apple.command` goes to the Swift engine
//! ([`crate::shell::apple_models`]), and its answers, and what a run did
//! (text, usage, the end, a tool call), go back as `apple.report`, in the
//! order the engine said them. Each time the window connects it says
//! whether this Mac has Apple's models (`ready`), which is when the daemon
//! offers the Apple On-Device connection, and which runs the engine still
//! has: a socket that came back keeps them going.

use std::collections::{BTreeMap, BTreeSet};

use conduit_protocol::{
    AppleCommand, AppleCommandKind, AppleReport, AppleReportKind, events, methods,
};
use futures::StreamExt as _;
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::rpc::Rpc;
use crate::shell::apple_models;

/// The events this store follows.
pub const EVENTS: &[&str] = &[events::APPLE_COMMAND];

pub struct AppleModelsStore {
    rpc: Rpc,
    _reports: Task<()>,
    /// The runs the engine started and has not ended, and the start
    /// commands not yet answered (by command id).
    runs: BTreeSet<String>,
    starting: BTreeMap<i64, String>,
    /// What the engine was asked, in order, and the text its runs wrote:
    /// for the E2E pass.
    pub asked: Vec<AppleCommandKind>,
    pub written: String,
}

impl AppleModelsStore {
    /// A store with no engine (view tests): nothing is installed, and no
    /// report ever comes.
    #[cfg(test)]
    pub fn for_test(rpc: Rpc) -> Self {
        Self {
            rpc,
            _reports: Task::ready(()),
            runs: BTreeSet::new(),
            starting: BTreeMap::new(),
            asked: vec![],
            written: String::new(),
        }
    }

    pub fn new(rpc: Rpc, cx: &mut Context<Self>) -> Self {
        let mut reports = apple_models::install();
        let task = cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            while let Some(json) = reports.next().await {
                let report = match serde_json::from_str::<AppleReport>(&json) {
                    Ok(report) => report,
                    Err(e) => {
                        log::warn!("apple: an unreadable report from the engine: {e}");
                        continue;
                    }
                };
                if this.update(cx, |s, _| s.send(report)).is_err() {
                    break;
                }
            }
        });
        Self {
            rpc,
            _reports: task,
            runs: BTreeSet::new(),
            starting: BTreeMap::new(),
            asked: vec![],
            written: String::new(),
        }
    }

    /// The window (re)connected: says whether this Mac has Apple's models.
    fn on_connected(&mut self) {
        self.send(AppleReport {
            kind: Some(AppleReportKind::Ready),
            supported: Some(apple_models::supported()),
            runs: self.runs.iter().cloned().collect(),
            ..Default::default()
        });
    }

    fn on_command(&mut self, command: &AppleCommand) {
        self.asked.push(command.kind);
        if command.kind == AppleCommandKind::Start
            && let Some(request) = &command.request
        {
            self.runs.insert(request.run_id.clone());
            self.starting.insert(command.id, request.run_id.clone());
        }
        match serde_json::to_string(command) {
            Ok(json) => apple_models::command(&json),
            Err(e) => self.send(AppleReport {
                id: Some(command.id),
                ok: false,
                error: Some(e.to_string()),
                ..Default::default()
            }),
        }
    }

    /// Sends a report now: `Rpc::call` queues it at once, so reports reach
    /// the daemon in the order the engine gave them.
    fn send(&mut self, report: AppleReport) {
        match report.kind {
            Some(AppleReportKind::Content) => {
                if let Some(text) = &report.content {
                    self.written.push_str(text);
                }
            }
            Some(AppleReportKind::Done | AppleReportKind::Failed) => {
                if let Some(run) = &report.run_id {
                    self.runs.remove(run);
                }
            }
            _ => {}
        }
        // A start the engine refused never ran.
        if let Some(run) = report.id.and_then(|id| self.starting.remove(&id))
            && !report.ok
        {
            self.runs.remove(&run);
        }
        let call = self.rpc.call::<methods::AppleReport>(&report);
        conduit_daemon::runtime::shared().spawn(async move {
            if let Err(e) = call.await {
                log::debug!("apple.report: {e}");
            }
        });
    }
}

pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("apple", EVENTS, vec![]));
    let s = stores.apple.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        use super::connection::ConnectionEvent;
        match event {
            ConnectionEvent::Connected { .. } => s.update(cx, |s, _| s.on_connected()),
            ConnectionEvent::Daemon(event) => {
                if let conduit_protocol::Event::AppleCommand(command) = event.as_ref() {
                    s.update(cx, |s, _| s.on_command(command));
                }
            }
            ConnectionEvent::Gap | ConnectionEvent::LocalDataReset { .. } => {}
        }
    })
    .detach();
}
