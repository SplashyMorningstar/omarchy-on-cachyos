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

Make a verified backup and a Snapper snapshot first. Review the script before
running it. Later Omarchy upgrades must be done with `omarchy update`.
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
cat <<'DONE'

Omarchy packages are installed. KDE remains installed. Log out and select the
Omarchy/Hyprland session in SDDM to try it. If the session is missing or
first-login provisioning does not complete, return to KDE and do not disable
SDDM or remove KDE; this CachyOS adaptation needs troubleshooting first.

For future Omarchy updates, use `omarchy update` from an Omarchy session.
DONE
