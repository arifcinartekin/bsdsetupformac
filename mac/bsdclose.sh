#!/bin/bash
#
# bsdclose - shuts the FreeBSD VM of BSD Setup for Mac down from macOS
#
# Presses the virtual power button through QEMU's QMP socket, so FreeBSD shuts
# down cleanly (same as `poweroff` inside the VM). If the VM has not stopped
# after the timeout, QEMU is stopped hard.
#
# Usage:
#   bsdclose            clean shutdown, hard stop after 90 s
#   bsdclose --force    hard stop right away (like pulling the plug)
#
# Environment: BSDOPEN_DIR (default: the directory of this script),
#              BSDCLOSE_TIMEOUT=90
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$DIR/start-uefi.sh" ]; then
  DIR="${BSDOPEN_DIR:-$HOME/vm/freebsd}"
fi
SOCK="$DIR/qmp.sock"
PIDFILE="$DIR/qemu.pid"
TIMEOUT="${BSDCLOSE_TIMEOUT:-90}"
FORCE=0

case "${1:-}" in
  "")         ;;
  -f|--force) FORCE=1 ;;
  -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)          echo "bsdclose: unknown option: $1 (help: --help)" >&2; exit 2 ;;
esac

# Prints the pid of this install's QEMU, if it is running
vm_pid() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$DIR/disk.qcow2" || return 1
  printf '%s\n' "$pid"
}

# qmp <command>: sends one QMP command to the running VM
qmp() {
  python3 - "$SOCK" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()  # greeting
for cmd in ("qmp_capabilities", sys.argv[2]):
    f.write(json.dumps({"execute": cmd}) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            sys.exit(0 if cmd == "quit" else 1)
        reply = json.loads(line)
        if "return" in reply:
            break
        if "error" in reply:
            sys.exit(reply["error"].get("desc", "QMP error"))
PY
}

wait_exit() { # pid seconds
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$i" -lt "$2" ] || return 1
    sleep 1
    i=$((i + 1))
  done
}

hard_stop() { # pid
  if [ -S "$SOCK" ] && qmp quit 2>/dev/null && wait_exit "$1" 10; then
    return 0
  fi
  kill "$1" 2>/dev/null || true
  wait_exit "$1" 10 || kill -9 "$1" 2>/dev/null || true
}

if ! PID="$(vm_pid)"; then
  echo "The FreeBSD VM is not running."
  exit 0
fi

if [ "$FORCE" = 1 ]; then
  echo "Stopping the FreeBSD VM hard (pid $PID)..."
  hard_stop "$PID"
  echo "Stopped."
  exit 0
fi

if [ ! -S "$SOCK" ]; then
  echo "No QMP socket ($SOCK): this VM was started by an older launcher." >&2
  echo "Shut it down with 'poweroff' inside the VM, or run: bsdclose --force" >&2
  exit 1
fi

printf 'Shutting down the FreeBSD VM (pid %s)' "$PID"
qmp system_powerdown || { echo; echo "QMP request failed. Try: bsdclose --force" >&2; exit 1; }
i=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$i" -ge "$TIMEOUT" ]; then
    echo
    echo "FreeBSD did not shut down within ${TIMEOUT} s, stopping it hard." >&2
    hard_stop "$PID"
    break
  fi
  printf '.'
  sleep 1
  i=$((i + 1))
done
echo
echo "FreeBSD VM is off."
