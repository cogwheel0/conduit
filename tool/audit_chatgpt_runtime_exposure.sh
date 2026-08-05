#!/usr/bin/env bash
set -euo pipefail

manifest="${CHATGPT_AUDIT_MANIFEST:-native/chatgpt_runtime/Cargo.toml}"
runtime="native/chatgpt_runtime/src/api/runtime.rs"
contract="native/chatgpt_runtime/src/api/contract.rs"
audit_cargo="${CHATGPT_AUDIT_CARGO:-cargo}"
failed=0

fail() {
  echo "ChatGPT runtime exposure audit: $1" >&2
  failed=1
}

# Only the lower-level pinned Codex clients may be direct dependencies. Cargo's
# transitive graph is reported for review, but accepted transitive crates do not
# fail this audit unless they introduce the prohibited V8/Deno runtime.
for crate in codex-api codex-login codex-protocol; do
  if ! grep -Eq "^$crate = \{ git = \"https://github.com/openai/codex\", rev = \"25af12f7e61572b0bc18ddb1008be543b91519b0\" \}$" "$manifest"; then
    fail "$crate is not pinned to the approved Codex commit"
  fi
done

prohibited_direct_crates=(
  codex-app-server
  codex-core
  codex-tools
  codex-exec
  codex-feedback
  codex-apply-patch
  codex-mcp
  codex-sandboxing
  codex-shell-command
)
for crate in "${prohibited_direct_crates[@]}"; do
  if grep -Eq "^[[:space:]]*($crate|\"$crate\"|'$crate')[[:space:]]*=" "$manifest" ||
    grep -Eq "package[[:space:]]*=[[:space:]]*['\"]$crate['\"]" "$manifest"; then
    fail "prohibited direct dependency is present: $crate"
  fi
done

if [ "$failed" -ne 0 ]; then
  exit "$failed"
fi

dependency_tree="$($audit_cargo tree --manifest-path "$manifest" --locked --prefix none --target all --all-features)"

for crate in deno_core deno_core_icudata v8; do
  if grep -Eq "^$crate v" <<<"$dependency_tree"; then
    fail "heavyweight scripting runtime is present: $crate"
  fi
done

# The bridge is a closed typed surface. Adding thread/app-server methods,
# generic dispatch, or an arbitrary tool registration API must fail CI.
expected_bridge_api=$'ack_auth_mutation\nauth_state\nbegin_device_code_login\nbridge_protocol_version\ncancel_device_code_login\ndisconnect_account\ninit_app\ninitialize_runtime\ninterrupt_turn\nlist_models\nruntime_events\nshutdown_runtime\nstart_turn'
actual_bridge_api="$(sed -nE 's/^pub (async )?fn ([A-Za-z0-9_]+).*/\2/p' "$runtime" | LC_ALL=C sort -u)"
if [ "$actual_bridge_api" != "$expected_bridge_api" ]; then
  fail "the FRB-exported Rust API differs from the approved v3 surface"
  echo "expected API:" >&2
  echo "$expected_bridge_api" >&2
  echo "actual API:" >&2
  echo "$actual_bridge_api" >&2
fi

if grep -Eiq '(json.?rpc|generic.?rpc|dispatch_rpc|register_tool|dynamic_tools|dart_tools)' "$runtime" "$contract"; then
  fail "generic RPC or arbitrary tool registration is exposed"
fi
if grep -Eiq '(workspace|filesystem|file_path|directory_path|shell_command|approval_policy)' "$contract"; then
  fail "the typed bridge exposes a coding, filesystem, or workspace capability"
fi
if grep -Eq 'thread_id|turn_id' "$contract" || grep -Eq 'pub (async )?fn (start_thread|resume_thread|fork_thread)' "$runtime"; then
  fail "legacy app-server thread/turn identifiers remain exposed"
fi

# These are the only lower-level endpoint clients the coordinator may create.
expected_clients=$'CompactClient\nImagesClient\nModelsClient\nResponsesClient\nSearchClient'
actual_clients="$(perl -ne 'while (/([A-Za-z]+Client)::new/g) { print "$1\n" }' "$runtime" | LC_ALL=C sort -u)"
if [ "$actual_clients" != "$expected_clients" ]; then
  fail "the approved endpoint-client families changed"
  echo "expected clients:" >&2
  echo "$expected_clients" >&2
  echo "actual clients:" >&2
  echo "$actual_clients" >&2
fi
auth_bound_client_count="$(grep -Fc 'Arc::clone(&runtime.auth_provider)' "$runtime")"
if [ "$auth_bound_client_count" -ne 5 ]; then
  fail "every approved endpoint client must use the fixed ChatGPT auth provider"
fi
if ! grep -Fq 'const CHATGPT_CODEX_BASE_URL: &str = "https://chatgpt.com/backend-api/codex";' "$runtime"; then
  fail "the transport base URL is no longer fixed to the ChatGPT Codex API"
fi
if ! grep -Fq 'store: false' "$runtime"; then
  fail "Responses requests must not synchronize Conduit chats to website history"
fi
if grep -Eq 'base_url|endpoint_url|provider_url' "$contract"; then
  fail "the bridge can supply an arbitrary provider endpoint"
fi

# Parse only the schema block so tests and execution matches cannot mask a
# newly exposed namespace. The exact public tools are web.run and
# image_gen.imagegen; image inputs are conversation bytes, never paths.
tool_schema="$(perl -0777 -ne 'if (/fn tool_specs.*?(fn tool_text_output)/s) { print $& }' "$runtime")"
actual_tool_names="$(grep -oE '"name": "[A-Za-z0-9_]+"' <<<"$tool_schema" | sed -E 's/.*"([A-Za-z0-9_]+)"/\1/' | LC_ALL=C sort -u)"
expected_tool_names=$'image_gen\nimagegen\nrun\nweb'
if [ "$actual_tool_names" != "$expected_tool_names" ]; then
  fail "the exposed tool namespaces/functions differ from web.run and image_gen.imagegen"
fi
namespace_count="$(grep -Fc '"type": "namespace"' <<<"$tool_schema")"
function_count="$(grep -Fc '"type": "function"' <<<"$tool_schema")"
if [ "$namespace_count" -ne 2 ] || [ "$function_count" -ne 2 ]; then
  fail "the tool schema does not contain exactly two namespaces and functions"
fi
if grep -Eiq '(referenced_image_paths|file_path|filesystem|workspace)' <<<"$tool_schema"; then
  fail "a tool accepts filesystem or workspace input"
fi

# Rust's exhaustive enum matches provide the compile-time protocol guard. Keep
# the explicit deny branches visible so unknown provider/tool/input items fail
# closed instead of leaking provider JSON to Flutter.
required_fail_closed_markers=(
  'the model returned an unsupported operation'
  'the model requested an unapproved tool'
  'the input type is unsupported'
  'validate_checkpoint_items(&checkpoint.items)?'
  'ResponseItem::LocalShellCall'
  'ResponseItem::CustomToolCall'
  'ResponseItem::ImageGenerationCall'
  'ResponseEvent::ReasoningContentDelta'
)
for marker in "${required_fail_closed_markers[@]}"; do
  if ! grep -Fq "$marker" "$runtime"; then
    fail "required fail-closed protocol guard is missing: $marker"
  fi
done
if grep -Eq 'ToolStarted|ToolCompleted|raw_provider|raw_reasoning' "$contract"; then
  fail "raw tool/provider/reasoning events are exposed to Flutter"
fi

# Credentials must remain in codex-login's in-memory store. The only durable
# snapshot crosses the typed AuthMutationRequired event to secure Dart storage.
for marker in 'AuthCredentialsStoreMode::Ephemeral' 'RuntimeEventKind::AuthMutationRequired' 'AUTH_ACK_TIMEOUT'; do
  if ! grep -Fq "$marker" "$runtime"; then
    fail "ephemeral credential persistence guard is missing: $marker"
  fi
done
if grep -Fq 'AuthCredentialsStoreMode::File' "$runtime"; then
  fail "Rust can persist an auth.json credential file"
fi

if [ "$failed" -ne 0 ]; then
  exit "$failed"
fi

transitive_codex_crates="$(grep '^codex-' <<<"$dependency_tree" | sed -E 's/ v[0-9].*$//' | LC_ALL=C sort -u)"
echo "ChatGPT runtime exposure audit passed"
echo "  typed FRB functions: $(printf '%s\n' "$expected_bridge_api" | wc -l | tr -d ' ')"
echo "  endpoint clients: $(printf '%s\n' "$expected_clients" | wc -l | tr -d ' ')"
echo "  tools: web.run, image_gen.imagegen"
echo "  accepted transitive Codex crates (report only):"
sed 's/^/    /' <<<"$transitive_codex_crates"
