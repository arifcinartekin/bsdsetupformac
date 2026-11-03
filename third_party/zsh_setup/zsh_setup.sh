#!/usr/bin/env sh
# =============================================================================
# Universal ZSH Setup Script
# Platforms: Fedora/RHEL, Arch, Debian/Ubuntu, macOS (Homebrew),
#            Termux (Android), Gentoo, Void, Alpine, OpenSUSE, Slackware, NixOS
# Installs : zsh, oh-my-zsh, powerlevel10k, MesloLGS NF fonts,
#            zsh-autosuggestions, zsh-syntax-highlighting
#            Enables setopt CORRECT_ALL
# =============================================================================

set -e

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
die()     { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; exit 1; }
header()  { printf "\n${BOLD}${CYAN}══ %s ══${RESET}\n" "$*"; }

# ── Root / sudo helper ────────────────────────────────────────────────────────
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    elif command -v doas >/dev/null 2>&1; then
        SUDO="doas"
    fi
    # Termux & some minimal envs run as "user" with no sudo — that's fine
fi

run_privileged() { $SUDO "$@"; }

# ── Platform detection ────────────────────────────────────────────────────────
detect_platform() {
    # Termux (Android) — must come first
    if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
        PLATFORM="termux"; PKG_MGR="pkg"; return
    fi

    # macOS
    if [ "$(uname)" = "Darwin" ]; then
        PLATFORM="macos"
        if command -v brew >/dev/null 2>&1; then PKG_MGR="brew"
        else PKG_MGR="brew_install"; fi   # brew itself needs installing
        return
    fi

    # Linux — read os-release
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        ID_LOWER=$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')
        ID_LIKE_LOWER=$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')

        case "$ID_LOWER" in
            fedora|rhel|centos|almalinux|rocky|ol)       PLATFORM="fedora";  PKG_MGR="dnf"   ;;
            arch|manjaro|endeavouros|artix|garuda|cachyos) PLATFORM="arch";  PKG_MGR="pacman" ;;
            debian|ubuntu|pop|mint|kali|parrot|elementary|zorin|raspbian) PLATFORM="debian"; PKG_MGR="apt" ;;
            opensuse*|sles)                               PLATFORM="opensuse"; PKG_MGR="zypper" ;;
            alpine)                                       PLATFORM="alpine";  PKG_MGR="apk"   ;;
            void)                                         PLATFORM="void";    PKG_MGR="xbps"  ;;
            gentoo)                                       PLATFORM="gentoo";  PKG_MGR="emerge" ;;
            nixos)                                        PLATFORM="nixos";   PKG_MGR="nix"   ;;
            slackware)                                    PLATFORM="slackware"; PKG_MGR="slackpkg" ;;
            *)
                # Fallback: check ID_LIKE
                case "$ID_LIKE_LOWER" in
                    *fedora*|*rhel*)   PLATFORM="fedora";  PKG_MGR="dnf"    ;;
                    *arch*)            PLATFORM="arch";    PKG_MGR="pacman" ;;
                    *debian*|*ubuntu*) PLATFORM="debian";  PKG_MGR="apt"    ;;
                    *suse*)            PLATFORM="opensuse"; PKG_MGR="zypper" ;;
                    *)                 PLATFORM="unknown"; PKG_MGR="unknown" ;;
                esac
                ;;
        esac
    else
        PLATFORM="unknown"; PKG_MGR="unknown"
    fi
}

# ── Package manager wrappers ──────────────────────────────────────────────────
pkg_update() {
    info "Updating package lists…"
    case "$PKG_MGR" in
        apt)      run_privileged apt-get update -qq ;;
        dnf)      run_privileged dnf check-update -q || true ;;
        pacman)   run_privileged pacman -Sy --noconfirm ;;
        zypper)   run_privileged zypper refresh -q ;;
        apk)      run_privileged apk update -q ;;
        xbps)     run_privileged xbps-install -Su -y >/dev/null 2>&1 || true ;;
        emerge)   run_privileged emerge --sync -q || true ;;
        nix)      : ;;  # nix-env manages channels differently
        slackpkg) run_privileged slackpkg update || true ;;
        pkg)      pkg update -y ;;
        brew)     brew update --quiet || true ;;
        brew_install) : ;;
        *)        warn "Unknown package manager — skipping update" ;;
    esac
}

pkg_install() {
    # pkg_install <package> [<package> …]
    info "Installing: $*"
    case "$PKG_MGR" in
        apt)         run_privileged apt-get install -y -qq "$@" ;;
        dnf)         run_privileged dnf install -y -q "$@" ;;
        pacman)      run_privileged pacman -S --noconfirm --needed "$@" ;;
        zypper)      run_privileged zypper install -y -q "$@" ;;
        apk)         run_privileged apk add -q "$@" ;;
        xbps)        run_privileged xbps-install -Sy "$@" ;;
        emerge)      run_privileged emerge --ask=n "$@" ;;
        nix)         nix-env -iA "$@" ;;          # caller must pass nixpkgs.X
        slackpkg)    run_privileged slackpkg install "$@" || true ;;
        pkg)         pkg install -y "$@" ;;
        brew)        brew install "$@" ;;
        brew_install) : ;;  # handled separately
        *)           die "Cannot install packages: unknown package manager" ;;
    esac
}

# ── Map generic names to distro-specific names ────────────────────────────────
resolve_pkg() {
    # resolve_pkg <generic>  →  prints distro package name
    generic="$1"
    case "$generic" in
        zsh)
            case "$PKG_MGR" in
                nix) echo "nixpkgs.zsh" ;;
                *)   echo "zsh" ;;
            esac ;;
        git)
            case "$PKG_MGR" in
                nix) echo "nixpkgs.git" ;;
                *)   echo "git" ;;
            esac ;;
        curl)
            case "$PKG_MGR" in
                apk)     echo "curl" ;;
                termux)  echo "curl" ;;
                nix)     echo "nixpkgs.curl" ;;
                *)       echo "curl" ;;
            esac ;;
        wget)
            case "$PKG_MGR" in
                nix) echo "nixpkgs.wget" ;;
                *)   echo "wget" ;;
            esac ;;
        fontconfig)
            case "$PKG_MGR" in
                apk)    echo "fontconfig" ;;
                emerge) echo "media-libs/fontconfig" ;;
                nix)    echo "nixpkgs.fontconfig" ;;
                brew|pkg) echo "" ;;   # not needed
                *)      echo "fontconfig" ;;
            esac ;;
        unzip)
            case "$PKG_MGR" in
                nix) echo "nixpkgs.unzip" ;;
                *)   echo "unzip" ;;
            esac ;;
    esac
}

# ── Install Homebrew on macOS if missing ──────────────────────────────────────
install_brew() {
    header "Installing Homebrew"
    if command -v brew >/dev/null 2>&1; then
        success "Homebrew already installed"
        PKG_MGR="brew"; return
    fi
    if ! command -v curl >/dev/null 2>&1; then
        # macOS ships curl, but just in case
        xcode-select --install 2>/dev/null || true
    fi
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for the rest of this script
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    PKG_MGR="brew"
    success "Homebrew installed"
}

# ── Download helper (curl → wget → fetch fallback) ────────────────────────────
download() {
    url="$1"; dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    elif command -v fetch >/dev/null 2>&1; then   # FreeBSD / some minimal
        fetch -q -o "$dest" "$url"
    else
        die "No download tool found (curl/wget/fetch). Please install one."
    fi
}

# ── Bootstrap: ensure curl + git exist before anything else ──────────────────
bootstrap_deps() {
    header "Bootstrapping dependencies"

    [ "$PKG_MGR" = "brew_install" ] && { install_brew; }

    pkg_update

    for dep in curl git wget unzip; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            pkg_name=$(resolve_pkg "$dep")
            [ -n "$pkg_name" ] && pkg_install "$pkg_name"
        else
            success "$dep already present"
        fi
    done

    # fontconfig (Linux only — needed for fc-cache)
    if [ "$PLATFORM" != "macos" ] && [ "$PLATFORM" != "termux" ]; then
        if ! command -v fc-cache >/dev/null 2>&1; then
            pkg_name=$(resolve_pkg fontconfig)
            [ -n "$pkg_name" ] && pkg_install "$pkg_name"
        fi
    fi
}

# ── Install ZSH ───────────────────────────────────────────────────────────────
install_zsh() {
    header "Installing ZSH"
    if command -v zsh >/dev/null 2>&1; then
        success "zsh already installed: $(zsh --version)"
        return
    fi
    pkg_name=$(resolve_pkg zsh)
    pkg_install "$pkg_name"
    success "zsh installed: $(zsh --version)"
}

# ── Set ZSH as default shell ──────────────────────────────────────────────────
set_default_shell() {
    header "Setting ZSH as default shell"
    ZSH_PATH=$(command -v zsh)

    # ── Termux ────────────────────────────────────────────────────────────────
    # Termux doesn't use /etc/shells or chsh.
    # We make zsh the default by auto-launching it from ~/.bashrc / ~/.bash_profile
    if [ "$PLATFORM" = "termux" ]; then
        for RC in "$HOME/.bashrc" "$HOME/.bash_profile"; do
            if [ -f "$RC" ] && ! grep -q 'exec zsh' "$RC" 2>/dev/null; then
                printf '\n# Launch zsh by default\n[ -x "$(command -v zsh)" ] && exec zsh\n' >> "$RC"
                success "Auto-launch zsh added to $RC"
            fi
        done
        # Also try termux's own chsh equivalent
        if command -v chsh >/dev/null 2>&1; then
            chsh -s zsh 2>/dev/null && success "Termux chsh set to zsh" || true
        fi
        return
    fi

    # ── NixOS ─────────────────────────────────────────────────────────────────
    # Edit /etc/nixos/configuration.nix to set defaultShell, then rebuild.
    if [ "$PLATFORM" = "nixos" ]; then
        NIXCFG="/etc/nixos/configuration.nix"
        if [ -f "$NIXCFG" ]; then
            # Add zsh program block if not already present
            if ! grep -q 'programs.zsh.enable' "$NIXCFG" 2>/dev/null; then
                run_privileged sed -i 's|^}$|  programs.zsh.enable = true;\n}|' "$NIXCFG"
                info "Added programs.zsh.enable to $NIXCFG"
            fi
            # Set default user shell
            CURRENT_USER=$(id -un)
            if ! grep -q "users.users.$CURRENT_USER" "$NIXCFG" 2>/dev/null; then
                run_privileged sed -i "s|^}$|  users.users.$CURRENT_USER.shell = pkgs.zsh;\n}|" "$NIXCFG"
                info "Set users.users.$CURRENT_USER.shell = pkgs.zsh in $NIXCFG"
            fi
            info "Running nixos-rebuild switch (this may take a moment)…"
            run_privileged nixos-rebuild switch && success "NixOS rebuilt with zsh as default shell" \
                || warn "nixos-rebuild failed — check $NIXCFG manually"
        else
            warn "Could not find $NIXCFG — skipping NixOS shell configuration"
        fi
        return
    fi

    # ── All other platforms ───────────────────────────────────────────────────
    # Add to /etc/shells if missing
    if ! grep -qx "$ZSH_PATH" /etc/shells 2>/dev/null; then
        echo "$ZSH_PATH" | run_privileged tee -a /etc/shells >/dev/null
    fi

    if [ "$SHELL" = "$ZSH_PATH" ]; then
        success "ZSH is already the default shell"
        return
    fi

    # Try chsh first
    if command -v chsh >/dev/null 2>&1; then
        if chsh -s "$ZSH_PATH" 2>/dev/null; then
            success "Default shell set to $ZSH_PATH via chsh"
            return
        fi
        # chsh exists but failed (e.g. PAM / LDAP env) — fall through
        warn "chsh failed, trying alternative methods…"
    fi

    # Fallback 1: usermod (Linux, requires root)
    if command -v usermod >/dev/null 2>&1; then
        if run_privileged usermod -s "$ZSH_PATH" "$(id -un)" 2>/dev/null; then
            success "Default shell set to $ZSH_PATH via usermod"
            return
        fi
    fi

    # Fallback 2: passwd -e / pw usermod (BSD-style)
    if command -v pw >/dev/null 2>&1; then
        if run_privileged pw usermod "$(id -un)" -s "$ZSH_PATH" 2>/dev/null; then
            success "Default shell set to $ZSH_PATH via pw usermod"
            return
        fi
    fi

    # Fallback 3: directly edit /etc/passwd with sed (last resort, always works)
    if [ -f /etc/passwd ]; then
        CURRENT_USER=$(id -un)
        ESCAPED_ZSH=$(printf '%s' "$ZSH_PATH" | sed 's/[\/&]/\\&/g')
        run_privileged sed -i.bak "s|^\($CURRENT_USER:.*:\)[^:]*$|\1$ESCAPED_ZSH|" /etc/passwd \
            && success "Default shell set to $ZSH_PATH via /etc/passwd edit" \
            || warn "Could not edit /etc/passwd — please run: chsh -s $ZSH_PATH"
        return
    fi

    warn "Could not set default shell automatically. Please run: chsh -s $ZSH_PATH"
}

# ── Install Oh My Zsh ─────────────────────────────────────────────────────────
install_omz() {
    header "Installing Oh My Zsh"
    if [ -d "$HOME/.oh-my-zsh" ]; then
        success "Oh My Zsh already installed"
        return
    fi

    TMPFILE=$(mktemp /tmp/omz_install.XXXXXX.sh)
    download "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" "$TMPFILE"
    chmod +x "$TMPFILE"
    # RUNZSH=no → don't switch to zsh mid-script; CHSH=no → we handle it
    RUNZSH=no CHSH=no sh "$TMPFILE" --unattended
    rm -f "$TMPFILE"
    success "Oh My Zsh installed"
}

# ── Install Powerlevel10k ─────────────────────────────────────────────────────
install_p10k() {
    header "Installing Powerlevel10k"
    P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    if [ -d "$P10K_DIR" ]; then
        success "Powerlevel10k already installed"
        return
    fi
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
    success "Powerlevel10k installed"
}

# ── Install MesloLGS NF fonts ─────────────────────────────────────────────────
install_fonts() {
    header "Installing MesloLGS NF fonts"

    FONT_BASE="https://github.com/romkatv/powerlevel10k-media/raw/master"
    FONTS="
MesloLGS%20NF%20Regular.ttf
MesloLGS%20NF%20Bold.ttf
MesloLGS%20NF%20Italic.ttf
MesloLGS%20NF%20Bold%20Italic.ttf
"

    if [ "$PLATFORM" = "macos" ]; then
        FONT_DIR="$HOME/Library/Fonts"
        mkdir -p "$FONT_DIR"
        for f in $FONTS; do
            [ -z "$f" ] && continue
            fname=$(printf '%s' "$f" | sed 's/%20/ /g')
            if [ ! -f "$FONT_DIR/$fname" ]; then
                info "Downloading $fname"
                download "$FONT_BASE/$f" "$FONT_DIR/$fname"
            fi
        done
        success "Fonts installed to ~/Library/Fonts"

    elif [ "$PLATFORM" = "termux" ]; then
        FONT_DIR="$HOME/.termux"
        mkdir -p "$FONT_DIR"
        info "Downloading MesloLGS NF Regular as Termux font"
        download "$FONT_BASE/MesloLGS%20NF%20Regular.ttf" "$FONT_DIR/font.ttf"
        # Reload termux settings if possible
        command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true
        success "Font installed to ~/.termux/font.ttf"

    else
        # Linux (all distros)
        FONT_DIR="$HOME/.local/share/fonts/MesloLGS-NF"
        mkdir -p "$FONT_DIR"
        for f in $FONTS; do
            [ -z "$f" ] && continue
            fname=$(printf '%s' "$f" | sed 's/%20/ /g')
            if [ ! -f "$FONT_DIR/$fname" ]; then
                info "Downloading $fname"
                download "$FONT_BASE/$f" "$FONT_DIR/$fname"
            fi
        done
        # Refresh font cache
        if command -v fc-cache >/dev/null 2>&1; then
            fc-cache -fv "$FONT_DIR" >/dev/null 2>&1
        fi
        success "Fonts installed to $FONT_DIR"
    fi
}

# ── Install ZSH plugins ───────────────────────────────────────────────────────
install_plugins() {
    header "Installing ZSH plugins"
    CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    mkdir -p "$CUSTOM"

    # zsh-autosuggestions
    AS_DIR="$CUSTOM/zsh-autosuggestions"
    if [ -d "$AS_DIR" ]; then
        success "zsh-autosuggestions already installed"
    else
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$AS_DIR"
        success "zsh-autosuggestions installed"
    fi

    # zsh-syntax-highlighting
    SH_DIR="$CUSTOM/zsh-syntax-highlighting"
    if [ -d "$SH_DIR" ]; then
        success "zsh-syntax-highlighting already installed"
    else
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$SH_DIR"
        success "zsh-syntax-highlighting installed"
    fi
}

# ── Configure .zshrc ──────────────────────────────────────────────────────────
configure_zshrc() {
    header "Configuring ~/.zshrc"
    ZSHRC="$HOME/.zshrc"

    # Backup existing
    if [ -f "$ZSHRC" ]; then
        cp "$ZSHRC" "$ZSHRC.bak.$(date +%Y%m%d%H%M%S)"
        info "Backed up existing .zshrc"
    fi

    # Set theme to powerlevel10k
    if grep -q '^ZSH_THEME=' "$ZSHRC" 2>/dev/null; then
        sed -i.tmp 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$ZSHRC"
        rm -f "$ZSHRC.tmp"
    else
        printf '\nZSH_THEME="powerlevel10k/powerlevel10k"\n' >> "$ZSHRC"
    fi

    # Enable plugins (preserve existing list, append if missing)
    if grep -q '^plugins=' "$ZSHRC" 2>/dev/null; then
        # Replace plugins line wholesale — safest approach
        sed -i.tmp 's|^plugins=.*|plugins=(git zsh-autosuggestions zsh-syntax-highlighting)|' "$ZSHRC"
        rm -f "$ZSHRC.tmp"
    else
        printf '\nplugins=(git zsh-autosuggestions zsh-syntax-highlighting)\n' >> "$ZSHRC"
    fi

    # p10k instant prompt — prepend if not already present
    P10K_INSTANT='# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi'
    if ! grep -q 'p10k-instant-prompt' "$ZSHRC" 2>/dev/null; then
        # Prepend to file
        TMPF=$(mktemp)
        printf '%s\n\n' "$P10K_INSTANT" > "$TMPF"
        cat "$ZSHRC" >> "$TMPF"
        mv "$TMPF" "$ZSHRC"
    fi

    # Source p10k config at end of .zshrc
    if ! grep -q 'p10k.zsh' "$ZSHRC" 2>/dev/null; then
        printf '\n# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.\n' >> "$ZSHRC"
        printf '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh\n' >> "$ZSHRC"
    fi

    # setopt CORRECT_ALL
    if ! grep -q 'setopt CORRECT_ALL' "$ZSHRC" 2>/dev/null; then
        printf '\n# Auto-correct commands\nsetopt CORRECT_ALL\n' >> "$ZSHRC"
    fi

    success ".zshrc configured"
}

# ── Final summary ─────────────────────────────────────────────────────────────
print_summary() {
    printf "\n${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}${GREEN}║        ZSH Setup Complete!                       ║${RESET}\n"
    printf "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}\n\n"
    printf "  Platform  : ${BOLD}%s${RESET}\n" "$PLATFORM"
    printf "  Pkg Mgr   : ${BOLD}%s${RESET}\n" "$PKG_MGR"
    printf "  ZSH       : ${BOLD}%s${RESET}\n" "$(command -v zsh)"
    printf "  OMZ       : ${BOLD}%s${RESET}\n" "$HOME/.oh-my-zsh"
    printf "  Theme     : ${BOLD}powerlevel10k${RESET}\n"
    printf "  Plugins   : ${BOLD}zsh-autosuggestions, zsh-syntax-highlighting${RESET}\n"
    printf "  Options   : ${BOLD}setopt CORRECT_ALL${RESET}\n\n"

    if [ "$PLATFORM" = "termux" ]; then
        printf "${YELLOW}► Termux:${RESET} Type 'zsh' to start using it.\n"
        printf "  Change default shell: chsh -s zsh  (or edit ~/.bashrc)\n\n"
    elif [ "$PLATFORM" = "nixos" ]; then
        printf "${YELLOW}► NixOS:${RESET} Add 'programs.zsh.enable = true;' to your config.\n\n"
    else
        printf "${YELLOW}► Log out and back in${RESET} (or run 'exec zsh') to apply shell change.\n\n"
    fi

    printf "${CYAN}► Starting p10k configuration wizard…${RESET}\n"
    printf "  (Set your terminal font to ${BOLD}MesloLGS NF${RESET} before proceeding!)\n\n"
}

# ── Launch p10k configure ─────────────────────────────────────────────────────
launch_p10k() {
    P10K_SCRIPT="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme"
    if [ -f "$P10K_SCRIPT" ]; then
        exec zsh -c "source $HOME/.zshrc 2>/dev/null; p10k configure"
    else
        warn "p10k theme not found — run 'p10k configure' manually after starting zsh"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    printf "${BOLD}${CYAN}\n"
    printf "  ███████╗███████╗██╗  ██╗    ███████╗███████╗████████╗██╗   ██╗██████╗ \n"
    printf "     ███╔╝██╔════╝██║  ██║    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗\n"
    printf "    ███╔╝ ███████╗███████║    ███████╗█████╗     ██║   ██║   ██║██████╔╝\n"
    printf "   ███╔╝  ╚════██║██╔══██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ \n"
    printf "  ███████╗███████║██║  ██║    ███████║███████╗   ██║   ╚██████╔╝██║     \n"
    printf "  ╚══════╝╚══════╝╚═╝  ╚═╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     \n"
    printf "                        Universal ZSH Setup${RESET}\n\n"

    detect_platform
    info "Detected platform : $PLATFORM"
    info "Package manager   : $PKG_MGR"

    bootstrap_deps
    install_zsh
    set_default_shell
    install_omz
    install_p10k
    install_fonts
    install_plugins
    configure_zshrc
    print_summary
    launch_p10k
}

main "$@"