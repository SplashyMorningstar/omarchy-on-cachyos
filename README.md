# Omarchy on CachyOS (experimental)

This README explains how to install, configure, troubleshoot, and uninstall Omarchy on CachyOS using this experimental adaptation. It is not an official Omarchy installation method.

The installer configures Omarchy's signed stable package repository, performs a full system upgrade, installs Omarchy's base package set, backs up and applies the shipped defaults to the current user, and runs Omarchy's user-provisioning steps. It adds an Omarchy session to the login manager while leaving CachyOS and its existing desktop installed.

## Desktop environment compatibility

- **CachyOS without a desktop environment:** Usually the simplest starting point because there are fewer overlapping desktop packages and user settings. You still need a working login manager/session setup and must meet the requirements below.
- **CachyOS with KDE Plasma:** It is possible to keep KDE installed and add Omarchy/Hyprland as another session. The installer does not remove Plasma or SDDM. Log out and select **Omarchy (Hyprland uwsm)** in SDDM; selecting a generic CachyOS Hyprland session can load CachyOS's Hyprland configuration instead.
- **Shared user account:** Omarchy's defaults are copied into the account that runs the installer. Matching files are backed up, then replaced with Omarchy defaults; unrelated files are left in place. This can change settings for applications used from KDE too. For stronger separation, use a dedicated CachyOS user for Omarchy rather than sharing one home directory.

KDE coexistence is experimental and does not guarantee every application, theme, or desktop integration behaves identically in both sessions.

## Requirements

- CachyOS on **x86_64**. Other Arch-based distributions are not accepted by the installer.
- Btrfs mounted as the root filesystem (`/`).
- Snapper installed and configured with a configuration named `root`. The installer checks for this, but you should verify that snapshots and rollback actually work.
- A regular user with working `sudo` access. Do not run either script as root or with `sudo`.
- Internet access for the system upgrade, Omarchy repository, packages, and first-time user provisioning.
- Enough free disk space for a full system upgrade and Omarchy's base package set.
- A separate, verified backup of important files. The installer's config backup is not a substitute for a system/data backup.

The installer stops if the OS, architecture, root filesystem, or Snapper check fails. It does not partition or format disks.

## Installation

Run these commands as your regular CachyOS user, **not** with `sudo`:

### 1. Clone the repository

```bash
git clone https://github.com/SplashyMorningstar/omarchy-on-cachyos.git
cd omarchy-on-cachyos
```

### 2. Make the installer and uninstaller executable

```bash
chmod +x install-omarchy-on-cachyos.sh uninstall-omarchy-on-cachyos.sh
```

### 3. Run the installer

```bash
./install-omarchy-on-cachyos.sh
```

Review the notice and type `INSTALL` to confirm. The script upgrades the system and installs Omarchy. Existing configuration files it replaces are backed up under `~/.local/backups/`.

When it finishes, log out and select **Omarchy (Hyprland uwsm)** in SDDM; do not select CachyOS's generic Hyprland session.

The Omarchy session entry is normally installed at `/usr/local/share/wayland-sessions/omarchy.desktop`.

### Repair/apply user configuration

If Omarchy is already installed but user setup did not complete, update the repository and run:

```bash
git pull
./install-omarchy-on-cachyos.sh --apply-user-configs
```

Type `APPLY-OMARCHY-CONFIGS` to confirm. The script installs any missing base packages, backs up matching files, applies Omarchy defaults, and reruns user provisioning.

## Uninstallation

From the repository directory, run as your regular user:

```bash
./uninstall-omarchy-on-cachyos.sh
```

Type `REMOVE-OMARCHY` to confirm. The uninstaller archives Omarchy-specific user data and removes packages named `omarchy` or `omarchy-*`, the pacman repository, and its signing key. It does not remove KDE or shared dependencies, preserves Hyprland configuration that may belong to CachyOS, and **does not modify the bootloader**.

## Important limitations

- This is experimental and unofficial. Btrfs alone does not guarantee that Snapper or boot recovery is configured correctly; keep an external backup.
- The installer uses the **current stable** Omarchy release; it does not pin a historical version such as 4.0.5.
- After installing Omarchy, use `omarchy update` to update it. Do not run `pacman -Syu` directly to bypass Omarchy's update flow.
- The installation does not format or repartition disks, uninstall KDE, or automatically configure the bootloader.
- Omarchy includes Limine/Snapper integration, but this installer does not configure an Omarchy boot entry. A Limine/Snapper notification may report that the `Omarchy` target is missing. Do not edit boot settings or change bootloaders without verifying the machine's active boot setup.

## Troubleshooting

- **Hyprland looks like CachyOS:** Make sure you selected **Omarchy (Hyprland uwsm)** in SDDM, not `Hyprland` or `Hyprland (uwsm)` from CachyOS. For an already-installed system, run the [user-config repair](#repairapply-user-configuration) command above.
- **User provisioning reports `mise: command not found`:** Update this repository and rerun the user-config repair command. The current script installs Omarchy's base package list, including `mise`, before provisioning.
- **Alacritty package conflict:** The installer has a narrow overwrite exception for CachyOS's `/etc/skel` Alacritty template. It does not remove `cachyos-alacritty-config` or overwrite the active user's Alacritty config.
- **Limine/Snapper target notification:** This is separate from the Hyprland session and does not prove the install failed. The script intentionally leaves bootloader configuration untouched; investigate the active boot setup before attempting a repair.
