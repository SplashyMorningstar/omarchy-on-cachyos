# Omarchy on CachyOS (experimental)

An experimental installer for Omarchy on an existing CachyOS x86_64 system. It uses Omarchy's official edge packages (`omarchy-dev`) to keep rolling CachyOS and Arch packages synchronized; it is **not** an official Omarchy installer or a replacement for its ISO.

The installer prefers Omarchy packages when repositories overlap; CachyOS supplies packages Omarchy does not publish, including Hyprland. It performs a full system upgrade, installs Omarchy's base packages, backs up and applies user defaults, and provisions the session. If Limine is present, it selects a snapshot hook compatible with the initramfs, targets the existing CachyOS entry when available, rebuilds boot files, and stops on build errors. Relevant system config files are backed up. The installer does not downgrade already-installed packages just because repository priority changes.

## Compatibility

- Keeps existing desktops and enabled display managers. Omarchy is added as another Wayland session; SDDM is only enabled after confirmation if no display manager is active.
- SDDM is Omarchy's native login manager. GDM, LightDM, and Ly are best-effort; other greeters may need manual session setup.
- Defaults replace matching files in the installing user's home after backing them up. Use a dedicated user if you want to isolate Omarchy from KDE or another desktop.

## Requirements

- CachyOS on **x86_64**. Other Arch-based distributions are not accepted by the installer.
- Btrfs mounted as the root filesystem (`/`).
- Snapper installed and configured with a configuration named `root`. The installer checks for this, but you should verify that snapshots and rollback actually work.
- A regular user with working `sudo` access. Do not run either script as root or with `sudo`. The installer asks for sudo authentication once and keeps that authorization alive while it runs; it does not enable passwordless sudo.
- A Wayland-capable display manager, or willingness to explicitly enable SDDM when prompted if none is detected.
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

Review the notice and answer **Yes** at the confirmation prompt (the default is **No**). Then authenticate with sudo once. The script upgrades the system and installs Omarchy. Pacman still shows its transaction summary and other decisions, but the installer automatically accepts only Pacman's prompt to remove a package that conflicts with the requested Omarchy packages. It does not use `--noconfirm` or automatically overwrite arbitrary files. Existing configuration files it replaces are backed up under `~/.local/backups/`.

When installation finishes, log out and select **Omarchy (Hyprland uwsm)** (or the Omarchy Wayland session) in your display manager. If the installer enabled SDDM, reboot to start it.

The installer creates the Omarchy session entry; it does not replace an existing display manager's configuration.

### Repair an existing installation

- Incomplete user setup: run `omarchy update`, then `git pull` and `./install-omarchy-on-cachyos.sh --apply-user-configs`.
- Browser theme not updating: `./install-omarchy-on-cachyos.sh --sync-browser-theme`.
- SDDM rejects the first login: `./install-omarchy-on-cachyos.sh --fix-sddm-first-login` (sets the username only; never enables autologin).

## Uninstallation

Run as your regular user from the repository directory:

```bash
./uninstall-omarchy-on-cachyos.sh
```

The uninstaller asks for confirmation, archives Omarchy-specific user data, and removes Omarchy packages, its repository, and signing key. It preserves existing desktops and shared dependencies and does not modify the bootloader. Reverting SDDM/default-target changes and deleting archived data require separate confirmation.

## Important limitations

- Experimental and unofficial. Keep an external backup; Btrfs/Snapper alone do not guarantee recovery.
- Use `omarchy update` from the Omarchy session. Do not bypass its migration flow by rerunning this installer or using `pacman -Syu` directly.
- If Limine is used, `sudo mkinitcpio -P` alone does not refresh Limine's UKIs. Use `sudo limine-mkinitcpio`, then verify with `limine-list` and `limine-snapper-info`. Do not reboot after a reported build error.
- The installer does not format disks, remove other desktops, install a bootloader, or change firmware boot order. Custom Limine entry names and snapshot recovery remain the user's responsibility.
- The installer uses Omarchy's edge packages (`omarchy-dev`), keeping compositor and plugin versions aligned with CachyOS's rolling package updates. Older preview share-picker versions use XDPH's built-in picker to avoid a known monitor-metadata issue.
