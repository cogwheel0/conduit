#!/bin/bash
# Checks that a build of the app carries none of its test harness (the
# `harness` cargo feature: the `--e2e` passes, the `--capture` screenshots,
# `--probe` and the `--fixture` runs) and refuses the harness's flags.
# bundle.sh verify runs it on Conduit.app.
#
#   desktop/packaging/macos/harness_check.sh <Conduit.app | binary> [scratch dir]
#
# 1. Symbols: no function of the harness's modules (`e2e`, `capture`, the
#    `*fixture` modules) is in the binary's symbol table.
# 2. Strings: none of their source paths (Rust keeps a file's path for its
#    panic messages) and none of the lines they print.
# 3. Flags: each harness flag makes the binary exit at once with status 64
#    and a message. Run only when 1 and 2 pass, on a throwaway dev profile,
#    and stopped after 20 s whatever happens.
#
# Exits non-zero when any check fails. Nothing here deletes files.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <Conduit.app | binary> [scratch dir]"
target="$1"
if [ -d "$target" ]; then
  bin="$target/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$target/Contents/Info.plist")"
else
  bin="$target"
fi
[ -x "$bin" ] || die "no executable at $bin"
scratch="${2:-$(mktemp -d "${TMPDIR:-/tmp}/conduit-harness-check.XXXXXX")}"
mkdir -p "$scratch"

failed=0
fail() {
  printf '\033[31mFAIL\033[0m %s\n' "$*"
  failed=1
}
ok() { printf 'ok   %s\n' "$*"; }

# Legacy-mangled Rust paths name each module with its length:
# `15conduit_desktop3e2e`, `7capture`, `12chat_fixture`.
symbols="$(nm -a "$bin" 2>/dev/null |
  grep -E '15conduit_desktop[0-9]+(e2e|capture|[a-z_]*fixture)[0-9]' | head -5 || true)"
if [ -z "$(nm -a "$bin" 2>/dev/null | grep -m1 '15conduit_desktop' || true)" ]; then
  printf 'note no conduit_desktop symbols to check (a stripped binary)\n'
elif [ -n "$symbols" ]; then
  fail "harness symbols in $bin:"
  printf '%s\n' "$symbols" | sed 's/^/     /'
else
  ok "no harness symbols (e2e, capture, fixtures)"
fi

strings="$(strings -a "$bin" | grep -E \
  'crates/app/src/(e2e|capture)(/|\.rs)|crates/app/src/[a-z_]*fixture\.rs|SMOKE e2e ok |SMOKE FAILED e2e |FIXTURE (perf|passed|FAILED)|local-owui\.env' |
  sort -u | head -5 || true)"
if [ -n "$strings" ]; then
  fail "harness strings in $bin:"
  printf '%s\n' "$strings" | sed 's/^/     /'
else
  ok "no harness source paths or output lines"
fi

if [ "$failed" = 0 ]; then
  refused=0
  for flag in --e2e --capture --probe --fixture --chat-fixture; do
    status=0
    err="$(CONDUIT_FLAVOR=dev CONDUIT_USER_DATA="$scratch/user-data" CONDUIT_LOGS="$scratch/logs" \
      perl -e 'alarm shift; exec @ARGV' 20 "$bin" "$flag" x 2>&1 >/dev/null)" || status=$?
    if [ "$status" = 64 ] && [[ "$err" == *"needs a build with the \`harness\` feature"* ]]; then
      refused=$((refused + 1))
    else
      fail "$flag: exit $status, '$err'"
    fi
  done
  [ "$refused" = 5 ] && ok "refuses --e2e, --capture, --probe, --fixture, --chat-fixture (exit 64)"
fi

[ "$failed" = 0 ] || die "the test harness is in $bin"
