#!/bin/bash
set -Eeuo pipefail

# CachyOS adaptation inspired by https://github.com/mroboff/omarchy-on-cachyos
# Uses Omarchy's signed stable binary repository (rather than patching its
# internal install scripts), so `omarchy update` remains the supported updater.

readonly OMARCHY_KEY_FINGERPRINT="40DFB630FF42BCFFB047046CF0134EE680CAC571"
readonly OMARCHY_REPO="https://pkgs.omarchy.org/stable/\$arch"
readonly MIN_OMARCHY_VERSION="4.5.0"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly OMARCHY_SESSION_LOCAL="/usr/local/share/wayland-sessions/omarchy.desktop"
readonly OMARCHY_SESSION_STANDARD="/usr/share/wayland-sessions/omarchy.desktop"
readonly OMARCHY_SESSION_COMPAT="/usr/share/wayland-sessions/omarchy-cachyos.desktop"
readonly INSTALL_STATE_DIR="/var/lib/omarchy-on-cachyos"
readonly SESSION_LINK_MARKER="$INSTALL_STATE_DIR/created-wayland-session-link"
readonly SDDM_ENABLED_MARKER="$INSTALL_STATE_DIR/enabled-sddm"
readonly DEFAULT_TARGET_MARKER="$INSTALL_STATE_DIR/default-target-before-sddm"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

detect_display_manager() {
  local target units unit
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || {
    printf 'unknown\n'
    return
  }

  target=$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)
  target=${target%.service}
  if [[ -n $target && $target != display-manager ]]; then
    printf '%s\n' "$target"
    return
  fi

  units=$(
    {
      systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null || true
      systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null || true
    } | awk 'NF { print $1 }' | sort -u
  )
  while IFS= read -r unit; do
    case $unit in
      sddm.service) printf 'sddm\n'; return ;;
      gdm.service) printf 'gdm\n'; return ;;
      lightdm.service) printf 'lightdm\n'; return ;;
      lxdm.service) printf 'lxdm\n'; return ;;
      ly.service|ly@*.service) printf 'ly\n'; return ;;
      greetd.service) printf 'greetd\n'; return ;;
      emptty.service|emptty@*.service) printf 'emptty\n'; return ;;
      *greeter*.service|*display-manager*.service) printf 'other\n'; return ;;
    esac
  done <<<"$units"

  printf 'none\n'
}

register_wayland_session() {
  local display_manager=${1:-unknown}
  local session_source

  case $display_manager in
    sddm)
      info 'SDDM is configured by Omarchy to read its packaged session from /usr/local/share/wayland-sessions.'
      return 0
      ;;
    none)
      return 0
      ;;
    lxdm)
      printf 'Warning: LXDM is not a reliable launcher for Wayland sessions; switch to SDDM, GDM, LightDM, or Ly to use Omarchy.\n' >&2
      return 0
      ;;
  esac

  if [[ -r $OMARCHY_SESSION_STANDARD ]]; then
    info "Omarchy Wayland session is already available at $OMARCHY_SESSION_STANDARD"
    return 0
  fi

  if [[ -r $OMARCHY_SESSION_LOCAL ]]; then
    session_source=$OMARCHY_SESSION_LOCAL
  else
    printf 'Warning: Omarchy Wayland session file was not found; could not register it for %s.\n' "$display_manager" >&2
    return 0
  fi

  if [[ -e $OMARCHY_SESSION_COMPAT || -L $OMARCHY_SESSION_COMPAT ]]; then
    if [[ -L $OMARCHY_SESSION_COMPAT && $(readlink -- "$OMARCHY_SESSION_COMPAT") == "$session_source" ]]; then
      info "Omarchy Wayland session link is already present at $OMARCHY_SESSION_COMPAT"
    else
      printf 'Warning: leaving existing session entry untouched: %s\n' "$OMARCHY_SESSION_COMPAT" >&2
    fi
    return 0
  fi

  if ! sudo install -d -m 755 /usr/share/wayland-sessions ||
    ! sudo ln -s -- "$session_source" "$OMARCHY_SESSION_COMPAT"; then
    printf "%s\n" "Warning: could not register Omarchy's standard Wayland session entry." >&2
    return 0
  fi

  if sudo install -d -m 755 "$INSTALL_STATE_DIR" && sudo touch "$SESSION_LINK_MARKER"; then
    info "Registered the Omarchy Wayland session for $display_manager at $OMARCHY_SESSION_COMPAT"
  else
    sudo rm -f -- "$OMARCHY_SESSION_COMPAT"
    printf 'Warning: could not save the session-link cleanup marker; removed the untracked link.\n' >&2
  fi
}

offer_enable_sddm_if_no_manager() {
  local answer default_target
  [[ ${1:-unknown} == none ]] || return 0
  [[ -d /run/systemd/system ]] || {
    printf 'No systemd display manager was detected. Configure a Wayland-capable login manager manually.\n' >&2
    return 0
  }

  cat <<'SDDM_NOTICE'
No enabled display manager was detected. Omarchy's package installs SDDM as a
dependency, but this installer will not enable a login manager without consent.
Type ENABLE-SDDM to enable SDDM for the next boot. If needed, this also changes
the system default target to graphical.target. Press Enter to leave SDDM
disabled and configure your preferred login manager yourself.
SDDM_NOTICE
  read -r -p 'Enable SDDM at boot? ' answer
  if [[ $answer == ENABLE-SDDM ]]; then
    default_target=$(systemctl get-default 2>/dev/null || true)
    [[ -n $default_target ]] || {
      printf 'Warning: could not determine the system default target; SDDM was not enabled.\n' >&2
      return 0
    }
    if ! sudo install -d -m 755 "$INSTALL_STATE_DIR"; then
      printf 'Warning: could not prepare installer state; SDDM was not enabled.\n' >&2
      return 0
    fi
    if [[ $default_target != graphical.target ]] &&
      ! printf '%s\n' "$default_target" | sudo tee "$DEFAULT_TARGET_MARKER" >/dev/null; then
      printf 'Warning: could not save the current default target; SDDM was not enabled.\n' >&2
      return 0
    fi
    if ! sudo systemctl enable sddm.service; then
      sudo rm -f -- "$DEFAULT_TARGET_MARKER"
      printf 'Warning: could not enable SDDM. Enable a Wayland-capable display manager manually.\n' >&2
      return 0
    fi

    if [[ $default_target != graphical.target ]] && ! sudo systemctl set-default graphical.target; then
      sudo systemctl disable sddm.service || true
      sudo rm -f -- "$DEFAULT_TARGET_MARKER"
      printf 'Warning: could not select graphical.target; SDDM was disabled again.\n' >&2
      return 0
    fi

    if ! sudo touch "$SDDM_ENABLED_MARKER"; then
      sudo systemctl disable sddm.service || true
      [[ $default_target == graphical.target ]] || sudo systemctl set-default "$default_target" || true
      sudo rm -f -- "$DEFAULT_TARGET_MARKER"
      printf 'Warning: could not save installer state; SDDM was disabled again.\n' >&2
      return 0
    fi

    printf 'SDDM is enabled. Reboot to reach the Omarchy login session.\n'
  else
    printf 'SDDM remains disabled. To use it later, run: sudo systemctl enable sddm.service\n'
  fi
}

sync_existing_user_configs() {
  local confirmed=${1:-no}
  [[ $EUID -ne 0 ]] || die 'Run this as the regular desktop user, not with sudo.'
  pacman -Q omarchy >/dev/null 2>&1 || die 'Omarchy is not installed yet.'
  pacman -Q omarchy-settings >/dev/null 2>&1 || die 'The Omarchy settings package is not installed.'
  [[ -d /etc/skel ]] || die 'The system user skeleton (/etc/skel) is missing.'
  command -v omarchy-provision-user >/dev/null 2>&1 || die 'Omarchy user provisioning is unavailable.'

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

  # Keep this to the user files only. Upstream omarchy-reinstall-configs also
  # refreshes Limine/Plymouth, which is deliberately outside this installer's scope.
  cp -a /etc/skel/. "$HOME/"
  printf 'Previous matching files backed up to: %s\n' "$backup"

  omarchy-provision-user --force

  register_wayland_session "$(detect_display_manager)"
  info 'Omarchy user defaults are now in place.'
}

if [[ ${1:-} == '--apply-user-configs' ]]; then
  [[ $# -eq 1 ]] || die 'Usage: install-omarchy-on-cachyos.sh --apply-user-configs'
  display_manager=$(detect_display_manager)
  sync_existing_user_configs
  offer_enable_sddm_if_no_manager "$display_manager"
  exit 0
fi

[[ $EUID -ne 0 ]] || die 'Run as your regular user, not with sudo.'
[[ $(uname -m) == x86_64 ]] || die 'This adaptation currently targets x86_64 CachyOS.'

is_cachyos=false
if [[ -r /etc/os-release ]]; then
  # Detect CachyOS through the standard distribution identifiers.
  . /etc/os-release
  id_like=${ID_LIKE:-}
  if [[ ${ID:-} == cachyos || " ${id_like,,} " == *" cachyos "* ]]; then
    is_cachyos=true
  fi
fi
if [[ $is_cachyos == false && -r /etc/lsb-release ]] && grep -Eiq '^(DISTRIB_ID|DISTRIB_DESCRIPTION)=.*cachy' /etc/lsb-release; then
  is_cachyos=true
fi
[[ $is_cachyos == true ]] || die 'CachyOS was not detected in /etc/os-release or /etc/lsb-release.'
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

display_manager=$(detect_display_manager)

if installed_omarchy=$(pacman -Q omarchy 2>/dev/null); then
  installed_omarchy=${installed_omarchy#omarchy }
  die "Omarchy $installed_omarchy is already installed. Log into Omarchy and run 'omarchy update' to upgrade it safely."
fi
if grep -q '^\[omarchy\]' "$PACMAN_CONF"; then
  die "An [omarchy] repository is already configured in $PACMAN_CONF. Inspect it and rerun; no changes made."
fi

cat <<'NOTICE'
This installs Omarchy's official stable packages on this existing CachyOS
installation. It does NOT format or repartition disks and does NOT uninstall
your existing desktop or switch an enabled display manager. Omarchy's upstream
package depends on SDDM, so SDDM will be installed if it is missing.

It also installs Omarchy's base package set, backs up and applies Omarchy's
defaults to this existing user's home, and runs Omarchy user provisioning.
Matching user config files are replaced after being backed up under
~/.local/backups/. Make a verified backup and Snapper snapshot first. Later
Omarchy upgrades must be done with `omarchy update`.
NOTICE

case $display_manager in
  sddm)
    info 'Detected SDDM; Omarchy provides a native SDDM Wayland session.'
    ;;
  gdm|lightdm|ly)
    info "Detected $display_manager; the installer will register Omarchy in the standard Wayland session directory."
    ;;
  lxdm)
    printf 'Warning: LXDM does not reliably launch Wayland sessions. The Omarchy session may not be selectable; use a Wayland-capable display manager.\n' >&2
    ;;
  none)
    info 'No enabled display manager detected; after installation you can explicitly enable SDDM or leave it disabled.'
    ;;
  unknown)
    info 'Could not identify the current display manager; it will not be switched automatically.'
    ;;
  *)
    info "Detected display manager '$display_manager'; it will not be switched automatically. A standard Wayland session entry will be added where possible."
    ;;
esac

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
info 'Refreshing package databases and checking the official stable Omarchy release'
sudo pacman -Syy
package_metadata=$(LC_ALL=C pacman -Si omarchy) || die 'Could not find the Omarchy package in the configured repositories.'
package_repo=$(awk -F: '$1 ~ /^Repository[[:space:]]*$/ { sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }' <<<"$package_metadata")
repo_version=$(awk -F: '$1 ~ /^Version[[:space:]]*$/ { sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }' <<<"$package_metadata")
[[ $package_repo == omarchy ]] || die "Expected the official [omarchy] repository, found '${package_repo:-none}'."
[[ -n $repo_version ]] || die 'Could not determine the Omarchy stable package version.'
if (( $(vercmp "$repo_version" "$MIN_OMARCHY_VERSION") < 0 )); then
  die "The official stable repository offers Omarchy $repo_version; this installer requires $MIN_OMARCHY_VERSION or newer. No system upgrade was started."
fi
info "Official stable Omarchy version selected: $repo_version (minimum: $MIN_OMARCHY_VERSION; newer stable versions are accepted)"

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

sudo pacman -Syu --needed "${pacman_args[@]}" omarchy

trap - EXIT
installed_omarchy=$(pacman -Q omarchy | awk '{print $2}')
[[ -n $installed_omarchy ]] || die 'Omarchy was not found after the package transaction.'
if (( $(vercmp "$installed_omarchy" "$MIN_OMARCHY_VERSION") < 0 )); then
  die "Omarchy $installed_omarchy was installed, below the required $MIN_OMARCHY_VERSION. Keep the [omarchy] repository configured and resolve the package issue before continuing."
fi
info "Installed Omarchy package version: $installed_omarchy"

if [[ -r $OMARCHY_SESSION_LOCAL || -r $OMARCHY_SESSION_STANDARD ]]; then
  printf '\nOmarchy Wayland session entry is installed.\n'
else
  printf '\nWarning: the Omarchy Wayland session entry was not found.\n' >&2
fi

printf '\nApplying Omarchy defaults and provisioning this existing user.\n'
sync_existing_user_configs yes
offer_enable_sddm_if_no_manager "$display_manager"

final_display_manager=$(detect_display_manager)

cat <<'DONE'

Omarchy packages and user defaults are installed. Existing desktops and
enabled display managers were left in place. Log out and choose the Omarchy
Wayland session in a compatible display manager.

For future Omarchy updates, use `omarchy update` from an Omarchy session.
DONE

case $final_display_manager in
  none)
    printf '\nNo display manager is enabled. Enable SDDM or configure another Wayland-capable manager before rebooting.\n'
    ;;
  lxdm)
    printf '\nLXDM may not be able to launch the Omarchy Wayland session. Switch to SDDM, GDM, LightDM, or Ly if it is not listed.\n'
    ;;
  sddm)
    printf '\nUse the Omarchy (Hyprland uwsm) entry in SDDM.\n'
    ;;
  gdm|lightdm|ly)
    printf '\nUse the Omarchy session in %s. LightDM also needs a greeter that lists Wayland sessions.\n' "$final_display_manager"
    ;;
  *)
    printf '\nUse the Omarchy session if your display manager supports standard Wayland session files; custom managers may need manual configuration.\n'
    ;;
esac
