#!/bin/bash
set -Eeuo pipefail

readonly OMARCHY_KEY_FINGERPRINT="40DFB630FF42BCFFB047046CF0134EE680CAC571"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly SESSION_SOURCE="/usr/local/share/wayland-sessions/omarchy.desktop"
readonly SESSION_COMPAT_LINK="/usr/share/wayland-sessions/omarchy-cachyos.desktop"
readonly INSTALL_STATE_DIR="/var/lib/omarchy-on-cachyos"
readonly SESSION_LINK_MARKER="$INSTALL_STATE_DIR/created-wayland-session-link"
readonly SDDM_ENABLED_MARKER="$INSTALL_STATE_DIR/enabled-sddm"
readonly DEFAULT_TARGET_MARKER="$INSTALL_STATE_DIR/default-target-before-sddm"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

confirm() {
  local prompt=$1 default=${2:-no} answer

  while true; do
    if [[ $default == yes ]]; then
      read -r -p "$prompt [Y/n]: " answer
    else
      read -r -p "$prompt [y/N]: " answer
    fi

    case ${answer,,} in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      '')
        if [[ $default == yes ]]; then
          return 0
        else
          return 1
        fi
        ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

[[ $EUID -ne 0 ]] || die 'Run as your regular user, not with sudo.'
command -v pacman >/dev/null || die 'pacman is required.'
command -v sudo >/dev/null || die 'sudo is required.'

mapfile -t packages < <(pacman -Qq | grep -E '^omarchy($|-)' || true)
if ((${#packages[@]} == 0)) && ! grep -q '^\[omarchy\]' "$PACMAN_CONF"; then
  die 'No Omarchy packages or [omarchy] repository were found.'
fi

printf 'Omarchy packages selected for removal:\n'
if ((${#packages[@]})); then
  printf '  %s\n' "${packages[@]}"
else
  printf '  (none installed)\n'
fi

cat <<'NOTICE'
This removes installed packages whose names start with "omarchy", removes the
[omarchy] pacman repository and local signing key, and archives Omarchy-specific
user state before removing it.

It does NOT remove shared dependencies, KDE, generic Hyprland configs, personal
files, or edit bootloader entries. Review the package list before continuing.
If this installer enabled SDDM, changed the default boot target, or added a
generic Wayland session link, those installer-managed changes will be handled
separately below.
NOTICE

confirm 'Continue with the uninstallation?' no || die 'Cancelled; no changes made.'

backup="$HOME/.local/backups/omarchy-uninstall-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
state_paths=(
  .config/omarchy
  .local/state/omarchy
  .local/share/omarchy
  .cache/omarchy
  .config/autostart/limine-snapper-notify.desktop
)
existing_paths=()
for path in "${state_paths[@]}"; do
  if [[ -e "$HOME/$path" || -L "$HOME/$path" ]]; then
    existing_paths+=("$path")
  fi
done

if ((${#existing_paths[@]})); then
  info 'Archiving Omarchy-specific user data'
  tar -C "$HOME" -cpf "$backup/user-data.tar" -- "${existing_paths[@]}"
fi

if ((${#packages[@]})); then
  info 'Removing Omarchy-named packages only'
  # No -s or -n: do not cascade into shared dependencies or purge user data.
  sudo pacman -R -- "${packages[@]}"
fi

if [[ -f $SDDM_ENABLED_MARKER ]] && command -v systemctl >/dev/null 2>&1; then
  current_target=$(systemctl get-default 2>/dev/null || true)
  if [[ -f $DEFAULT_TARGET_MARKER && $current_target == graphical.target ]]; then
    original_target=$(<"$DEFAULT_TARGET_MARKER")
    if systemctl is-enabled --quiet sddm.service 2>/dev/null; then
      if ! confirm "This installer enabled SDDM and changed the default target from $original_target to graphical.target. Keep both?" yes; then
        sudo systemctl disable sddm.service || printf 'Warning: could not disable SDDM; disable it manually if desired.\n' >&2
        sudo systemctl set-default "$original_target" || printf 'Warning: could not restore the previous default target (%s).\n' "$original_target" >&2
      else
        printf 'Keeping SDDM and graphical.target enabled.\n'
      fi
    else
      if confirm "SDDM is already disabled. Restore the previous default target ($original_target)?" yes; then
        sudo systemctl set-default "$original_target" || printf 'Warning: could not restore the previous default target (%s).\n' "$original_target" >&2
      else
        printf 'Leaving graphical.target unchanged.\n'
      fi
    fi
  elif systemctl is-enabled --quiet sddm.service 2>/dev/null; then
    if ! confirm 'This installer enabled SDDM. Keep it enabled after removing Omarchy?' yes; then
      sudo systemctl disable sddm.service || printf 'Warning: could not disable SDDM; disable it manually if desired.\n' >&2
    else
      printf 'Keeping SDDM enabled. It may still be useful for another installed desktop.\n'
    fi
  fi
fi

if [[ -f $SESSION_LINK_MARKER ]]; then
  if [[ -L $SESSION_COMPAT_LINK && $(readlink -- "$SESSION_COMPAT_LINK") == "$SESSION_SOURCE" ]]; then
    if session_owner=$(pacman -Qqo "$SESSION_COMPAT_LINK" 2>/dev/null); then
      printf 'Keeping %s because it is now owned by package %s.\n' "$SESSION_COMPAT_LINK" "$session_owner"
    else
      sudo rm -f -- "$SESSION_COMPAT_LINK"
      info 'Removed the generic Wayland session link created by this installer'
    fi
  fi
fi

sudo rm -f -- "$SESSION_LINK_MARKER" "$SDDM_ENABLED_MARKER" "$DEFAULT_TARGET_MARKER"
sudo rmdir "$INSTALL_STATE_DIR" 2>/dev/null || true

if ((${#existing_paths[@]})); then
  if confirm 'Remove the archived Omarchy-specific user paths?' no; then
    for path in "${existing_paths[@]}"; do
      rm -rf -- "$HOME/$path"
    done
  else
    printf 'Kept user data in place; archive is at %s/user-data.tar\n' "$backup"
  fi
fi

if grep -q '^\[omarchy\]' "$PACMAN_CONF"; then
  info 'Removing the [omarchy] repository configuration'
  conf_backup="${PACMAN_CONF}.before-omarchy-uninstall.$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$PACMAN_CONF" "$conf_backup"
  temporary_conf=$(mktemp)
  awk '
    /^\[[^]]+\]/ { in_omarchy = ($0 == "[omarchy]"); if (!in_omarchy) print; next }
    !in_omarchy { print }
  ' "$PACMAN_CONF" >"$temporary_conf"
  sudo install -m 644 -o root -g root "$temporary_conf" "$PACMAN_CONF"
  rm -f "$temporary_conf"
  printf 'Saved pacman.conf backup: %s\n' "$conf_backup"
fi

if sudo pacman-key --list-keys "$OMARCHY_KEY_FINGERPRINT" >/dev/null 2>&1; then
  info 'Removing the locally trusted Omarchy signing key'
  sudo pacman-key --delete "$OMARCHY_KEY_FINGERPRINT" || printf 'Warning: key removal failed; remove it manually if desired.\n' >&2
fi

cat <<DONE

Omarchy packages and repository configuration have been removed.
User-data backup (if any): $backup

Shared dependencies and all bootloader entries/configuration were left alone.
Inspect the boot menu and /etc/default/limine manually before removing any
Omarchy-related entry; this script deliberately does not alter boot settings.
DONE
