#!/bin/bash
set -Eeuo pipefail

# CachyOS adaptation inspired by https://github.com/mroboff/omarchy-on-cachyos
# Uses Omarchy's signed stable binary repository (rather than patching its
# internal install scripts), so `omarchy update` remains the supported updater.

readonly OMARCHY_KEY_FINGERPRINT="40DFB630FF42BCFFB047046CF0134EE680CAC571"
readonly OMARCHY_REPO="https://pkgs.omarchy.org/stable/\$arch"
readonly PACMAN_CONF="/etc/pacman.conf"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

sync_existing_user_configs() {
  local confirmed=${1:-no}
  [[ $EUID -ne 0 ]] || die 'Run this as the regular desktop user, not with sudo.'
  pacman -Q omarchy >/dev/null 2>&1 || die 'Omarchy is not installed yet.'
  [[ -f /etc/skel/.config/hypr/hyprland.lua ]] || die 'Omarchy Hyprland defaults were not found in /etc/skel.'

  if [[ $confirmed != yes ]]; then
    cat <<'WARNING'
This copies Omarchy's shipped defaults from /etc/skel into your existing home.
Files with matching paths will be replaced. A backup of every existing file
that would be replaced is made first. Your unrelated files are left in place.
WARNING
    read -r -p 'Type APPLY-OMARCHY-CONFIGS to continue: ' answer
    [[ $answer == APPLY-OMARCHY-CONFIGS ]] || die 'Cancelled; no user files changed.'
  fi

  local package_list
  local -a base_packages
  package_list='/usr/share/omarchy/install/omarchy-base.packages'
  [[ -r $package_list ]] || die "Omarchy base package list not found: $package_list"
  mapfile -t base_packages < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$package_list")
  if pacman -Q tealdeer >/dev/null 2>&1; then
    local -a filtered_packages=()
    local package
    for package in "${base_packages[@]}"; do
      [[ $package == tldr ]] || filtered_packages+=("$package")
    done
    base_packages=("${filtered_packages[@]}")
    info 'Keeping CachyOS tealdeer; omitting the conflicting tldr package'
  fi
  ((${#base_packages[@]})) || die 'Omarchy base package list is empty.'

  info 'Installing Omarchy base packages required for user provisioning'
  sudo pacman -S --needed -- "${base_packages[@]}"

  local backup source relative destination
  backup="$HOME/.local/backups/omarchy-configs-before-sync-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"

  while IFS= read -r -d '' source; do
    relative=${source#/etc/skel/}
    destination="$HOME/$relative"
    if [[ -e $destination || -L $destination ]]; then
      mkdir -p "$backup/$(dirname "$relative")"
      cp -a "$destination" "$backup/$relative"
    fi
  done < <(find /etc/skel -mindepth 1 \( -type f -o -type l \) -print0)

  cp -a /etc/skel/. "$HOME/"
  printf 'Previous matching files backed up to: %s\n' "$backup"

  if command -v omarchy-provision-user >/dev/null 2>&1; then
    omarchy-provision-user
  else
    printf 'Warning: omarchy-provision-user is unavailable; user finalization was skipped.\n' >&2
  fi

  grep -q 'default.hypr.omarchy' "$HOME/.config/hypr/hyprland.lua" || die 'The copied Hyprland config does not appear to load Omarchy defaults.'
  info 'Omarchy user defaults are now in place. Log out and select the Omarchy session in SDDM.'
}

if [[ ${1:-} == '--apply-user-configs' ]]; then
  [[ $# -eq 1 ]] || die 'Usage: install-omarchy-on-cachyos.sh --apply-user-configs'
  sync_existing_user_configs
  exit 0
fi

[[ $EUID -ne 0 ]] || die 'Run as your regular user, not with sudo.'
[[ $(uname -m) == x86_64 ]] || die 'This adaptation currently targets x86_64 CachyOS.'
is_cachyos=false
if [[ -f /etc/cachyos-release ]]; then
  is_cachyos=true
elif [[ -r /etc/os-release ]]; then
  # CachyOS release files vary between installations; use the standard
  # distribution identifiers as well as the CachyOS-specific marker.
  . /etc/os-release
  id_like=${ID_LIKE:-}
  if [[ ${ID:-} == cachyos || " ${id_like,,} " == *" cachyos "* ]]; then
    is_cachyos=true
  fi
fi
if [[ $is_cachyos == false && -r /etc/lsb-release ]] && grep -Eiq '^(DISTRIB_ID|DISTRIB_DESCRIPTION)=.*cachy' /etc/lsb-release; then
  is_cachyos=true
fi
[[ $is_cachyos == true ]] || die 'CachyOS was not detected in /etc/cachyos-release, /etc/os-release, or /etc/lsb-release.'
command -v pacman >/dev/null || die 'pacman is required.'
command -v sudo >/dev/null || die 'sudo is required.'
command -v btrfs >/dev/null || die 'btrfs-progs is required to verify the root filesystem.'

root_fstype=$(findmnt -n -o FSTYPE /)
[[ $root_fstype == btrfs ]] || die "Root filesystem is '$root_fstype', not Btrfs. No changes made."

if ! command -v snapper >/dev/null || ! sudo snapper -c root list-configs 2>/dev/null | grep -q '^root '; then
  die 'Btrfs is present, but a Snapper config named root was not detected. Configure and test Snapper snapshots first; no changes made.'
fi

if [[ -n ${SSH_CONNECTION:-} ]]; then
  die 'Run this from the local desktop session, not over SSH.'
fi

if pacman -Q omarchy >/dev/null 2>&1; then
  die 'Omarchy is already installed. Use `omarchy update` from its session instead.'
fi
if grep -q '^\[omarchy\]' "$PACMAN_CONF"; then
  die "An [omarchy] repository is already configured in $PACMAN_CONF. Inspect it and rerun; no changes made."
fi

cat <<'NOTICE'
This installs Omarchy's official stable packages on this existing CachyOS
installation. It does NOT format or repartition disks and does NOT uninstall
KDE. However, CachyOS + KDE is not an officially supported Omarchy platform.

It also installs Omarchy's base package set, backs up and applies Omarchy's
defaults to this existing user's home, and runs Omarchy user provisioning.
Matching user config files are replaced after being backed up under
~/.local/backups/. Make a verified backup and Snapper snapshot first. Later
Omarchy upgrades must be done with `omarchy update`.
NOTICE

read -r -p 'Type INSTALL to continue: ' answer
[[ $answer == INSTALL ]] || die 'Cancelled; no changes made.'

info 'Saving pacman configuration backup'
backup="${PACMAN_CONF}.before-omarchy.$(date +%Y%m%d-%H%M%S)"
sudo cp -a "$PACMAN_CONF" "$backup"
printf 'Saved: %s\n' "$backup"

info 'Importing and locally trusting the Omarchy repository signing key'
sudo pacman-key --recv-keys "$OMARCHY_KEY_FINGERPRINT" --keyserver keys.openpgp.org
sudo pacman-key --lsign-key "$OMARCHY_KEY_FINGERPRINT"

sudo tee -a "$PACMAN_CONF" >/dev/null <<EOF

[omarchy]
SigLevel = Required DatabaseOptional
Server = $OMARCHY_REPO
EOF

rollback_repo() {
  status=$?
  if (( status != 0 )); then
    printf '\nInstall failed. Restoring pacman.conf from %s\n' "$backup" >&2
    sudo cp -a "$backup" "$PACMAN_CONF"
  fi
}
trap rollback_repo EXIT

info 'Synchronizing the system and installing Omarchy (full Arch upgrade required)'
pacman_args=()
skel_alacritty='/etc/skel/.config/alacritty/alacritty.toml'
alacritty_owner=$(pacman -Qqo "$skel_alacritty" 2>/dev/null || true)
if [[ $alacritty_owner == cachyos-* ]]; then
  cat <<EOF
Detected a known CachyOS package file conflict:
  $skel_alacritty (owned by $alacritty_owner)

Omarchy's settings package also supplies this default for newly created users.
The installer will let Omarchy replace only this one /etc/skel template. This
does not change the current user's Alacritty configuration or remove the
CachyOS package.
EOF
  pacman_args+=(--overwrite "${skel_alacritty#/}")
fi

sudo pacman -Syyu --needed "${pacman_args[@]}" omarchy

trap - EXIT
if [[ -r /usr/local/share/wayland-sessions/omarchy.desktop ]]; then
  printf '\nOmarchy session entry found: /usr/local/share/wayland-sessions/omarchy.desktop\n'
else
  printf '\nWarning: the Omarchy SDDM session entry was not found under /usr/local/share/wayland-sessions.\n' >&2
fi

printf '\nApplying Omarchy defaults and provisioning this existing user.\n'
sync_existing_user_configs yes

cat <<'DONE'

Omarchy packages are installed. KDE remains installed. Log out and select the
Omarchy session (not the generic CachyOS Hyprland session) in SDDM.

For future Omarchy updates, use `omarchy update` from an Omarchy session.
DONE
