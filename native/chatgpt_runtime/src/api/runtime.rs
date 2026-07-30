use std::collections::{HashMap, VecDeque};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::time::Duration;

use base64::Engine as _;
use codex_app_server_client::{
    InProcessAppServerClient, InProcessAppServerRequestHandle, InProcessClientStartArgs,
    InProcessServerEvent,
};
use codex_app_server_protocol::{ClientRequest, ServerNotification};
use codex_arg0::Arg0DispatchPaths;
use codex_config::{CloudConfigBundleLoader, LoaderOverrides};
use codex_core::config::ConfigBuilder;
use codex_exec_server::EnvironmentManager;
use codex_feedback::CodexFeedback;
use codex_login::{
    AuthCredentialsStoreMode, AuthDotJson, AuthKeyringBackendKind, load_auth_dot_json, save_auth,
};
use codex_protocol::protocol::SessionSource;
use flutter_rust_bridge::frb;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::{Instant, sleep_until, timeout};
use uuid::Uuid;

use super::contract::*;
use crate::frb_generated::StreamSink;

const AUTH_ACK_TIMEOUT: Duration = Duration::from_secs(30);
const RPC_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const DELTA_FLUSH_INTERVAL: Duration = Duration::from_millis(16);
const DELTA_FLUSH_BYTES: usize = 8 * 1024;
const ACTIVE_RUN_IDLE_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const ACTIVE_RUN_WATCHDOG_INTERVAL: Duration = Duration::from_secs(30);
const MAX_ACTIVE_RUNS: usize = 2;
const ALLOWED_RPC_METHODS: &[&str] = &[
    "account/login/cancel",
    "account/login/start",
    "account/logout",
    "account/read",
    "model/list",
    "thread/fork",
    "thread/resume",
    "thread/start",
    "turn/interrupt",
    "turn/start",
];
const GENERAL_CHAT_INSTRUCTIONS: &str = "You are ChatGPT inside Conduit, a general-purpose chat client. Answer the user's request directly. Do not inspect or modify files, execute shell commands, apply patches, use MCP, ask for coding approvals, or access a workspace. Web search and image generation may be used only when the client explicitly enables them.";

static NEXT_REQUEST_ID: AtomicI64 = AtomicI64::new(1);
static RUNTIME: LazyLock<Mutex<Option<RuntimeHandle>>> = LazyLock::new(|| Mutex::new(None));
static RUNTIME_LIFECYCLE: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

#[derive(Clone)]
struct EventHub {
    epoch: u64,
    sequence: Arc<AtomicU64>,
    delivery: Arc<Mutex<()>>,
    subscribers: Arc<Mutex<Vec<mpsc::Sender<RuntimeEvent>>>>,
}

impl EventHub {
    fn new(epoch: u64) -> Self {
        Self {
            epoch,
            sequence: Arc::new(AtomicU64::new(0)),
            delivery: Arc::new(Mutex::new(())),
            subscribers: Arc::new(Mutex::new(Vec::new())),
        }
    }

    async fn subscribe(&self) -> mpsc::Receiver<RuntimeEvent> {
        let (tx, rx) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        self.subscribers.lock().await.push(tx);
        rx
    }

    async fn emit(&self, mut event: RuntimeEvent) {
        // Serializing numbering and delivery keeps sequence order identical to
        // subscriber order even when independent tasks emit concurrently.
        let _delivery = self.delivery.lock().await;
        event.client_epoch = self.epoch;
        event.sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
        self.subscribers.lock().await.retain(|subscriber| {
            match subscriber.try_send(event.clone()) {
                Ok(()) => true,
                Err(TrySendError::Closed(_)) => false,
                Err(TrySendError::Full(_)) => {
                    // A stale or stalled Dart isolate must not block auth
                    // acknowledgements or the native event pump. Removing the
                    // sender closes this subscriber with an explicit delivery
                    // error from runtime_events.
                    tracing::warn!(
                        sequence = event.sequence,
                        "native event subscriber exceeded its bounded queue"
                    );
                    false
                }
            }
        });
    }
}

struct PendingAuthMutation {
    expected_hash: Option<String>,
    acknowledgement: oneshot::Sender<bool>,
}

struct RuntimeHandle {
    epoch: u64,
    request: InProcessAppServerRequestHandle,
    hub: EventHub,
    shutdown: mpsc::Sender<oneshot::Sender<()>>,
    codex_home: PathBuf,
    committed_auth_hash: Arc<Mutex<Option<String>>>,
    auth_persistence: Arc<Mutex<()>>,
    pending_auth: Arc<Mutex<HashMap<String, PendingAuthMutation>>>,
    active_login_id: Arc<Mutex<Option<String>>>,
    turn_to_run: Arc<Mutex<HashMap<String, String>>>,
    scheduler: Arc<Mutex<TurnScheduler>>,
}

#[derive(Clone)]
struct EventContext {
    hub: EventHub,
    codex_home: PathBuf,
    committed_auth_hash: Arc<Mutex<Option<String>>>,
    auth_persistence: Arc<Mutex<()>>,
    pending_auth: Arc<Mutex<HashMap<String, PendingAuthMutation>>>,
    active_login_id: Arc<Mutex<Option<String>>>,
    turn_to_run: Arc<Mutex<HashMap<String, String>>>,
    scheduler: Arc<Mutex<TurnScheduler>>,
}

#[derive(Default)]
#[frb(ignore)]
struct TurnScheduler {
    active_by_thread: HashMap<String, ActiveRun>,
    queued: VecDeque<QueuedRun>,
    queued_input_bytes: usize,
}

struct ActiveRun {
    run_id: String,
    turn_id: Option<String>,
    cancellation_requested: bool,
    last_activity: Instant,
}

struct QueuedRun {
    run_id: String,
    request: TurnRequest,
    encoded_inputs: Vec<Value>,
    encoded_input_bytes: usize,
}

impl TurnScheduler {
    fn enqueue(&mut self, queued: QueuedRun) -> Result<(), BridgeError> {
        if self.queued.len() >= MAX_QUEUED_TURNS {
            return Err(BridgeError::new(
                BridgeErrorKind::RateLimit,
                "too many ChatGPT turns are queued",
            ));
        }
        let next_bytes = self
            .queued_input_bytes
            .checked_add(queued.encoded_input_bytes)
            .ok_or_else(|| {
                BridgeError::new(BridgeErrorKind::RateLimit, "queued input size overflow")
            })?;
        if next_bytes > MAX_QUEUED_INPUT_BYTES {
            return Err(BridgeError::new(
                BridgeErrorKind::RateLimit,
                "queued ChatGPT inputs exceed the memory limit",
            ));
        }
        self.queued_input_bytes = next_bytes;
        self.queued.push_back(queued);
        Ok(())
    }

    fn remove_queued(&mut self, position: usize) -> Option<QueuedRun> {
        let queued = self.queued.remove(position)?;
        self.queued_input_bytes = self
            .queued_input_bytes
            .saturating_sub(queued.encoded_input_bytes);
        Some(queued)
    }

    fn pop_queued(&mut self) -> Option<QueuedRun> {
        let queued = self.queued.pop_front()?;
        self.queued_input_bytes = self
            .queued_input_bytes
            .saturating_sub(queued.encoded_input_bytes);
        Some(queued)
    }

    fn drain_queued(&mut self) -> Vec<QueuedRun> {
        self.queued_input_bytes = 0;
        self.queued.drain(..).collect()
    }
}

#[derive(Clone)]
struct PendingDelta {
    event: RuntimeEvent,
    deadline: Instant,
}

#[frb(init)]
pub fn init_app() {
    // FRB's default initializer enables TRACE console logging. Codex HTTP
    // debug events can include response headers, so keep only crash backtrace
    // capture and route operational diagnostics through the sanitized bridge.
    flutter_rust_bridge::setup_backtrace();
}

pub fn bridge_protocol_version() -> u32 {
    BRIDGE_PROTOCOL_VERSION
}

pub async fn initialize_runtime(
    client_epoch: u64,
    data_directory: String,
    auth_snapshot: Option<Vec<u8>>,
) -> Result<(), BridgeError> {
    if client_epoch == 0 {
        return Err(BridgeError::new(
            BridgeErrorKind::InvalidInput,
            "client epoch must be non-zero",
        ));
    }
    let _lifecycle = RUNTIME_LIFECYCLE.lock().await;
    let active_epoch = RUNTIME.lock().await.as_ref().map(|runtime| runtime.epoch);
    validate_client_epoch(active_epoch, client_epoch)?;
    let root = validated_runtime_root(data_directory)?;
    let codex_home = root.join("rollouts");
    std::fs::create_dir_all(&codex_home)
        .map_err(|_| BridgeError::internal("unable to create the native runtime directory"))?;

    shutdown_runtime_inner().await?;

    if let Some(snapshot) = auth_snapshot.as_deref() {
        install_auth_snapshot(&codex_home, snapshot)?;
    }

    let cli_overrides = vec![
        (
            "model_provider".to_owned(),
            toml::Value::String("conduit-chatgpt".to_owned()),
        ),
        (
            "model_providers.conduit-chatgpt.name".to_owned(),
            toml::Value::String("OpenAI".to_owned()),
        ),
        (
            "model_providers.conduit-chatgpt.wire_api".to_owned(),
            toml::Value::String("responses".to_owned()),
        ),
        (
            "model_providers.conduit-chatgpt.http_headers.version".to_owned(),
            toml::Value::String("0.145.0".to_owned()),
        ),
        (
            "model_providers.conduit-chatgpt.requires_openai_auth".to_owned(),
            toml::Value::Boolean(true),
        ),
        (
            "model_providers.conduit-chatgpt.supports_websockets".to_owned(),
            toml::Value::Boolean(false),
        ),
        (
            "cli_auth_credentials_store".to_owned(),
            toml::Value::String("ephemeral".to_owned()),
        ),
        (
            "approval_policy".to_owned(),
            toml::Value::String("never".to_owned()),
        ),
        (
            "sandbox_mode".to_owned(),
            toml::Value::String("read-only".to_owned()),
        ),
        ("features.skills".to_owned(), toml::Value::Boolean(false)),
        ("features.apps".to_owned(), toml::Value::Boolean(false)),
        ("features.plugins".to_owned(), toml::Value::Boolean(false)),
        (
            "features.plugin_hooks".to_owned(),
            toml::Value::Boolean(false),
        ),
        (
            "features.tool_search".to_owned(),
            toml::Value::Boolean(false),
        ),
        (
            "features.tool_suggest".to_owned(),
            toml::Value::Boolean(false),
        ),
        (
            "features.shell_tool".to_owned(),
            toml::Value::Boolean(false),
        ),
        ("features.code_mode".to_owned(), toml::Value::Boolean(false)),
        (
            "features.multi_agent".to_owned(),
            toml::Value::Boolean(false),
        ),
        (
            "features.multi_agent_v2".to_owned(),
            toml::Value::Boolean(false),
        ),
        (
            "features.request_permissions_tool".to_owned(),
            toml::Value::Boolean(false),
        ),
    ];
    let config = ConfigBuilder::default()
        .codex_home(codex_home.clone())
        .fallback_cwd(Some(root.clone()))
        .cli_overrides(cli_overrides.clone())
        .build()
        .await
        .map_err(|_| BridgeError::internal("unable to configure the native runtime"))?;

    let args = InProcessClientStartArgs {
        arg0_paths: Arg0DispatchPaths::default(),
        config: Arc::new(config),
        cli_overrides,
        loader_overrides: LoaderOverrides::default(),
        strict_config: false,
        cloud_config_bundle: CloudConfigBundleLoader::default(),
        feedback: CodexFeedback::new(),
        log_db: None,
        state_db: None,
        environment_manager: Arc::new(EnvironmentManager::without_environments()),
        config_warnings: Vec::new(),
        session_source: SessionSource::Custom("conduit".to_owned()),
        enable_codex_api_key_env: false,
        client_name: "Conduit".to_owned(),
        client_version: env!("CARGO_PKG_VERSION").to_owned(),
        experimental_api: true,
        mcp_server_openai_form_elicitation: false,
        opt_out_notification_methods: vec![
            "skills/changed".to_owned(),
            "fs/changed".to_owned(),
            "mcpServer/startupStatus/updated".to_owned(),
        ],
        channel_capacity: EVENT_QUEUE_CAPACITY,
    };
    let mut client = InProcessAppServerClient::start(args)
        .await
        .map_err(|error| {
            BridgeError::internal(format!("unable to start the native runtime: {error}"))
        })?;
    let request = client.request_handle();
    let hub = EventHub::new(client_epoch);
    let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<oneshot::Sender<()>>(1);
    let committed_auth_hash = Arc::new(Mutex::new(snapshot_hash(auth_snapshot.as_deref())));
    let auth_persistence = Arc::new(Mutex::new(()));
    let pending_auth = Arc::new(Mutex::new(HashMap::new()));
    let active_login_id = Arc::new(Mutex::new(None));
    let turn_to_run = Arc::new(Mutex::new(HashMap::new()));
    let scheduler = Arc::new(Mutex::new(TurnScheduler::default()));
    let event_context = EventContext {
        hub: hub.clone(),
        codex_home: codex_home.clone(),
        committed_auth_hash: committed_auth_hash.clone(),
        auth_persistence: auth_persistence.clone(),
        pending_auth: pending_auth.clone(),
        active_login_id: active_login_id.clone(),
        turn_to_run: turn_to_run.clone(),
        scheduler: scheduler.clone(),
    };
    tokio::spawn(async move {
        let mut pending_delta: Option<PendingDelta> = None;
        let mut watchdog = tokio::time::interval(ACTIVE_RUN_WATCHDOG_INTERVAL);
        watchdog.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                shutdown = shutdown_rx.recv() => {
                    if let Some(delta) = pending_delta.take() {
                        event_context.hub.emit(delta.event).await;
                    }
                    let _ = client.shutdown().await;
                    if let Some(done) = shutdown { let _ = done.send(()); }
                    break;
                }
                _ = sleep_until(pending_delta.as_ref().map(|d| d.deadline).unwrap_or_else(|| Instant::now() + Duration::from_secs(86400))), if pending_delta.is_some() => {
                    if let Some(delta) = pending_delta.take() {
                        event_context.hub.emit(delta.event).await;
                    }
                }
                _ = watchdog.tick() => {
                    expire_stalled_runs(&event_context).await;
                }
                event = client.next_event() => {
                    let Some(event) = event else {
                        fail_all_runtime_runs(
                            &event_context,
                            "The native ChatGPT event stream ended unexpectedly.",
                        ).await;
                        break;
                    };
                    match event {
                        InProcessServerEvent::ServerNotification(notification) => {
                            if let Some(mapped) = map_notification(&event_context, notification).await {
                                if matches!(mapped.kind, RuntimeEventKind::TextDelta | RuntimeEventKind::ReasoningDelta) {
                                    merge_or_flush_delta(&event_context.hub, &mut pending_delta, mapped).await;
                                } else {
                                    if let Some(delta) = pending_delta.take() {
                                        event_context.hub.emit(delta.event).await;
                                    }
                                    emit_runtime_event(&event_context, mapped).await;
                                }
                            }
                        }
                        InProcessServerEvent::ServerRequest(request) => {
                            let request_id = request.id().clone();
                            let params = serde_json::to_value(&request)
                                .ok()
                                .and_then(|value| value.get("params").cloned())
                                .unwrap_or(Value::Null);
                            let ids = notification_ids(&params, &event_context.turn_to_run).await;
                            let payload = if ids.run_id.is_some() && ids.thread_id.is_some() {
                                event_with_ids(
                                    RuntimeEventKind::Failure,
                                    Some("The model requested a disabled capability.".to_owned()),
                                    None,
                                    ids,
                                )
                            } else {
                                RuntimeEvent {
                                    kind: RuntimeEventKind::Diagnostic,
                                    text: Some("A disabled native capability was rejected.".to_owned()),
                                    ..blank_event()
                                }
                            };
                            emit_runtime_event(&event_context, payload).await;
                            let _ = client.reject_server_request(
                                request_id,
                                codex_app_server_protocol::JSONRPCErrorError {
                                    code: -32004,
                                    message: "capability disabled by Conduit mobile-chat runtime".to_owned(),
                                    data: None,
                                },
                            ).await;
                        }
                        InProcessServerEvent::Lagged { skipped } => {
                            fail_all_runtime_runs(
                                &event_context,
                                &format!("Native event queue overflowed ({skipped} events)."),
                            ).await;
                        }
                    }
                }
            }
        }
        let mut runtime = RUNTIME.lock().await;
        if runtime
            .as_ref()
            .is_some_and(|active| active.epoch == event_context.hub.epoch)
        {
            runtime.take();
        }
    });

    *RUNTIME.lock().await = Some(RuntimeHandle {
        epoch: client_epoch,
        request,
        hub,
        shutdown: shutdown_tx,
        codex_home,
        committed_auth_hash,
        auth_persistence,
        pending_auth,
        active_login_id,
        turn_to_run,
        scheduler,
    });
    Ok(())
}

pub async fn runtime_events(
    client_epoch: u64,
    sink: StreamSink<RuntimeEvent>,
) -> Result<(), BridgeError> {
    let hub = {
        let guard = RUNTIME.lock().await;
        let runtime = guard.as_ref().ok_or_else(runtime_not_initialized)?;
        if runtime.epoch != client_epoch {
            return Err(BridgeError::new(
                BridgeErrorKind::ProtocolMismatch,
                "stale native runtime epoch",
            ));
        }
        runtime.hub.clone()
    };
    let mut receiver = hub.subscribe().await;
    while let Some(event) = receiver.recv().await {
        if sink.add(event).is_err() {
            return Ok(());
        }
    }
    Err(BridgeError::new(
        BridgeErrorKind::Network,
        "native event delivery queue closed",
    ))
}

pub async fn auth_state() -> Result<AuthStateInfo, BridgeError> {
    let value = rpc("account/read", json!({"refreshToken": false})).await?;
    let account_id = {
        let guard = RUNTIME.lock().await;
        let runtime = guard.as_ref().ok_or_else(runtime_not_initialized)?;
        chatgpt_account_id(&runtime.codex_home)
    };
    Ok(parse_auth_state(&value, account_id))
}

pub async fn begin_device_code_login() -> Result<DeviceCodeChallenge, BridgeError> {
    let value = rpc("account/login/start", json!({"type": "chatgptDeviceCode"})).await?;
    let challenge = DeviceCodeChallenge {
        login_id: required_string(&value, "loginId")?,
        verification_url: required_string(&value, "verificationUrl")?,
        user_code: required_string(&value, "userCode")?,
    };
    let guard = RUNTIME.lock().await;
    let runtime = guard.as_ref().ok_or_else(runtime_not_initialized)?;
    *runtime.active_login_id.lock().await = Some(challenge.login_id.clone());
    Ok(challenge)
}

pub async fn cancel_device_code_login() -> Result<(), BridgeError> {
    let login_id = {
        let guard = RUNTIME.lock().await;
        let runtime = guard.as_ref().ok_or_else(runtime_not_initialized)?;
        runtime.active_login_id.lock().await.take()
    };
    if let Some(login_id) = login_id {
        let _ = rpc("account/login/cancel", json!({"loginId": login_id})).await?;
    }
    Ok(())
}

pub async fn list_models() -> Result<Vec<ModelInfo>, BridgeError> {
    let value = rpc("model/list", json!({"includeHidden": false, "limit": 100})).await?;
    let data = value
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(data
        .into_iter()
        .filter_map(|model| {
            let id = model
                .get("model")
                .or_else(|| model.get("id"))?
                .as_str()?
                .to_owned();
            let modalities = model
                .get("inputModalities")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let efforts = model
                .get("supportedReasoningEfforts")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            Some(ModelInfo {
                display_name: model
                    .get("displayName")
                    .and_then(Value::as_str)
                    .unwrap_or(&id)
                    .to_owned(),
                description: model
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                supports_images: modalities.iter().any(|item| item.as_str() == Some("image")),
                supports_audio: modalities.iter().any(|item| item.as_str() == Some("audio")),
                supported_reasoning_efforts: efforts
                    .iter()
                    .filter_map(|item| {
                        item.get("reasoningEffort")
                            .or(Some(item))
                            .and_then(Value::as_str)
                            .map(str::to_owned)
                    })
                    .collect(),
                default_reasoning_effort: model
                    .get("defaultReasoningEffort")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                id,
            })
        })
        .collect())
}

pub async fn start_thread(
    model_id: String,
    enable_web_search: bool,
    enable_image_generation: bool,
) -> Result<ThreadInfo, BridgeError> {
    validate_identifier(&model_id, "model id")?;
    let value = rpc(
        "thread/start",
        json!({
            "model": model_id,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "baseInstructions": GENERAL_CHAT_INSTRUCTIONS,
            "developerInstructions": GENERAL_CHAT_INSTRUCTIONS,
            "config": {
                "web_search": if enable_web_search { "live" } else { "disabled" },
                "features.image_generation": enable_image_generation,
            },
            "environments": [],
            "dynamicTools": [],
            "ephemeral": false
        }),
    )
    .await?;
    Ok(ThreadInfo {
        thread_id: required_nested_string(&value, &["thread", "id"])?,
        model_id: required_string(&value, "model")?,
    })
}

pub async fn resume_thread(thread_id: String) -> Result<ThreadInfo, BridgeError> {
    validate_identifier(&thread_id, "thread id")?;
    let value = rpc("thread/resume", json!({"threadId": thread_id})).await?;
    Ok(ThreadInfo {
        thread_id: required_nested_string(&value, &["thread", "id"])?,
        model_id: value
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    })
}

pub async fn fork_thread(
    thread_id: String,
    turn_id: Option<String>,
) -> Result<ThreadInfo, BridgeError> {
    validate_identifier(&thread_id, "thread id")?;
    let value = rpc(
        "thread/fork",
        json!({"threadId": thread_id, "turnId": turn_id}),
    )
    .await?;
    Ok(ThreadInfo {
        thread_id: required_nested_string(&value, &["thread", "id"])?,
        model_id: value
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    })
}

pub async fn start_turn(request: TurnRequest) -> Result<RunInfo, BridgeError> {
    validate_identifier(&request.thread_id, "thread id")?;
    validate_identifier(&request.model_id, "model id")?;
    if request.inputs.is_empty() {
        return Err(BridgeError::new(
            BridgeErrorKind::InvalidInput,
            "a turn requires at least one input",
        ));
    }
    // Validate and bound all inputs before accepting a run into the FIFO.
    let encoded_inputs = encode_turn_inputs(&request.inputs)?;
    let encoded_input_bytes = encoded_inputs_size(&encoded_inputs)?;
    let run_id = Uuid::new_v4().to_string();
    let context = context_snapshot().await?;
    let starts_now = {
        let mut scheduler = context.scheduler.lock().await;
        if scheduler.active_by_thread.len() < MAX_ACTIVE_RUNS
            && !scheduler.active_by_thread.contains_key(&request.thread_id)
            && scheduler.queued.is_empty()
        {
            scheduler.active_by_thread.insert(
                request.thread_id.clone(),
                ActiveRun {
                    run_id: run_id.clone(),
                    turn_id: None,
                    cancellation_requested: false,
                    last_activity: Instant::now(),
                },
            );
            true
        } else {
            let mut queued_request = request.clone();
            queued_request.inputs.clear();
            scheduler.enqueue(QueuedRun {
                run_id: run_id.clone(),
                request: queued_request,
                encoded_inputs: encoded_inputs.clone(),
                encoded_input_bytes,
            })?;
            false
        }
    };
    let turn_id = if starts_now {
        match start_native_turn(&context, &run_id, &request, &encoded_inputs).await {
            Ok(turn_id) => Some(turn_id),
            Err(error) => {
                finish_scheduled_run(context, &run_id, &request.thread_id).await;
                return Err(error);
            }
        }
    } else {
        None
    };
    Ok(RunInfo {
        run_id,
        thread_id: request.thread_id,
        turn_id,
    })
}

pub async fn interrupt_turn(run_id: String) -> Result<(), BridgeError> {
    validate_identifier(&run_id, "run id")?;
    let context = context_snapshot().await?;
    let action = {
        let mut scheduler = context.scheduler.lock().await;
        if let Some(position) = scheduler
            .queued
            .iter()
            .position(|queued| queued.run_id == run_id)
        {
            let queued = scheduler
                .remove_queued(position)
                .expect("queued run exists");
            Some((queued.request.thread_id, None, true))
        } else if let Some((thread_id, active)) = scheduler
            .active_by_thread
            .iter_mut()
            .find(|(_, active)| active.run_id == run_id)
        {
            active.cancellation_requested = true;
            Some((thread_id.clone(), active.turn_id.clone(), false))
        } else {
            None
        }
    };
    let Some((thread_id, turn_id, was_queued)) = action else {
        return Err(BridgeError::new(
            BridgeErrorKind::Cancellation,
            "run is no longer active",
        ));
    };
    if was_queued {
        context
            .hub
            .emit(RuntimeEvent {
                kind: RuntimeEventKind::Cancelled,
                run_id: Some(run_id),
                thread_id: Some(thread_id),
                ..blank_event()
            })
            .await;
        start_next_queued_run(context).await;
    } else if let Some(turn_id) = turn_id {
        let _ = rpc(
            "turn/interrupt",
            json!({"threadId": thread_id, "turnId": turn_id}),
        )
        .await?;
    }
    Ok(())
}

pub async fn ack_auth_mutation(mutation_id: String, persisted: bool) -> Result<(), BridgeError> {
    validate_identifier(&mutation_id, "auth mutation id")?;
    let pending = {
        let guard = RUNTIME.lock().await;
        let runtime = guard.as_ref().ok_or_else(runtime_not_initialized)?;
        runtime.pending_auth.lock().await.remove(&mutation_id)
    };
    let pending = pending.ok_or_else(|| {
        BridgeError::new(
            BridgeErrorKind::ProtocolMismatch,
            "auth mutation is not pending",
        )
    })?;
    if persisted {
        let guard = RUNTIME.lock().await;
        if let Some(runtime) = guard.as_ref() {
            *runtime.committed_auth_hash.lock().await = pending.expected_hash.clone();
        }
    }
    let _ = pending.acknowledgement.send(persisted);
    Ok(())
}

pub async fn disconnect_account() -> Result<(), BridgeError> {
    let _ = cancel_device_code_login().await;
    let context = context_snapshot().await?;
    let (queued, active) = {
        let mut scheduler = context.scheduler.lock().await;
        let queued = scheduler.drain_queued();
        let active = scheduler
            .active_by_thread
            .iter_mut()
            .map(|(thread_id, run)| {
                run.cancellation_requested = true;
                (thread_id.clone(), run.run_id.clone(), run.turn_id.clone())
            })
            .collect::<Vec<_>>();
        (queued, active)
    };
    for queued in queued {
        context
            .hub
            .emit(RuntimeEvent {
                kind: RuntimeEventKind::Cancelled,
                run_id: Some(queued.run_id),
                thread_id: Some(queued.request.thread_id),
                ..blank_event()
            })
            .await;
    }
    for (thread_id, _, turn_id) in active {
        if let Some(turn_id) = turn_id {
            let _ = rpc(
                "turn/interrupt",
                json!({"threadId": thread_id, "turnId": turn_id}),
            )
            .await;
        }
    }
    let _ = rpc("account/logout", Value::Null).await;
    let _single_flight = context.auth_persistence.lock().await;
    request_auth_persistence(context.clone(), Vec::new(), None).await?;
    Ok(())
}

async fn start_native_turn(
    context: &EventContext,
    run_id: &str,
    request: &TurnRequest,
    encoded_inputs: &[Value],
) -> Result<String, BridgeError> {
    let mut input = encoded_inputs.to_vec();
    input.insert(
        0,
        json!({
            "type": "text",
            "text": format!(
                "Conduit tool policy for this turn: web search is {}; image generation is {}. Never use a disabled tool.",
                if request.enable_web_search { "enabled" } else { "disabled" },
                if request.enable_image_generation { "enabled" } else { "disabled" },
            ),
            "text_elements": []
        }),
    );
    let mut params = json!({
        "threadId": request.thread_id,
        "clientUserMessageId": request.client_user_message_id,
        "input": input,
        "model": request.model_id,
        "environments": [],
        "approvalPolicy": "never",
        "responsesapiClientMetadata": {
            "conduit_run_id": run_id,
            "web_search": request.enable_web_search.to_string(),
            "image_generation": request.enable_image_generation.to_string()
        }
    });
    if let Some(effort) = request.reasoning_effort.as_deref() {
        params["effort"] = Value::String(effort.to_owned());
    }
    let value = rpc("turn/start", params).await?;
    let turn_id = required_nested_string(&value, &["turn", "id"])?;
    context
        .turn_to_run
        .lock()
        .await
        .insert(turn_id.clone(), run_id.to_owned());
    let active_state = {
        let mut scheduler = context.scheduler.lock().await;
        scheduler
            .active_by_thread
            .get_mut(&request.thread_id)
            .filter(|active| active.run_id == run_id)
            .map(|active| {
                active.turn_id = Some(turn_id.clone());
                active.cancellation_requested
            })
    };
    let Some(cancel_now) = active_state else {
        context.turn_to_run.lock().await.remove(&turn_id);
        let _ = rpc(
            "turn/interrupt",
            json!({"threadId": request.thread_id, "turnId": turn_id}),
        )
        .await;
        return Err(BridgeError::new(
            BridgeErrorKind::Cancellation,
            "run was cancelled before it started",
        ));
    };
    context
        .hub
        .emit(RuntimeEvent {
            kind: RuntimeEventKind::TurnStarted,
            run_id: Some(run_id.to_owned()),
            thread_id: Some(request.thread_id.clone()),
            turn_id: Some(turn_id.clone()),
            ..blank_event()
        })
        .await;
    if cancel_now {
        let _ = rpc(
            "turn/interrupt",
            json!({"threadId": request.thread_id, "turnId": turn_id}),
        )
        .await;
    }
    Ok(turn_id)
}

async fn finish_scheduled_run(context: EventContext, run_id: &str, thread_id: &str) {
    let next = release_and_take_next(&context, run_id, thread_id).await;
    if let Some(queued) = next {
        tokio::spawn(run_queued_chain(context, queued));
    }
}

async fn start_next_queued_run(context: EventContext) {
    let next = {
        let mut scheduler = context.scheduler.lock().await;
        take_next_ready_run(&mut scheduler)
    };
    if let Some(queued) = next {
        tokio::spawn(run_queued_chain(context, queued));
    }
}

async fn release_and_take_next(
    context: &EventContext,
    run_id: &str,
    thread_id: &str,
) -> Option<QueuedRun> {
    let mut scheduler = context.scheduler.lock().await;
    if scheduler
        .active_by_thread
        .get(thread_id)
        .is_some_and(|active| active.run_id == run_id)
    {
        scheduler.active_by_thread.remove(thread_id);
    }
    take_next_ready_run(&mut scheduler)
}

fn take_next_ready_run(scheduler: &mut TurnScheduler) -> Option<QueuedRun> {
    let can_start_head = scheduler.active_by_thread.len() < MAX_ACTIVE_RUNS
        && scheduler.queued.front().is_some_and(|queued| {
            !scheduler
                .active_by_thread
                .contains_key(&queued.request.thread_id)
        });
    if !can_start_head {
        return None;
    }
    let queued = scheduler.pop_queued().expect("queued head exists");
    scheduler.active_by_thread.insert(
        queued.request.thread_id.clone(),
        ActiveRun {
            run_id: queued.run_id.clone(),
            turn_id: None,
            cancellation_requested: false,
            last_activity: Instant::now(),
        },
    );
    Some(queued)
}

async fn run_queued_chain(context: EventContext, mut queued: QueuedRun) {
    loop {
        if let Err(error) = start_native_turn(
            &context,
            &queued.run_id,
            &queued.request,
            &queued.encoded_inputs,
        )
        .await
        {
            context
                .hub
                .emit(RuntimeEvent {
                    kind: RuntimeEventKind::Failure,
                    run_id: Some(queued.run_id.clone()),
                    thread_id: Some(queued.request.thread_id.clone()),
                    text: Some(error.message),
                    ..blank_event()
                })
                .await;
            if let Some(next) =
                release_and_take_next(&context, &queued.run_id, &queued.request.thread_id).await
            {
                queued = next;
                continue;
            }
        }
        break;
    }
}

async fn touch_active_run(context: &EventContext, ids: &NotificationIds) {
    let (Some(run_id), Some(thread_id)) = (ids.run_id.as_deref(), ids.thread_id.as_deref()) else {
        return;
    };
    let mut scheduler = context.scheduler.lock().await;
    if let Some(active) = scheduler
        .active_by_thread
        .get_mut(thread_id)
        .filter(|active| active.run_id == run_id)
    {
        active.last_activity = Instant::now();
    }
}

async fn expire_stalled_runs(context: &EventContext) {
    let expired = {
        let mut scheduler = context.scheduler.lock().await;
        let threads = scheduler
            .active_by_thread
            .iter()
            .filter(|(_, active)| active.last_activity.elapsed() >= ACTIVE_RUN_IDLE_TIMEOUT)
            .map(|(thread_id, _)| thread_id.clone())
            .collect::<Vec<_>>();
        threads
            .into_iter()
            .filter_map(|thread_id| {
                scheduler
                    .active_by_thread
                    .remove(&thread_id)
                    .map(|active| (thread_id, active))
            })
            .collect::<Vec<_>>()
    };
    for (thread_id, active) in expired {
        if let Some(turn_id) = active.turn_id.as_deref() {
            context.turn_to_run.lock().await.remove(turn_id);
            let _ = rpc(
                "turn/interrupt",
                json!({"threadId": thread_id, "turnId": turn_id}),
            )
            .await;
        }
        context
            .hub
            .emit(RuntimeEvent {
                kind: RuntimeEventKind::Failure,
                run_id: Some(active.run_id),
                thread_id: Some(thread_id),
                turn_id: active.turn_id,
                text: Some("The ChatGPT turn stopped responding.".to_owned()),
                ..blank_event()
            })
            .await;
        start_next_queued_run(context.clone()).await;
    }
}

async fn fail_all_runtime_runs(context: &EventContext, message: &str) {
    let failed = {
        let mut scheduler = context.scheduler.lock().await;
        let mut runs = scheduler
            .active_by_thread
            .drain()
            .map(|(thread_id, active)| (active.run_id, thread_id, active.turn_id))
            .collect::<Vec<_>>();
        runs.extend(
            scheduler
                .drain_queued()
                .into_iter()
                .map(|queued| (queued.run_id, queued.request.thread_id, None)),
        );
        runs
    };
    context.turn_to_run.lock().await.clear();
    for (run_id, thread_id, turn_id) in failed {
        context
            .hub
            .emit(RuntimeEvent {
                kind: RuntimeEventKind::Failure,
                run_id: Some(run_id),
                thread_id: Some(thread_id),
                turn_id,
                text: Some(message.to_owned()),
                ..blank_event()
            })
            .await;
    }
}

pub async fn shutdown_runtime() -> Result<(), BridgeError> {
    let _lifecycle = RUNTIME_LIFECYCLE.lock().await;
    shutdown_runtime_inner().await
}

async fn shutdown_runtime_inner() -> Result<(), BridgeError> {
    let previous = RUNTIME.lock().await.take();
    if let Some(runtime) = previous {
        let (tx, rx) = oneshot::channel();
        if runtime.shutdown.send(tx).await.is_ok() {
            let _ = timeout(Duration::from_secs(6), rx).await;
        }
    }
    Ok(())
}

async fn rpc(method: &str, params: Value) -> Result<Value, BridgeError> {
    if !ALLOWED_RPC_METHODS.contains(&method) {
        return Err(BridgeError::new(
            BridgeErrorKind::Unsupported,
            "native protocol method is outside the mobile-chat capability boundary",
        ));
    }
    let request = {
        let request_id = NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        serde_json::from_value::<ClientRequest>(
            json!({"method": method, "id": request_id, "params": params}),
        )
        .map_err(|_| {
            BridgeError::new(
                BridgeErrorKind::ProtocolMismatch,
                "unable to encode native protocol request",
            )
        })?
    };
    let handle = {
        let guard = RUNTIME.lock().await;
        guard
            .as_ref()
            .ok_or_else(runtime_not_initialized)?
            .request
            .clone()
    };
    let response = timeout(RPC_REQUEST_TIMEOUT, handle.request(request))
        .await
        .map_err(|_| {
            BridgeError::new(
                BridgeErrorKind::Network,
                "native protocol request timed out",
            )
        })?
        .map_err(|_| {
            BridgeError::new(BridgeErrorKind::Network, "native protocol transport failed")
        })?;
    response.map_err(|error| classify_protocol_error(error.code, &error.message))
}

async fn map_notification(
    context: &EventContext,
    notification: ServerNotification,
) -> Option<RuntimeEvent> {
    let value = serde_json::to_value(&notification).ok()?;
    let method = value.get("method")?.as_str()?;
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let ids = notification_ids(&params, &context.turn_to_run).await;
    touch_active_run(context, &ids).await;
    match method {
        "item/agentMessage/delta" => Some(event_with_ids(
            RuntimeEventKind::TextDelta,
            params
                .get("delta")
                .and_then(Value::as_str)
                .map(str::to_owned),
            None,
            ids,
        )),
        "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" => Some(event_with_ids(
            RuntimeEventKind::ReasoningDelta,
            params
                .get("delta")
                .and_then(Value::as_str)
                .map(str::to_owned),
            None,
            ids,
        )),
        "thread/tokenUsage/updated" | "rawResponse/completed" => Some(event_with_ids(
            RuntimeEventKind::Usage,
            None,
            sanitized_usage_json(&params),
            ids,
        )),
        "turn/completed" => {
            let status = params
                .pointer("/turn/status")
                .and_then(Value::as_str)
                .unwrap_or("completed");
            let kind = if status == "interrupted" {
                RuntimeEventKind::Cancelled
            } else if status == "failed" {
                RuntimeEventKind::Failure
            } else {
                RuntimeEventKind::Completed
            };
            let terminal = event_with_ids(kind, None, sanitized_json(&params), ids);
            let auth_context = context.clone();
            tokio::spawn(async move {
                let _ = maybe_request_auth_persistence(auth_context).await;
            });
            Some(terminal)
        }
        "item/started" => Some(event_with_ids(
            RuntimeEventKind::ToolStarted,
            item_label(&params),
            sanitized_item_json(&params),
            ids,
        )),
        "item/completed" => {
            let item_type = params
                .pointer("/item/type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let kind = if item_type == "webSearch" {
                RuntimeEventKind::Source
            } else if item_type == "imageGeneration" {
                RuntimeEventKind::GeneratedImage
            } else {
                RuntimeEventKind::ToolCompleted
            };
            let mut event = event_with_ids(
                kind,
                item_label(&params),
                if kind == RuntimeEventKind::Source {
                    sanitized_source_json(&params)
                } else if kind == RuntimeEventKind::GeneratedImage {
                    sanitized_generated_image_json(&params)
                } else {
                    sanitized_item_json(&params)
                },
                ids,
            );
            if kind == RuntimeEventKind::GeneratedImage {
                event.binary_data = generated_image_bytes(&params, &context.codex_home).await;
                if event.binary_data.is_none() {
                    event.kind = RuntimeEventKind::Failure;
                    event.text = Some("The generated image could not be imported.".to_owned());
                }
            }
            Some(event)
        }
        "account/login/completed" => {
            let success = params
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            *context.active_login_id.lock().await = None;
            if success {
                let auth_context = context.clone();
                tokio::spawn(async move {
                    let result = maybe_request_auth_persistence(auth_context.clone()).await;
                    let success = result.is_ok();
                    let text = result.err().map(|error| error.message);
                    auth_context
                        .hub
                        .emit(RuntimeEvent {
                            kind: if success {
                                RuntimeEventKind::LoginCompleted
                            } else {
                                RuntimeEventKind::Failure
                            },
                            text,
                            json_data: Some(json!({"success": success}).to_string()),
                            ..blank_event()
                        })
                        .await;
                });
                None
            } else {
                let reason = params
                    .get("error")
                    .and_then(Value::as_str)
                    .map(str::to_ascii_lowercase)
                    .map(|error| {
                        if error.contains("denied") {
                            "denied"
                        } else if error.contains("expir") {
                            "expired"
                        } else if error.contains("cancel") {
                            "cancelled"
                        } else {
                            "error"
                        }
                    })
                    .unwrap_or("error");
                Some(RuntimeEvent {
                    kind: RuntimeEventKind::LoginCompleted,
                    text: Some("ChatGPT sign-in did not complete.".to_owned()),
                    json_data: Some(json!({"success": false, "reason": reason}).to_string()),
                    ..blank_event()
                })
            }
        }
        "account/updated" => Some(RuntimeEvent {
            kind: RuntimeEventKind::AuthState,
            json_data: sanitized_account_json(&params),
            ..blank_event()
        }),
        "error" => Some(event_with_ids(
            RuntimeEventKind::Failure,
            Some("The ChatGPT request failed.".to_owned()),
            sanitized_error_json(&params),
            ids,
        )),
        "warning" | "guardianWarning" | "model/rerouted" => Some(event_with_ids(
            RuntimeEventKind::Diagnostic,
            sanitized_warning(&params),
            None,
            ids,
        )),
        _ => None,
    }
}

async fn emit_runtime_event(context: &EventContext, event: RuntimeEvent) {
    let terminal = matches!(
        event.kind,
        RuntimeEventKind::Completed | RuntimeEventKind::Cancelled | RuntimeEventKind::Failure
    );
    let run_id = event.run_id.clone();
    let thread_id = event.thread_id.clone();
    let turn_id = event.turn_id.clone();
    context.hub.emit(event).await;
    if !terminal {
        return;
    }
    if let Some(turn_id) = turn_id {
        context.turn_to_run.lock().await.remove(&turn_id);
    }
    if let (Some(run_id), Some(thread_id)) = (run_id, thread_id) {
        finish_scheduled_run(context.clone(), &run_id, &thread_id).await;
    }
}

async fn merge_or_flush_delta(
    hub: &EventHub,
    pending: &mut Option<PendingDelta>,
    incoming: RuntimeEvent,
) {
    if let Some(current) = pending.as_mut() {
        let same_stream = current.event.kind == incoming.kind
            && current.event.run_id == incoming.run_id
            && current.event.thread_id == incoming.thread_id
            && current.event.turn_id == incoming.turn_id
            && current.event.item_id == incoming.item_id;
        let incoming_len = incoming.text.as_deref().map(str::len).unwrap_or(0);
        let current_len = current.event.text.as_deref().map(str::len).unwrap_or(0);
        if same_stream && current_len + incoming_len <= DELTA_FLUSH_BYTES {
            current
                .event
                .text
                .get_or_insert_with(String::new)
                .push_str(incoming.text.as_deref().unwrap_or_default());
            return;
        }
        let previous = pending.take().expect("pending delta exists");
        hub.emit(previous.event).await;
    }
    *pending = Some(PendingDelta {
        event: incoming,
        deadline: Instant::now() + DELTA_FLUSH_INTERVAL,
    });
}

async fn maybe_request_auth_persistence(context: EventContext) -> Result<(), BridgeError> {
    let _single_flight = context.auth_persistence.lock().await;
    let snapshot = load_auth_dot_json(
        &context.codex_home,
        AuthCredentialsStoreMode::Ephemeral,
        AuthKeyringBackendKind::default(),
    )
    .map_err(|_| {
        BridgeError::new(
            BridgeErrorKind::Authentication,
            "unable to read refreshed credentials",
        )
    })?
    .ok_or_else(|| {
        BridgeError::new(
            BridgeErrorKind::Authentication,
            "ChatGPT did not return credentials",
        )
    })?;
    let bytes = serde_json::to_vec(&snapshot)
        .map_err(|_| BridgeError::internal("unable to encode refreshed credentials"))?;
    let hash = snapshot_hash(Some(&bytes));
    if *context.committed_auth_hash.lock().await == hash {
        return Ok(());
    }
    request_auth_persistence(context.clone(), bytes, hash).await
}

async fn request_auth_persistence(
    context: EventContext,
    snapshot: Vec<u8>,
    expected_hash: Option<String>,
) -> Result<(), BridgeError> {
    let mutation_id = Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    context.pending_auth.lock().await.insert(
        mutation_id.clone(),
        PendingAuthMutation {
            expected_hash: expected_hash.clone(),
            acknowledgement: tx,
        },
    );
    context
        .hub
        .emit(RuntimeEvent {
            kind: RuntimeEventKind::AuthMutationRequired,
            json_data: Some(
                json!({"mutationId": mutation_id, "delete": snapshot.is_empty()}).to_string(),
            ),
            binary_data: Some(snapshot),
            ..blank_event()
        })
        .await;
    match timeout(AUTH_ACK_TIMEOUT, rx).await {
        Ok(Ok(true)) => {
            *context.committed_auth_hash.lock().await = expected_hash;
            Ok(())
        }
        _ => {
            context.pending_auth.lock().await.remove(&mutation_id);
            Err(BridgeError::new(
                BridgeErrorKind::Authentication,
                "secure credential persistence was not acknowledged",
            ))
        }
    }
}

fn install_auth_snapshot(codex_home: &Path, snapshot: &[u8]) -> Result<(), BridgeError> {
    let auth: AuthDotJson = serde_json::from_slice(snapshot).map_err(|_| {
        BridgeError::new(
            BridgeErrorKind::Authentication,
            "stored ChatGPT credentials are invalid",
        )
    })?;
    save_auth(
        codex_home,
        &auth,
        AuthCredentialsStoreMode::Ephemeral,
        AuthKeyringBackendKind::default(),
    )
    .map_err(|_| {
        BridgeError::new(
            BridgeErrorKind::Authentication,
            "unable to load stored ChatGPT credentials",
        )
    })
}

fn encode_turn_inputs(parts: &[TurnInputPart]) -> Result<Vec<Value>, BridgeError> {
    let mut encoded = Vec::with_capacity(parts.len());
    let mut aggregate_input_bytes = 0usize;
    for part in parts {
        let bytes = part.bytes.as_deref().unwrap_or_default();
        let text_bytes = part.text.as_deref().map(str::len).unwrap_or_default();
        if text_bytes > MAX_TEXT_INPUT_BYTES {
            return Err(BridgeError::new(
                BridgeErrorKind::InvalidInput,
                "a text input exceeds the 1 MiB limit",
            ));
        }
        if bytes.len() > MAX_BINARY_INPUT_BYTES {
            return Err(BridgeError::new(
                BridgeErrorKind::InvalidInput,
                "an input exceeds the 20 MiB limit",
            ));
        }
        aggregate_input_bytes = aggregate_input_bytes
            .checked_add(bytes.len())
            .and_then(|size| size.checked_add(text_bytes))
            .ok_or_else(|| {
                BridgeError::new(BridgeErrorKind::InvalidInput, "input size overflow")
            })?;
        if aggregate_input_bytes > MAX_AGGREGATE_INPUT_BYTES {
            return Err(BridgeError::new(
                BridgeErrorKind::InvalidInput,
                "inputs exceed the 40 MiB aggregate limit",
            ));
        }
        match part.kind.as_str() {
            "text" => encoded.push(json!({"type": "text", "text": part.text.as_deref().unwrap_or_default(), "text_elements": []})),
            "image" => {
                let mime = validated_media_type(
                    part.mime_type.as_deref().unwrap_or("image/jpeg"),
                    "image/",
                )?;
                encoded.push(json!({"type": "image", "image_url": data_url(&mime, bytes)}));
            }
            "audio" => {
                let mime = validated_media_type(
                    part.mime_type.as_deref().unwrap_or("audio/mpeg"),
                    "audio/",
                )?;
                encoded.push(json!({"type": "audio", "audio_url": data_url(&mime, bytes)}));
            }
            "document" => {
                let mime = validated_media_type(
                    part.mime_type.as_deref().unwrap_or("application/octet-stream"),
                    "",
                )?;
                if !(mime.starts_with("text/") || matches!(mime.as_str(), "application/json" | "application/xml" | "application/yaml" | "application/x-yaml")) {
                    return Err(BridgeError::new(BridgeErrorKind::Unsupported, "this document type is not supported by the pinned ChatGPT runtime"));
                }
                let text = std::str::from_utf8(bytes).map_err(|_| BridgeError::new(BridgeErrorKind::InvalidInput, "document text is not valid UTF-8"))?;
                let text = escaped_document_text(text);
                let name = sanitized_document_attribute(
                    part.filename.as_deref().unwrap_or("document"),
                    "document",
                );
                let mime = sanitized_document_attribute(&mime, "application/octet-stream");
                encoded.push(json!({"type": "text", "text": format!("<document name=\"{name}\" mime=\"{mime}\">\n{text}\n</document>"), "text_elements": []}));
            }
            _ => return Err(BridgeError::new(BridgeErrorKind::Unsupported, "unsupported turn input kind")),
        }
    }
    Ok(encoded)
}

fn encoded_inputs_size(inputs: &[Value]) -> Result<usize, BridgeError> {
    inputs.iter().try_fold(0usize, |total, input| {
        let bytes = serde_json::to_vec(input)
            .map_err(|_| BridgeError::internal("unable to size encoded turn inputs"))?
            .len();
        total.checked_add(bytes).ok_or_else(|| {
            BridgeError::new(BridgeErrorKind::RateLimit, "queued input size overflow")
        })
    })
}

fn sanitized_document_attribute(value: &str, fallback: &str) -> String {
    let sanitized = value
        .chars()
        .filter(|character| {
            character.is_ascii_alphanumeric()
                || matches!(character, '.' | '_' | '-' | '/' | '+' | ' ')
        })
        .take(128)
        .collect::<String>();
    if sanitized.is_empty() {
        fallback.to_owned()
    } else {
        sanitized
    }
}

fn validated_media_type(value: &str, required_prefix: &str) -> Result<String, BridgeError> {
    let normalized = value.trim().to_ascii_lowercase();
    let valid = !normalized.is_empty()
        && normalized.len() <= 128
        && normalized.starts_with(required_prefix)
        && normalized.contains('/')
        && normalized.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '/' | '.' | '+' | '-')
        });
    if !valid {
        return Err(BridgeError::new(
            BridgeErrorKind::InvalidInput,
            "input media type is invalid",
        ));
    }
    Ok(normalized)
}

fn escaped_document_text(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn data_url(mime: &str, bytes: &[u8]) -> String {
    format!(
        "data:{mime};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    )
}

fn chatgpt_account_id(codex_home: &Path) -> Option<String> {
    let tokens = load_auth_dot_json(
        codex_home,
        AuthCredentialsStoreMode::Ephemeral,
        AuthKeyringBackendKind::default(),
    )
    .ok()
    .flatten()?
    .tokens?;
    tokens
        .account_id
        .filter(|id| !id.trim().is_empty())
        .or_else(|| {
            tokens
                .id_token
                .chatgpt_account_id
                .filter(|id| !id.trim().is_empty())
        })
        .or_else(|| {
            tokens
                .id_token
                .chatgpt_user_id
                .filter(|id| !id.trim().is_empty())
        })
}

fn parse_auth_state(value: &Value, account_id: Option<String>) -> AuthStateInfo {
    let account = value.get("account").filter(|account| account.is_object());
    let email = account
        .and_then(|account| account.get("email"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let fingerprint_source = account_id
        .as_ref()
        .map(|id| format!("account:{id}"))
        .or_else(|| {
            email
                .as_deref()
                .map(str::trim)
                .filter(|email| !email.is_empty())
                .map(|email| format!("email:{}", email.to_ascii_lowercase()))
        });
    AuthStateInfo {
        // `requiresOpenaiAuth` describes the configured provider and remains
        // true after login. The typed account object is the session signal.
        authenticated: account
            .and_then(|account| account.get("type"))
            .and_then(Value::as_str)
            == Some("chatgpt"),
        email,
        plan_type: account
            .and_then(|account| account.get("planType"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        account_fingerprint: fingerprint_source
            .as_ref()
            .map(|id| hex_prefix(&Sha256::digest(id.as_bytes()))),
        account_id,
    }
}

async fn notification_ids(
    params: &Value,
    turns: &Arc<Mutex<HashMap<String, String>>>,
) -> NotificationIds {
    let thread_id = json_string_at(params, &["threadId"]);
    let turn_id =
        json_string_at(params, &["turnId"]).or_else(|| json_string_at(params, &["turn", "id"]));
    let item_id =
        json_string_at(params, &["itemId"]).or_else(|| json_string_at(params, &["item", "id"]));
    let run_id = match turn_id.as_ref() {
        Some(id) => turns.lock().await.get(id).cloned(),
        None => None,
    };
    NotificationIds {
        run_id,
        thread_id,
        turn_id,
        item_id,
    }
}

struct NotificationIds {
    run_id: Option<String>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    item_id: Option<String>,
}

fn event_with_ids(
    kind: RuntimeEventKind,
    text: Option<String>,
    json_data: Option<String>,
    ids: NotificationIds,
) -> RuntimeEvent {
    RuntimeEvent {
        kind,
        run_id: ids.run_id,
        thread_id: ids.thread_id,
        turn_id: ids.turn_id,
        item_id: ids.item_id,
        text,
        json_data,
        ..blank_event()
    }
}

fn blank_event() -> RuntimeEvent {
    RuntimeEvent {
        client_epoch: 0,
        sequence: 0,
        kind: RuntimeEventKind::Diagnostic,
        run_id: None,
        thread_id: None,
        turn_id: None,
        item_id: None,
        text: None,
        json_data: None,
        binary_data: None,
    }
}

fn sanitized_json(value: &Value) -> Option<String> {
    serde_json::to_string(value)
        .ok()
        .filter(|text| text.len() <= 64 * 1024)
}

fn sanitized_item_json(value: &Value) -> Option<String> {
    let item = value.get("item")?;
    let safe = json!({"id": item.get("id"), "type": item.get("type"), "status": item.get("status"), "query": item.get("query"), "url": item.get("url"), "title": item.get("title")});
    sanitized_json(&safe)
}

fn sanitized_usage_json(value: &Value) -> Option<String> {
    let usage = value.get("usage").or_else(|| value.get("tokenUsage"))?;
    let safe = json!({
        "totalTokens": usage.get("totalTokens"),
        "inputTokens": usage.get("inputTokens"),
        "cachedInputTokens": usage.get("cachedInputTokens"),
        "outputTokens": usage.get("outputTokens"),
        "reasoningOutputTokens": usage.get("reasoningOutputTokens"),
        "total": usage.get("total"),
        "last": usage.get("last"),
        "modelContextWindow": usage.get("modelContextWindow"),
    });
    sanitized_json(&safe)
}

fn sanitized_source_json(value: &Value) -> Option<String> {
    let item = value.get("item")?;
    let result = item
        .get("results")
        .and_then(Value::as_array)
        .and_then(|results| {
            results
                .iter()
                .find(|result| safe_web_url(result.get("url")))
        })
        .unwrap_or(item);
    let url = result.get("url").and_then(Value::as_str)?;
    if !url.starts_with("https://") && !url.starts_with("http://") {
        return None;
    }
    let safe = json!({
        "url": url,
        "title": bounded_string(result.get("title"), 512),
        "snippet": bounded_string(result.get("snippet").or_else(|| result.get("text")), 2_048),
    });
    sanitized_json(&safe)
}

fn safe_web_url(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|url| url.starts_with("https://") || url.starts_with("http://"))
}

fn bounded_string(value: Option<&Value>, max_bytes: usize) -> Option<String> {
    value.and_then(Value::as_str).map(|text| {
        let mut end = text.len().min(max_bytes);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text[..end].to_owned()
    })
}

fn sanitized_generated_image_json(value: &Value) -> Option<String> {
    let item = value.get("item")?;
    let safe = json!({
        "id": item.get("id"),
        "type": "imageGeneration",
        "status": item.get("status"),
        "mediaType": generated_image_media_type(item),
        "revisedPrompt": bounded_string(item.get("revisedPrompt"), 4_096),
    });
    sanitized_json(&safe)
}

fn generated_image_media_type(item: &Value) -> &str {
    item.get("result")
        .and_then(Value::as_str)
        .and_then(|result| result.strip_prefix("data:"))
        .and_then(|metadata| metadata.split(';').next())
        .filter(|mime| mime.starts_with("image/"))
        .unwrap_or("image/png")
}

async fn generated_image_bytes(value: &Value, codex_home: &Path) -> Option<Vec<u8>> {
    let item = value.get("item")?;
    if let Some(result) = item.get("result").and_then(Value::as_str) {
        let (metadata, encoded) = result.split_once(',')?;
        if !metadata.starts_with("data:image/")
            || !metadata.to_ascii_lowercase().ends_with(";base64")
            || encoded.is_empty()
        {
            return None;
        }
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded)
            && !bytes.is_empty()
            && bytes.len() <= MAX_BINARY_INPUT_BYTES
        {
            return Some(bytes);
        }
    }
    let saved_path = item.get("savedPath").and_then(Value::as_str)?;
    let images_root = tokio::fs::canonicalize(codex_home.join("generated_images"))
        .await
        .ok()?;
    let candidate = tokio::fs::canonicalize(saved_path).await.ok()?;
    if !candidate.starts_with(&images_root) {
        return None;
    }
    let metadata = tokio::fs::metadata(&candidate).await.ok()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_BINARY_INPUT_BYTES as u64
    {
        return None;
    }
    tokio::fs::read(candidate).await.ok()
}

fn sanitized_account_json(value: &Value) -> Option<String> {
    let safe = json!({"authMode": value.get("authMode"), "planType": value.pointer("/account/planType"), "email": value.pointer("/account/email")});
    sanitized_json(&safe)
}

fn sanitized_error_json(value: &Value) -> Option<String> {
    let safe = json!({"code": value.get("code"), "status": value.get("status")});
    sanitized_json(&safe)
}

fn sanitized_warning(value: &Value) -> Option<String> {
    value
        .get("message")
        .or_else(|| value.get("summary"))
        .and_then(Value::as_str)
        .map(|message| message.chars().take(512).collect())
}

fn item_label(params: &Value) -> Option<String> {
    params
        .pointer("/item/type")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn validated_runtime_root(data_directory: String) -> Result<PathBuf, BridgeError> {
    let path = PathBuf::from(data_directory);
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(BridgeError::new(
            BridgeErrorKind::InvalidInput,
            "native runtime directory must be an absolute, normalized path",
        ));
    }
    Ok(path)
}

fn validate_client_epoch(active_epoch: Option<u64>, requested: u64) -> Result<(), BridgeError> {
    if active_epoch.is_some_and(|active| requested <= active) {
        return Err(BridgeError::new(
            BridgeErrorKind::InvalidInput,
            "client epoch must advance beyond the active runtime",
        ));
    }
    Ok(())
}

fn validate_identifier(value: &str, name: &str) -> Result<(), BridgeError> {
    if value.trim().is_empty() || value.len() > 512 {
        return Err(BridgeError::new(
            BridgeErrorKind::InvalidInput,
            format!("invalid {name}"),
        ));
    }
    Ok(())
}

fn required_string(value: &Value, key: &str) -> Result<String, BridgeError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| {
            BridgeError::new(
                BridgeErrorKind::ProtocolMismatch,
                format!("missing {key} in native response"),
            )
        })
}

fn required_nested_string(value: &Value, path: &[&str]) -> Result<String, BridgeError> {
    json_string_at(value, path).ok_or_else(|| {
        BridgeError::new(
            BridgeErrorKind::ProtocolMismatch,
            "native response is missing an identifier",
        )
    })
}

fn json_string_at(value: &Value, path: &[&str]) -> Option<String> {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn snapshot_hash(snapshot: Option<&[u8]>) -> Option<String> {
    snapshot.map(|bytes| hex_prefix(&Sha256::digest(bytes)))
}

fn hex_prefix(bytes: &[u8]) -> String {
    bytes
        .iter()
        .take(16)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn classify_protocol_error(code: i64, message: &str) -> BridgeError {
    let lower = message.to_ascii_lowercase();
    let kind = if code == 429 || lower.contains("rate limit") {
        BridgeErrorKind::RateLimit
    } else if code == 401 || lower.contains("auth") || lower.contains("login") {
        BridgeErrorKind::Authentication
    } else if lower.contains("cancel") || lower.contains("interrupt") {
        BridgeErrorKind::Cancellation
    } else if code == -32602 {
        BridgeErrorKind::InvalidInput
    } else {
        BridgeErrorKind::Network
    };
    BridgeError::new(
        kind,
        match kind {
            BridgeErrorKind::RateLimit => "ChatGPT rate limit reached.",
            BridgeErrorKind::Authentication => "ChatGPT authentication is required.",
            BridgeErrorKind::Cancellation => "The ChatGPT request was cancelled.",
            BridgeErrorKind::InvalidInput => "ChatGPT rejected the request.",
            _ => "The ChatGPT request failed.",
        },
    )
}

fn runtime_not_initialized() -> BridgeError {
    BridgeError::new(
        BridgeErrorKind::ProtocolMismatch,
        "native runtime is not initialized",
    )
}

async fn context_snapshot() -> Result<EventContext, BridgeError> {
    let guard = RUNTIME.lock().await;
    let runtime = guard.as_ref().ok_or_else(runtime_not_initialized)?;
    Ok(EventContext {
        hub: runtime.hub.clone(),
        codex_home: runtime.codex_home.clone(),
        committed_auth_hash: runtime.committed_auth_hash.clone(),
        auth_persistence: runtime.auth_persistence.clone(),
        pending_auth: runtime.pending_auth.clone(),
        active_login_id: runtime.active_login_id.clone(),
        turn_to_run: runtime.turn_to_run.clone(),
        scheduler: runtime.scheduler.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_context(scheduler: TurnScheduler) -> EventContext {
        EventContext {
            hub: EventHub::new(1),
            codex_home: PathBuf::new(),
            committed_auth_hash: Arc::new(Mutex::new(None)),
            auth_persistence: Arc::new(Mutex::new(())),
            pending_auth: Arc::new(Mutex::new(HashMap::new())),
            active_login_id: Arc::new(Mutex::new(None)),
            turn_to_run: Arc::new(Mutex::new(HashMap::new())),
            scheduler: Arc::new(Mutex::new(scheduler)),
        }
    }

    fn queued_run(run_id: &str, thread_id: &str) -> QueuedRun {
        let mut request = TurnRequest {
            thread_id: thread_id.to_owned(),
            client_user_message_id: None,
            model_id: "model".to_owned(),
            reasoning_effort: None,
            enable_web_search: false,
            enable_image_generation: false,
            inputs: vec![TurnInputPart {
                kind: "text".to_owned(),
                text: Some("hello".to_owned()),
                filename: None,
                mime_type: None,
                bytes: None,
            }],
        };
        let encoded_inputs = encode_turn_inputs(&request.inputs).unwrap();
        let encoded_input_bytes = encoded_inputs_size(&encoded_inputs).unwrap();
        request.inputs.clear();
        QueuedRun {
            run_id: run_id.to_owned(),
            request,
            encoded_inputs,
            encoded_input_bytes,
        }
    }

    #[test]
    fn document_input_accepts_text_and_rejects_opaque_binary() {
        let text = TurnInputPart {
            kind: "document".to_owned(),
            text: None,
            filename: Some("notes.md".to_owned()),
            mime_type: Some("text/markdown".to_owned()),
            bytes: Some(b"hello </document> & goodbye".to_vec()),
        };
        let encoded = encode_turn_inputs(&[text]).unwrap();
        let rendered = encoded[0].get("text").and_then(Value::as_str).unwrap();
        assert!(rendered.contains("hello &lt;/document&gt; &amp; goodbye"));
        assert!(!rendered.contains("hello </document>"));
        let pdf = TurnInputPart {
            kind: "document".to_owned(),
            text: None,
            filename: Some("file.pdf".to_owned()),
            mime_type: Some("application/pdf".to_owned()),
            bytes: Some(vec![1, 2, 3]),
        };
        assert_eq!(
            encode_turn_inputs(&[pdf]).unwrap_err().kind,
            BridgeErrorKind::Unsupported
        );
    }

    #[test]
    fn binary_input_media_types_are_validated() {
        for (kind, mime_type) in [
            ("image", "text/plain"),
            ("audio", "audio/mpeg;codecs=mp3"),
            ("image", "image/png\ninvalid"),
        ] {
            let part = TurnInputPart {
                kind: kind.to_owned(),
                text: None,
                filename: None,
                mime_type: Some(mime_type.to_owned()),
                bytes: Some(vec![1, 2, 3]),
            };
            assert_eq!(
                encode_turn_inputs(&[part]).unwrap_err().kind,
                BridgeErrorKind::InvalidInput
            );
        }
    }

    #[test]
    fn text_inputs_are_bounded() {
        let oversized = TurnInputPart {
            kind: "text".to_owned(),
            text: Some("x".repeat(MAX_TEXT_INPUT_BYTES + 1)),
            filename: None,
            mime_type: None,
            bytes: None,
        };
        assert_eq!(
            encode_turn_inputs(&[oversized]).unwrap_err().kind,
            BridgeErrorKind::InvalidInput
        );
    }
    #[test]
    fn protocol_errors_are_redacted_and_typed() {
        let error = classify_protocol_error(401, "token abc-secret was invalid");
        assert_eq!(error.kind, BridgeErrorKind::Authentication);
        assert!(!error.message.contains("abc-secret"));
    }

    #[test]
    fn chatgpt_account_response_is_authenticated() {
        let auth = parse_auth_state(
            &json!({
                "account": {
                    "type": "chatgpt",
                    "email": "person@example.com",
                    "planType": "plus"
                },
                "requiresOpenaiAuth": true
            }),
            Some("workspace-123".to_owned()),
        );

        assert!(auth.authenticated);
        assert_eq!(auth.email.as_deref(), Some("person@example.com"));
        assert_eq!(auth.plan_type.as_deref(), Some("plus"));
        assert!(auth.account_fingerprint.is_some());
    }

    #[test]
    fn missing_chatgpt_account_response_is_disconnected() {
        let auth = parse_auth_state(&json!({"account": null, "requiresOpenaiAuth": true}), None);

        assert!(!auth.authenticated);
        assert!(auth.account_fingerprint.is_none());
    }

    #[test]
    fn rpc_allowlist_contains_only_mobile_chat_methods() {
        assert_eq!(
            ALLOWED_RPC_METHODS,
            [
                "account/login/cancel",
                "account/login/start",
                "account/logout",
                "account/read",
                "model/list",
                "thread/fork",
                "thread/resume",
                "thread/start",
                "turn/interrupt",
                "turn/start",
            ]
        );
        assert!(!ALLOWED_RPC_METHODS.iter().any(|method| {
            method.contains("exec")
                || method.contains("mcp")
                || method.contains("command")
                || method.contains("workspace")
                || method.contains("approval")
                || method.contains("patch")
        }));
    }

    #[tokio::test]
    async fn generated_images_cross_the_bridge_as_bounded_bytes() {
        let params = json!({
            "item": {
                "type": "imageGeneration",
                "result": "data:image/webp;base64,AQID",
                "savedPath": "/private/secret/image.webp"
            }
        });
        assert_eq!(
            generated_image_bytes(&params, Path::new("/unavailable")).await,
            Some(vec![1, 2, 3])
        );
        let metadata = sanitized_generated_image_json(&params).unwrap();
        assert!(metadata.contains("image/webp"));
        assert!(!metadata.contains("savedPath"));
        assert!(!metadata.contains("private/secret"));

        let raw_base64 = json!({"item": {"result": "AQID"}});
        assert_eq!(
            generated_image_bytes(&raw_base64, Path::new("/unavailable")).await,
            None
        );
        let wrong_mime = json!({
            "item": {"result": "data:text/plain;base64,AQID"}
        });
        assert_eq!(
            generated_image_bytes(&wrong_mime, Path::new("/unavailable")).await,
            None
        );
    }

    #[test]
    fn source_and_usage_payloads_drop_untrusted_response_fields() {
        let source = json!({
            "item": {
                "type": "webSearch",
                "query": "secret query",
                "results": [{
                    "url": "https://example.com/source",
                    "title": "Example",
                    "snippet": "A result",
                    "raw_html": "<private>"
                }]
            }
        });
        let source_json = sanitized_source_json(&source).unwrap();
        assert!(source_json.contains("https://example.com/source"));
        assert!(!source_json.contains("secret query"));
        assert!(!source_json.contains("raw_html"));

        let usage = json!({
            "responseId": "sensitive-response-id",
            "usage": {"inputTokens": 12, "outputTokens": 4},
            "raw": "provider payload"
        });
        let usage_json = sanitized_usage_json(&usage).unwrap();
        assert!(usage_json.contains("12"));
        assert!(!usage_json.contains("sensitive-response-id"));
        assert!(!usage_json.contains("provider payload"));
    }

    #[tokio::test]
    async fn delta_coalescer_preserves_order_and_limit() {
        let hub = EventHub::new(7);
        let mut receiver = hub.subscribe().await;
        let mut pending = None;
        let first = RuntimeEvent {
            kind: RuntimeEventKind::TextDelta,
            text: Some("a".to_owned()),
            ..blank_event()
        };
        let second = RuntimeEvent {
            kind: RuntimeEventKind::TextDelta,
            text: Some("b".to_owned()),
            ..blank_event()
        };
        merge_or_flush_delta(&hub, &mut pending, first).await;
        merge_or_flush_delta(&hub, &mut pending, second).await;
        hub.emit(pending.take().unwrap().event).await;
        let event = receiver.recv().await.unwrap();
        assert_eq!(event.text.as_deref(), Some("ab"));
        assert_eq!(event.client_epoch, 7);
    }

    #[tokio::test]
    async fn delta_coalescer_never_merges_different_turns() {
        let hub = EventHub::new(7);
        let mut receiver = hub.subscribe().await;
        let mut pending = None;
        let first = RuntimeEvent {
            kind: RuntimeEventKind::TextDelta,
            run_id: Some("run".to_owned()),
            thread_id: Some("thread-a".to_owned()),
            turn_id: Some("turn-a".to_owned()),
            item_id: Some("item".to_owned()),
            text: Some("a".to_owned()),
            ..blank_event()
        };
        let second = RuntimeEvent {
            kind: RuntimeEventKind::TextDelta,
            run_id: Some("run".to_owned()),
            thread_id: Some("thread-b".to_owned()),
            turn_id: Some("turn-b".to_owned()),
            item_id: Some("item".to_owned()),
            text: Some("b".to_owned()),
            ..blank_event()
        };

        merge_or_flush_delta(&hub, &mut pending, first).await;
        merge_or_flush_delta(&hub, &mut pending, second).await;
        hub.emit(pending.take().unwrap().event).await;

        assert_eq!(receiver.recv().await.unwrap().text.as_deref(), Some("a"));
        assert_eq!(receiver.recv().await.unwrap().text.as_deref(), Some("b"));
    }

    #[test]
    fn client_epoch_must_advance_beyond_active_runtime() {
        assert!(validate_client_epoch(None, 1).is_ok());
        assert!(validate_client_epoch(Some(7), 8).is_ok());
        assert!(validate_client_epoch(Some(7), 7).is_err());
        assert!(validate_client_epoch(Some(7), 6).is_err());
    }

    #[tokio::test]
    async fn scheduler_keeps_fifo_and_one_run_per_thread() {
        let queued = VecDeque::from([
            queued_run("run-a2", "thread-a"),
            queued_run("run-c", "thread-c"),
        ]);
        let queued_input_bytes = queued.iter().map(|run| run.encoded_input_bytes).sum();
        let context = test_context(TurnScheduler {
            active_by_thread: HashMap::from([
                (
                    "thread-a".to_owned(),
                    ActiveRun {
                        run_id: "run-a".to_owned(),
                        turn_id: Some("turn-a".to_owned()),
                        cancellation_requested: false,
                        last_activity: Instant::now(),
                    },
                ),
                (
                    "thread-b".to_owned(),
                    ActiveRun {
                        run_id: "run-b".to_owned(),
                        turn_id: Some("turn-b".to_owned()),
                        cancellation_requested: false,
                        last_activity: Instant::now(),
                    },
                ),
            ]),
            queued,
            queued_input_bytes,
        });

        // Completing B opens capacity, but strict FIFO keeps C behind A2.
        assert!(
            release_and_take_next(&context, "run-b", "thread-b")
                .await
                .is_none()
        );
        let next = release_and_take_next(&context, "run-a", "thread-a")
            .await
            .expect("head becomes eligible");
        assert_eq!(next.run_id, "run-a2");
        let scheduler = context.scheduler.lock().await;
        assert_eq!(scheduler.active_by_thread.len(), 1);
        assert_eq!(scheduler.queued.front().unwrap().run_id, "run-c");
    }

    #[tokio::test]
    async fn watchdog_releases_a_stalled_run_and_emits_failure() {
        let context = test_context(TurnScheduler {
            active_by_thread: HashMap::from([(
                "thread-a".to_owned(),
                ActiveRun {
                    run_id: "run-a".to_owned(),
                    turn_id: None,
                    cancellation_requested: false,
                    last_activity: Instant::now() - ACTIVE_RUN_IDLE_TIMEOUT,
                },
            )]),
            queued: VecDeque::new(),
            queued_input_bytes: 0,
        });
        let mut receiver = context.hub.subscribe().await;

        expire_stalled_runs(&context).await;

        let event = tokio::time::timeout(Duration::from_secs(1), receiver.recv())
            .await
            .expect("watchdog event timed out")
            .expect("watchdog event stream closed");
        assert_eq!(event.kind, RuntimeEventKind::Failure);
        assert_eq!(event.run_id.as_deref(), Some("run-a"));
        assert_eq!(event.thread_id.as_deref(), Some("thread-a"));
        assert!(context.scheduler.lock().await.active_by_thread.is_empty());
    }
}
