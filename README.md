# Omarchy on CachyOS

An unofficial, community-maintained installer that adds Omarchy 4 to an **existing CachyOS x86_64 system** — no formatting, no repartitioning, no bootloader replacement. It uses Omarchy's official edge packages (`omarchy-dev`) so rolling CachyOS and Arch packages stay synchronized. It is not an official Omarchy installer or a replacement for the ISO.

## What it does

- Installs on an already working CachyOS system: it does not format disks, partition, or install a bootloader.
- Keeps **CachyOS as the default package source**, so its optimized builds keep being used; `[omarchy]` is added last for the packages it owns.
- Runs a full system upgrade, installs Omarchy's base packages, and provisions the Wayland session. Existing desktops and display managers are preserved; SDDM is only enabled after confirmation if none is active. GDM, LightDM, and Ly are best-effort.
- Backs up files it replaces under `~/.local/backups/`. Use a dedicated user if you want to isolate Omarchy from KDE or another desktop.
- Installs a small version guard that keeps the two repositories aligned and protects deliberate package choices. It runs on the **edge** channel (`omarchy-dev`) and refreshes the guard automatically on every run.

## Requirements

- CachyOS on **x86_64**; other Arch-based distributions are rejected.
- Btrfs root (`/`) and Snapper with a configuration named `root`. Verify that snapshots and rollback actually work.
- A regular user with working `sudo`. Do not run the installer as root: it asks for authentication once and keeps that authorization alive.
- A Wayland-capable display manager, or willingness to enable SDDM when prompted.
- Internet access and enough free space for a full upgrade and Omarchy's base packages.
- A separate, verified backup of important files. The installer's config backup is not a substitute for a system/data backup.

The installer validates the OS, architecture, root filesystem, and Snapper before making changes.

## Quick start

Run these commands as your regular CachyOS user, **not** with `sudo`:

```bash
git clone https://github.com/SplashyMorningstar/omarchy-on-cachyos.git
cd omarchy-on-cachyos
chmod +x install-omarchy-on-cachyos.sh uninstall-omarchy-on-cachyos.sh
./install-omarchy-on-cachyos.sh
```

Review the notice and answer **Yes** at the confirmation prompt (the default is **No**), then authenticate with sudo once. Pacman still shows its transaction summary and other decisions; the installer only auto-accepts Pacman's prompt to remove a package that conflicts with the requested Omarchy packages. It does not use `--noconfirm` or overwrite arbitrary files.

When it finishes, log out and select **Omarchy (Hyprland uwsm)** (or the Omarchy Wayland session) in your display manager. If SDDM was enabled, reboot to start it.

For updates, use `omarchy update` from the Omarchy session.

## Repositories and versions

CachyOS stays first as the default source. A small local `omarchy-cachyos-pins` repository is placed before it for packages kept at a deliberately different version, and `[omarchy]` is added last for the packages it owns. The guard installed by the installer runs after every `omarchy update` and is refreshed automatically on each installer run.

The policy file is `/var/lib/omarchy-on-cachyos/version-check.conf`.

## Uninstall

Run as your regular user from the repository directory:

```bash
./uninstall-omarchy-on-cachyos.sh
```

It asks for confirmation, archives Omarchy-specific user data, and removes Omarchy packages, its repository, signing key, and guard. Other desktops and shared dependencies are preserved, and bootloader settings are not changed. Reverting SDDM/default-target changes or deleting archived data requires separate confirmation.

## Things it does not do

- Format disks, install a bootloader, or change firmware boot order. Custom Limine entry names and snapshot recovery remain the user's responsibility.
- Replace existing desktops or display-manager configuration.
- Replace `omarchy update` as the supported updater.
- Refresh Limine UKIs via `sudo mkinitcpio -P`; use `sudo limine-mkinitcpio`, then verify with `limine-list` and `limine-snapper-info` before rebooting.
