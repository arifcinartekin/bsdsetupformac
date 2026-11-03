#!/bin/bash
#
# bsdopen-setup.sh - BSD Setup for Mac
#
# Installs FreeBSD (arm64) on macOS (Apple Silicon) with QEMU and adds four
# terminal commands: `bsdopen`, `bsdclose`, `bsduninstall` and `bsdseal`.
# One command, fully automatic:
#
#   1. Homebrew + qemu (installed if missing)
#   2. Asks for the disk passphrase, downloads the pinned FreeBSD bootonly ISO
#      and the base/kernel distribution sets and verifies them (sha256 pinned
#      here, checked against FreeBSD's published checksums and the MANIFEST)
#   3. Boots the FreeBSD installer in a temporary VM and drives its shell over
#      the serial console: GPT with an ESP and a GELI-encrypted (AES-XTS 256)
#      ZFS pool, boot environments layout (zroot/ROOT/default), base + kernel
#      extracted, loader on the ESP, rc.conf / loader.conf / fstab / hostname /
#      timezone / terminfo, pkg with sudo/zsh/git/curl, first-boot wizard
#   4. Generates start-uefi.sh, seals the VM files (bsdseal), boots the new
#      system via UEFI, unlocks the disk, logs in and checks it
#   5. Adds the bsdopen / bsdclose / bsduninstall / bsdseal aliases to ~/.zshrc
#
# Every `bsdopen` first checks the VM files against the seal kept in the macOS
# Keychain and refuses to boot if one of them changed. Then the FreeBSD loader
# asks for the disk passphrase; log in as root (password: root) the first time.
# The first-boot wizard then creates your user, sets up sudo and zsh, and
# locks root.
#
# Usage:
#   bash bsdopen-setup.sh
#   bash <(curl -fsSL https://bsd.arifcinartekin.me/install)
#
# Environment variables (all optional):
#   BSDOPEN_DIR=~/vm/freebsd    Install directory
#   BSDOPEN_HOSTNAME=freebsd    Hostname inside FreeBSD
#   BSDOPEN_FORCE=1             Overwrite a completed install
#   BSDOPEN_YES=1               Do not ask for confirmation
#   BSDOPEN_PIN_BREW=1          brew pin qemu (keep brew upgrade away from it)
#   BSDOPEN_CPUS=4  BSDOPEN_MEM=4G  BSDOPEN_DISK_SIZE=20G  BSDOPEN_ESP_SIZE=260M
#   BSDOPEN_SSH_PORT=2223
#   BSDOPEN_GELI_PASSPHRASE=...  Disk passphrase (otherwise asked for; needed with BSDOPEN_YES=1 without a terminal)
#   BSDOPEN_REPO=owner/name  BSDOPEN_REF=main   Where companion files are fetched from
#
# For testing (non-macOS / no HVF): BSDOPEN_ALLOW_NON_MAC=1 BSDOPEN_ACCEL=tcg
#   BSDOPEN_CPU=cortex-a72 BSDOPEN_FW_CODE=... BSDOPEN_FW_VARS=...
#
set -euo pipefail

###############################################################################
# VERSION PINS
###############################################################################
BSDOPEN_REPO="${BSDOPEN_REPO:-arifcinartekin/bsdsetupformac}"
BSDOPEN_REF="${BSDOPEN_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${BSDOPEN_REPO}/${BSDOPEN_REF}"

# FreeBSD keeps release files at fixed, versioned URLs: no mirror of our own is
# needed. Once a release reaches end of life it moves to ftp-archive (http
# only there; the pinned sha256 is what is trusted, not the transport).
FREEBSD_RELEASE="15.1-RELEASE"
FREEBSD_ISO="FreeBSD-${FREEBSD_RELEASE}-arm64-aarch64-bootonly.iso"
FREEBSD_ISO_SHA256="359136c2af73e03da6f15ad59f0c67bc561ca8b69631d78bfb8f2225e2c9a5ef"
FREEBSD_ISO_XZ_SHA256="33e2dc303b5dce5a374727ba12c41c303db70fe0676e76333e09e0ea8cb2fbd0"
FREEBSD_CHECKSUM_FILE="CHECKSUM.SHA256-FreeBSD-${FREEBSD_RELEASE}-arm64-aarch64"
FREEBSD_ISO_URLS="https://download.freebsd.org/releases/arm64/aarch64/ISO-IMAGES/${FREEBSD_RELEASE%-RELEASE}
http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/arm64/aarch64/ISO-IMAGES/${FREEBSD_RELEASE%-RELEASE}"
FREEBSD_DIST_URLS="https://download.freebsd.org/releases/arm64/aarch64/${FREEBSD_RELEASE}
http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/arm64/aarch64/${FREEBSD_RELEASE}"
# From the release's MANIFEST (the ISO carries the same MANIFEST; the guest checks both)
BASE_TXZ_SHA256="5b7a46a0abfbe23a1d4454b5600e2efcfce16b705bc7e9c851c37470c035ef98"
KERNEL_TXZ_SHA256="05f770c6af035fab312cd65592f1dbd1bff020c7daa75d8d4ecc96cae8f042c0"

# Root password until the first-boot wizard locks the root account
TEMP_ROOT_PASSWORD="root"

###############################################################################
# SETTINGS
###############################################################################
INSTALL_DIR="${BSDOPEN_DIR:-$HOME/vm/freebsd}"
BSD_HOSTNAME="${BSDOPEN_HOSTNAME:-freebsd}"
CPUS="${BSDOPEN_CPUS:-4}"
MEM="${BSDOPEN_MEM:-4G}"
DISK_SIZE="${BSDOPEN_DISK_SIZE:-20G}"
ESP_SIZE="${BSDOPEN_ESP_SIZE:-260M}"
# 2222 is what Arch Setup for Mac uses: both VMs can run at the same time
SSH_PORT="${BSDOPEN_SSH_PORT:-2223}"
ACCEL="${BSDOPEN_ACCEL:-hvf}"
CPU_MODEL="${BSDOPEN_CPU:-host}"

DL_DIR="$INSTALL_DIR/downloads"
LOG_FILE="$INSTALL_DIR/install.log"
INCOMPLETE_MARK="$INSTALL_DIR/.bsdopen-incomplete"
MANIFEST="$INSTALL_DIR/.bsdopen-manifest"

# Directory of this script when run from a checkout (empty under bash <(curl ...))
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

WORK=""
HTTP_PID=""
IS_MAC=0
FW_CODE=""
FW_VARS=""
QEMU_BIN=""
HAS_TERMINFO=0
GELI_PW=""
TZ_NAME=""
BREW_INSTALLED_BY_US=0
FORMULAE_INSTALLED_BY_US=""

###############################################################################
# HELPERS
###############################################################################
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# has_sha <file> <sha256>: the file exists and has that checksum
has_sha() { [ -f "$1" ] && [ "$(sha256_of "$1")" = "$2" ]; }

fetch() { # url file
  curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 20 -o "$2" "$1"
}

fetch_big() { # url file  (resumable, with progress bar)
  curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 -C - --progress-bar -o "$2" "$1"
}

# fetch_pinned <name> <sha256> <file> <base-url>...: downloads <name> from the
# first base URL that has it, until the file has the pinned checksum. A partial
# file from an interrupted run is resumed; a wrong file is downloaded again.
fetch_pinned() {
  local name="$1" sha="$2" out="$3" base
  shift 3
  has_sha "$out" "$sha" && return 0
  for base in "$@"; do
    fetch_big "$base/$name" "$out" || true
    has_sha "$out" "$sha" && return 0
    rm -f "$out"
    fetch_big "$base/$name" "$out" || true
    has_sha "$out" "$sha" && return 0
    rm -f "$out"
  done
  return 1
}

# Copies a file of this repo from the local checkout, or downloads it from GitHub
repo_file() { # repo-path destination
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$1" ]; then
    cp "$SCRIPT_DIR/$1" "$2"
  else
    fetch "$RAW_BASE/$1" "$2" || die "Could not download $1 from $RAW_BASE"
  fi
}

# unxz <in> <out>: xz decompression without needing xz itself (Python's lzma)
unxz_to() {
  if python3 -I -c 'import lzma' 2>/dev/null; then
    python3 -I -c 'import lzma, shutil, sys
with lzma.open(sys.argv[1]) as i, open(sys.argv[2], "wb") as o:
    shutil.copyfileobj(i, o, 1 << 20)' "$1" "$2"
  elif command -v xz >/dev/null 2>&1; then
    xz -dc "$1" > "$2"
  else
    return 1
  fi
}

###############################################################################
# 0) PRE-FLIGHT CHECKS, DEPENDENCIES
###############################################################################
check_platform() {
  if [ "$(uname -s)" = "Darwin" ]; then
    IS_MAC=1
    [ "$(uname -m)" = "arm64" ] || die "This script is for Apple Silicon (arm64) Macs."
    [ "$(id -u)" -ne 0 ] || die "Do not run this script as root (Homebrew does not allow it)."
  else
    [ "${BSDOPEN_ALLOW_NON_MAC:-0}" = "1" ] || die "This script is for macOS. (For testing: BSDOPEN_ALLOW_NON_MAC=1)"
  fi
  printf '%s' "$BSD_HOSTNAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || die "Invalid hostname: $BSD_HOSTNAME"
  printf '%s' "$SSH_PORT" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$SSH_PORT" -le 65535 ] || die "Invalid SSH port: $SSH_PORT"
}

ensure_deps() {
  if [ "$IS_MAC" = "1" ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      warn "Xcode Command Line Tools are missing, opening the installer."
      xcode-select --install || true
      die "Run this script again once that installation has finished."
    fi

    local brew_bin=""
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
      brew_bin="/opt/homebrew/bin/brew"
    fi
    if [ -z "$brew_bin" ]; then
      log "Installing Homebrew (may ask for your Mac password)"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      brew_bin="/opt/homebrew/bin/brew"
      [ -x "$brew_bin" ] || die "Homebrew installation failed."
      BREW_INSTALLED_BY_US=1
    fi
    eval "$("$brew_bin" shellenv)"

    local pkgs="qemu" pkg
    # The ISO comes xz-compressed; Python's lzma module usually handles it
    python3 -I -c 'import lzma' 2>/dev/null || command -v xz >/dev/null 2>&1 || pkgs="$pkgs xz"
    for pkg in $pkgs; do
      if ! brew list --versions "$pkg" >/dev/null 2>&1; then
        log "brew install $pkg"
        brew install "$pkg"
        FORMULAE_INSTALLED_BY_US="${FORMULAE_INSTALLED_BY_US:+$FORMULAE_INSTALLED_BY_US }$pkg"
      fi
    done
    if [ "${BSDOPEN_PIN_BREW:-0}" = "1" ]; then
      brew pin qemu || warn "brew pin failed (not critical)."
    fi
  fi

  local t
  for t in curl python3 expect qemu-system-aarch64 qemu-img awk; do
    command -v "$t" >/dev/null 2>&1 || die "Missing tool: $t"
  done
  QEMU_BIN="$(command -v qemu-system-aarch64)"
}

find_firmware() {
  if [ -n "${BSDOPEN_FW_CODE:-}" ]; then
    FW_CODE="$BSDOPEN_FW_CODE"
    FW_VARS="${BSDOPEN_FW_VARS:?BSDOPEN_FW_VARS must be set as well}"
  else
    local prefix share=""
    prefix=""
    if command -v brew >/dev/null 2>&1; then
      prefix="$(brew --prefix 2>/dev/null || true)"
    fi
    local cand
    for cand in "$prefix/share/qemu" /opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu; do
      if [ -f "$cand/edk2-aarch64-code.fd" ] && [ -f "$cand/edk2-arm-vars.fd" ]; then
        share="$cand"
        break
      fi
    done
    [ -n "$share" ] || die "QEMU UEFI firmware files (edk2-aarch64-code.fd) not found."
    FW_CODE="$share/edk2-aarch64-code.fd"
    FW_VARS="$share/edk2-arm-vars.fd"
  fi
  if [ ! -f "$FW_CODE" ] || [ ! -f "$FW_VARS" ]; then
    die "Firmware files missing: $FW_CODE / $FW_VARS"
  fi
}

# The Mac's time zone (e.g. Europe/Istanbul), so FreeBSD shows the same local time
detect_timezone() {
  local link
  link="$(readlink /etc/localtime 2>/dev/null || true)"
  TZ_NAME="${link##*/zoneinfo/}"
  printf '%s' "$TZ_NAME" | grep -Eq '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$' || TZ_NAME="UTC"
}

confirm_plan() {
  cat <<EOF

  Install directory : $INSTALL_DIR
  Virtual machine   : ${CPUS} CPUs, ${MEM} RAM, ${DISK_SIZE} disk (${ESP_SIZE} ESP)
  Root disk         : GELI encrypted (AES-XTS 256), ZFS with boot environments
  Integrity seal    : VM files checked before every boot, seal in the macOS Keychain
  Hostname          : ${BSD_HOSTNAME}
  Time zone         : ${TZ_NAME} (from this Mac)
  FreeBSD           : ${FREEBSD_RELEASE} arm64 (pinned sha256 + FreeBSD's checksums)
  Will change       : brew packages (qemu),
                      ~/.zshrc (bsdopen, bsdclose, bsduninstall, bsdseal aliases),
                      login Keychain (one item: bsdopen-seal)

EOF
  if [ "${BSDOPEN_YES:-0}" = "1" ]; then
    return 0
  fi
  [ -r /dev/tty ] || return 0
  local ans
  printf 'Continue? [Y/n] ' >/dev/tty
  IFS= read -r ans </dev/tty || ans="n"
  case "$ans" in
    ""|y|Y|yes|Yes) return 0 ;;
    *) die "Cancelled." ;;
  esac
}

# The GELI passphrase never touches the disk or the log: the installer types it
# into the installer VM over the serial console with echo off
ask_passphrase() {
  if [ -n "${BSDOPEN_GELI_PASSPHRASE:-}" ]; then
    GELI_PW="$BSDOPEN_GELI_PASSPHRASE"
    # Not passed on to QEMU and the other tools started from here
    unset BSDOPEN_GELI_PASSPHRASE
  else
    [ -r /dev/tty ] || die "No terminal to ask for the disk passphrase on: set BSDOPEN_GELI_PASSPHRASE."
    local again
    cat >/dev/tty <<'EOF'
  The FreeBSD disk is encrypted with GELI. You type this passphrase at every boot.
  There is no way to recover the data without it.

EOF
    while :; do
      printf 'Disk passphrase: ' >/dev/tty
      IFS= read -rs GELI_PW </dev/tty || die "Cancelled."
      printf '\nRepeat passphrase: ' >/dev/tty
      IFS= read -rs again </dev/tty || die "Cancelled."
      printf '\n' >/dev/tty
      if [ "$GELI_PW" != "$again" ]; then
        echo "  The passphrases do not match, try again." >/dev/tty
      elif [ "${#GELI_PW}" -lt 8 ]; then
        echo "  Use at least 8 characters." >/dev/tty
      else
        break
      fi
    done
  fi
  # Control characters would be interpreted by the serial console instead of
  # typed. Plain ASCII only: the FreeBSD loader reads the passphrase byte by
  # byte from the UEFI console, which does not pass multibyte characters through.
  case "$GELI_PW" in
    *[[:cntrl:]]*) die "The disk passphrase must not contain control characters." ;;
  esac
  LC_ALL=C printf '%s' "$GELI_PW" | LC_ALL=C grep -q '[^ -~]' \
    && die "Use only plain ASCII characters (no ı, ş, ğ, é ...) in the disk passphrase: the boot loader cannot read others."
  [ -n "$GELI_PW" ] || die "The disk passphrase is empty."
  # The loader's passphrase buffer is 256 bytes
  [ "${#GELI_PW}" -le 128 ] || die "Use at most 128 characters for the disk passphrase."
}

check_existing() {
  if [ -e "$INSTALL_DIR/disk.qcow2" ] && [ ! -e "$INCOMPLETE_MARK" ] && [ "${BSDOPEN_FORCE:-0}" != "1" ]; then
    die "There is already an install in $INSTALL_DIR. Stopping so it is not overwritten.
      Other directory: BSDOPEN_DIR=~/vm/freebsd2 bash bsdopen-setup.sh
      Overwrite      : BSDOPEN_FORCE=1 bash bsdopen-setup.sh
      Remove it      : bsduninstall"
  fi
}

prepare_dirs() {
  mkdir -p "$DL_DIR"
  : > "$INCOMPLETE_MARK"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/bsdopen.XXXXXX")"
  chmod 700 "$WORK"
}

# Records what this script installed on the Mac so bsduninstall can offer to remove it.
# Earlier runs are merged: something installed by a previous attempt stays recorded.
write_manifest() {
  local prev_brew=0 prev_formulae="" f formulae
  if [ -f "$MANIFEST" ]; then
    prev_brew="$(awk -F= '$1 == "installed_homebrew" { print $2 }' "$MANIFEST")"
    prev_formulae="$(awk -F= '$1 == "installed_formulae" { print $2 }' "$MANIFEST")"
  fi
  formulae="$prev_formulae"
  for f in $FORMULAE_INSTALLED_BY_US; do
    case " $formulae " in
      *" $f "*) ;;
      *) formulae="${formulae:+$formulae }$f" ;;
    esac
  done
  {
    echo "# Written by bsdopen-setup.sh, read by bsduninstall"
    echo "installed_homebrew=$([ "$BREW_INSTALLED_BY_US" = 1 ] || [ "${prev_brew:-0}" = 1 ] && echo 1 || echo 0)"
    echo "installed_formulae=$formulae"
    echo "pinned_formulae=$([ "${BSDOPEN_PIN_BREW:-0}" = 1 ] && echo "qemu")"
    echo "ssh_port=$SSH_PORT"
  } > "$MANIFEST"
}

# Gets the companion files (first-boot wizard, zsh setup, Mac commands)
fetch_companions() {
  log "Getting companion files"
  repo_file guest/bsdopen-firstboot.sh "$WORK/bsdopen-firstboot.sh"
  repo_file guest/bsdopen-winsize.sh "$WORK/bsdopen-winsize.sh"
  repo_file third_party/zsh_setup/zsh_setup.sh "$WORK/zsh_setup.sh"
  repo_file mac/bsdclose.sh "$WORK/bsdclose.sh"
  repo_file mac/bsduninstall.sh "$WORK/bsduninstall.sh"
  repo_file mac/bsdseal.sh "$WORK/bsdseal.sh"
  ok "first-boot wizard, winsize helper, zsh_setup.sh, bsdclose, bsduninstall, bsdseal"
}

###############################################################################
# 1) DOWNLOAD + VERIFY
###############################################################################
# Uses a copy you already downloaded (~/Downloads) when its checksum matches
local_copy() { # name sha256 destination
  local f="$HOME/Downloads/$1"
  if has_sha "$f" "$2"; then
    cp "$f" "$3"
    ok "using $f"
    return 0
  fi
  return 1
}

get_freebsd_iso() {
  log "Getting and verifying the FreeBSD ${FREEBSD_RELEASE} installer (bootonly ISO)"
  local iso="$DL_DIR/$FREEBSD_ISO" xz="$DL_DIR/$FREEBSD_ISO.xz" sums="$DL_DIR/$FREEBSD_CHECKSUM_FILE" base got
  # The ISO must be the release's: the pin, and FreeBSD's published list as a second source
  # shellcheck disable=SC2086
  if [ ! -s "$sums" ]; then
    for base in $FREEBSD_ISO_URLS; do
      fetch "$base/$FREEBSD_CHECKSUM_FILE" "$sums" 2>/dev/null && break
      rm -f "$sums"
    done
    [ -s "$sums" ] || cp "$HOME/Downloads/$FREEBSD_CHECKSUM_FILE" "$sums" 2>/dev/null || true
  fi

  if ! has_sha "$iso" "$FREEBSD_ISO_SHA256"; then
    rm -f "$iso"
    if ! local_copy "$FREEBSD_ISO" "$FREEBSD_ISO_SHA256" "$iso"; then
      if ! has_sha "$xz" "$FREEBSD_ISO_XZ_SHA256"; then
        # shellcheck disable=SC2086
        local_copy "$FREEBSD_ISO.xz" "$FREEBSD_ISO_XZ_SHA256" "$xz" \
          || fetch_pinned "$FREEBSD_ISO.xz" "$FREEBSD_ISO_XZ_SHA256" "$xz" $FREEBSD_ISO_URLS \
          || die "Could not download $FREEBSD_ISO.xz with the pinned sha256."
      fi
      echo "    Decompressing the ISO"
      unxz_to "$xz" "$iso.part" || die "Could not decompress $xz (no python3 lzma and no xz)."
      mv "$iso.part" "$iso"
      rm -f "$xz"
    fi
  fi
  got="$(sha256_of "$iso")"
  [ "$got" = "$FREEBSD_ISO_SHA256" ] || die "FreeBSD ISO sha256 does not match the pin in this script ($got)."
  ok "sha256 OK (pinned)"

  if [ -s "$sums" ]; then
    grep -qF "SHA256 ($FREEBSD_ISO) = $FREEBSD_ISO_SHA256" "$sums" \
      || die "The FreeBSD ISO does not match FreeBSD's published $FREEBSD_CHECKSUM_FILE."
    ok "matches FreeBSD's published $FREEBSD_CHECKSUM_FILE"
  else
    warn "could not get FreeBSD's checksum list to compare with (the pinned sha256 matched)"
  fi
}

get_freebsd_dists() {
  log "Getting and verifying the FreeBSD base system and kernel"
  local d sha
  for d in base kernel; do
    sha="$BASE_TXZ_SHA256"
    [ "$d" = kernel ] && sha="$KERNEL_TXZ_SHA256"
    # shellcheck disable=SC2086
    fetch_pinned "$d.txz" "$sha" "$DL_DIR/$d.txz" $FREEBSD_DIST_URLS \
      || die "Could not download $d.txz with the pinned sha256."
    ok "$d.txz sha256 OK"
  done
}

###############################################################################
# 2) DISK AND THE INSTALLER VM
###############################################################################
create_images() {
  log "Creating the virtual disk"
  rm -f "$INSTALL_DIR/disk.qcow2" "$INSTALL_DIR/vars.fd" "$INSTALL_DIR/efi-code.fd"
  qemu-img create -q -f qcow2 "$INSTALL_DIR/disk.qcow2" "$DISK_SIZE"
  # The firmware is part of the boot chain the seal covers: use a private copy,
  # so a `brew upgrade qemu` does not change it under the seal
  cp "$FW_CODE" "$INSTALL_DIR/efi-code.fd"
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  ok "disk.qcow2 ($DISK_SIZE), efi-code.fd, vars.fd"
}

# terminfo source (infocmp -x output) of the Mac terminal, so the terminal also
# works over SSH inside FreeBSD. Looks in the system first, then in the apps'
# own terminfo directories under /Applications (e.g. Ghostty).
find_terminfo_source() {
  local name="$1" d src
  [ -n "$name" ] || return 1
  if src="$(infocmp -x "$name" 2>/dev/null)" && [ -n "$src" ]; then
    printf '%s\n' "$src"; return 0
  fi
  for d in "${TERMINFO:-}" /Applications/*/Contents/Resources/terminfo \
           "$HOME"/Applications/*/Contents/Resources/terminfo; do
    [ -d "$d" ] || continue
    if src="$(TERMINFO="$d" infocmp -x "$name" 2>/dev/null)" && [ -n "$src" ]; then
      printf '%s\n' "$src"; return 0
    fi
  done
  return 1
}

stage_terminfo() { # output
  local name="${TERM:-}"
  case "$name" in
    ""|dumb|xterm|xterm-256color|screen*|tmux*|linux|vt100|vt220)
      return 0 ;;
  esac
  command -v infocmp >/dev/null 2>&1 || return 0
  if find_terminfo_source "$name" > "$1"; then
    HAS_TERMINFO=1
    ok "terminfo of this terminal will be installed: $name"
  else
    rm -f "$1"
    warn "terminfo '$name' not found on this Mac, skipping"
  fi
}

write_installer_vm_script() { # output
  local out="$1"
  {
    printf '#!/bin/bash\n'
    printf 'exec %q \\\n' "$QEMU_BIN"
    printf '  -machine virt,highmem=on -accel %q -cpu %q -smp %q -m %q \\\n' "$ACCEL" "$CPU_MODEL" "$CPUS" "$MEM"
    printf '  -drive if=pflash,format=raw,readonly=on,file=%q \\\n' "$INSTALL_DIR/efi-code.fd"
    printf '  -drive if=pflash,format=raw,file=%q \\\n' "$INSTALL_DIR/vars.fd"
    printf '  -drive if=none,id=root,file=%q,format=qcow2 \\\n' "$INSTALL_DIR/disk.qcow2"
    printf '  -device virtio-blk-pci,drive=root,serial=BSDROOT \\\n'
    printf '  -drive if=none,id=iso,file=%q,format=raw,readonly=on \\\n' "$DL_DIR/$FREEBSD_ISO"
    printf '  -device virtio-blk-pci,drive=iso,serial=BSDISO,bootindex=0 \\\n'
    printf '  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \\\n'
    printf '  -nographic\n'
  } > "$out"
  chmod 700 "$out"
}

# Settings for the guest script, fetched by it from the Mac (keeps the command
# typed over the serial console short). Nothing secret: the passphrase is typed.
write_guest_env() { # output
  {
    printf 'BSD_HOSTNAME=%s\n' "$BSD_HOSTNAME"
    printf 'ROOT_PW=%s\n' "$TEMP_ROOT_PASSWORD"
    printf 'ESP_SIZE=%s\n' "$ESP_SIZE"
    printf 'TZ_NAME=%s\n' "$TZ_NAME"
    printf 'SSH_PORT=%s\n' "$SSH_PORT"
    printf 'HAS_TERMINFO=%s\n' "$HAS_TERMINFO"
    printf 'BASE_SHA256=%s\n' "$BASE_TXZ_SHA256"
    printf 'KERNEL_SHA256=%s\n' "$KERNEL_TXZ_SHA256"
  } > "$1"
}

write_guest_script() { # output
  cat > "$1" <<'GUEST_EOF'
#!/bin/sh
# bsdopen guest installer: runs in the shell of the FreeBSD installer (/bin/sh)
set -eu

step() { echo "BSDOPEN_STEP: $*"; }
die()  { echo "BSDOPEN_ERROR: $*"; exit 1; }
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "BSDOPEN_ERROR: guest script exited with code $rc"' EXIT

: "${FILES_URL:?}"
fetch -q -o /tmp/bsdopen.env "$FILES_URL/guest.env" || die "could not fetch the settings from the Mac"
. /tmp/bsdopen.env
: "${BSD_HOSTNAME:?}" "${ROOT_PW:?}" "${ESP_SIZE:?}" "${TZ_NAME:?}" "${SSH_PORT:?}" "${BASE_SHA256:?}" "${KERNEL_SHA256:?}"
HAS_TERMINFO="${HAS_TERMINFO:-0}"
POOL=zroot
M=/mnt

find_disk() { # ident -> device name
  for d in $(sysctl -n kern.disks); do
    if [ "$(diskinfo -s "$d" 2>/dev/null)" = "$1" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

step "Loading GELI and ZFS"
kldload -n geom_eli zfs || die "could not load geom_eli/zfs"
sysctl vfs.zfs.vdev.min_auto_ashift=12 >/dev/null 2>&1 || sysctl vfs.zfs.min_auto_ashift=12 >/dev/null 2>&1 || true
DISK="$(find_disk BSDROOT)" || die "disk not found"
step "Disk: $DISK"

step "Partitioning (GPT: ESP + encrypted ZFS) and formatting the ESP (FAT32)"
gpart destroy -F "$DISK" >/dev/null 2>&1 || true
gpart create -s gpt "$DISK" >/dev/null
gpart add -t efi -l efiboot0 -a 1m -s "$ESP_SIZE" "$DISK" >/dev/null
gpart add -t freebsd-zfs -l zfs0 -a 1m "$DISK" >/dev/null
newfs_msdos -F 32 -c 1 -L EFISYS "/dev/${DISK}p1" >/dev/null 2>&1 || die "newfs_msdos failed"

step "Encrypting the ZFS partition with GELI (AES-XTS 256)"
# The Mac types the passphrase in with echo off, so it is not in the log
stty -echo 2>/dev/null || true
echo "BSDOPEN_NEED_PASSPHRASE"
IFS= read -r GELI_PW || die "no passphrase received"
stty echo 2>/dev/null || true
[ -n "$GELI_PW" ] || die "empty passphrase"
# -g: the loader asks for the passphrase and hands the key to the kernel;
# -b: the kernel asks itself if the loader did not. printf without a newline
# matches what is typed at boot.
printf '%s' "$GELI_PW" | geli init -bg -B none -e AES-XTS -l 256 -s 4096 -J - "/dev/${DISK}p2" >/dev/null \
  || die "geli init failed"
printf '%s' "$GELI_PW" | geli attach -j - "/dev/${DISK}p2" || die "geli attach failed"
GELI_PW=""

step "Creating the ZFS pool ($POOL) and datasets"
zpool create -f -o altroot="$M" -O compress=lz4 -O atime=off -m none "$POOL" "/dev/${DISK}p2.eli" \
  || die "zpool create failed"
zfs create -o mountpoint=none "$POOL/ROOT"
zfs create -o mountpoint=/ "$POOL/ROOT/default"
zfs create -o mountpoint=/home "$POOL/home"
zfs create -o mountpoint=/tmp -o exec=on -o setuid=off "$POOL/tmp"
zfs create -o mountpoint=/usr -o canmount=off "$POOL/usr"
zfs create -o setuid=off "$POOL/usr/ports"
zfs create "$POOL/usr/src"
zfs create -o mountpoint=/var -o canmount=off "$POOL/var"
zfs create -o exec=off -o setuid=off "$POOL/var/audit"
zfs create -o exec=off -o setuid=off "$POOL/var/crash"
zfs create -o exec=off -o setuid=off "$POOL/var/log"
zfs create -o atime=on "$POOL/var/mail"
zfs create -o setuid=off "$POOL/var/tmp"
zpool set bootfs="$POOL/ROOT/default" "$POOL"
chmod 1777 "$M/tmp" "$M/var/tmp"

for d in base kernel; do
  step "Fetching $d.txz from the Mac and verifying sha256"
  want="$BASE_SHA256"
  [ "$d" = kernel ] && want="$KERNEL_SHA256"
  # Second, independent source: the MANIFEST on the (verified) ISO
  [ "$(awk -v f="$d.txz" '$1 == f { print $2 }' /usr/freebsd-dist/MANIFEST)" = "$want" ] \
    || die "$d.txz: the pinned sha256 does not match the ISO's MANIFEST"
  fetch -q -o "$M/var/tmp/$d.txz" "$FILES_URL/$d.txz" || die "could not fetch $d.txz"
  [ "$(sha256 -q "$M/var/tmp/$d.txz")" = "$want" ] || die "$d.txz sha256 mismatch"
  step "Extracting $d.txz"
  tar -xpf "$M/var/tmp/$d.txz" -C "$M" || die "extracting $d.txz failed"
  rm -f "$M/var/tmp/$d.txz"
done
[ -f "$M/boot/kernel/kernel" ] && [ -f "$M/boot/loader.efi" ] || die "base/kernel do not have the expected layout"

step "Installing the boot loader on the ESP"
mkdir -p "$M/boot/efi"
mount_msdosfs "/dev/${DISK}p1" "$M/boot/efi" || die "could not mount the ESP"
mkdir -p "$M/boot/efi/efi/boot" "$M/boot/efi/efi/freebsd"
cp "$M/boot/loader.efi" "$M/boot/efi/efi/boot/bootaa64.efi"
cp "$M/boot/loader.efi" "$M/boot/efi/efi/freebsd/loader.efi"

step "Writing loader.conf, rc.conf, fstab"
cat > "$M/boot/loader.conf" <<'LOADER_EOF'
# Written by bsdopen-setup.sh
zfs_load="YES"
geom_eli_load="YES"
# The terminal size channel from the Mac (bsdopen-winsize)
virtio_console_load="YES"
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gptid.enable="0"
autoboot_delay="3"
LOADER_EOF
cat > "$M/etc/rc.conf" <<RC_EOF
# Written by bsdopen-setup.sh
hostname="${BSD_HOSTNAME}"
ifconfig_DEFAULT="DHCP"
sshd_enable="YES"
zfs_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
dumpdev="NO"
bsdopen_winsize_enable="YES"
RC_EOF
printf '# Device\t\tMountpoint\tFStype\tOptions\tDump\tPass#\n/dev/gpt/efiboot0\t/boot/efi\tmsdosfs\trw\t2\t2\n' > "$M/etc/fstab"

# The serial console the Mac terminal is attached to: tell programs it is a
# capable terminal (the Mac's), not a vt100
TAB="$(printf '\t')"
sed -i '' "s|^ttyu0[[:space:]].*|ttyu0${TAB}\"/usr/libexec/getty 3wire\"${TAB}xterm-256color${TAB}onifconsole secure|" "$M/etc/ttys"
grep -q '^ttyu0.*xterm-256color' "$M/etc/ttys" || die "could not set the console terminal type in /etc/ttys"

step "Setting the time zone: $TZ_NAME"
if [ -f "$M/usr/share/zoneinfo/$TZ_NAME" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ_NAME" "$M/etc/localtime"
  echo "$TZ_NAME" > "$M/var/db/zoneinfo"
else
  echo "warning: unknown time zone $TZ_NAME, keeping UTC"
fi

step "Setting the temporary root password"
printf '%s\n' "$ROOT_PW" | pw -R "$M" usermod root -h 0 || die "could not set the root password"

step "Installing the first-boot wizard, zsh setup and the terminal size helper"
fetch -q -o /tmp/bsdopen-firstboot.sh "$FILES_URL/bsdopen-firstboot.sh" || die "could not fetch the first-boot wizard"
fetch -q -o /tmp/zsh_setup.sh "$FILES_URL/zsh_setup.sh" || die "could not fetch zsh_setup.sh"
fetch -q -o /tmp/bsdopen-winsize.sh "$FILES_URL/bsdopen-winsize.sh" || die "could not fetch the winsize helper"
mkdir -p "$M/usr/local/sbin" "$M/usr/local/share/bsdopen" "$M/usr/local/etc/rc.d"
install -m 0755 /tmp/bsdopen-firstboot.sh "$M/usr/local/sbin/bsdopen-firstboot"
install -m 0644 /tmp/zsh_setup.sh "$M/usr/local/share/bsdopen/zsh_setup.sh"
install -m 0755 /tmp/bsdopen-winsize.sh "$M/usr/local/sbin/bsdopen-winsize"
printf '# Written by bsdopen-setup.sh\nssh_port=%s\n' "$SSH_PORT" > "$M/usr/local/etc/bsdopen.conf"
cat > "$M/usr/local/etc/rc.d/bsdopen_winsize" <<'RCD_EOF'
#!/bin/sh
#
# PROVIDE: bsdopen_winsize
# REQUIRE: DAEMON
# KEYWORD: nojail
#
# Keeps the serial console the size of the Mac terminal (bsdopen)

. /etc/rc.subr

name=bsdopen_winsize
rcvar=bsdopen_winsize_enable
port=/dev/vtcon/org.bsdopen.winsize
pidfile="/var/run/${name}.pid"
command=/usr/sbin/daemon
command_args="-r -R 1 -P ${pidfile} /usr/local/sbin/bsdopen-winsize"
start_precmd="${name}_precmd"

bsdopen_winsize_precmd()
{
	# Only under the bsdopen launcher, which provides the port
	[ -e "$port" ] || { echo "${name}: $port not found, not starting"; return 1; }
}

load_rc_config $name
: ${bsdopen_winsize_enable:=NO}
run_rc_command "$1"
RCD_EOF
chmod 0555 "$M/usr/local/etc/rc.d/bsdopen_winsize"

if [ "$HAS_TERMINFO" = "1" ]; then
  step "Installing the terminal's terminfo"
  fetch -q -o "$M/tmp/terminfo.src" "$FILES_URL/terminfo.src" || die "could not fetch terminfo"
  chroot "$M" /usr/bin/tic -x -o /usr/share/terminfo /tmp/terminfo.src || echo "warning: tic failed"
  rm -f "$M/tmp/terminfo.src"
fi

step "Installing packages with pkg (sudo, zsh, git, curl, ...)"
cp /etc/resolv.conf "$M/etc/resolv.conf"
mount -t devfs devfs "$M/dev"
# pkg verifies the repository signature with the keys shipped in base
chroot "$M" /usr/bin/env ASSUME_ALWAYS_YES=yes PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/pkg bootstrap -y \
  || die "pkg bootstrap failed (internet access?)"
chroot "$M" /usr/bin/env ASSUME_ALWAYS_YES=yes PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin \
  /usr/local/sbin/pkg install -y sudo zsh git-lite curl wget unzip fontconfig || die "pkg install failed"
rm -f "$M/etc/resolv.conf"

step "Checking the installation"
for f in boot/efi/efi/boot/bootaa64.efi boot/loader.conf boot/kernel/kernel boot/kernel/zfs.ko boot/kernel/geom_eli.ko \
         usr/local/bin/sudo usr/local/bin/zsh usr/local/sbin/bsdopen-firstboot; do
  [ -s "$M/$f" ] || die "/$f is missing"
done
echo "BSDOPEN_PKGLIST_BEGIN"
chroot "$M" /usr/local/sbin/pkg query '%n %v'
echo "BSDOPEN_PKGLIST_END"

step "Unmounting"
sync
umount "$M/dev" 2>/dev/null || umount -f "$M/dev" 2>/dev/null || true
umount "$M/boot/efi" 2>/dev/null || umount -f "$M/boot/efi" 2>/dev/null || true
zpool export "$POOL" || die "zpool export failed"
geli detach "/dev/${DISK}p2.eli" 2>/dev/null || true
step "Installer stage done"
GUEST_EOF
}

write_installer_expect() { # output
  cat > "$1" <<'EXP_EOF'
#!/usr/bin/expect -f
# Drives the FreeBSD installer VM over the serial console. Input: environment variables (BSDOPEN_*)
set timeout 30
match_max 200000
log_user 0
proc wait_info {} {
    if {[catch {wait} r]} { return "could not get exit status" }
    return "pid=[lindex $r 0] os_error=[lindex $r 2] exit_code_or_signal=[lindex $r 3]"
}
log_file -a $env(BSDOPEN_LOG)

proc die {msg} {
    puts stderr "\nERROR: $msg"
    exit 1
}

# Kept out of the environment of QEMU and everything else spawned from here
set geli $env(BSDOPEN_GELI_PW)
unset env(BSDOPEN_GELI_PW)

spawn $env(BSDOPEN_VM_SCRIPT)

# 1) Boot, then from the installer's welcome menu into its shell
set timeout 20
set waited 0
set menu 0
expect {
    -re {Console type \[[a-z0-9]+\]: ?$} {
        # Not vt100: its NUL padding made QEMU's console stop under expect
        send "xterm\r"
        exp_continue
    }
    -re {\x1b\[6n} {
        # resizewin asks the terminal for its size (cursor position report).
        # Without an answer the installer's menus get a 0x0 terminal and fail.
        send "\x1b\[45;160R"
        exp_continue
    }
    -re {ive System} {
        # Install | Shell | Live System, with the hotkey letters highlighted
        # (so "Live System" never shows up in one piece): S picks Shell.
        incr menu
        if {$menu == 1} {
            sleep 1
            send "S"
        }
        exp_continue
    }
    -re {type 'exit' to return to the installer} {
        exp_continue
    }
    -re {\n# $} { }
    timeout {
        incr waited
        if {$waited > $env(BSDOPEN_BOOT_NUDGES)} { die "the FreeBSD installer did not come up (log: $env(BSDOPEN_LOG))" }
        exp_continue
    }
    eof { die "QEMU exited unexpectedly - [wait_info] (log: $env(BSDOPEN_LOG))" }
}

# Runs one command and returns its exit code
proc run {cmd tmo} {
    global timeout
    set timeout $tmo
    send -- "$cmd; echo BSDOPEN_RC=\$?\r"
    expect {
        -re {BSDOPEN_RC=([0-9]+)\r} { return $expect_out(1,string) }
        timeout { die "timed out: $cmd" }
        eof { die "QEMU exited - [wait_info]: $cmd" }
    }
}

puts "    - The FreeBSD installer is up, configuring the network"; flush stdout
if {[run "dhclient vtnet0 >/dev/null 2>&1" 120] != 0} { die "the installer's network did not come up (DHCP)" }
if {[run "fetch -q -o /tmp/guest.sh http://10.0.2.2:$env(BSDOPEN_PORT)/guest-install.sh" 60] != 0} { die "could not fetch the guest script from the Mac" }

# 2) The actual installation
set timeout $env(BSDOPEN_IDLE_TIMEOUT)
send -- "FILES_URL=http://10.0.2.2:$env(BSDOPEN_PORT) sh /tmp/guest.sh; echo BSDOPEN_GUEST_DONE=\$?\r"

set guest_rc -1
set errmsg ""
expect {
    -re {([^\n]*)\n} {
        set line [string trimright $expect_out(1,string) "\r"]
        set cont 1
        if {[regexp {^BSDOPEN_STEP: (.*)$} $line -> msg]} {
            puts "    - $msg"; flush stdout
        } elseif {$line eq "BSDOPEN_NEED_PASSPHRASE"} {
            # The guest turned echo off before asking
            send -- "$geli\r"
        } elseif {[regexp {^BSDOPEN_ERROR: (.*)$} $line -> msg]} {
            set errmsg $msg
            puts stderr "    x $msg"; flush stderr
        } elseif {[regexp {^BSDOPEN_GUEST_DONE=([0-9]+)$} $line -> rc]} {
            set guest_rc $rc
            set cont 0
        }
        if {$cont} { exp_continue }
    }
    timeout { die "The installation produced no output for $env(BSDOPEN_IDLE_TIMEOUT) s (log: $env(BSDOPEN_LOG))" }
    eof { die "QEMU exited during the installation - [wait_info] (log: $env(BSDOPEN_LOG))" }
}

if {$guest_rc != 0} {
    die "Installation failed (exit code $guest_rc) $errmsg (log: $env(BSDOPEN_LOG))"
}

# 3) Clean shutdown
set timeout 180
send -- "sync; poweroff\r"
expect {
    eof { }
    timeout { die "the FreeBSD installer did not shut down" }
}
catch {wait}
exit 0
EXP_EOF
}

run_installer() {
  log "Installer VM running (FreeBSD installer shell, driven over the serial console)"
  echo "    Detailed output: $LOG_FILE"

  local stage="$WORK/stage"
  mkdir -p "$stage"
  write_guest_script "$stage/guest-install.sh"
  ln -s "$DL_DIR/base.txz" "$stage/base.txz"
  ln -s "$DL_DIR/kernel.txz" "$stage/kernel.txz"
  cp "$WORK/bsdopen-firstboot.sh" "$stage/bsdopen-firstboot.sh"
  cp "$WORK/bsdopen-winsize.sh" "$stage/bsdopen-winsize.sh"
  cp "$WORK/zsh_setup.sh" "$stage/zsh_setup.sh"
  stage_terminfo "$stage/terminfo.src"
  # After stage_terminfo, which decides HAS_TERMINFO
  write_guest_env "$stage/guest.env"

  local port
  port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$stage" >"$WORK/http.log" 2>&1 &
  HTTP_PID=$!
  local i=0
  until curl -fsI "http://127.0.0.1:$port/guest-install.sh" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || die "The local HTTP server did not start ($WORK/http.log)"
    sleep 0.2
  done

  write_installer_vm_script "$WORK/run-installer-vm.sh"
  write_installer_expect "$WORK/installer.exp"

  BSDOPEN_LOG="$LOG_FILE" \
  BSDOPEN_VM_SCRIPT="$WORK/run-installer-vm.sh" \
  BSDOPEN_PORT="$port" \
  BSDOPEN_GELI_PW="$GELI_PW" \
  BSDOPEN_BOOT_NUDGES="${BSDOPEN_BOOT_NUDGES:-15}" \
  BSDOPEN_IDLE_TIMEOUT="${BSDOPEN_IDLE_TIMEOUT:-1800}" \
    expect -f "$WORK/installer.exp" || die "The installer VM failed. Log: $LOG_FILE"

  kill "$HTTP_PID" >/dev/null 2>&1 || true
  HTTP_PID=""
  ok "Disk ready"
}

###############################################################################
# 3) LAUNCHER, VERIFICATION, ALIASES
###############################################################################
write_start_script() {
  local out="$INSTALL_DIR/start-uefi.sh"
  # Console on stdio with signal=off: Ctrl+C goes to the process running in the
  # guest instead of killing QEMU (what -nographic does). mux keeps Ctrl+A X/C.
  local mon_opt='-mon chardev=con0,mode=readline'
  if "$QEMU_BIN" -object help 2>/dev/null | grep -qw monitor-hmp; then
    mon_opt='-object monitor-hmp,id=mon0,chardev=con0'
  fi
  # The generated script intentionally contains literal $
  # shellcheck disable=SC2016
  {
    printf '#!/bin/bash\n'
    printf '# FreeBSD (QEMU) launcher. Generated by bsdopen-setup.sh.\n'
    printf '# Quit: `bsdclose` from another Mac terminal, `poweroff` inside the VM, or Ctrl+A then X.\n'
    printf '# Ctrl+C goes to the guest (it does not stop the VM).\n'
    printf '# SSH: ssh -p %s <user>@localhost\n' "$SSH_PORT"
    printf 'SSH_PORT="${BSDOPEN_SSH_PORT:-%s}"\n' "$SSH_PORT"
    printf 'QEMU_BIN=%q\n' "$QEMU_BIN"
    printf 'QEMU_MACHINE=(-machine virt,highmem=on -accel %q -cpu %q -smp %q -m %q)\n' "$ACCEL" "$CPU_MODEL" "$CPUS" "$MEM"
    printf 'QEMU_MONITOR=(%s)\n' "$mon_opt"
    cat <<'LAUNCHER_EOF'
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
pid="$(cat "$DIR/qemu.pid" 2>/dev/null || true)"
if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qF "$DIR/disk.qcow2"; then
  echo "The FreeBSD VM is already running (pid $pid). Shut it down with: bsdclose" >&2
  exit 1
fi
# Integrity check: if any VM file differs from the seal, QEMU is not started
# and the disk passphrase prompt never appears
"$DIR/bsdseal.sh" verify || exit 1
echo "$$" > "$DIR/.bsdopen-session"
rm -f "$DIR/qmp.sock" "$DIR/winsize.in" "$DIR/winsize.out"
# vars.fd stays as sealed: each boot gets a throwaway copy of the UEFI variables
cp "$DIR/vars.fd" "$DIR/vars.run.fd" || exit 1
# Terminal size channel to the guest (bsdopen-winsize inside FreeBSD)
WINSIZE=0
mkfifo -m 600 "$DIR/winsize.in" "$DIR/winsize.out" 2>/dev/null && WINSIZE=1
WINSIZE_ARGS=()
if [ "$WINSIZE" = 1 ]; then
  WINSIZE_ARGS=(-device virtio-serial-pci,id=vser0
    -chardev "pipe,id=winsize,path=$DIR/winsize"
    -device virtserialport,bus=vser0.0,chardev=winsize,name=org.bsdopen.winsize)
fi
# Closing the terminal must not skip the reseal below; QEMU still gets the signal
hup=""
trap 'hup=1' HUP TERM
# In the background so this script can forward window size changes, with the
# terminal as its input (a background job would otherwise read /dev/null)
"$QEMU_BIN" "${QEMU_MACHINE[@]}" \
  -drive if=pflash,format=raw,readonly=on,file="$DIR/efi-code.fd" \
  -drive if=pflash,format=raw,file="$DIR/vars.run.fd" \
  -drive if=none,id=root,file="$DIR/disk.qcow2",format=qcow2 \
  -device virtio-blk-pci,drive=root,bootindex=0 \
  -device virtio-net-pci,netdev=n0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 \
  ${WINSIZE_ARGS[@]+"${WINSIZE_ARGS[@]}"} \
  -qmp "unix:$DIR/qmp.sock,server=on,wait=off" \
  -pidfile "$DIR/qemu.pid" \
  -display none \
  -chardev stdio,id=con0,mux=on,signal=off \
  -serial chardev:con0 "${QEMU_MONITOR[@]}" <&0 &
qpid=$!
wpid=""
if [ "$WINSIZE" = 1 ]; then
  # Sends the terminal size on every resize (SIGWINCH), and every 2 s so a
  # reboot inside the VM gets it again. Read-write open: never blocks on the FIFO
  (
    trap - HUP TERM
    exec 9<>"$DIR/winsize.in" || exit 0
    send() {
      local sz
      sz="$(stty size </dev/tty 2>/dev/null)" || return 0
      case "$sz" in [1-9]*" "[1-9]*) printf '%s\n' "$sz" >&9 ;; esac
    }
    trap send WINCH
    while kill -0 "$qpid" 2>/dev/null; do
      send
      sleep 2 & wait $! 2>/dev/null
    done
  ) &
  wpid=$!
  # The guest side is a tty: drain whatever it writes back, so the FIFO never fills up
  ( trap - HUP TERM; exec cat "$DIR/winsize.out" >/dev/null 2>&1 ) &
  wpid="$wpid $!"
fi
# wait returns early when a trapped signal arrives: keep waiting until QEMU is gone
wait "$qpid"
rc=$?
while kill -0 "$qpid" 2>/dev/null; do
  wait "$qpid"
  rc=$?
done
# shellcheck disable=SC2086
[ -z "$wpid" ] || kill $wpid 2>/dev/null
rm -f "$DIR/vars.run.fd" "$DIR/qmp.sock" "$DIR/qemu.pid" "$DIR/winsize.in" "$DIR/winsize.out"
# What this session wrote to the disk is the new sealed state
if [ -n "$hup" ]; then
  "$DIR/bsdseal.sh" update >/dev/null 2>&1 && rm -f "$DIR/.bsdopen-session"
elif "$DIR/bsdseal.sh" update; then
  rm -f "$DIR/.bsdopen-session"
else
  echo "Could not seal the VM files: the next bsdopen will refuse to boot until you run bsdseal accept" >&2
fi
exit "$rc"
LAUNCHER_EOF
  } > "$out"
  chmod 755 "$out"
}

write_verify_expect() { # output
  cat > "$1" <<'EXP_EOF'
#!/usr/bin/expect -f
# Boots the new system through the launcher (seal check), unlocks the GELI disk
# at the loader, logs in as root, checks a few things, enables the first-boot
# wizard and shuts down.
set timeout 30
match_max 200000
log_user 0
log_file -a $env(BSDOPEN_LOG)

proc die {msg} {
    puts stderr "\nERROR: $msg"
    exit 1
}

set pw $env(BSDOPEN_PASSWORD)
# Kept out of the environment of QEMU
set geli $env(BSDOPEN_GELI_PW)
unset env(BSDOPEN_GELI_PW)
spawn $env(BSDOPEN_START_SCRIPT)

set waited 0
set logins 0
set unlocks 0
expect {
    -re {INTEGRITY CHECK FAILED} { die "the launcher's integrity check failed (log: $env(BSDOPEN_LOG))" }
    -re {GELI Passphrase for [^\r\n]*: ?$} {
        incr unlocks
        if {$unlocks > 3} { die "the GELI passphrase was rejected" }
        sleep 1
        send -- "$geli\r"
        exp_continue
    }
    -re {mountroot> ?$} { die "FreeBSD could not mount its root file system (log: $env(BSDOPEN_LOG))" }
    -re {\x1b\[6n} {
        # resizewin in root's .profile asks the terminal for its size
        send "\x1b\[45;160R"
        exp_continue
    }
    -re {login: $} {
        incr logins
        if {$logins > 3} { die "FreeBSD login failed (password rejected?)" }
        send "root\r"
        exp_continue
    }
    -re {Password:$} {
        send -- "$pw\r"
        exp_continue
    }
    -re {:~ # $} { }
    timeout {
        incr waited
        if {$waited > $env(BSDOPEN_BOOT_NUDGES)} { die "FreeBSD boot timed out (log: $env(BSDOPEN_LOG))" }
        exp_continue
    }
    eof { die "QEMU exited; the system did not boot (log: $env(BSDOPEN_LOG))" }
}
puts "    - Logged in"; flush stdout

set timeout 60
# Every field is followed by a fixed delimiter: output can arrive in pieces,
# and an unterminated last group would match a partial value
send -- "echo BSDOPEN_\$((20+22))_\$(freebsd-version -k)_\$(mount -p | awk '\$2 == \"/\" { print \$3 }')_\$(zpool status -P zroot | grep -q '\\.eli ' && echo geli || echo plain)_\$(hostname -s)_END\r"
expect {
    -re {BSDOPEN_42_([^_\r\n]+)_([a-z0-9]+)_([a-z]+)_([A-Za-z0-9.-]+)_END} {
        set kver $expect_out(1,string)
        set rootfs $expect_out(2,string)
        set crypt $expect_out(3,string)
        set host $expect_out(4,string)
    }
    timeout { die "could not read freebsd-version/mount/zpool output" }
    eof { die "QEMU exited" }
}
puts "    - FreeBSD $kver, root: $rootfs on $crypt, hostname: $host"; flush stdout
if {$host ne $env(BSDOPEN_HOSTNAME)} { die "hostname is '$host', expected '$env(BSDOPEN_HOSTNAME)'" }
if {$rootfs ne "zfs"} { die "the root filesystem is '$rootfs', expected zfs" }
if {$crypt ne "geli"} { die "the ZFS pool is not on the GELI provider" }

# sshd (key generation on first boot can take a while)
set ssh_ok 0
for {set i 0} {$i < 90} {incr i} {
    set banner ""
    catch {exec python3 -c {import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.settimeout(3)
sys.stdout.write(s.recv(64).decode("ascii", "ignore"))} $env(BSDOPEN_SSH_PORT)} banner
    if {[string match "SSH-2.0*" $banner]} { set ssh_ok 1; break }
    after 2000
}
if {$ssh_ok} {
    puts "    - sshd is answering (127.0.0.1:$env(BSDOPEN_SSH_PORT))"
} else {
    puts "    ! sshd did not answer within 3 min (not critical, try again later)"
}
flush stdout

# The terminal size helper: the launcher's port is there and the daemon runs
send -- "service bsdopen_winsize status >/dev/null 2>&1; echo BSDOPEN_WS=\$?\r"
expect {
    -re {BSDOPEN_WS=([0-9]+)\r} {
        if {$expect_out(1,string) == 0} {
            puts "    - Terminal size helper is running"
        } else {
            puts "    ! the terminal size helper is not running (resizing the window will not resize the console)"
        }
        flush stdout
    }
    timeout { die "could not check the terminal size helper" }
    eof { die "QEMU exited" }
}

# The wizard starts on the next interactive root login
send -- "/usr/local/sbin/bsdopen-firstboot --enable; echo BSDOPEN_EN=\$?\r"
expect {
    -re {BSDOPEN_EN=([0-9]+)\r} {
        if {$expect_out(1,string) != 0} { die "could not enable the first-boot wizard" }
    }
    timeout { die "could not enable the first-boot wizard (timeout)" }
    eof { die "QEMU exited" }
}
puts "    - First-boot wizard enabled"; flush stdout

set f [open "$env(BSDOPEN_WORK)/kver" w]
puts $f $kver
close $f

set timeout 180
send -- "sync; poweroff\r"
expect {
    eof { }
    timeout { die "FreeBSD did not shut down" }
}
catch {wait}
exit 0
EXP_EOF
}

verify_boot() {
  log "Sealing the VM files (seal stored in the login Keychain)"
  # Drop the NVRAM state left by the installer VM: vars.fd is sealed as a clean
  # template, and every boot runs on a throwaway copy of it
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  write_start_script
  "$INSTALL_DIR/bsdseal.sh" update || die "Could not seal the VM files. Is the login Keychain unlocked?"

  # The launcher checks the seal, boots, and seals again after the shutdown
  log "Booting the new system via UEFI and verifying it"
  write_verify_expect "$WORK/verify.exp"
  BSDOPEN_LOG="$LOG_FILE" \
  BSDOPEN_START_SCRIPT="$INSTALL_DIR/start-uefi.sh" \
  BSDOPEN_PASSWORD="$TEMP_ROOT_PASSWORD" \
  BSDOPEN_GELI_PW="$GELI_PW" \
  BSDOPEN_HOSTNAME="$BSD_HOSTNAME" \
  BSDOPEN_SSH_PORT="$SSH_PORT" \
  BSDOPEN_WORK="$WORK" \
  BSDOPEN_BOOT_NUDGES="${BSDOPEN_BOOT_NUDGES:-15}" \
    expect -f "$WORK/verify.exp" || die "Verification boot failed. Log: $LOG_FILE"
  "$INSTALL_DIR/bsdseal.sh" verify >/dev/null || die "The VM files were not sealed after the verification boot."
  ok "Seal checked, disk unlocked, login works, first-boot wizard armed, clean shutdown, sealed again"
}

# The Mac commands live next to the disk and are covered by the seal
install_scripts() {
  install -m 755 "$WORK/bsdclose.sh" "$INSTALL_DIR/bsdclose.sh"
  install -m 755 "$WORK/bsduninstall.sh" "$INSTALL_DIR/bsduninstall.sh"
  install -m 755 "$WORK/bsdseal.sh" "$INSTALL_DIR/bsdseal.sh"
}

install_aliases() {
  local rc="$HOME/.zshrc" begin="# >>> bsdopen >>>" end="# <<< bsdopen <<<"
  touch "$rc"
  if [ ! -f "$rc.bsdopen-backup" ]; then
    cp "$rc" "$rc.bsdopen-backup"
  fi
  local tmp="$WORK/zshrc.new"
  awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$rc" > "$tmp"
  {
    printf '%s\n' "$begin"
    printf 'alias bsdopen=%q\n' "$INSTALL_DIR/start-uefi.sh"
    printf 'alias bsdclose=%q\n' "$INSTALL_DIR/bsdclose.sh"
    printf 'alias bsduninstall=%q\n' "$INSTALL_DIR/bsduninstall.sh"
    printf 'alias bsdseal=%q\n' "$INSTALL_DIR/bsdseal.sh"
    printf '%s\n' "$end"
  } >> "$tmp"
  cat "$tmp" > "$rc"
  # shellcheck disable=SC2088
  ok "bsdopen, bsdclose, bsduninstall, bsdseal added to ~/.zshrc (backup: $rc.bsdopen-backup)"
}

write_lock() {
  local lock="$INSTALL_DIR/versions.lock"
  {
    echo "# Generated by bsdopen-setup.sh: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "freebsd_release=$FREEBSD_RELEASE"
    echo "freebsd_iso=$FREEBSD_ISO"
    echo "freebsd_iso_sha256=$FREEBSD_ISO_SHA256"
    echo "base_txz_sha256=$BASE_TXZ_SHA256"
    echo "kernel_txz_sha256=$KERNEL_TXZ_SHA256"
    echo "freebsd_kernel=$(cat "$WORK/kver" 2>/dev/null || echo unknown)"
    echo "hostname=$BSD_HOSTNAME"
    echo "timezone=$TZ_NAME"
    echo "qemu=$("$QEMU_BIN" --version | head -n 1)"
    echo "root_fs=zfs (pool zroot, boot environment zroot/ROOT/default) on GELI AES-XTS 256"
    echo
    echo "# FreeBSD packages (pkg query)"
    awk '/^BSDOPEN_PKGLIST_BEGIN/ { on = 1; next } /^BSDOPEN_PKGLIST_END/ { on = 0 } on { gsub(/\033\[[?0-9;]*[a-zA-Z]/, ""); sub(/\r$/, ""); if ($0 ~ /^[^ ]+ [^ ]+$/) print }' "$LOG_FILE"
  } > "$lock"
  ok "Version record: $lock"
}

###############################################################################
# MAIN
###############################################################################
main() {
  printf '\n\033[1mBSD Setup for Mac\033[0m: FreeBSD on macOS with QEMU\n'
  check_platform
  check_existing
  log "Checking dependencies"
  ensure_deps
  find_firmware
  detect_timezone
  confirm_plan
  ask_passphrase
  prepare_dirs
  write_manifest
  fetch_companions
  get_freebsd_iso
  get_freebsd_dists
  create_images
  run_installer
  install_scripts
  verify_boot
  install_aliases
  write_lock
  rm -f "$INCOMPLETE_MARK"

  printf '\n\033[1;32mInstallation complete.\033[0m\n'
  cat <<EOF

  Open a new terminal (or run: source ~/.zshrc). Commands:

      bsdopen         start FreeBSD in this terminal
      bsdclose        shut FreeBSD down cleanly (from another Mac terminal)
      bsduninstall    remove what this setup installed, asking item by item
      bsdseal         integrity seal of the VM files (bsdopen checks it before every boot)

  Every boot      : the seal is checked, then the loader asks for the disk passphrase
  First login     : user root, password ${TEMP_ROOT_PASSWORD}
                    The first-boot wizard then creates your user, sets up sudo
                    and zsh, and locks the root account.
  SSH (afterwards): ssh -p $SSH_PORT <user>@localhost   (reachable from this Mac only)
  Directory       : $INSTALL_DIR
  Version record  : $INSTALL_DIR/versions.lock

EOF
  if [ "${BSDOPEN_YES:-0}" != "1" ] && [ -r /dev/tty ]; then
    local ans
    printf 'Start FreeBSD now? [Y/n] ' >/dev/tty
    IFS= read -r ans </dev/tty || ans="n"
    case "$ans" in
      ""|y|Y|yes|Yes)
        GELI_PW=""
        cleanup
        trap - EXIT
        exec "$INSTALL_DIR/start-uefi.sh" ;;
    esac
  fi
}

main "$@"
