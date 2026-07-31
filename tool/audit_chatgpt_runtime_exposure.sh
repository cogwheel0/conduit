#!/usr/bin/env bash
set -euo pipefail

manifest="native/chatgpt_runtime/Cargo.toml"
runtime="native/chatgpt_runtime/src/api/runtime.rs"
mobile_app_server="native/codex_mobile_compat/app-server/src/in_process.rs"
mobile_app_server_lib="native/codex_mobile_compat/app-server/src/lib.rs"
mobile_app_server_models="native/codex_mobile_compat/app-server/src/models.rs"
mobile_message_processor="native/codex_mobile_compat/app-server/src/message_processor.rs"
audit_cargo="${CHATGPT_AUDIT_CARGO:-cargo}"

failed=0

fail() {
  echo "ChatGPT runtime exposure audit: $1" >&2
  failed=1
}

contains_crate() {
  case "$dependency_tree" in
    "$1 v"*|*$'\n'"$1 v"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Codex 0.145.0 does not feature-gate these coding-oriented crates out of its
# app-server/core graph. They are an explicit dependency-only exception for
# this PR; none may become reachable through the bridge or RPC allowlists below.
accepted_upstream_crates=(
  codex-apply-patch
  codex-exec-server
  codex-file-watcher
  codex-git-utils
  codex-mcp
  codex-sandboxing
  codex-shell-command
  codex-shell-escalation
  codex-skills
)

dependency_tree="$("$audit_cargo" tree --manifest-path "$manifest" --locked --prefix none --target all --all-features)"
if ! grep -Fq 'codex-app-server = { path = "../codex_mobile_compat/app-server" }' "$manifest"; then
  fail "the pinned Codex app-server mobile overlay is not active"
fi
if ! grep -Fq 'codex-app-server v0.145.0 (' <<<"$dependency_tree"; then
  fail "the dependency graph is not using the local Codex app-server overlay"
fi

# Mobile uses the Responses HTTPS stream. Android's platform HTTP client can
# honor device trust configuration that rustls WebSockets cannot import, while
# retaining TLS verification and response streaming.
if ! perl -0777 -e '$text = <>; exit($text =~ /"model_provider".{0,160}?toml::Value::String\("conduit-chatgpt"\.to_owned\(\)\)/s ? 0 : 1)' "$runtime"; then
  fail "the mobile runtime does not select its HTTPS-only ChatGPT provider"
fi
for provider_setting in name wire_api http_headers.version requires_openai_auth supports_websockets; do
  if ! grep -Fq "model_providers.conduit-chatgpt.$provider_setting" "$runtime"; then
    fail "the HTTPS-only ChatGPT provider is missing: $provider_setting"
  fi
done
if ! perl -0777 -e '$text = <>; exit($text =~ /"model_providers\.conduit-chatgpt\.http_headers\.version".{0,160}?toml::Value::String\("0\.145\.0"\.to_owned\(\)\)/s ? 0 : 1)' "$runtime"; then
  fail "the ChatGPT provider version header differs from pinned Codex 0.145.0"
fi
if ! perl -0777 -e '$text = <>; exit($text =~ /"model_providers\.conduit-chatgpt\.supports_websockets".{0,160}?toml::Value::Boolean\(false\)/s ? 0 : 1)' "$runtime"; then
  fail "the mobile ChatGPT provider can re-enable the unsupported WebSocket transport"
fi

# FRB's convenience initializer enables TRACE logging on mobile. Upstream HTTP
# trace/debug events include full response headers, which can contain cookies.
# Keep panic backtraces, but require native diagnostics to cross the sanitized
# Dart event/error boundary instead of entering Android/iOS system logs.
if grep -Fq 'setup_default_user_utils' "$runtime"; then
  fail "the runtime enables FRB TRACE console logging, which can expose response credentials"
fi
if ! grep -Fq 'flutter_rust_bridge::setup_backtrace();' "$runtime"; then
  fail "the runtime no longer initializes native panic backtraces"
fi

# Android/iOS app-private filesystems can reject Codex's advisory lock with
# ErrorKind::Unsupported. The fallback must remain mobile-only, preserve all
# other failures, and serialize same-process installation-ID access.
mobile_lock_markers=(
  'target_os = "android"'
  'target_os = "ios"'
  'error.kind() == ErrorKind::Unsupported'
  'MOBILE_INSTALLATION_ID_LOCK.lock().await'
  'Uuid::parse_str(contents.trim())'
  'Err(error) => Err(error)'
)
for marker in "${mobile_lock_markers[@]}"; do
  if ! grep -Fq "$marker" "$mobile_app_server"; then
    fail "required mobile installation-ID lock fallback is missing: $marker"
  fi
done

# Codex's turn-context future is larger than Tokio's default mobile worker
# stack. Keep the embedded app-server on its isolated, explicitly sized mobile
# runtime so a first turn cannot exhaust an FRB worker and terminate the app.
mobile_runtime_stack_markers=(
  'const MOBILE_RUNTIME_STACK_SIZE_BYTES: usize = 8 * 1024 * 1024;'
  '.thread_stack_size(MOBILE_RUNTIME_STACK_SIZE_BYTES)'
  'codex-mobile-runtime'
)
for marker in "${mobile_runtime_stack_markers[@]}"; do
  if ! grep -Fq "$marker" "$mobile_app_server"; then
    fail "required isolated mobile runtime stack guard is missing: $marker"
  fi
done

for crate in "${accepted_upstream_crates[@]}"; do
  if contains_crate "$crate"; then
    echo "acknowledged upstream-only dependency retained: $crate"
  fi
done

# The V8/Deno code-mode implementation is not accepted. Mobile builds must
# continue to use the local codex-code-mode stub.
for crate in deno_core deno_core_icudata v8; do
  if contains_crate "$crate"; then
    fail "heavyweight scripting runtime is present: $crate"
  fi
done

expected_bridge_api=$'ack_auth_mutation\nauth_state\nbegin_device_code_login\nbridge_protocol_version\ncancel_device_code_login\ndisconnect_account\nfork_thread\ninit_app\ninitialize_runtime\ninterrupt_turn\nlist_models\nresume_thread\nruntime_events\nshutdown_runtime\nstart_thread\nstart_turn'
actual_bridge_api="$(sed -nE 's/^pub (async )?fn ([A-Za-z0-9_]+).*/\2/p' "$runtime" | LC_ALL=C sort -u)"
if [ "$actual_bridge_api" != "$expected_bridge_api" ]; then
  fail "the FRB-exported Rust API differs from the approved typed surface"
  echo "expected API:" >&2
  echo "$expected_bridge_api" >&2
  echo "actual API:" >&2
  echo "$actual_bridge_api" >&2
fi

expected_rpc_methods=$'account/login/cancel\naccount/login/start\naccount/logout\naccount/read\nmodel/list\nthread/fork\nthread/resume\nthread/start\nturn/interrupt\nturn/start'
actual_rpc_allowlist="$(perl -0777 -ne 'if (/const ALLOWED_RPC_METHODS:\s*&\[&str\]\s*=\s*&\[(.*?)\];/s) { $body = $1; while ($body =~ /"([^"]+)"/g) { print "$1\n" } }' "$runtime" | LC_ALL=C sort -u)"
if [ "$actual_rpc_allowlist" != "$expected_rpc_methods" ]; then
  fail "the runtime app-server allowlist differs from the approved chat/auth/thread methods"
  echo "expected allowlist:" >&2
  echo "$expected_rpc_methods" >&2
  echo "actual allowlist:" >&2
  echo "$actual_rpc_allowlist" >&2
fi

actual_rpc_methods="$(perl -0777 -ne 'while (/\brpc\s*\(\s*"([^"]+)"/g) { print "$1\n" }' "$runtime" | LC_ALL=C sort -u)"
if [ "$actual_rpc_methods" != "$expected_rpc_methods" ]; then
  fail "outgoing app-server methods differ from the approved chat/auth/thread allowlist"
  echo "expected methods:" >&2
  echo "$expected_rpc_methods" >&2
  echo "actual methods:" >&2
  echo "$actual_rpc_methods" >&2
fi

# The mobile app-server dispatcher must mirror the bridge allowlist. Besides
# enforcing the capability boundary at runtime, this keeps the async request
# future small enough for Android/iOS worker stacks.
expected_mobile_request_variants=$'CancelLoginAccount\nGetAccount\nLoginAccount\nLogoutAccount\nModelList\nThreadFork\nThreadResume\nThreadStart\nTurnInterrupt\nTurnStart'
actual_mobile_request_variants="$(perl -0777 -ne 'if (/#\[cfg\(any\(target_os = "android", target_os = "ios"\)\)\]\s+async fn handle_initialized_client_request(.*?)#\[cfg\(not\(any\(target_os = "android", target_os = "ios"\)\)\)\]/s) { $body = $1; while ($body =~ /ClientRequest::([A-Za-z0-9_]+)/g) { print "$1\n" } }' "$mobile_message_processor" | LC_ALL=C sort -u)"
if [ "$actual_mobile_request_variants" != "$expected_mobile_request_variants" ]; then
  fail "the compiled mobile app-server dispatcher differs from the approved chat/auth/thread variants"
  echo "expected mobile variants:" >&2
  echo "$expected_mobile_request_variants" >&2
  echo "actual mobile variants:" >&2
  echo "$actual_mobile_request_variants" >&2
fi
if ! grep -Fq 'request is outside the Conduit mobile-chat capability boundary' "$mobile_message_processor"; then
  fail "the mobile app-server dispatcher lacks its deny-by-default branch"
fi

# This deliberately tiny model-normalization helper is the sole new public
# callable added to the app-server overlay. Keep both its re-export and forced
# Direct result visible to the exposure audit.
if ! grep -Fqx 'pub use models::mobile_chat_tool_mode;' "$mobile_app_server_lib"; then
  fail "the audited mobile model-normalization re-export changed"
fi
if ! perl -0777 -e '$text = <>; exit($text =~ /pub fn mobile_chat_tool_mode\([^)]*\)\s*->\s*Option<ToolMode>\s*\{\s*Some\(ToolMode::Direct\)\s*\}/s ? 0 : 1)' "$mobile_app_server_models"; then
  fail "the public mobile model-normalization helper no longer forces Direct mode"
fi

all_rpc_calls="$(perl -0777 -ne '$count++ while /\brpc\s*\(/g; print $count' "$runtime")"
literal_rpc_calls="$(perl -0777 -ne '$count++ while /\brpc\s*\(\s*"[^"]+"/g; print $count' "$runtime")"
if [ "$all_rpc_calls" -ne "$((literal_rpc_calls + 1))" ]; then
  fail "every app-server dispatch must use a literal audited method (plus the rpc function definition)"
fi

required_markers=(
  'const ALLOWED_RPC_METHODS'
  '!ALLOWED_RPC_METHODS.contains(&method)'
  'InProcessServerEvent::ServerRequest(request) =>'
  'client.reject_server_request('
  'code: -32004'
  'EnvironmentManager::without_environments()'
  '"dynamicTools": []'
  '"approvalPolicy": "never"'
  '"sandbox": "read-only"'
)
for marker in "${required_markers[@]}"; do
  if ! grep -Fq "$marker" "$runtime"; then
    fail "required capability guard is missing: $marker"
  fi
done

disabled_features=(
  features.skills
  features.apps
  features.plugins
  features.plugin_hooks
  features.tool_search
  features.tool_suggest
  features.shell_tool
  features.code_mode
  features.multi_agent
  features.multi_agent_v2
  features.request_permissions_tool
)
for feature in "${disabled_features[@]}"; do
  if ! perl -0777 -e '$feature = pop @ARGV; $text = <>; exit($text =~ /"\Q$feature\E".{0,160}?toml::Value::Boolean\(false\)/s ? 0 : 1)' "$runtime" "$feature"; then
    fail "native feature is not explicitly disabled: $feature"
  fi
done

if ! perl -0777 -e '$text = <>; exit($text =~ /"approval_policy".{0,160}?toml::Value::String\("never"\.to_owned\(\)\)/s ? 0 : 1)' "$runtime"; then
  fail "global approval policy is not fixed to never"
fi
if ! perl -0777 -e '$text = <>; exit($text =~ /"sandbox_mode".{0,160}?toml::Value::String\("read-only"\.to_owned\(\)\)/s ? 0 : 1)' "$runtime"; then
  fail "global sandbox mode is not fixed to read-only"
fi

if [ "$failed" -ne 0 ]; then
  exit "$failed"
fi

echo "ChatGPT runtime exposure audit passed"
echo "  typed FRB functions: $(printf '%s\n' "$expected_bridge_api" | wc -l | tr -d ' ')"
echo "  allowed app-server methods: $(printf '%s\n' "$expected_rpc_methods" | wc -l | tr -d ' ')"
echo "  accepted upstream-only crates: ${#accepted_upstream_crates[@]}"
