#!/bin/bash
set -Eeuo pipefail

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
SUDO_KEEPALIVE_PID=""
PACMAN_CONF_BACKUP=""
PACMAN_CONF_CHANGED=false
LIMINE_UPDATE_REQUIRED=false
LIMINE_SNAPSHOT_SYNC_TARGETED=false

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

stop_sudo_keepalive() {
  if [[ -n $SUDO_KEEPALIVE_PID ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}

on_exit() {
  local status=$?
  stop_sudo_keepalive

  if ((status != 0)) && [[ $PACMAN_CONF_CHANGED == true && -n $PACMAN_CONF_BACKUP && -f $PACMAN_CONF_BACKUP ]]; then
    printf '\nInstall failed. Restoring pacman.conf from %s\n' "$PACMAN_CONF_BACKUP" >&2
    sudo cp -a "$PACMAN_CONF_BACKUP" "$PACMAN_CONF" ||
      printf 'Warning: could not restore pacman.conf; restore it manually from %s.\n' "$PACMAN_CONF_BACKUP" >&2
  fi

  return "$status"
}
trap on_exit EXIT

start_sudo_keepalive() {
  if [[ -n $SUDO_KEEPALIVE_PID ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    return 0
  fi

  info 'Authenticating with sudo; the installer will reuse this authorization'
  sudo -v || die 'Could not authenticate with sudo.'

  # Keep the sudo timestamp alive while pacman and provisioning run. Never add a
  # passwordless sudo rule or store the password in the installer.
  (
    sleep_pid=""
    cleanup_keepalive() {
      [[ -n $sleep_pid ]] && kill "$sleep_pid" 2>/dev/null || true
    }
    trap cleanup_keepalive EXIT

    while :; do
      sleep 45 &
      sleep_pid=$!
      wait "$sleep_pid" || exit 0
      sleep_pid=""
      sudo -n -v || exit 0
    done
  ) <&0 >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
}

ensure_chromium_theme_policy() {
  local policy_dir=/etc/chromium/policies/managed
  local policy_setup=/usr/share/omarchy/install/config/browser-policy.sh

  command -v chromium >/dev/null 2>&1 || return 0
  [[ -d $policy_dir && ! -L $policy_dir ]] && return 0

  if [[ -e $policy_dir || -L $policy_dir ]]; then
    printf 'Warning: Chromium policy path exists but is not a normal directory: %s\n' "$policy_dir" >&2
    return 1
  fi

  [[ -r $policy_setup ]] || {
    printf 'Warning: Omarchy Chromium policy setup was not found: %s\n' "$policy_setup" >&2
    return 1
  }

  info 'Creating Omarchy managed Chromium policy directory'
  sudo env OMARCHY_PATH=/usr/share/omarchy bash "$policy_setup"
}

configure_limine_update_compatibility() {
  local hook_config=/etc/mkinitcpio.conf.d/10-limine-snapper-sync.conf
  local limine_config=/etc/default/limine
  local boot_config=/boot/limine.conf
  local backup temporary_conf current_target

  if command -v limine-mkinitcpio >/dev/null 2>&1 &&
    sudo test -r "$hook_config" &&
    sudo grep -Fxq 'HOOKS+=(sd-btrfs-overlayfs)' "$hook_config"; then
    backup="${hook_config}.before-omarchy.$(date +%Y%m%d-%H%M%S)"
    sudo cp -a "$hook_config" "$backup" || die "Could not back up $hook_config."
    temporary_conf=$(mktemp)
    if ! awk '
      $0 == "HOOKS+=(sd-btrfs-overlayfs)" {
        print "# Select the Limine snapshot overlay hook that matches Omarchy initramfs."
        print "if [[ \" ${HOOKS[*]:-} \" == *\" systemd \"* ]]; then"
        print "  [[ \" ${HOOKS[*]:-} \" == *\" sd-btrfs-overlayfs \"* ]] || HOOKS+=(sd-btrfs-overlayfs)"
        print "elif [[ \" ${HOOKS[*]:-} \" != *\" btrfs-overlayfs \"* ]]; then"
        print "  HOOKS+=(btrfs-overlayfs)"
        print "fi"
        replaced = 1
        next
      }
      { print }
      END { if (!replaced) exit 1 }
    ' "$hook_config" >"$temporary_conf"; then
      rm -f -- "$temporary_conf"
      die "Could not adapt the Limine snapshot hook in $hook_config."
    fi
    sudo install -m 644 -o root -g root "$temporary_conf" "$hook_config" || die "Could not update $hook_config."
    rm -f -- "$temporary_conf"
    printf 'Saved incompatible Limine hook configuration: %s\n' "$backup"
    LIMINE_UPDATE_REQUIRED=true
  fi

  if ! command -v limine-entry-tool >/dev/null 2>&1 ||
    ! sudo test -r "$boot_config" ||
    ! sudo grep -Eq '^/[+]?CachyOS([[:space:]]|$)' "$boot_config"; then
    return 0
  fi

  if sudo test -r "$limine_config"; then
    current_target=$(sudo awk -F= '
      /^[[:space:]]*TARGET_OS_NAME[[:space:]]*=/ {
        value = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^"|"$/, "", value)
        target = value
      }
      END { print target }
    ' "$limine_config") || die "Could not read $limine_config."
  else
    current_target=""
  fi

  if [[ $current_target == CachyOS ]]; then
    LIMINE_SNAPSHOT_SYNC_TARGETED=true
    return 0
  fi
  if [[ -n $current_target && $current_target != Omarchy ]]; then
    printf 'Warning: keeping the custom Limine target %q; it does not match the detected CachyOS boot entry.\n' "$current_target" >&2
    return 0
  fi

  if sudo test -e "$limine_config"; then
    backup="${limine_config}.before-omarchy.$(date +%Y%m%d-%H%M%S)"
    sudo cp -a "$limine_config" "$backup" || die "Could not back up $limine_config."
    printf 'Saved Limine settings: %s\n' "$backup"
  fi
  temporary_conf=$(mktemp)
  if sudo test -r "$limine_config"; then
    awk '
      /^[[:space:]]*TARGET_OS_NAME[[:space:]]*=/ {
        if (!replaced) print "TARGET_OS_NAME=\"CachyOS\""
        replaced = 1
        next
      }
      { print }
      END { if (!replaced) print "TARGET_OS_NAME=\"CachyOS\"" }
    ' "$limine_config" >"$temporary_conf" || die "Could not prepare $limine_config."
  else
    printf 'TARGET_OS_NAME="CachyOS"\n' >"$temporary_conf"
  fi
  sudo install -m 644 -o root -g root "$temporary_conf" "$limine_config" || die "Could not update $limine_config."
  rm -f -- "$temporary_conf"
  LIMINE_UPDATE_REQUIRED=true
  LIMINE_SNAPSHOT_SYNC_TARGETED=true
  info 'Pointed Limine snapshot synchronization at the existing CachyOS boot entry'
}

rebuild_limine_boot_files() {
  local build_log sync_log
  if [[ $LIMINE_UPDATE_REQUIRED == true ]]; then
    if ! command -v limine-mkinitcpio >/dev/null 2>&1; then
      printf 'Limine configuration changed, but limine-mkinitcpio is unavailable. Do not reboot until boot files are rebuilt.\n' >&2
      return 1
    fi

    info 'Rebuilding Limine boot files with the compatible initramfs hooks'
    build_log=$(mktemp)
    if ! sudo limine-mkinitcpio 2>&1 | tee "$build_log"; then
      printf 'Limine kernel image rebuild failed. Do not reboot until it is resolved. Log: %s\n' "$build_log" >&2
      return 1
    fi
    if grep -q 'mkinitcpio failed for kernel' "$build_log"; then
      printf 'At least one Limine kernel image failed to rebuild. Do not reboot until it is resolved. Log: %s\n' "$build_log" >&2
      return 1
    fi
    rm -f -- "$build_log"
  fi

  if [[ $LIMINE_SNAPSHOT_SYNC_TARGETED == true ]] && command -v limine-snapper-sync >/dev/null 2>&1; then
    info 'Synchronizing Snapper recovery entries with the CachyOS Limine entry'
    sync_log=$(mktemp)
    if ! sudo limine-snapper-sync 2>&1 | tee "$sync_log"; then
      printf 'Limine snapshot synchronization failed. Review the boot entries before rebooting. Log: %s\n' "$sync_log" >&2
      return 1
    fi
    if grep -q "Target OS name .* not found" "$sync_log"; then
      printf 'Limine could not find its CachyOS target entry. Review the boot configuration before rebooting. Log: %s\n' "$sync_log" >&2
      return 1
    fi
    rm -f -- "$sync_log"
  fi
}

seed_sddm_last_user() {
  local username=${1:-}
  [[ -n $username ]] || return 1

  sudo python3 - "$username" <<'PY'
import os
import pwd
import re
import stat
import sys
import tempfile

state_file = "/var/lib/sddm/state.conf"
username = sys.argv[1]

try:
    account = pwd.getpwnam(username)
    if account.pw_uid < 1000:
        raise ValueError("refusing to preselect a system account")
    sddm = pwd.getpwnam("sddm")

    parent = os.path.dirname(state_file)
    if not stat.S_ISDIR(os.lstat(parent).st_mode):
        raise ValueError(f"SDDM state directory is not a real directory: {parent}")

    try:
        file_info = os.lstat(state_file)
    except FileNotFoundError:
        lines = []
    else:
        if not stat.S_ISREG(file_info.st_mode):
            raise ValueError(f"SDDM state file is not a regular file: {state_file}")
        with open(state_file, "r", encoding="utf-8", newline="") as state:
            lines = state.readlines()

    section = None
    last_header = None
    last_end = None
    user_index = None
    existing_user = ""
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if section == "Last" and last_end is None:
                last_end = index
            section = stripped[1:-1]
            if section == "Last":
                last_header = index
                last_end = len(lines)
        elif section == "Last" and re.match(r"^\s*User\s*=", line):
            user_index = index
            existing_user = line.split("=", 1)[1].strip()

    if existing_user:
        print(f"SDDM already remembers user '{existing_user}'; leaving its state unchanged.")
        sys.exit(0)

    if user_index is not None:
        old_line = lines[user_index]
        ending = "\r\n" if old_line.endswith("\r\n") else "\n" if old_line.endswith("\n") else ""
        lines[user_index] = f"User={username}{ending}"
    elif last_header is not None:
        insert_at = last_end if last_end is not None else len(lines)
        if insert_at and not lines[insert_at - 1].endswith(("\n", "\r")):
            lines[insert_at - 1] += "\n"
        lines.insert(insert_at, f"User={username}\n")
    else:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(("[Last]\n", f"User={username}\n"))

    fd, staged = tempfile.mkstemp(prefix=".state.conf.", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as output:
            output.writelines(lines)
            output.flush()
            os.fsync(output.fileno())
        os.chown(staged, sddm.pw_uid, sddm.pw_gid)
        os.chmod(staged, 0o600)
        os.replace(staged, state_file)
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)

    print(f"Seeded SDDM's first-login user as '{username}'. A password is still required.")
except Exception as error:
    print(f"Could not initialize SDDM's first-login user: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

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
  local default_target
  [[ ${1:-unknown} == none ]] || return 0
  [[ -d /run/systemd/system ]] || {
    printf 'No systemd display manager was detected. Configure a Wayland-capable login manager manually.\n' >&2
    return 0
  }

  cat <<'SDDM_NOTICE'
No enabled display manager was detected. Omarchy's package installs SDDM as a
dependency, but this installer will not enable a login manager without consent.
Enabling SDDM may also change the system default target to graphical.target.
Answer No or press Enter to leave SDDM disabled and configure your preferred
login manager yourself.
SDDM_NOTICE
  if confirm 'Enable SDDM for the next boot?' no; then
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
    confirm "Apply Omarchy's defaults to this home directory?" no || die 'Cancelled; no user files changed.'
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
  start_sudo_keepalive
  # Pacman's ask value 4 accepts only removal of a conflicting package; leave
  # the transaction confirmation and all unrelated prompts interactive.
  sudo pacman -S --needed --ask=4 -- "${base_packages[@]}"

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
  configure_legacy_screencast_picker

  if ! ensure_chromium_theme_policy; then
    printf 'Warning: Chromium theme policy could not be initialized.\n' >&2
  fi

  if command -v omarchy-theme-set-browser >/dev/null 2>&1; then
    info 'Applying the current Omarchy theme to installed Chromium-based browsers'
    if ! omarchy-theme-set-browser; then
      printf 'Warning: Chromium theme synchronization did not complete. Try `omarchy-theme-set-browser` from the Omarchy session.\n' >&2
    fi
  else
    printf 'Warning: omarchy-theme-set-browser is unavailable; browser colors may not follow Omarchy themes.\n' >&2
  fi

  if ! seed_sddm_last_user "$(id -un)"; then
    printf 'Warning: SDDM may need a last-user value before its password-only Omarchy greeter can log in.\n' >&2
  fi

  register_wayland_session "$(detect_display_manager)"
  info 'Omarchy user defaults are now in place.'
}

configure_legacy_screencast_picker() {
  local picker_info picker_version config_file
  config_file="$HOME/.config/hypr/xdph.conf"

  [[ -f $config_file && ! -L $config_file ]] || return 0
  picker_info=$(pacman -Q hyprland-preview-share-picker 2>/dev/null) || return 0
  picker_version=${picker_info##* }

  # Preview picker versions before 0.3.0 depend on Hyprland's monitor JSON
  # schema and can fail to build both the window and output pages on newer
  # Hyprland releases. Use XDPH's built-in picker until the fixed release is
  # installed; region sharing continues to work either way.
  (( $(vercmp "$picker_version" '0.3.0') < 0 )) || return 0
  grep -Eq '^[[:space:]]*custom_picker_binary[[:space:]]*=[[:space:]]*hyprland-preview-share-picker([[:space:]]*(#.*)?)?$' "$config_file" || return 0

  sed -i -E 's/^([[:space:]]*custom_picker_binary[[:space:]]*=[[:space:]]*)hyprland-preview-share-picker([[:space:]]*(#.*)?)$/\1hyprland-share-picker\2/' "$config_file"
  info "Using XDPH's built-in share picker; installed preview picker $picker_version is incompatible with current Hyprland monitor metadata"
}

if [[ ${1:-} == '--apply-user-configs' ]]; then
  [[ $# -eq 1 ]] || die 'Usage: install-omarchy-on-cachyos.sh --apply-user-configs'
  display_manager=$(detect_display_manager)
  sync_existing_user_configs
  offer_enable_sddm_if_no_manager "$display_manager"
  exit 0
fi

if [[ ${1:-} == '--sync-browser-theme' ]]; then
  [[ $# -eq 1 ]] || die 'Usage: install-omarchy-on-cachyos.sh --sync-browser-theme'
  [[ $EUID -ne 0 ]] || die 'Run this as the regular user, not with sudo.'
  command -v sudo >/dev/null || die 'sudo is required.'
  command -v pacman >/dev/null || die 'pacman is required.'
  pacman -Q omarchy >/dev/null 2>&1 || die 'Omarchy is not installed.'
  command -v omarchy-theme-set-browser >/dev/null || die 'Omarchy browser theme integration is unavailable.'

  start_sudo_keepalive
  ensure_chromium_theme_policy || die 'Could not initialize the Chromium theme policy; inspect the warning above.'
  omarchy-theme-set-browser || die 'Could not synchronize the current Omarchy theme to browsers.'
  info 'Current Omarchy theme synchronized to installed Chromium-based browsers.'
  exit 0
fi

if [[ ${1:-} == '--fix-sddm-first-login' ]]; then
  [[ $# -eq 1 ]] || die 'Usage: install-omarchy-on-cachyos.sh --fix-sddm-first-login'
  [[ $EUID -ne 0 ]] || die 'Run this as the regular user, not with sudo.'
  command -v sudo >/dev/null || die 'sudo is required.'
  command -v pacman >/dev/null || die 'pacman is required.'
  pacman -Q omarchy >/dev/null 2>&1 || die 'Omarchy is not installed.'
  command -v sddm >/dev/null || die 'SDDM is not installed.'

  start_sudo_keepalive
  seed_sddm_last_user "$(id -un)" || die 'Could not initialize SDDM; inspect the error above.'
  info 'SDDM will use this account on its next start; the password prompt remains enabled.'
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
command -v snapper >/dev/null || die 'snapper is required to verify the root snapshot configuration.'

root_fstype=$(findmnt -n -o FSTYPE /)
[[ $root_fstype == btrfs ]] || die "Root filesystem is '$root_fstype', not Btrfs. No changes made."

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

confirm 'Continue with the installation?' no || die 'Cancelled; no changes made.'

start_sudo_keepalive

if ! sudo snapper -c root list-configs 2>/dev/null | grep -q '^root '; then
  die 'Btrfs is present, but a Snapper config named root was not detected. Configure and test Snapper snapshots first; no system changes were made.'
fi

info 'Saving pacman configuration backup'
backup="${PACMAN_CONF}.before-omarchy.$(date +%Y%m%d-%H%M%S)"
sudo cp -a "$PACMAN_CONF" "$backup"
PACMAN_CONF_BACKUP=$backup
printf 'Saved: %s\n' "$backup"

info 'Importing and locally trusting the Omarchy repository signing key'
sudo pacman-key --recv-keys "$OMARCHY_KEY_FINGERPRINT" --keyserver keys.openpgp.org
sudo pacman-key --lsign-key "$OMARCHY_KEY_FINGERPRINT"

# Put Omarchy first so packages it customizes (notably Quickshell) do not get
# silently replaced by a same-named CachyOS package. CachyOS remains the source
# for packages Omarchy does not publish, including Hyprland.
info 'Adding the Omarchy repository before the existing CachyOS repositories'
PACMAN_CONF_CHANGED=true
temporary_conf=$(mktemp)
awk -v server="$OMARCHY_REPO" '
  function print_omarchy_repo() {
    print "[omarchy]"
    print "SigLevel = Required DatabaseOptional"
    print "Server = " server
    print ""
  }
  /^\[[^]]+\]/ && $0 != "[options]" && !inserted {
    print_omarchy_repo()
    inserted = 1
  }
  { print }
  END {
    if (!inserted) print_omarchy_repo()
  }
' "$PACMAN_CONF" >"$temporary_conf" || die 'Could not prepare pacman configuration.'
sudo install -m 644 -o root -g root "$temporary_conf" "$PACMAN_CONF"
rm -f -- "$temporary_conf"

repo_order=$(pacman-conf --repo-list) || die 'Could not read the configured pacman repository order.'
first_repo=$(awk 'NF { print; exit }' <<<"$repo_order")
[[ $first_repo == omarchy ]] || die 'Omarchy is not the first enabled pacman repository; restoring the previous pacman configuration.'

configure_limine_update_compatibility

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

sudo pacman -Syu --needed --ask=4 "${pacman_args[@]}" omarchy

PACMAN_CONF_CHANGED=false
installed_omarchy=$(pacman -Q omarchy | awk '{print $2}')
[[ -n $installed_omarchy ]] || die 'Omarchy was not found after the package transaction.'
if (( $(vercmp "$installed_omarchy" "$MIN_OMARCHY_VERSION") < 0 )); then
  die "Omarchy $installed_omarchy was installed, below the required $MIN_OMARCHY_VERSION. Keep the [omarchy] repository configured and resolve the package issue before continuing."
fi
info "Installed Omarchy package version: $installed_omarchy"

if ! rebuild_limine_boot_files; then
  die 'Limine boot-file preparation did not complete. Do not reboot until the reported issue is fixed.'
fi

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
