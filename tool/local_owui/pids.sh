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

# Records PID, just started, in FILE. Waits (a few seconds at most) for a
# `nohup` in front of it to hand over to the program, whose command line is
# the one to remember. Writes nothing if the process is already gone.
pid_record() {
  local file=$1 pid=$2 command identity
  for _ in $(seq 1 50); do
    command=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
    case "$command" in
      nohup\ *) sleep 0.1 ;;
      *) break ;;
    esac
  done
  identity=$(pid_identity "$pid")
  [ -n "$identity" ] || return 0
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
