#!/usr/bin/env bash
# Records one LibreChat generation's SSE stream to a file, for Conduit's
# stream fixtures (packages/conduit_core/test/features/librechat/fixtures/).
#
#   LIBRECHAT_PASSWORD=... ./record_sse.sh <email> <endpoint> <model> '<prompt>' out.sse [resume]
#
# For the agents endpoint, set LIBRECHAT_AGENT_ID to the agent to run.
# Signs in, starts a generation over protocol v2, and writes the raw stream.
# With a sixth argument "resume", it waits a second after starting and
# subscribes with resume=true, which captures the sync frame a reconnecting
# client sees. Without LIBRECHAT_PASSWORD it asks for the password. The
# password, request bodies and token never reach a command line, where other
# users could read them. Needs curl and jq.

set -euo pipefail

if [ "$#" -lt 5 ]; then
  sed -n '2,14p' "$0" >&2
  exit 64
fi

email=$1 endpoint=$2 model=$3 prompt=$4 out=$5 mode=${6:-fresh}
base=${LIBRECHAT_URL:-http://localhost:3080}
# Any User-Agent without a browser name gets the account banned.
ua='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

if [ -z "${LIBRECHAT_PASSWORD:-}" ]; then
  read -rsp 'LibreChat password: ' LIBRECHAT_PASSWORD
  echo >&2
fi
export LIBRECHAT_EMAIL=$email LIBRECHAT_PASSWORD

# mktemp creates these readable by this user only.
jar=$(mktemp)
tmp=$(mktemp)
auth=$(mktemp)
trap 'rm -f "$jar" "$tmp" "$auth"' EXIT

token=$(jq -n '{email: env.LIBRECHAT_EMAIL, password: env.LIBRECHAT_PASSWORD}' |
  curl -sf -c "$jar" -A "$ua" -H 'Content-Type: application/json' -d @- \
    "$base/api/auth/login" | jq -r .token)
printf 'Authorization: Bearer %s\n' "$token" >"$auth"

if [ "$endpoint" = agents ] && [ -z "${LIBRECHAT_AGENT_ID:-}" ]; then
  echo "the agents endpoint needs LIBRECHAT_AGENT_ID" >&2
  exit 64
fi
jq -n --arg t "$prompt" --arg e "$endpoint" --arg m "$model" --arg a "${LIBRECHAT_AGENT_ID:-}" --arg r "conduit-fixture-$(date +%s)-$RANDOM$RANDOM" '{
  text: $t, endpoint: $e, endpointType: (if $e == "agents" then null else "custom" end), model: $m,
  conversationId: null, parentMessageId: "00000000-0000-0000-0000-000000000000",
  clientRequestId: $r, generationProtocolVersion: 2
} + (if $e == "agents" then {agent_id: $a} else {} end)' >"$tmp"

start=$(curl -sf -A "$ua" -H @"$auth" -H 'Content-Type: application/json' \
  -H 'x-librechat-generation-protocol: 2' -d @"$tmp" \
  "$base/api/agents/chat/$(jq -rn --arg e "$endpoint" '$e|@uri')?generationProtocolVersion=2")
echo "start: $start" >&2

stream=$(jq -r .streamId <<<"$start")
created=$(jq -r .generationCreatedAt <<<"$start")
query="generationCreatedAt=$created&generationProtocolVersion=2"
if [ "$mode" = resume ]; then
  sleep 1
  query="$query&resume=true"
fi

# An HTTP error (a 404 once the generation already finished, say) fails
# the script and leaves $out alone.
curl -fsN -A "$ua" -H @"$auth" -H 'Accept: text/event-stream' \
  -H 'x-librechat-generation-protocol: 2' \
  "$base/api/agents/chat/stream/$stream?$query" >"$tmp"
# A generation that fails after it started still answers 200 and ends the
# stream with an error event, and a v2 stream can end on a reconcile frame
# that carries no reply: only a final frame with the reply replaces $out.
if grep -q '^event: error' "$tmp" ||
  ! sed -n 's/^data: //p' "$tmp" |
    jq -Re 'fromjson? | select(.final == true and .responseMessage != null)' \
      >/dev/null; then
  echo "the generation did not finish; $out left alone:" >&2
  tail -n 3 "$tmp" >&2
  exit 1
fi
mv "$tmp" "$out"
echo "wrote $out" >&2
