#!/bin/sh
#
# bsdopen-winsize - keeps the serial console the size of the Mac terminal
#
# A serial line has no way to tell the guest that the terminal window was
# resized. The Mac launcher (start-uefi.sh) sends "<rows> <cols>" lines over a
# virtio-serial port whenever the window changes (and every few seconds, so a
# reboot inside the VM picks the size up again). This applies them to the
# console with stty, and the kernel then sends SIGWINCH to the program running
# there (shell, htop, vi, the login screen), which redraws at the new size.
#
# Installed by bsdopen-setup.sh as /usr/local/sbin/bsdopen-winsize and run by
# daemon(8) from /usr/local/etc/rc.d/bsdopen_winsize.
#
PORT="/dev/vtcon/org.bsdopen.winsize"
TTY="${BSDOPEN_WINSIZE_TTY:-/dev/ttyu0}"

[ -e "$PORT" ] || { echo "bsdopen-winsize: $PORT not found" >&2; exit 0; }
exec 3<"$PORT" || exit 1
# The port is a tty: without this it would echo every line back to the Mac
stty -echo <&3 2>/dev/null || true

valid() {
  case "$1" in
    ""|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 4 ]
}

while IFS=' ' read -r rows cols <&3; do
  cols="${cols%"$(printf '\r')"}"
  if ! valid "$rows" || ! valid "$cols"; then continue; fi
  [ "$(stty -f "$TTY" size 2>/dev/null)" = "$rows $cols" ] && continue
  stty -f "$TTY" rows "$rows" columns "$cols" 2>/dev/null || true
done
