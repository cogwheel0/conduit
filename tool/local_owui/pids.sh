# Pid files for owui.sh's processes, sourced by it and by pids_test.sh.
#
# A pid file holds the pid on its first line and, on the second, what `ps`
# said about that process when it was started: its start time and command
# line. A process counts as ours only while `ps` still says exactly that. A
# pid left behind by a crash and reused by another process has another start
# time, so it is never taken for ours, nor stopped; nor is another instance's
# process, whose command line differs.

# The start time and command line of process PID, or nothing.
pid_identity() {
  ps -ww -p "$1" -o lstart=,command= 2>/dev/null || true
}

# Records PID, just started, in FILE. Waits (a few seconds at most) for what
# runs first to hand over to the program, whose command line is the one to
# remember: the shell's own copy before it runs the command, a `nohup` in
# front of it, a launcher script such as Homebrew's `dart`, which runs the
# Dart VM in its place. The command line counts as settled once three reads
# a tenth of a second apart agree. Writes nothing if the process is gone. A
# launcher slower than that is caught by pid_refresh once the program serves.
pid_record() {
  local file=$1 pid=$2 command previous= same=0 identity
  # Whatever an earlier run left is not this process.
  rm -f "$file"
  for _ in $(seq 1 50); do
    command=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
    [ -n "$command" ] || return 0
    case "$command" in
      nohup\ *) same=0 ;;
      *)
        if [ "$command" = "$previous" ]; then
          same=$((same + 1))
          [ "$same" -ge 2 ] && break
        else
          same=0
        fi
        ;;
    esac
    previous=$command
    sleep 0.1
  done
  identity=$(pid_identity "$pid")
  [ -n "$identity" ] || return 0
  printf '%s\n%s\n' "$pid" "$identity" > "$file"
}

# Records again, from what `ps` says now, the process FILE names, for a
# program that may have been started through a launcher: once it answers on
# its port, the launcher has handed over, however slow it was. A hand-over
# keeps the pid and its start time and changes only the command line, so the
# record is rewritten only while the start time is still the recorded one: a
# pid that another process has taken since is never adopted.
pid_refresh() {
  local file=$1 pid saved started identity
  [ -f "$file" ] || return 0
  pid=$(sed -n 1p "$file")
  saved=$(sed -n 2p "$file")
  [ -n "$pid" ] && [ -n "$saved" ] || return 0
  # One read, so the start time checked belongs to the identity written
  # (`lstart`, its first 24 characters, is fixed-width).
  identity=$(pid_identity "$pid")
  [ -n "$identity" ] || return 0
  started=${identity:0:24}
  case "$saved" in
    "$started"*) ;;
    *) return 0 ;;
  esac
  printf '%s\n%s\n' "$pid" "$identity" > "$file"
}

# The pid in FILE.
pid_of() {
  sed -n 1p "$1"
}

# Whether the process FILE names is still the one recorded there.
pid_alive() {
  local file=$1 pid saved
  [ -f "$file" ] || return 1
  pid=$(sed -n 1p "$file")
  saved=$(sed -n 2p "$file")
  [ -n "$pid" ] && [ -n "$saved" ] || return 1
  [ "$(pid_identity "$pid")" = "$saved" ]
}

# Stops the process FILE names if it is still the one recorded there: TERM
# to it and its children (some `dart` launchers run the program in a child
# VM), then KILL if it has not ended after TRIES half-seconds (default 20).
# Each check is against the recorded identity, not just the pid, so a pid
# that another process takes meanwhile is never signalled. Prints "stopped"
# or "killed", or nothing when nothing of ours was running.
pid_stop() {
  local file=$1 tries=${2:-20} pid
  pid_alive "$file" || return 0
  pid=$(pid_of "$file")
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 "$tries"); do
    pid_alive "$file" || { echo stopped; return 0; }
    sleep 0.5
  done
  if pid_alive "$file"; then
    kill -KILL "$pid" 2>/dev/null || true
    echo killed
  else
    echo stopped
  fi
}
