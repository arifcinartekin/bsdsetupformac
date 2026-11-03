#!/bin/sh
#
# bsdopen-firstboot - first-boot wizard inside the FreeBSD VM
#
# Installed by bsdopen-setup.sh as /usr/local/sbin/bsdopen-firstboot and
# started automatically on the first interactive root login (root / root):
#
#   1) Creates your user, adds it to wheel and grants sudo
#   2) Optionally runs zsh_setup.sh for that user (zsh, Oh My Zsh, Powerlevel10k)
#   3) Optionally installs htop, fastfetch with an `info` alias that also
#      runs at every login, and lsd (ls, ll, la, lt use it)
#   4) Optionally sets up the ly login screen on the console
#   5) LOCKS the root password (pw lock), only once sudo is verified
#   6) Removes its own login hook
#
# Ctrl+C aborts without changes to the hook; it runs again at the next root login.
#
# Usage:
#   bsdopen-firstboot              run the wizard
#   bsdopen-firstboot --enable     run it at the next interactive root login
#   bsdopen-firstboot --disable    do not run it at login anymore
#   bsdopen-firstboot --login-screen ly|console
#                                  ly login screen, or the plain console login
#
set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

PROFILE="/root/.profile"
HOOK_BEGIN="# >>> bsdopen firstboot >>>"
HOOK_END="# <<< bsdopen firstboot <<<"
INFO_BEGIN="# >>> bsdopen info >>>"
INFO_END="# <<< bsdopen info <<<"
LSD_BEGIN="# >>> bsdopen lsd >>>"
LSD_END="# <<< bsdopen lsd <<<"
P10K_BEGIN="# >>> bsdopen p10k >>>"
P10K_END="# <<< bsdopen p10k <<<"
GETTY_BEGIN="# >>> bsdopen ly >>>"
GETTY_END="# <<< bsdopen ly <<<"
ZSH_SETUP="/usr/local/share/bsdopen/zsh_setup.sh"
SUDOERS="/usr/local/etc/sudoers"
SUDOERS_D="/usr/local/etc/sudoers.d"
TEMP_SUDOERS="$SUDOERS_D/99-bsdopen-firstboot"
CONF="/usr/local/etc/bsdopen.conf"
SSH_PORT="$(awk -F= '$1 == "ssh_port" { print $2 }' "$CONF" 2>/dev/null || true)"
SSH_PORT="${SSH_PORT:-2223}"
# The serial console the Mac terminal is attached to
CONSOLE_TTY="ttyu0"
CONSOLE_TERM="xterm-256color"
# gettytab entry that runs ly on the console instead of login(1)
LY_GETTY="Ly.bsdopen"
LY_CONFIG="/usr/local/etc/ly/config.ini"
SHELL_SESSION="/usr/local/bin/bsdopen-shell-session"
ZSH_BIN="/usr/local/bin/zsh"

NEW_USER=""
DO_ZSH=1
DO_HTOP=1
DO_FASTFETCH=1
DO_LSD=1
DO_LY=1
SUDO_OK=0
LY_OK=0

if [ -t 1 ]; then
  C_B="$(printf '\033[1m')"; C_G="$(printf '\033[32m')"; C_Y="$(printf '\033[33m')"
  C_R="$(printf '\033[31m')"; C_0="$(printf '\033[0m')"
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# strip_block <file> <begin> <end>: prints the file without that block
strip_block() {
  awk -v b="$2" -v e="$3" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1"
}

# ----------------------------------------------------------------------------
# Login hook
# ----------------------------------------------------------------------------

remove_hook() {
  [ -f "$PROFILE" ] || return 0
  tmp="$(mktemp)"
  strip_block "$PROFILE" "$HOOK_BEGIN" "$HOOK_END" > "$tmp"
  cat "$tmp" > "$PROFILE"
  rm -f "$tmp"
}

enable_hook() {
  [ -f "$PROFILE" ] || : > "$PROFILE"
  remove_hook
  {
    printf '%s\n' "$HOOK_BEGIN"
    printf 'if [ -t 0 ] && [ -x /usr/local/sbin/bsdopen-firstboot ]; then\n'
    printf '  /usr/local/sbin/bsdopen-firstboot && exit\n'
    printf 'fi\n'
    printf '%s\n' "$HOOK_END"
  } >> "$PROFILE"
}

# ----------------------------------------------------------------------------
# Wizard
# ----------------------------------------------------------------------------

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; }

# The password field of an account in master.passwd
pw_hash() { pw usershow -n "$1" 2>/dev/null | cut -d: -f2; }
has_password() {
  case "$(pw_hash "$1")" in
    ""|"*"|"*LOCKED*"*) return 1 ;;
  esac
  return 0
}
is_locked() {
  case "$(pw_hash "$1")" in
    "*LOCKED*"*) return 0 ;;
  esac
  return 1
}

ask_yes_no() { # question default(y|n)
  hint="[Y/n]"
  [ "$2" = "n" ] && hint="[y/N]"
  while :; do
    printf '%s %s ' "$1" "$hint"
    IFS= read -r ans || ans=""
    case "${ans:-$2}" in
      y|Y|yes|Yes) return 0 ;;
      n|N|no|No)   return 1 ;;
    esac
  done
}

pkg_install() {
  env ASSUME_ALWAYS_YES=yes pkg install -y "$@"
}

cleanup() { rm -f "$TEMP_SUDOERS"; }

on_interrupt() {
  printf '\n'
  warn "Aborted. The wizard will start again at the next root login."
  exit 130
}

ask_questions() {
  while :; do
    printf 'Username for your account [user]: '
    IFS= read -r name || name=""
    name="${name:-user}"
    if [ "$name" = "root" ] || [ "$name" = "toor" ]; then
      warn "Pick a name other than $name."
    elif valid_name "$name"; then
      break
    else
      warn "Invalid username: lowercase letters, digits, - and _ (max 32 characters)."
    fi
  done
  NEW_USER="$name"

  if [ -f "$ZSH_SETUP" ]; then
    if ask_yes_no "Set up zsh + Oh My Zsh + Powerlevel10k for $NEW_USER?" y; then DO_ZSH=1; else DO_ZSH=0; fi
  else
    DO_ZSH=0
  fi
  if ask_yes_no "Install htop (interactive process viewer)?" y; then DO_HTOP=1; else DO_HTOP=0; fi
  if ask_yes_no "Install fastfetch (system info, 'info' command, shown at every login)?" y; then DO_FASTFETCH=1; else DO_FASTFETCH=0; fi
  if ask_yes_no "Install lsd (ls with colors and icons; ls, ll, la, lt use it)?" y; then DO_LSD=1; else DO_LSD=0; fi
  if ask_yes_no "Use the ly login screen instead of the plain console login?" y; then DO_LY=1; else DO_LY=0; fi
}

create_user() {
  log "User: $NEW_USER"
  shell=/bin/sh
  if [ "$DO_ZSH" = 1 ] && [ -x "$ZSH_BIN" ]; then
    # With zsh already the login shell, zsh_setup.sh does not need to call chsh
    shell="$ZSH_BIN"
  fi
  if pw usershow -n "$NEW_USER" >/dev/null 2>&1; then
    pw groupmod wheel -m "$NEW_USER"
    pw usermod -n "$NEW_USER" -s "$shell"
    ok "user already existed, added to wheel"
  else
    pw useradd -n "$NEW_USER" -m -G wheel -s "$shell" -c "$NEW_USER"
    ok "user created (wheel)"
  fi

  tries=0
  while ! has_password "$NEW_USER"; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die "no valid password was set for $NEW_USER"
    printf 'Set a password for %s:\n' "$NEW_USER"
    passwd "$NEW_USER" || warn "try again"
  done
  ok "password set"
}

setup_sudo() {
  log "sudo for wheel"
  if ! command -v sudo >/dev/null 2>&1; then
    pkg_install sudo
  fi
  grep -Eq '^[#@]includedir[[:space:]]+/usr/local/etc/sudoers\.d' "$SUDOERS" \
    || die "$SUDOERS does not include sudoers.d; fix it by hand (visudo)"
  mkdir -p "$SUDOERS_D"
  tmp="$(mktemp)"
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "invalid sudoers file"; }
  install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_D/10-wheel"
  rm -f "$tmp"
  visudo -c >/dev/null || die "sudoers could not be validated"

  if sudo -l -U "$NEW_USER" 2>/dev/null | grep -Eq '\(ALL *: *ALL\) +ALL'; then
    SUDO_OK=1
    ok "$NEW_USER can use sudo"
  else
    SUDO_OK=0
    warn "sudo access for $NEW_USER could not be verified"
  fi
}

run_zsh_setup() {
  [ "$DO_ZSH" = 1 ] || return 0
  log "zsh setup for $NEW_USER"
  # zsh_setup.sh may call sudo; no password prompts while it runs
  tmp="$(mktemp)"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$tmp"
  if visudo -cf "$tmp" >/dev/null; then
    install -m 0440 -o root -g wheel "$tmp" "$TEMP_SUDOERS"
  fi
  rm -f "$tmp"

  # Powerlevel10k has no prebuilt gitstatusd for FreeBSD arm64 and would print
  # an error at every prompt; it falls back to its slower built-in git status.
  # In .zshenv, so it is set before the first zsh (the p10k wizard) starts.
  append_block "$(pw usershow -n "$NEW_USER" | cut -d: -f9)/.zshenv" "$P10K_BEGIN" "$P10K_END" \
    'typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true'

  # The serial console may report vt100; the Mac terminal behind it handles more
  case "${TERM:-}" in
    ""|dumb|vt100|vt220|cons25|xterm) TERM=xterm-256color; export TERM ;;
  esac
  echo "  The Powerlevel10k configuration wizard starts at the end."
  if su -l "$NEW_USER" -c "sh $ZSH_SETUP"; then
    ok "zsh setup finished"
  else
    warn "zsh setup did not finish; run it later as $NEW_USER: sh $ZSH_SETUP"
  fi
  rm -f "$TEMP_SUDOERS"
}

install_tools() {
  pkgs=""
  [ "$DO_HTOP" = 1 ] && pkgs="$pkgs htop"
  [ "$DO_FASTFETCH" = 1 ] && pkgs="$pkgs fastfetch"
  [ "$DO_LSD" = 1 ] && pkgs="$pkgs lsd"
  [ "$DO_LY" = 1 ] && pkgs="$pkgs ly"
  pkgs="${pkgs# }"
  [ -n "$pkgs" ] || return 0
  log "Packages: $pkgs"
  # shellcheck disable=SC2086
  if pkg_install $pkgs; then
    ok "installed: $pkgs"
    if [ "$DO_LY" = 1 ]; then
      ok "(the setup steps in ly's package message above are done by this wizard)"
    fi
  else
    warn "pkg failed; install them later with: sudo pkg install $pkgs"
  fi
}

# append_block <file> <begin> <end> <text>: replaces that bsdopen block in a file of the new user
append_block() {
  tmp="$(mktemp)"
  if [ -f "$1" ]; then
    strip_block "$1" "$2" "$3" > "$tmp"
  fi
  printf '%s\n%s\n%s\n' "$2" "$4" "$3" >> "$tmp"
  install -m 0644 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$tmp" "$1"
  rm -f "$tmp"
}

# user_rc_files: sets USER_RC and USER_PROFILE for the new user's login shell
user_rc_files() {
  home="$(pw usershow -n "$NEW_USER" | cut -d: -f9)"
  if [ "$(pw usershow -n "$NEW_USER" | cut -d: -f10)" = "$ZSH_BIN" ]; then
    USER_RC="$home/.zshrc"
    # .zprofile runs before .zshrc, so the output does not upset Powerlevel10k's instant prompt
    USER_PROFILE="$home/.zprofile"
  else
    # sh reads $ENV (~/.shrc, set in ~/.profile) in interactive shells
    USER_RC="$home/.shrc"
    USER_PROFILE="$home/.profile"
  fi
}

setup_info() {
  [ "$DO_FASTFETCH" = 1 ] && command -v fastfetch >/dev/null 2>&1 || return 0
  log "'info' command"
  user_rc_files
  append_block "$USER_RC" "$INFO_BEGIN" "$INFO_END" "alias info='fastfetch'"
  append_block "$USER_PROFILE" "$INFO_BEGIN" "$INFO_END" \
    '[ -t 1 ] && command -v fastfetch >/dev/null 2>&1 && fastfetch'
  ok "'info' runs fastfetch; it also runs at every login ($(basename "$USER_PROFILE"))"
}

setup_lsd() {
  [ "$DO_LSD" = 1 ] && command -v lsd >/dev/null 2>&1 || return 0
  log "lsd aliases"
  user_rc_files
  # Appended after zsh_setup has written .zshrc, so these win over Oh My Zsh's ll/la
  append_block "$USER_RC" "$LSD_BEGIN" "$LSD_END" "$(printf '%s\n' \
    "alias ls='lsd'" \
    "alias ll='lsd -l'" \
    "alias la='lsd -la'" \
    "alias lt='lsd --tree'")"
  ok "ls, ll, la, lt use lsd ($(basename "$USER_RC"))"
}

# ----------------------------------------------------------------------------
# Login screen (ly on the serial console)
# ----------------------------------------------------------------------------

# ly_set <option> <value>: one option of ly's config.ini
ly_set() {
  if grep -q "^$1 = " "$LY_CONFIG"; then
    sed -i '' "s|^$1 = .*|$1 = $2|" "$LY_CONFIG"
  else
    warn "ly has no option '$1' (newer version?), skipped"
  fi
}

configure_ly() {
  if [ ! -f "$LY_CONFIG" ]; then
    [ -f "$LY_CONFIG.sample" ] || { warn "$LY_CONFIG.sample not found, is ly installed?"; return 1; }
    cp "$LY_CONFIG.sample" "$LY_CONFIG"
  fi
  # A serial line has no keyboard LEDs and no backlight; there is no X server
  ly_set hide_keyboard_locks true
  ly_set brightness_down_key null
  ly_set brightness_up_key null
  ly_set xinitrc null
  ly_set clock '%a %d %b  %H:%M'
  ly_set bigclock en
  # ly would send the shell's output to this log instead of the terminal
  ly_set session_log null
  # The user is already picked (there is one); start in the password field.
  # With the default (login), the first password typed goes nowhere.
  ly_set default_input password

  # The session to log into: your login shell, in this terminal
  cat > "$SHELL_SESSION" <<'SESSION_EOF'
#!/bin/sh
# Shell session for ly on the serial console (bsdopen). ly sends a session's
# output to a log file, which suits graphical sessions; a shell needs the terminal.
exec >/dev/tty 2>&1
printf '\033[H\033[2J'
exec "${SHELL:-/bin/sh}" -l
SESSION_EOF
  chmod 755 "$SHELL_SESSION"
  mkdir -p /usr/local/etc/ly/custom-sessions
  cat > /usr/local/etc/ly/custom-sessions/shell.desktop <<SESSION_EOF
[Desktop Entry]
Name=Shell
Comment=Your login shell in this terminal
Exec=$SHELL_SESSION
Type=Application
SESSION_EOF

  # getty runs ly instead of login(1); ly_wrapper drops the "-f root" getty adds
  tmp="$(mktemp)"
  strip_block /etc/gettytab "$GETTY_BEGIN" "$GETTY_END" > "$tmp"
  {
    printf '%s\n' "$GETTY_BEGIN"
    printf '%s:\\\n\t:lo=/usr/local/bin/ly_wrapper:al=root:tc=3wire:\n' "$LY_GETTY"
    printf '%s\n' "$GETTY_END"
  } >> "$tmp"
  cat "$tmp" > /etc/gettytab
  rm -f "$tmp"
}

# console_getty <gettytab entry>: what init runs on the console (/etc/ttys)
console_getty() {
  tab="$(printf '\t')"
  sed -i '' "s|^${CONSOLE_TTY}[[:space:]].*|${CONSOLE_TTY}${tab}\"/usr/libexec/getty $1\"${tab}${CONSOLE_TERM}${tab}onifconsole secure|" /etc/ttys
  grep -q "^${CONSOLE_TTY}${tab}\"/usr/libexec/getty $1\"" /etc/ttys
}

# login_screen ly|console: what greets you on the console from the next boot on
login_screen() {
  case "$1" in
    ly)
      [ -x /usr/local/bin/ly ] || pkg_install ly || return 1
      configure_ly || return 1
      console_getty "$LY_GETTY" || return 1
      ;;
    console)
      console_getty 3wire || die "could not set the console back to the plain login in /etc/ttys"
      ;;
    *) die "usage: bsdopen-firstboot --login-screen ly|console" ;;
  esac
}

# Applies /etc/ttys right away: init restarts the console with the new program,
# which ends the session running there
switch_console() { kill -HUP 1; }

setup_login_screen() {
  [ "$DO_LY" = 1 ] || return 0
  log "Login screen"
  if login_screen ly; then
    LY_OK=1
    ok "ly greets you on the console from now on (back to the plain login: sudo bsdopen-firstboot --login-screen console)"
  else
    console_getty 3wire || true
    warn "ly could not be set up; the plain console login stays"
  fi
}

# on_console: this runs in the console session. sudo runs commands in a pty of
# their own, so look for the console among the parent processes instead.
on_console() {
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$(ps -o tt= -p "$p" 2>/dev/null | tr -d ' ')" = "${CONSOLE_TTY#tty}" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

set_login_screen() { # ly|console, from the command line
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  login_screen "$1"
  if [ -t 0 ] && on_console; then
    echo "Login screen: $1, from the next boot on."
    if ask_yes_no "Switch the console now? This ends this console session." n; then
      switch_console
    fi
  else
    switch_console
    echo "Login screen: $1. The console has switched over."
  fi
}

lock_root() {
  log "root account"
  if is_locked root; then
    ok "root is already locked"
  elif [ "$SUDO_OK" = 1 ] && has_password "$NEW_USER"; then
    pw lock root
    ok "root password locked (use sudo -i from now on; undo: sudo pw unlock root)"
  else
    warn "root was NOT locked: sudo has to work first, so you do not lock yourself out"
  fi
}

run_wizard() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  command -v pw >/dev/null 2>&1 || die "pw not found; this script is for the FreeBSD VM"
  [ -t 0 ] || die "a terminal is required"

  trap cleanup EXIT
  trap on_interrupt INT TERM

  printf '\n%sWelcome to FreeBSD %s (%s)%s\n' "$C_B" "$(freebsd-version -u)" "$(hostname -s)" "$C_0"
  printf 'This one-time setup creates your own account and then locks root.\n'
  printf 'Press Ctrl+C to skip it for now.\n\n'

  ask_questions
  create_user
  setup_sudo
  install_tools
  run_zsh_setup
  setup_info
  setup_lsd
  setup_login_screen
  lock_root
  remove_hook

  printf '\n%sDone.%s Log in as %s%s%s from now on.\n' "$C_B" "$C_0" "$C_B" "$NEW_USER" "$C_0"
  printf '  SSH from the Mac : ssh -p %s %s@localhost\n' "$SSH_PORT" "$NEW_USER"
  printf '  Shut down       : bsdclose (on the Mac) or sudo poweroff\n\n'
  if [ "$LY_OK" = 1 ]; then
    printf 'Press Enter to go to the login screen. '
    IFS= read -r _ || true
    switch_console
  else
    printf 'Press Enter to log out. '
    IFS= read -r _ || true
  fi
}

case "${1:-}" in
  --enable)  enable_hook ;;
  --disable) remove_hook ;;
  --login-screen) set_login_screen "${2:-}" ;;
  "")        run_wizard ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)         die "unknown option: $1 (help: --help)" ;;
esac
