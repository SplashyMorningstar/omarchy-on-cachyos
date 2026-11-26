#!/bin/bash
#
# omarchy-cachyos-version-check
#
# Version guard for Omarchy installed on top of CachyOS.
#
# CachyOS packages must remain the default source so their build flags and
# optimizations keep being used. That means [omarchy] cannot simply be moved
# to the top of pacman.conf: every package it shares with CachyOS would be
# replaced by Omarchy's build.
#
# pacman only compares a local package against the FIRST enabled repository
# that contains it. When a package was deliberately installed from Omarchy
# (or built by hand) at a version newer than the CachyOS candidate, pacman
# prints "local (...) is newer than ..." on every upgrade. IgnorePkg does not
# suppress that message (checked against pacman 7.1.0's lib/libalpm/sync.c).
#
# This guard fixes the situation without changing which repository is the
# default:
#
#   1. Packages listed as "follow" are upgraded from [omarchy] when the local
#      version is older than the one published there.
#   2. Installed packages that are newer than the first CachyOS/Arch candidate
#      are published in a tiny local repository placed before CachyOS. pacman
#      then sees an equal version, stays quiet, and never downgrades them.
#   3. Everything else is left to pacman, so CachyOS remains the default.
#
# Configuration: /var/lib/omarchy-on-cachyos/version-check.conf
#   "<package> pin"     never upgrade from [omarchy]; pin when it is newer
#                       than the default candidate, but keep taking CachyOS
#                       upgrades while the versions are equal
#   "<package> follow"  track the version in [omarchy]
#

set -Eeuo pipefail

readonly STATE_DIR="/var/lib/omarchy-on-cachyos"
readonly PINS_DIR="$STATE_DIR/pins"
readonly CONFIG="$STATE_DIR/version-check.conf"
readonly PINS_REPO="omarchy-cachyos-pins"
readonly OMARCHY_REPO="omarchy"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if (( EUID != 0 )); then
  exec sudo "$0" "$@"
fi

for command_name in pacman pacman-conf vercmp repo-add awk find install mktemp bsdtar; do
  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

[[ -d $STATE_DIR ]] || die "State directory $STATE_DIR is missing. Run the CachyOS installer first."
[[ -r $CONFIG ]] || die "Configuration file $CONFIG is missing. Run the CachyOS installer first."

install -d -m 755 -o root -g root "$PINS_DIR" || die "Could not create $PINS_DIR."

mapfile -t cache_dirs < <(pacman-conf CacheDir 2>/dev/null) || cache_dirs=()
(( ${#cache_dirs[@]} )) || cache_dirs=("/var/cache/pacman/pkg")

declare -A policy=()
while read -r package_name mode _; do
  [[ -z ${package_name:-} || $package_name == \#* ]] && continue
  case ${mode:-} in
    pin | follow) policy[$package_name]=$mode ;;
  esac
done <"$CONFIG"

local_version() {
  pacman -Q "$1" 2>/dev/null | awk 'NF { print $2; exit }'
}

repo_version() {
  local repository=$1 package_name=$2 version
  version=$(LC_ALL=C pacman -Si "$repository/$package_name" 2>/dev/null |
    awk -F': ' '$1 ~ /^Version[[:space:]]*$/ { print $2; exit }') || return 1
  [[ -n $version ]] || return 1
  printf '%s\n' "$version"
}

# Version in the first enabled repository other than our pin repository; this
# is the candidate pacman would compare against without the guard.
default_candidate() {
  local package_name=$1 repository version
  while read -r repository; do
    [[ -n $repository && $repository != "$PINS_REPO" ]] || continue
    if version=$(repo_version "$repository" "$package_name"); then
      printf '%s\n' "$version"
      return 0
    fi
  done < <(pacman-conf --repo-list)
  return 1
}

version_is_newer() {
  (( $(vercmp "$1" "$2") > 0 ))
}

# A hand-installed package often has no copy left in pacman's cache. Rebuild a
# small package from the files that are actually installed so it can still be
# pinned. It is only a repository candidate: pacman sees the same version as
# the local one and never installs it.
build_pin_package() {
  local package_name=$1 version=$2 destination=$3
  local staging archive_name file
  local -a files=() bsdtar_args=()

  staging=$(mktemp -d) || return 1
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    files+=("${file#/}")
  done < <(pacman -Qql "$package_name" 2>/dev/null) || {
    rm -rf -- "$staging"
    return 1
  }

  {
    printf 'pkgname = %s\n' "$package_name"
    printf 'pkgver = %s\n' "$version"
    printf 'pkgdesc = locally pinned %s\n' "$package_name"
    printf 'url = https://archlinux.org\n'
    printf 'packager = omarchy-cachyos-version-check\n'
    printf 'arch = %s\n' "$(uname -m)"
  } >"$staging/.PKGINFO"

  archive_name="$package_name-$version-$(uname -m).pkg.tar.zst"
  bsdtar_args=(--zstd --no-recursion -cf "$destination/$archive_name" -C "$staging" .PKGINFO -C /)
  for file in "${files[@]}"; do
    bsdtar_args+=("$file")
  done
  if ! bsdtar "${bsdtar_args[@]}"; then
    rm -rf -- "$staging"
    return 1
  fi
  rm -rf -- "$staging"
  printf '%s\n' "$destination/$archive_name"
}

# Rule 1: if a followed Omarchy package is behind the repository, upgrade it.
for package_name in "${!policy[@]}"; do
  [[ ${policy[$package_name]} == follow ]] || continue
  installed=$(local_version "$package_name") || continue
  available=$(repo_version "$OMARCHY_REPO" "$package_name") || continue
  if version_is_newer "$available" "$installed"; then
    log "Upgrading $package_name $installed -> $available from [$OMARCHY_REPO]"
    pacman -S --noconfirm --needed "$OMARCHY_REPO/$package_name"
  fi
done

# Rule 2: publish locally newer packages so pacman sees an equal version.
declare -A need_pin=()
while read -r package_name; do
  [[ -n $package_name ]] || continue
  installed=$(local_version "$package_name") || continue
  candidate=$(default_candidate "$package_name") || continue
  version_is_newer "$installed" "$candidate" && need_pin[$package_name]=$installed
done < <(comm -12 \
  <(pacman -Qnq | sort -u) \
  <(pacman -Slq "$OMARCHY_REPO" 2>/dev/null | sort -u))

# Rebuild the local repository from scratch so removed pins cannot linger.
staging=$(mktemp -d) || die 'Could not create a temporary directory.'
trap 'rm -rf -- "$staging"' EXIT
pin_count=0
for package_name in "${!need_pin[@]}"; do
  installed=${need_pin[$package_name]}
  package_file=""
  for cache_dir in "${cache_dirs[@]}"; do
    [[ -d $cache_dir ]] || continue
    while IFS= read -r candidate_file; do
      if [[ -n $candidate_file ]]; then
        package_file=$candidate_file
        break 2
      fi
    done < <(find "$cache_dir" -maxdepth 1 -type f \
      -name "$package_name-$installed-*.pkg.tar.zst" -print -quit)
  done

  if [[ -z $package_file ]]; then
    # The installed copy may still be in the pin directory from a prior run.
    while IFS= read -r existing_file; do
      [[ -n $existing_file ]] && package_file=$existing_file && break
    done < <(find "$PINS_DIR" -maxdepth 1 -type f \
      -name "$package_name-$installed-*.pkg.tar.zst" -print -quit)
  fi

  if [[ -n $package_file ]]; then
    install -m 644 -o root -g root "$package_file" "$staging/" ||
      die "Could not stage $package_name-$installed."
  else
    log "Rebuilding a pin package for $package_name-$installed from installed files"
    if ! package_file=$(build_pin_package "$package_name" "$installed" "$staging"); then
      warn "No package file found for $package_name-$installed; it cannot be pinned."
      continue
    fi
  fi
  ((pin_count += 1))
done

find "$PINS_DIR" -mindepth 1 -maxdepth 1 -type f -delete ||
  die "Could not clear $PINS_DIR."

if (( pin_count > 0 )); then
  (
    cd "$staging" || exit 1
    repo-add -n -R "$PINS_REPO.db.tar.gz" ./*.pkg.tar.zst
  ) || die 'Could not build the pin repository database.'
  install -m 644 -o root -g root "$staging"/* "$PINS_DIR/" ||
    die "Could not install the pin repository into $PINS_DIR."
else
  # repo-add silently creates nothing when there are no packages.
  tar -czf "$staging/$PINS_REPO.db.tar.gz" --files-from /dev/null ||
    die 'Could not build an empty pin repository database.'
  ln -sf "$PINS_REPO.db.tar.gz" "$staging/$PINS_REPO.db" ||
    die 'Could not create the empty pin repository database link.'
  install -m 644 -o root -g root "$staging"/* "$PINS_DIR/" ||
    die "Could not install the empty pin repository database."
fi

log "Pin repository ready with $pin_count package(s); CachyOS remains the default repository."
