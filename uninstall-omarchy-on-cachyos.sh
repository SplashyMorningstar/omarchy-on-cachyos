#!/bin/bash
set -Eeuo pipefail

readonly OMARCHY_KEY_FINGERPRINT="40DFB630FF42BCFFB047046CF0134EE680CAC571"
readonly PACMAN_CONF="/etc/pacman.conf"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

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
NOTICE

read -r -p 'Type REMOVE-OMARCHY to continue: ' answer
[[ $answer == REMOVE-OMARCHY ]] || die 'Cancelled; no changes made.'

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

if ((${#existing_paths[@]})); then
  read -r -p 'Remove the archived Omarchy-specific user paths? [y/N]: ' remove_user_data
  if [[ ${remove_user_data,,} == y || ${remove_user_data,,} == yes ]]; then
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
