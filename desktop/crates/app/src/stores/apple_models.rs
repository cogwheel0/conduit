//! Apple's on-device model (`apple.*`): this window's part in it.
//!
//! The chat runs in the daemon, in the core's Direct engine and its Apple
//! adapter, as on the phone. The model is a Swift API, so it runs here:
//! each `apple.command` goes to the Swift engine
//! ([`crate::shell::apple_models`]), and its answers, and what a run did
//! (text, usage, the end, a tool call), go back as `apple.report`, in the
//! order the engine said them. Each time the window connects it says
//! whether this Mac has Apple's models (`ready`, said again while the
//! daemon's core is still starting and refuses it), which is when the daemon
//! offers the Apple On-Device connection, and which runs the engine still
//! has: runs end with the session that ran them, so after a reconnect the
//! daemon stops each one (its turn has already failed). After a gap in the
//! events it says `ready` again, so a run whose Cancel was lost stops too.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use conduit_daemon::protocol::{RpcErrorExt as _, codes};
use conduit_protocol::{
    AppleCommand, AppleCommandKind, AppleFailure, AppleReport, AppleReportKind, events, methods,
};
use futures::StreamExt as _;
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionEvent;
use super::rpc::Rpc;
use crate::shell::apple_models;

/// The events this store follows.
pub const EVENTS: &[&str] = &[events::APPLE_COMMAND];

/// The id of the stop this window puts to its own engine for a lost run:
/// never one of the daemon's (they count up from 1), so its answer stays
/// here.
const STOP_ID: i64 = -1;

/// How long a `ready` the daemon refused while its core starts waits
/// before it is said again (the client has already retried for its own
/// budget by then).
const READY_RETRY: std::time::Duration = std::time::Duration::from_secs(5);

pub struct AppleModelsStore {
    rpc: Rpc,
    _reports: Task<()>,
    /// The runs the engine started and has not ended, and the start
    /// commands not yet answered (by command id).
    runs: BTreeSet<String>,
    starting: BTreeMap<i64, String>,
    /// The number the last report of each run carried (from 1): the daemon
    /// ends a run whose numbers skip, so a report lost on the way never
    /// leaves a reply with words missing.
    numbers: BTreeMap<String, i64>,
    /// Runs a report of which never reached the daemon: stopped in the
    /// engine and ended at the daemon; what the engine still says of them
    /// is dropped, until it says they ended.
    lost: BTreeSet<String>,
    /// How many commands of each kind the engine was asked: for the E2E
    /// pass.
    pub asked: HashMap<AppleCommandKind, usize>,
    /// What went to the engine, in a store with none (tests).
    engine_log: Option<Vec<AppleCommand>>,
    /// Counts the daemon sessions: a `ready` said again belongs to its own.
    session: u64,
    /// The number the last report carried ([`AppleReport::order`]), given
    /// as it is sent: a send the connection tries again keeps its number,
    /// so the daemon knows a late copy of a `ready` from a newer one.
    order: i64,
}

impl AppleModelsStore {
    /// A store with no engine (view tests): nothing is installed, no report
    /// ever comes, and what would go to the engine is kept.
    #[cfg(test)]
    pub fn for_test(rpc: Rpc) -> Self {
        Self {
            rpc,
            _reports: Task::ready(()),
            runs: BTreeSet::new(),
            starting: BTreeMap::new(),
            numbers: BTreeMap::new(),
            lost: BTreeSet::new(),
            asked: HashMap::new(),
            engine_log: Some(vec![]),
            session: 0,
            order: 0,
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
                if this.update(cx, |s, cx| s.send(report, cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            rpc,
            _reports: task,
            runs: BTreeSet::new(),
            starting: BTreeMap::new(),
            numbers: BTreeMap::new(),
            lost: BTreeSet::new(),
            asked: HashMap::new(),
            engine_log: None,
            session: 0,
            order: 0,
        }
    }

    /// The window (re)connected: a new daemon session, told [`Self::ready`].
    fn on_connected(&mut self, cx: &mut Context<Self>) {
        self.session += 1;
        self.ready(self.session, cx);
    }

    /// Says whether this Mac has Apple's models, and which runs the engine
    /// still has (lost ones are not). The daemon takes it only once its
    /// core is up, and no event says when that is: refused meanwhile
    /// (`rpc.daemonUnavailable`), it is said again, with the runs as they
    /// are then, for as long as `session` is the daemon session.
    fn ready(&mut self, session: u64, cx: &mut Context<Self>) {
        let call = self.report_call(AppleReport {
            kind: Some(AppleReportKind::Ready),
            supported: Some(apple_models::supported()),
            runs: self.runs.iter().cloned().collect(),
            ..Default::default()
        });
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| match call.await {
                Ok(_) => {}
                Err(e) if e.is(codes::DAEMON_UNAVAILABLE) => {
                    log::info!("apple: ready refused while the core starts; saying it again");
                    cx.background_executor().timer(READY_RETRY).await;
                    let _ = this.update(cx, |s, cx| {
                        if s.session == session {
                            s.ready(session, cx);
                        }
                    });
                }
                Err(e) => log::debug!("apple.report (ready): {e}"),
            },
        )
        .detach();
    }

    /// Sends `report` numbered now: `Rpc::call` queues it at once, in the
    /// order of the numbers.
    fn report_call(
        &mut self,
        mut report: AppleReport,
    ) -> impl std::future::Future<
        Output = Result<conduit_protocol::OkResult, conduit_daemon::RpcError>,
    > + use<> {
        self.order += 1;
        report.order = Some(self.order);
        self.rpc.call::<methods::AppleReport>(&report)
    }

    /// What the window's connection says.
    fn on_connection(&mut self, event: &ConnectionEvent, cx: &mut Context<Self>) {
        match event {
            ConnectionEvent::Connected { .. } => self.on_connected(cx),
            // Events were lost: a Cancel among them would leave a run going
            // here. Saying `ready` again with the runs the engine has, as a
            // reconnect does, has the daemon stop any that ended there.
            ConnectionEvent::Gap => self.ready(self.session, cx),
            ConnectionEvent::Daemon(event) => {
                if let conduit_protocol::Event::AppleCommand(command) = event.as_ref() {
                    self.on_command(command, cx);
                }
            }
            ConnectionEvent::LocalDataReset { .. } => {}
        }
    }

    fn on_command(&mut self, command: &AppleCommand, cx: &mut Context<Self>) {
        *self.asked.entry(command.kind).or_default() += 1;
        if command.kind == AppleCommandKind::Start
            && let Some(request) = &command.request
        {
            self.runs.insert(request.run_id.clone());
            self.starting.insert(command.id, request.run_id.clone());
        }
        self.tell_engine(command, cx);
    }

    fn tell_engine(&mut self, command: &AppleCommand, cx: &mut Context<Self>) {
        if let Some(log) = &mut self.engine_log {
            log.push(command.clone());
            return;
        }
        match serde_json::to_string(command) {
            Ok(json) => apple_models::command(&json),
            Err(e) => self.send(
                AppleReport {
                    id: Some(command.id),
                    ok: false,
                    error: Some(e.to_string()),
                    ..Default::default()
                },
                cx,
            ),
        }
    }

    /// Sends a report now: `Rpc::call` queues it at once, so reports reach
    /// the daemon in the order the engine gave them. A run's reports are
    /// numbered; one that never reaches the daemon loses its run
    /// ([`Self::lose`]).
    fn send(&mut self, mut report: AppleReport, cx: &mut Context<Self>) {
        // The answer to this window's own stop of a lost run.
        if report.id == Some(STOP_ID) {
            return;
        }
        let run = match report.kind {
            Some(
                AppleReportKind::Content
                | AppleReportKind::Usage
                | AppleReportKind::ToolCall
                | AppleReportKind::Done
                | AppleReportKind::Failed,
            ) => report.run_id.clone(),
            _ => None,
        };
        if let Some(run) = &run {
            let ended = matches!(
                report.kind,
                Some(AppleReportKind::Done | AppleReportKind::Failed)
            );
            if self.lost.contains(run) {
                if ended {
                    self.lost.remove(run);
                }
                return;
            }
            let number = self.numbers.entry(run.clone()).or_default();
            *number += 1;
            report.seq = Some(*number);
            if ended {
                self.runs.remove(run);
                self.numbers.remove(run);
            }
        }
        // A start the engine refused never ran; one whose answer is lost
        // is a lost run too.
        let mut started = None;
        if let Some(r) = report.id.and_then(|id| self.starting.remove(&id)) {
            if report.ok {
                started = Some(r);
            } else {
                self.runs.remove(&r);
                self.numbers.remove(&r);
            }
        }
        let concerns = run.or(started);
        let call = self.report_call(report);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                log::debug!("apple.report: {e}");
                if let Some(run) = concerns {
                    let _ = this.update(cx, |s, cx| s.lose(run, cx));
                }
            }
        })
        .detach();
    }

    /// A report of `run` never reached the daemon: the reply would miss
    /// words, or the engine wait on a tool result that never comes. The
    /// engine stops the run (its tool waits too), and the daemon is told it
    /// failed, unnumbered so it ends whatever it took. Once per run.
    fn lose(&mut self, run: String, cx: &mut Context<Self>) {
        if self.lost.contains(&run) {
            return;
        }
        self.numbers.remove(&run);
        if self.runs.remove(&run) {
            self.lost.insert(run.clone());
            self.tell_engine(
                &AppleCommand {
                    id: STOP_ID,
                    kind: AppleCommandKind::Cancel,
                    model: None,
                    request: None,
                    run_id: Some(run.clone()),
                    call_id: None,
                    tool_content: None,
                    tool_cancelled: false,
                },
                cx,
            );
        }
        let call = self.report_call(AppleReport {
            kind: Some(AppleReportKind::Failed),
            run_id: Some(run),
            failure: Some(AppleFailure::Failed),
            ..Default::default()
        });
        cx.spawn(async move |_: WeakEntity<Self>, _: &mut AsyncApp| {
            if let Err(e) = call.await {
                // The run is not in the next `ready`: the daemon ends it then.
                log::debug!("apple.report (failed): {e}");
            }
        })
        .detach();
    }
}

pub fn wire(stores: &Stores, cx: &mut App) {
    stores
        .connection
        .update(cx, |c, _| c.subscribe("apple", EVENTS, vec![]));
    let s = stores.apple.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| {
        s.update(cx, |s, cx| s.on_connection(event, cx))
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{AppleGeneration, AppleModelKind, OkResult, methods};
    use gpui_kit::{AppContext as _, Entity, TestAppContext};
    use serde_json::Value;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn start(id: i64, run: &str) -> AppleCommand {
        AppleCommand {
            id,
            kind: AppleCommandKind::Start,
            model: Some(AppleModelKind::OnDevice),
            request: Some(
                serde_json::from_value::<AppleGeneration>(serde_json::json!({
                    "runId": run,
                    "model": "onDevice",
                }))
                .unwrap(),
            ),
            run_id: None,
            call_id: None,
            tool_content: None,
            tool_cancelled: false,
        }
    }

    fn content(run: &str, text: &str) -> AppleReport {
        AppleReport {
            kind: Some(AppleReportKind::Content),
            run_id: Some(run.into()),
            content: Some(text.into()),
            ..Default::default()
        }
    }

    fn sent(daemon: &FakeDaemon) -> Vec<Value> {
        daemon.calls::<methods::AppleReport>()
    }

    #[gpui_kit::test]
    fn a_report_that_never_reaches_the_daemon_stops_its_run_and_ends_it_there(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AppleReport>(OkResult { ok: true });
        // The start's answer and the first words arrive; the next words are
        // lost with the socket.
        daemon
            .once::<methods::AppleReport>(Ok(OkResult { ok: true }))
            .once::<methods::AppleReport>(Ok(OkResult { ok: true }))
            .once::<methods::AppleReport>(Err(conduit_daemon::protocol::error(
                "transport.disconnected",
                "the socket dropped",
            )));
        let store: Entity<AppleModelsStore> = cx.new(|_| AppleModelsStore::for_test(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_command(&start(1, "run-1"), cx);
            s.send(
                AppleReport {
                    id: Some(1),
                    ..Default::default()
                },
                cx,
            );
            s.send(content("run-1", "One "), cx);
            s.send(content("run-1", "two "), cx);
        });
        cx.run_until_parked();
        // What the engine still says of the run never reaches the daemon.
        store.update(cx, |s, cx| {
            s.send(content("run-1", "three."), cx);
            s.send(
                AppleReport {
                    kind: Some(AppleReportKind::Done),
                    run_id: Some("run-1".into()),
                    ..Default::default()
                },
                cx,
            );
        });
        cx.run_until_parked();

        let sent = sent(&daemon);
        let seqs: Vec<Option<i64>> = sent.iter().map(|r| r["seq"].as_i64()).collect();
        assert_eq!(seqs, vec![None, Some(1), Some(2), None], "{sent:?}");
        // Every report is numbered as it is sent, whatever its kind.
        let orders: Vec<Option<i64>> = sent.iter().map(|r| r["order"].as_i64()).collect();
        let first = orders[0].expect("numbered");
        assert_eq!(
            orders,
            (first..first + 4).map(Some).collect::<Vec<_>>(),
            "{sent:?}"
        );
        assert_eq!(sent[3]["kind"], "failed");
        assert_eq!(sent[3]["runId"], "run-1");
        assert!(
            !sent
                .iter()
                .any(|r| r["content"] == "three." || r["kind"] == "done"),
            "{sent:?}"
        );
        // The engine was told to stop it (a tool wait included).
        store.read_with(cx, |s, _| {
            let log = s.engine_log.as_ref().unwrap();
            let stop = log.last().unwrap();
            assert_eq!(stop.kind, AppleCommandKind::Cancel);
            assert_eq!(stop.run_id.as_deref(), Some("run-1"));
            assert_eq!(stop.id, STOP_ID);
            assert!(s.runs.is_empty(), "not kept for the next ready");
        });
    }

    /// Events were lost (a gap): a Cancel among them would leave the run
    /// going here. The window says `ready` again with the runs its engine
    /// has, as on a reconnect, so the daemon stops any that ended there.
    #[gpui_kit::test]
    fn after_a_gap_the_window_tells_the_daemon_which_runs_it_still_has(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AppleReport>(OkResult { ok: true });
        let store: Entity<AppleModelsStore> = cx.new(|_| AppleModelsStore::for_test(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_command(&start(1, "run-1"), cx);
            s.send(
                AppleReport {
                    id: Some(1),
                    ..Default::default()
                },
                cx,
            );
        });
        cx.run_until_parked();
        let before = sent(&daemon).len();
        store.update(cx, |s, cx| s.on_connection(&ConnectionEvent::Gap, cx));
        cx.run_until_parked();
        let sent = sent(&daemon);
        assert_eq!(sent.len(), before + 1, "nothing said after the gap");
        let ready = sent.last().unwrap();
        assert_eq!(ready["kind"], "ready");
        assert_eq!(ready["runs"], serde_json::json!(["run-1"]));
    }

    /// The core is still starting when the window connects: `ready` is
    /// refused (`rpc.daemonUnavailable`) and no event follows once it is
    /// up. The window says it again, with the runs it has then, until it
    /// lands; not for a session that has ended.
    #[gpui_kit::test]
    fn a_ready_refused_while_the_core_starts_is_said_again(cx: &mut TestAppContext) {
        let unavailable = || {
            Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "the core is not up yet",
            ))
        };
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AppleReport>(OkResult { ok: true });
        daemon
            .once::<methods::AppleReport>(unavailable())
            .once::<methods::AppleReport>(unavailable());
        let store: Entity<AppleModelsStore> = cx.new(|_| AppleModelsStore::for_test(daemon.rpc()));
        store.update(cx, |s, cx| s.on_connected(cx));
        cx.run_until_parked();
        assert_eq!(sent(&daemon).len(), 1);
        for _ in 0..3 {
            cx.executor()
                .advance_clock(std::time::Duration::from_secs(60));
            cx.run_until_parked();
        }
        let readies: Vec<Value> = sent(&daemon)
            .into_iter()
            .filter(|r| r["kind"] == "ready")
            .collect();
        assert_eq!(readies.len(), 3, "said once, refused twice, then landed");

        // A retry belongs to its session: once another one said `ready`,
        // the old one's retry says nothing.
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AppleReport>(OkResult { ok: true });
        daemon.once::<methods::AppleReport>(unavailable());
        let store: Entity<AppleModelsStore> = cx.new(|_| AppleModelsStore::for_test(daemon.rpc()));
        store.update(cx, |s, cx| s.on_connected(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.on_connected(cx));
        cx.run_until_parked();
        for _ in 0..3 {
            cx.executor()
                .advance_clock(std::time::Duration::from_secs(60));
            cx.run_until_parked();
        }
        assert_eq!(sent(&daemon).len(), 2);
    }

    #[gpui_kit::test]
    fn a_tool_call_that_never_reaches_the_daemon_stops_its_run(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AppleReport>(OkResult { ok: true });
        daemon
            .once::<methods::AppleReport>(Ok(OkResult { ok: true }))
            .once::<methods::AppleReport>(Err(conduit_daemon::protocol::error(
                "transport.disconnected",
                "the socket dropped",
            )));
        let store: Entity<AppleModelsStore> = cx.new(|_| AppleModelsStore::for_test(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.on_command(&start(1, "run-1"), cx);
            s.send(
                AppleReport {
                    id: Some(1),
                    ..Default::default()
                },
                cx,
            );
            s.send(
                AppleReport {
                    kind: Some(AppleReportKind::ToolCall),
                    run_id: Some("run-1".into()),
                    call_id: Some("call-1".into()),
                    tool_name: Some("garden_lookup".into()),
                    arguments_json: Some("{}".into()),
                    ..Default::default()
                },
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let stop = s.engine_log.as_ref().unwrap().last().unwrap().clone();
            assert_eq!(stop.kind, AppleCommandKind::Cancel);
            assert_eq!(stop.run_id.as_deref(), Some("run-1"));
        });
        assert_eq!(sent(&daemon).last().unwrap()["kind"], "failed");
    }
}
