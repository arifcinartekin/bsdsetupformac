#!/bin/bash
#
# bsdseal - integrity seal over the files of the FreeBSD VM
#
# `bsdopen` runs `bsdseal verify` before it starts QEMU. If any file in the
# install directory differs from the seal (a disk image, the UEFI firmware or
# its variables, a launcher script), or a file was added or removed, the VM is
# not started: the GELI passphrase prompt never appears on a boot chain that
# was changed behind your back. When the VM shuts down, the launcher seals the
# new state, since the session itself changed the disk.
#
# The seal is the sha256 of a list of every file with its sha256, size and
# mode. That digest is kept in your macOS login Keychain, not next to the
# files, so replacing disk.qcow2 together with the list is not enough.
#
# Usage:
#   bsdseal verify   check the files against the seal (exit 1 if they differ)
#   bsdseal accept   show what changed, ask, then seal the current state
#   bsdseal update   seal the current state without asking (used by the launcher)
#   bsdseal forget   delete the seal from the Keychain (used by bsduninstall)
#
# Environment: BSDOPEN_DIR (default: the directory of this script)
# For testing: BSDSEAL_KEYCHAIN=<path> uses that keychain instead of the login one
#
set -euo pipefail

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$DIR/start-uefi.sh" ]; then
  DIR="${BSDOPEN_DIR:-$HOME/vm/freebsd}"
fi
SEAL_FILE="$DIR/.bsdopen-seal"
SESSION_FILE="$DIR/.bsdopen-session"
KC_SERVICE="bsdopen-seal"
KC=()
[ -z "${BSDSEAL_KEYCHAIN:-}" ] || KC=("$BSDSEAL_KEYCHAIN")

# Not sealed: written by the setup or while the VM runs, and never read at boot
IGNORED=" downloads install.log versions.lock .bsdopen-manifest .bsdopen-seal .bsdopen-session .bsdopen-incomplete qmp.sock qemu.pid vars.run.fd winsize.in winsize.out .DS_Store "
# A seal is only written when the whole boot chain is there
REQUIRED="start-uefi.sh bsdseal.sh efi-code.fd vars.fd disk.qcow2"

sha256() { # [file], stdin without one
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$@" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | awk '{ print $1 }'
  else
    sha256sum "$@" | awk '{ print $1 }'
  fi
}

if [ "$(uname -s)" = Darwin ]; then
  size_mode() { stat -f '%z %Lp' "$1"; }
else
  size_mode() { stat -c '%s %a' "$1"; }
fi

# The reference digest lives in the login Keychain; without `security` (testing
# on Linux) it falls back to a file outside the install directory
if command -v security >/dev/null 2>&1; then
  ref_get() { security find-generic-password -s "$KC_SERVICE" -a "$DIR" -w ${KC[@]+"${KC[@]}"} 2>/dev/null; }
  ref_set() { security add-generic-password -U -s "$KC_SERVICE" -a "$DIR" -l "BSD Setup for Mac: VM integrity seal" -w "$1" ${KC[@]+"${KC[@]}"} >/dev/null; }
  ref_del() { security delete-generic-password -s "$KC_SERVICE" -a "$DIR" ${KC[@]+"${KC[@]}"} >/dev/null 2>&1; }
else
  REF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/bsdopen-seal/$(printf '%s' "$DIR" | sha256)"
  ref_get() { cat "$REF_FILE" 2>/dev/null; }
  ref_set() { mkdir -p "$(dirname "$REF_FILE")" && printf '%s\n' "$1" > "$REF_FILE"; }
  ref_del() { rm -f "$REF_FILE"; }
fi

# One tab-separated line per entry, sorted, path last (escaped with %q, so it has no tabs):
#   file <sha256> <size> <mode> <path> | dir - - <mode> <path> | link <target> <path>
manifest() {
  local path rel
  echo "# bsdseal v1"
  while IFS= read -r -d '' path; do
    rel="${path#./}"
    case "$IGNORED" in *" ${rel%%/*} "*) continue ;; esac
    if [ -L "$DIR/$rel" ]; then
      printf 'link\t%q\t%q\n' "$(readlink "$DIR/$rel")" "$rel"
    elif [ -d "$DIR/$rel" ]; then
      printf 'dir\t-\t-\t%s\t%q\n' "$(size_mode "$DIR/$rel" | awk '{ print $2 }')" "$rel"
    elif [ -f "$DIR/$rel" ]; then
      printf 'file\t%s\t%s\t%q\n' "$(sha256 "$DIR/$rel")" "$(size_mode "$DIR/$rel" | tr ' ' '\t')" "$rel"
    else
      printf 'other\t-\t-\t-\t%q\n' "$rel"
    fi
  done < <(cd "$DIR" && find . -mindepth 1 -print0 | LC_ALL=C sort -z)
}

digest_of() { printf '%s\n' "$1" | sha256; }

vm_running() {
  local pid
  pid="$(cat "$DIR/qemu.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qF "$DIR/disk.qcow2"
}

# Names what differs between the sealed list and the current one. The list in
# .bsdopen-seal is only trusted when it matches the digest in the Keychain.
report_changes() { # current-manifest reference-digest
  local sealed
  sealed="$(cat "$SEAL_FILE" 2>/dev/null || true)"
  if [ -z "$sealed" ] || [ "$(digest_of "$sealed")" != "$2" ]; then
    echo "  The file list next to the VM ($SEAL_FILE) was changed or removed too,"
    echo "  so the changed files cannot be named."
    return 0
  fi
  awk -F '\t' 'NR == FNR { old[$NF] = $0; next }
       { seen[$NF] = 1
         if (!($NF in old)) print "  added:   " $NF
         else if (old[$NF] != $0) print "  changed: " $NF }
       END { for (p in old) if (!(p in seen)) print "  missing: " p }' \
    <(printf '%s\n' "$sealed") <(printf '%s\n' "$1")
}

write_seal() { # manifest digest
  local f
  for f in $REQUIRED; do
    [ -f "$DIR/$f" ] || die "$DIR/$f is missing, not sealing"
  done
  printf '%s\n' "$1" > "$SEAL_FILE.tmp"
  mv "$SEAL_FILE.tmp" "$SEAL_FILE"
  ref_set "$2" || die "could not store the seal in the Keychain (is it locked?)"
}

cmd_verify() {
  local want m cur pid
  log "Checking the VM files against the integrity seal"
  want="$(ref_get || true)"
  if [ -z "$want" ]; then
    printf '%sINTEGRITY CHECK FAILED:%s there is no seal for %s in the Keychain.\n' "$C_R" "$C_0" "$DIR" >&2
    echo "  The VM was not started. A fresh install creates the seal. If you moved or" >&2
    echo "  restored this directory, check it and then run: bsdseal accept" >&2
    return 1
  fi
  m="$(manifest)"
  cur="$(digest_of "$m")"
  if [ "$cur" = "$want" ]; then
    ok "all files match the seal ($(printf '%s\n' "$m" | grep -c '^file') files)"
    return 0
  fi
  {
    printf '\n%sINTEGRITY CHECK FAILED:%s the VM files are not what they were when it last shut down.\n' "$C_R" "$C_0"
    report_changes "$m" "$want"
    echo
    echo "  The VM was NOT started, so nothing has asked for your disk passphrase."
    pid="$(cat "$SESSION_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      echo "  Note: the last session did not end normally (terminal killed, Mac crashed),"
      echo "  so its changes were never sealed. That alone explains a changed disk.qcow2."
    fi
    echo "  If you know why these files changed, check them and run: bsdseal accept"
    echo "  If you do not, do not boot the VM."
  } >&2
  return 1
}

cmd_accept() {
  local want m cur
  { : </dev/tty; } 2>/dev/null || die "bsdseal accept needs a terminal"
  vm_running && die "the VM is running; shut it down first (bsdclose)"
  want="$(ref_get || true)"
  m="$(manifest)"
  cur="$(digest_of "$m")"
  if [ "$cur" = "$want" ]; then
    ok "all files already match the seal"
    return 0
  fi
  if [ -n "$want" ]; then
    echo "Differences from the seal:"
    report_changes "$m" "$want"
  else
    echo "There is no seal for $DIR yet."
  fi
  echo
  warn "Only accept this if you know why the files changed. The next boot will trust them."
  local ans
  printf 'Seal the current state of %s? [y/N] ' "$DIR" >/dev/tty
  IFS= read -r ans </dev/tty || ans=""
  case "$ans" in
    y|Y|yes|Yes) ;;
    *) echo "Nothing changed."; return 1 ;;
  esac
  write_seal "$m" "$cur"
  ok "sealed"
}

cmd_update() {
  local m
  vm_running && die "the VM is running; not sealing a disk that is in use"
  m="$(manifest)"
  write_seal "$m" "$(digest_of "$m")"
  ok "VM files sealed"
}

case "${1:-}" in
  verify)    cmd_verify ;;
  accept)    cmd_accept ;;
  update)    cmd_update ;;
  forget)    ref_del || true; rm -f "$SEAL_FILE"; ok "seal removed" ;;
  -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)         die "usage: bsdseal verify|accept|update|forget (help: --help)" ;;
esac
