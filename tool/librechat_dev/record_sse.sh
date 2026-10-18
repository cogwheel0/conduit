#!/usr/bin/env bash
# Records one LibreChat generation's SSE stream to a file, for Conduit's
# stream fixtures (packages/conduit_core/test/features/librechat/fixtures/).
#
#   ./record_sse.sh <email> <password> <endpoint> <model> '<prompt>' out.sse [resume]
#
# Signs in, starts a generation over protocol v2, and writes the raw stream.
# With a seventh argument "resume", it waits a second after starting and
# subscribes with resume=true, which captures the sync frame a reconnecting
# client sees. Needs curl and jq.

set -euo pipefail

if [ "$#" -lt 6 ]; then
  sed -n '2,10p' "$0" >&2
  exit 64
fi

email=$1 password=$2 endpoint=$3 model=$4 prompt=$5 out=$6 mode=${7:-fresh}
base=${LIBRECHAT_URL:-http://localhost:3080}
# Any User-Agent without a browser name gets the account banned.
ua='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

jar=$(mktemp)
tmp=$(mktemp)
trap 'rm -f "$jar" "$tmp"' EXIT

token=$(curl -sf -c "$jar" -A "$ua" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" \
  "$base/api/auth/login" | jq -r .token)

body=$(jq -n --arg t "$prompt" --arg e "$endpoint" --arg m "$model" --arg r "conduit-fixture-$(date +%s)-$RANDOM$RANDOM" '{
  text: $t, endpoint: $e, endpointType: (if $e == "agents" then null else "custom" end), model: $m,
  conversationId: null, parentMessageId: "00000000-0000-0000-0000-000000000000",
  clientRequestId: $r, generationProtocolVersion: 2
}')

start=$(curl -sf -A "$ua" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  -H 'x-librechat-generation-protocol: 2' -d "$body" \
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
curl -fsN -A "$ua" -H "Authorization: Bearer $token" -H 'Accept: text/event-stream' \
  -H 'x-librechat-generation-protocol: 2' \
  "$base/api/agents/chat/stream/$stream?$query" >"$tmp"
mv "$tmp" "$out"
echo "wrote $out" >&2
