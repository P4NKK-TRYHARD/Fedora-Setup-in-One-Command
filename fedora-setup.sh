#!/usr/bin/env bash
# Copyright (c) 2026 PANKKY
# Licensed under the MIT License - see the LICENSE file.
#
# fedora-setup.sh - Save how your Fedora is set up, and restore it on a fresh
# install with a single command.
#
#   ./fedora-setup.sh export  [DIR]   Save your current setup to DIR (default: ./my-setup)
#   ./fedora-setup.sh install [DIR]   Restore a saved setup on a fresh Fedora
#   ./fedora-setup.sh essentials      Only the must-haves for a fresh Fedora
#                                     (updates, RPM Fusion, codecs, Flathub, drivers)
#
# Options:
#   -y, --yes       Don't ask questions (answer "yes" to optional steps)
#   -n, --dry-run   Show what would be done, without changing anything
#   -h, --help      Show this help
#
# Run it as your normal user (NOT with sudo). It will ask for your password
# when it needs it.

set -uo pipefail

VERSION="1.0.0"
ASSUME_YES=0
DRY_RUN=0
ACTION=""
PROFILE_DIR=""
LOG_FILE="${HOME}/fedora-setup.log"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
REPOS_DIR="${REPOS_DIR:-/etc/yum.repos.d}"
FAILED_STEPS=()

# Files and folders from $HOME that are saved by "export" (if they exist).
# They cover the shell, git and the KDE Plasma / GTK look & feel.
# Nothing with passwords or keys (.ssh, .gnupg, browser profiles...) is saved.
DOTFILES=(
    .bashrc .bash_profile .zshrc .zprofile .p10k.zsh .gitconfig .vimrc
    .oh-my-zsh/custom
    .themes .icons .fonts
    .config/kdeglobals .config/kwinrc .config/kwinrulesrc .config/plasmarc
    .config/plasmashellrc .config/plasma-org.kde.plasma.desktop-appletsrc
    .config/kcminputrc .config/kglobalshortcutsrc .config/kxkbrc
    .config/kscreenlockerrc .config/ksplashrc .config/krunnerrc
    .config/dolphinrc .config/konsolerc .config/breezerc .config/powerdevilrc
    .config/systemsettingsrc .config/Kvantum .config/latte
    .config/gtk-3.0 .config/gtk-4.0 .config/fontconfig .config/autostart
    .config/starship.toml .config/fastfetch .config/neofetch .config/kitty
    .config/alacritty .config/Code/User/settings.json .config/Code/User/keybindings.json
    .local/share/plasma .local/share/color-schemes .local/share/aurorae
    .local/share/icons .local/share/fonts .local/share/konsole
    .local/share/wallpapers .local/share/kxmlgui5
)

# Packages that are never restored by name (they are handled separately).
SKIP_PACKAGES_REGEX='^(kernel|kernel-.*|gpg-pubkey|rpmfusion-.*-release.*|fedora-release.*|ffmpeg-free|libavcodec-free|.*-debuginfo|.*-debugsource)$'

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_OFF=$'\e[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

step()  { echo; echo "${C_BLUE}==> $*${C_OFF}"; echo "==> $*" >>"$LOG_FILE"; }
ok()    { echo "${C_GREEN}  ✓ $*${C_OFF}"; echo "  ok: $*" >>"$LOG_FILE"; }
warn()  { echo "${C_YELLOW}  ! $*${C_OFF}"; echo "  warning: $*" >>"$LOG_FILE"; }
die()   { echo "${C_RED}✗ $*${C_OFF}" >&2; exit 1; }

# Run a command (or just print it in --dry-run mode). Never aborts the script:
# failures are recorded and listed at the end.
run() {
    echo "    \$ $*" >>"$LOG_FILE"
    if (( DRY_RUN )); then
        echo "    [dry-run] $*"
        return 0
    fi
    if "$@" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    local rc=$?
    FAILED_STEPS+=("$*")
    warn "Failed (exit $rc): $*  — see $LOG_FILE"
    return "$rc"
}

ask() {
    # ask "Question?"  -> returns 0 for yes
    (( ASSUME_YES )) && return 0
    local reply
    read -r -p "  ${C_YELLOW}?${C_OFF} $1 [y/N] " reply </dev/tty || return 1
    [[ "$reply" =~ ^[YySs]$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

check_fedora() {
    [[ -r "$OS_RELEASE_FILE" ]] || die "Can't read $OS_RELEASE_FILE."
    # shellcheck disable=SC1091
    . "$OS_RELEASE_FILE"
    [[ "${ID:-}" == "fedora" ]] || die "This script is for Fedora (detected: ${ID:-unknown})."
    if [[ "${VARIANT_ID:-}" =~ ^(silverblue|kinoite|sericea|onyx|cosmic-atomic)$ ]] || [[ -e /run/ostree-booted ]]; then
        die "Atomic Fedora (Silverblue/Kinoite...) is not supported: it uses rpm-ostree instead of dnf."
    fi
    FEDORA_VERSION="${VERSION_ID:-$(rpm -E %fedora)}"
}

check_not_root() {
    (( EUID != 0 )) || die "Run it as your normal user, without sudo. It will ask for your password when needed."
}

start_sudo() {
    (( DRY_RUN )) && return 0
    echo "  The script needs administrator rights for some steps."
    sudo -v || die "sudo is required."
    # Keep sudo alive while the script runs.
    ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "${SUDO_KEEPALIVE_PID:-0}" 2>/dev/null' EXIT
}

# --------------------------------------------------------------------------
# EXPORT: save the current setup
# --------------------------------------------------------------------------

do_export() {
    local dir="${PROFILE_DIR:-./my-setup}"
    mkdir -p "$dir/repos/keys" || die "Can't create $dir"
    dir="$(cd "$dir" && pwd)"
    echo "Saving your setup to: $dir"

    step "Fedora version and desktop"
    {
        echo "fedora=${FEDORA_VERSION}"
        echo "desktop=${XDG_CURRENT_DESKTOP:-unknown}"
        echo "shell=$(basename "${SHELL:-bash}")"
        echo "date=$(date -Iseconds)"
        echo "tool_version=${VERSION}"
    } >"$dir/info.txt"
    ok "info.txt"

    step "Installed packages (the ones you or the installer chose)"
    if dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null | sort -u | grep -Ev "$SKIP_PACKAGES_REGEX" >"$dir/packages.txt"; then
        ok "$(wc -l <"$dir/packages.txt") packages → packages.txt"
    else
        warn "Couldn't list packages with dnf."
    fi

    step "Software repositories"
    if dnf repolist --enabled 2>/dev/null | awk 'NR>1 && $1 !~ /^repo/ {print $1}' >"$dir/enabled-repos.txt"; then
        ok "$(wc -l <"$dir/enabled-repos.txt") enabled repositories → enabled-repos.txt"
    fi
    if rpm -q rpmfusion-free-release >/dev/null 2>&1; then echo "free" >"$dir/rpmfusion.txt"; fi
    if rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then echo "nonfree" >>"$dir/rpmfusion.txt"; fi
    local f n=0
    for f in "$REPOS_DIR"/*.repo; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
            fedora*.repo|rpmfusion*.repo) continue ;;
        esac
        cp "$f" "$dir/repos/" && n=$((n + 1))
        # Copy local GPG keys referenced by the repo (gpgkey=file:///...)
        grep -ho 'file://[^ ,]*' "$f" 2>/dev/null | sed 's#^file://##' | while read -r key; do
            [[ -r "$key" ]] && cp "$key" "$dir/repos/keys/"
        done
    done
    ok "$n extra repositories (Copr, Brave, VS Code, Chrome...) → repos/"

    step "Flatpak apps"
    if have flatpak; then
        flatpak remotes --system --columns=name,url 2>/dev/null >"$dir/flatpak-remotes.txt"
        flatpak list --app --system --columns=application,origin 2>/dev/null >"$dir/flatpaks.txt"
        flatpak list --app --user --columns=application,origin 2>/dev/null | sed 's/$/\tuser/' >>"$dir/flatpaks.txt"
        ok "$(grep -c . "$dir/flatpaks.txt" || true) Flatpak apps → flatpaks.txt"
    else
        : >"$dir/flatpaks.txt"
        warn "flatpak not installed, skipping."
    fi

    step "Snap apps"
    if have snap; then
        snap list 2>/dev/null | awk 'NR>1 && $1 !~ /^(core[0-9]*|snapd|bare|gtk-common-themes|gnome-.*|kde-.*|mesa-.*)$/ {
            classic = ($NF ~ /classic/) ? "classic" : ""
            print $1, classic
        }' >"$dir/snaps.txt"
        ok "$(grep -c . "$dir/snaps.txt" || true) Snap apps → snaps.txt"
    else
        : >"$dir/snaps.txt"
    fi

    step "VS Code extensions"
    if have code; then
        code --list-extensions 2>/dev/null >"$dir/vscode-extensions.txt"
        ok "$(grep -c . "$dir/vscode-extensions.txt" || true) extensions → vscode-extensions.txt"
    else
        : >"$dir/vscode-extensions.txt"
    fi

    step "Personal settings (shell, git, KDE/GTK theme, fonts, icons...)"
    local existing=() item
    for item in "${DOTFILES[@]}"; do
        [[ -e "$HOME/$item" ]] && existing+=("$item")
    done
    if [[ -e "$HOME/.oh-my-zsh" ]]; then echo "yes" >"$dir/oh-my-zsh.txt"; else rm -f "$dir/oh-my-zsh.txt"; fi
    if (( ${#existing[@]} )); then
        tar -czf "$dir/dotfiles.tar.gz" -C "$HOME" --exclude='*.cache' --exclude='.git' "${existing[@]}" 2>>"$LOG_FILE"
        ok "${#existing[@]} items → dotfiles.tar.gz ($(du -h "$dir/dotfiles.tar.gz" | cut -f1))"
        local size_kb
        size_kb=$(du -k "$dir/dotfiles.tar.gz" | cut -f1)
        (( size_kb > 95000 )) && warn "dotfiles.tar.gz is big (>95 MB): GitHub rejects files over 100 MB. Remove some icon/font folders or keep it outside GitHub."
    fi

    if [[ ! -e "$dir/extra.sh" ]]; then
        cat >"$dir/extra.sh" <<'EOF'
#!/usr/bin/env bash
# Your own extra commands. They run at the end of "install", as your user.
# Use "sudo" for anything that needs root. Examples:
#
#   sudo dnf install -y some-package
#   git clone https://github.com/you/your-dotfiles ~/dotfiles
#   gsettings set org.gnome.desktop.interface clock-show-seconds true
EOF
        chmod +x "$dir/extra.sh"
    fi

    echo
    echo "${C_GREEN}Done!${C_OFF} Your setup is saved in: $dir"
    echo "  • Check dotfiles.tar.gz doesn't contain anything private before sharing it."
    echo "  • You can edit packages.txt, flatpaks.txt... and add commands to extra.sh."
    echo "  • On the new Fedora:  ./fedora-setup.sh install \"$(basename "$dir")\""
}

# --------------------------------------------------------------------------
# ESSENTIALS: the must-haves on a fresh Fedora
# --------------------------------------------------------------------------

essentials() {
    step "Faster downloads for dnf"
    if ! grep -q '^max_parallel_downloads' /etc/dnf/dnf.conf 2>/dev/null; then
        run sudo sh -c 'echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf' && ok "max_parallel_downloads=10"
    else
        ok "Already configured"
    fi

    step "Updating the system (this can take a while)"
    run sudo dnf upgrade --refresh -y && ok "System up to date"

    step "Enabling RPM Fusion (free + nonfree)"
    run sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm" \
        && ok "RPM Fusion enabled"
    run sudo dnf install -y --skip-unavailable 'rpmfusion-*-appstream-data'
    run sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

    step "Multimedia codecs (full ffmpeg, H.264, H.265, AAC, MP3...)"
    if rpm -q ffmpeg-free >/dev/null 2>&1; then
        run sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing && ok "ffmpeg-free → ffmpeg"
    else
        run sudo dnf install -y ffmpeg --allowerasing && ok "ffmpeg installed"
    fi
    run sudo dnf install -y --skip-unavailable gstreamer1-plugins-bad-free gstreamer1-plugins-good \
        gstreamer1-plugins-ugly gstreamer1-plugin-openh264 gstreamer1-plugin-libav lame

    step "Hardware video acceleration"
    local gpu
    gpu="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
    if grep -qi intel <<<"$gpu"; then
        run sudo dnf install -y --skip-unavailable intel-media-driver libva-utils && ok "Intel VA-API"
    fi
    if grep -qiwE 'amd|ati|radeon' <<<"$gpu"; then
        run sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing
        run sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld --allowerasing
        ok "AMD VA-API/VDPAU (freeworld)"
    fi

    step "Flathub (app store for Flatpak apps)"
    if have flatpak || run sudo dnf install -y flatpak; then
        run sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
            && ok "Flathub enabled"
    fi

    nvidia_driver
    asus_tools
}

nvidia_driver() {
    lspci 2>/dev/null | grep -Ei 'vga|3d' | grep -qi nvidia || return 0
    step "NVIDIA graphics card detected"
    if rpm -q akmod-nvidia >/dev/null 2>&1; then
        ok "NVIDIA driver already installed"
        return 0
    fi
    if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        warn "Secure Boot is ON. The NVIDIA driver must be signed or it won't load."
        warn "See: https://rpmfusion.org/Howto/Secure%20Boot  (or turn Secure Boot off in the BIOS)."
    fi
    if ask "Install the NVIDIA proprietary driver (RPM Fusion)?"; then
        run sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda \
            && ok "Driver installed. It compiles in the background: wait ~5 minutes before rebooting."
    fi
}

asus_tools() {
    grep -qi asus /sys/class/dmi/id/sys_vendor 2>/dev/null || return 0
    step "ASUS laptop detected"
    if rpm -q asusctl >/dev/null 2>&1; then
        ok "asusctl already installed"
        return 0
    fi
    if ask "Install asusctl (fan profiles, battery charge limit, keyboard lights) from asus-linux.org?"; then
        run sudo dnf copr enable -y lukenukem/asus-linux
        run sudo dnf install -y --skip-unavailable asusctl supergfxctl rog-control-center asusctl-rog-gui
        run sudo systemctl enable --now supergfxd.service
        ok "ASUS tools installed (open 'ROG Control Center')"
    fi
}

# --------------------------------------------------------------------------
# INSTALL: restore a saved setup
# --------------------------------------------------------------------------

restore_repos() {
    local dir="$1"
    step "Restoring software repositories"
    if [[ -f "$dir/rpmfusion.txt" ]] && grep -q nonfree "$dir/rpmfusion.txt"; then
        : # already enabled by essentials()
    fi
    local f n=0
    for f in "$dir"/repos/keys/*; do
        [[ -e "$f" ]] || continue
        run sudo install -m 644 "$f" /etc/pki/rpm-gpg/
    done
    for f in "$dir"/repos/*.repo; do
        [[ -e "$f" ]] || continue
        if [[ -e "/etc/yum.repos.d/$(basename "$f")" ]]; then
            continue
        fi
        run sudo install -m 644 "$f" /etc/yum.repos.d/ && n=$((n + 1))
    done
    ok "$n repositories added"

    # Re-enable repos that were enabled before (e.g. Steam, NVIDIA from RPM Fusion)
    if [[ -s "$dir/enabled-repos.txt" ]]; then
        local available id
        available="$(dnf repolist --all 2>/dev/null | awk 'NR>1 {print $1}')"
        while read -r id; do
            [[ -n "$id" ]] || continue
            if grep -qxF "$id" <<<"$available" && ! dnf repolist --enabled 2>/dev/null | awk '{print $1}' | grep -qxF "$id"; then
                run sudo dnf config-manager setopt "${id}.enabled=1" && ok "Enabled $id"
            fi
        done <"$dir/enabled-repos.txt"
    fi
    run sudo dnf makecache -y
}

restore_packages() {
    local dir="$1"
    [[ -s "$dir/packages.txt" ]] || return 0
    step "Installing your packages (this is the longest step)"
    local pkgs=()
    mapfile -t pkgs < <(grep -Ev "$SKIP_PACKAGES_REGEX" "$dir/packages.txt" | grep -v '^\s*$' | grep -v '^#')
    echo "  ${#pkgs[@]} packages. Ones that don't exist on this Fedora version are skipped."
    run sudo dnf install -y --skip-unavailable --skip-broken "${pkgs[@]}" && ok "Packages installed"
}

restore_flatpaks() {
    local dir="$1"
    [[ -s "$dir/flatpaks.txt" ]] || return 0
    step "Installing your Flatpak apps"
    have flatpak || run sudo dnf install -y flatpak
    # Flathub is added by essentials(). Other remotes need their .flatpakrepo file.
    local name url existing
    existing="$(flatpak remotes --system --columns=name 2>/dev/null)"
    if [[ -s "$dir/flatpak-remotes.txt" ]]; then
        while read -r name url; do
            [[ -n "$name" ]] || continue
            grep -qxF "$name" <<<"$existing" && continue
            case "$name" in
                flathub) ;;
                flathub-beta) run sudo flatpak remote-add --if-not-exists flathub-beta https://dl.flathub.org/beta-repo/flathub-beta.flatpakrepo ;;
                fedora|fedora-testing) ;;   # comes with Fedora
                *) warn "Flatpak remote '$name' ($url) must be added by hand; its apps may fail." ;;
            esac
        done <"$dir/flatpak-remotes.txt"
    fi
    local app origin scope n=0
    while IFS=$'\t ' read -r app origin scope; do
        [[ -n "$app" ]] || continue
        origin="${origin:-flathub}"
        if [[ "$scope" == "user" ]]; then
            run flatpak install --user -y --noninteractive "$origin" "$app" && n=$((n + 1))
        else
            run sudo flatpak install -y --noninteractive "$origin" "$app" && n=$((n + 1))
        fi
    done <"$dir/flatpaks.txt"
    ok "$n Flatpak apps installed"
}

restore_snaps() {
    local dir="$1"
    [[ -s "$dir/snaps.txt" ]] || return 0
    step "Installing your Snap apps"
    if ! have snap; then
        run sudo dnf install -y snapd
        [[ -e /snap ]] || run sudo ln -s /var/lib/snapd/snap /snap
        run sudo systemctl enable --now snapd.socket
        (( DRY_RUN )) || sleep 10   # snapd needs a moment to be ready
    fi
    local name mode
    while read -r name mode; do
        [[ -n "$name" ]] || continue
        if [[ "$mode" == "classic" ]]; then
            run sudo snap install "$name" --classic
        else
            run sudo snap install "$name"
        fi
    done <"$dir/snaps.txt"
    ok "Snap apps installed"
}

restore_vscode() {
    local dir="$1"
    [[ -s "$dir/vscode-extensions.txt" ]] || return 0
    step "Installing VS Code extensions"
    if ! have code && (( ! DRY_RUN )); then
        warn "VS Code isn't installed, skipping extensions."
        return 0
    fi
    local ext n=0
    while read -r ext; do
        [[ -n "$ext" ]] || continue
        run code --install-extension "$ext" --force && n=$((n + 1))
    done <"$dir/vscode-extensions.txt"
    ok "$n extensions installed"
}

restore_shell() {
    local dir="$1" shell=""
    [[ -f "$dir/info.txt" ]] && shell="$(sed -n 's/^shell=//p' "$dir/info.txt")"
    if [[ -f "$dir/oh-my-zsh.txt" ]] && [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        step "Installing Oh My Zsh"
        have git || run sudo dnf install -y git
        run git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" && ok "Oh My Zsh installed"
    fi
    if [[ -n "$shell" && "$shell" != "bash" ]]; then
        step "Setting $shell as your default shell"
        have "$shell" || run sudo dnf install -y "$shell"
        local path
        path="$(command -v "$shell" || echo "/usr/bin/$shell")"
        run sudo usermod -s "$path" "$USER" && ok "Default shell: $path (from your next login)"
    fi
}

restore_dotfiles() {
    local dir="$1"
    [[ -f "$dir/dotfiles.tar.gz" ]] || return 0
    step "Restoring your personal settings (theme, fonts, icons, shell, git...)"
    local backup
    backup="$HOME/fedora-setup-backup-$(date +%Y%m%d-%H%M%S)"
    local item n=0
    # Back up any existing file that is about to be overwritten
    while read -r item; do
        item="${item%/}"
        [[ -n "$item" ]] || continue
        if [[ -f "$HOME/$item" || -L "$HOME/$item" ]]; then
            n=$((n + 1))
            (( DRY_RUN )) && continue
            mkdir -p "$backup/$(dirname "$item")" && cp -a "$HOME/$item" "$backup/$item"
        fi
    done < <(tar -tzf "$dir/dotfiles.tar.gz" 2>/dev/null)
    if (( n )); then
        if (( DRY_RUN )); then ok "$n existing file(s) would be backed up to $backup"
        else ok "$n existing file(s) backed up to $backup"; fi
    fi
    run tar -xzf "$dir/dotfiles.tar.gz" -C "$HOME" && ok "Settings restored (log out and back in to see them)"
}

run_extra() {
    local dir="$1"
    [[ -f "$dir/extra.sh" ]] || return 0
    grep -qv '^\s*\(#.*\)\?$' "$dir/extra.sh" || return 0   # only comments
    step "Running your extra commands (extra.sh)"
    run bash "$dir/extra.sh" && ok "extra.sh finished"
}

do_install() {
    local dir="${PROFILE_DIR:-./my-setup}"
    [[ -d "$dir" ]] || die "Can't find the saved setup '$dir'. Run 'export' on your old Fedora first, or use 'essentials'."
    dir="$(cd "$dir" && pwd)"
    if [[ -f "$dir/info.txt" ]]; then
        local saved
        saved="$(sed -n 's/^fedora=//p' "$dir/info.txt")"
        echo "Restoring setup saved on Fedora ${saved:-?} (this is Fedora ${FEDORA_VERSION})."
    fi
    start_sudo
    essentials
    restore_repos "$dir"
    restore_packages "$dir"
    restore_flatpaks "$dir"
    restore_snaps "$dir"
    restore_vscode "$dir"
    restore_shell "$dir"
    restore_dotfiles "$dir"
    run_extra "$dir"
}

summary() {
    echo
    if (( ${#FAILED_STEPS[@]} )); then
        echo "${C_YELLOW}Finished with ${#FAILED_STEPS[@]} step(s) that failed:${C_OFF}"
        printf '  - %s\n' "${FAILED_STEPS[@]}"
        echo "  Details in: $LOG_FILE"
    else
        echo "${C_GREEN}All done!${C_OFF} Full log: $LOG_FILE"
    fi
    (( DRY_RUN )) || echo "Reboot your computer to finish:  sudo systemctl reboot"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
    while (( $# )); do
        case "$1" in
            export|install|essentials) ACTION="$1" ;;
            -y|--yes) ASSUME_YES=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -h|--help) usage 0 ;;
            -v|--version) echo "fedora-setup $VERSION"; exit 0 ;;
            -*) echo "Unknown option: $1"; usage 1 ;;
            *) PROFILE_DIR="$1" ;;
        esac
        shift
    done
    [[ -n "$ACTION" ]] || usage 1

    check_not_root
    check_fedora
    : >"$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
    echo "fedora-setup $VERSION — $ACTION$( (( DRY_RUN )) && echo ' (dry run: nothing will be changed)')"

    case "$ACTION" in
        export) do_export; return ;;
        essentials) start_sudo; essentials ;;
        install) do_install ;;
    esac
    summary
}

main "$@"
