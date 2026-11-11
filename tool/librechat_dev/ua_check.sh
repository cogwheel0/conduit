#!/usr/bin/env bash
# Checks User-Agent strings with the ua-parser-js that the running LibreChat
# server uses. Its uaParser middleware bans a user and IP when a chat or file
# request's User-Agent parses without a browser name, so every User-Agent
# Conduit sends to LibreChat must print a browser name here.
#
#   ./ua_check.sh 'Mozilla/5.0 (iPhone; ...) Conduit/4.2.1' ['another UA' ...]
#
# With no arguments it checks the strings Conduit's tests pin
# (packages/conduit_core/test/features/librechat/fixtures/user_agents.txt).

set -euo pipefail
cd "$(dirname "$0")"

fixtures=../../packages/conduit_core/test/features/librechat/fixtures/user_agents.txt
if [ "$#" -eq 0 ]; then
  if [ ! -f "$fixtures" ]; then
    echo "usage: $0 '<user agent>' [...]" >&2
    exit 64
  fi
  agents=()
  while IFS= read -r line; do
    agents+=("$line")
  done < <(grep -v '^#' "$fixtures" | grep -v '^$')
else
  agents=("$@")
fi

status=0
for agent in "${agents[@]}"; do
  browser=$(docker compose exec -T api node -e \
    "const b=require('ua-parser-js')(process.argv[1]).browser; process.stdout.write(b.name ? b.name + ' ' + (b.version || '') : '')" \
    "$agent")
  if [ -n "$browser" ]; then
    printf 'ok    %-20s %s\n' "$browser" "$agent"
  else
    printf 'BAN   %-20s %s\n' '(no browser)' "$agent"
    status=1
  fi
done
exit "$status"
