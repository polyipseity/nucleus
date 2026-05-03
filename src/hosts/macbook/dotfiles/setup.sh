#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script supports macOS only"
    exit 1
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

log_step() {
    printf "\n==> %s\n" "$1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_DOTFILES_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles"
DOTFILES_DIR="$DEFAULT_DOTFILES_DIR"
DARWIN_HOST_NAME="${DARWIN_HOST_NAME:-MacBook}"
SUDO_ALIVE_PID=""

# Prefer the directory containing setup.sh when it already has the Nix files.
if [ -f "$SCRIPT_DIR/flake.nix" ] && [ -f "$SCRIPT_DIR/configuration.nix" ]; then
    DOTFILES_DIR="$SCRIPT_DIR"
fi

cleanup() {
    if [ -n "$SUDO_ALIVE_PID" ] && kill -0 "$SUDO_ALIVE_PID" 2>/dev/null; then
        kill "$SUDO_ALIVE_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Ask for sudo once and refresh it while this script runs.
keep_sudo_alive() {
    if [ -n "$SUDO_ALIVE_PID" ] && kill -0 "$SUDO_ALIVE_PID" 2>/dev/null; then
        kill "$SUDO_ALIVE_PID" 2>/dev/null || true
    fi

    echo "Authorizing setup. Enter your password if prompted."
    if sudo -v; then
        while true; do
            sudo -n true
            sleep 60
            kill -0 "$$" || exit
        done 2>/dev/null &

        SUDO_ALIVE_PID=$!
        echo "Sudo keep-alive started (PID: $SUDO_ALIVE_PID)"
    else
        echo "Sudo authentication failed"
        exit 1
    fi
}

echo "Starting MacBook bootstrap"
log_step "Using dotfiles directory: $DOTFILES_DIR"

keep_sudo_alive

log_step "Checking /nix prerequisite"
if [ ! -e /nix ]; then
    echo "/nix not found. Checking /etc/synthetic.conf"

    if [ -f /etc/synthetic.conf ] && sudo -n grep -q "^nix$" /etc/synthetic.conf; then
        echo "'nix' entry already exists in /etc/synthetic.conf"
    else
        echo "Adding 'nix' to /etc/synthetic.conf"
        printf "nix\n" | sudo -n tee -a /etc/synthetic.conf >/dev/null
    fi

    echo "-----------------------------------------------------------"
    echo "ACTION REQUIRED: Reboot is required once to create /nix."
    echo "After reboot, run this script again."
    echo "-----------------------------------------------------------"
    exit 1
fi

log_step "Checking Homebrew"
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if ! command_exists brew; then
    echo "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    eval "$(/opt/homebrew/bin/brew shellenv)"

    BREW_STR='eval "$(/opt/homebrew/bin/brew shellenv)"'
    [ -f ~/.zprofile ] || touch ~/.zprofile
    if ! grep -Fq "$BREW_STR" ~/.zprofile; then
        echo "Adding Homebrew activation to ~/.zprofile"
        echo "$BREW_STR" >>~/.zprofile
    fi

    keep_sudo_alive
else
    echo "Homebrew already installed"
fi

log_step "Checking Nix"
if ! command_exists nix; then
    echo "Installing Determinate Nix"
    curl -L https://install.determinate.systems/nix | sudo -n sh -s -- install --no-confirm

    if [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
        . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
    elif [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix.sh" ]; then
        . "/nix/var/nix/profiles/default/etc/profile.d/nix.sh"
    fi

    if [ -n "${ZSH_VERSION:-}" ]; then
        rehash
    elif [ -n "${BASH_VERSION:-}" ]; then
        hash -r
    fi

    if ! command_exists nix; then
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
    fi

    NIX_STR='if [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"; fi'
    [ -f ~/.zshrc ] || touch ~/.zshrc
    if ! grep -Fq "$NIX_STR" ~/.zshrc; then
        echo "Adding Nix activation to ~/.zshrc"
        echo "$NIX_STR" >>~/.zshrc
    fi
else
    echo "Nix already installed"
fi

log_step "Syncing config into /etc/nix-darwin"
if [ ! -f "$DOTFILES_DIR/flake.nix" ] || [ ! -f "$DOTFILES_DIR/configuration.nix" ]; then
    echo "Expected config files were not found in: $DOTFILES_DIR"
    echo "Make sure flake.nix and configuration.nix exist there, then rerun setup"
    exit 1
fi

if [ ! -d "$DOTFILES_DIR/files/wallpapers" ]; then
    echo "Required wallpaper source folder is missing: $DOTFILES_DIR/files/wallpapers"
    echo "Create it or update configuration.nix, then rerun setup"
    exit 1
fi

sudo -n mkdir -p /etc/nix-darwin
sudo -n install -m 0644 "$DOTFILES_DIR/flake.nix" /etc/nix-darwin/flake.nix
sudo -n install -m 0644 "$DOTFILES_DIR/configuration.nix" /etc/nix-darwin/configuration.nix

# Keep flake-relative assets in sync (for example ./files/wallpapers).
sudo -n install -d -m 0755 /etc/nix-darwin/files
if command_exists rsync; then
    sudo -n rsync -a --delete "$DOTFILES_DIR/files/" /etc/nix-darwin/files/
else
    sudo -n cp -R "$DOTFILES_DIR/files/." /etc/nix-darwin/files/
fi

if [ -f "$DOTFILES_DIR/setup.sh" ]; then
    sudo -n install -m 0755 "$DOTFILES_DIR/setup.sh" /etc/nix-darwin/setup.sh
fi

log_step "Building and switching nix-darwin system"
cd /etc/nix-darwin

# --impure is required because flake.nix resolves currentUserName from env vars.
sudo -n -E HOME=/var/root nix run nix-darwin -- switch \
  --flake ".#${DARWIN_HOST_NAME}" \
  --impure \
  --option accept-flake-config true

log_step "Repairing SSH permissions"
if [ -d ~/.ssh ]; then
    chmod 700 ~/.ssh
fi

if [ -f ~/.ssh/id_rsa ]; then
    chmod 600 ~/.ssh/id_rsa
fi

if [ -f ~/.ssh/id_rsa.pub ]; then
    chmod 644 ~/.ssh/id_rsa.pub
fi

log_step "Bootstrap completed"
