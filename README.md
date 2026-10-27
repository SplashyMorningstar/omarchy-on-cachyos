# Omarchy on CachyOS (experimental)

An experimental installer inspired by [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos), adapted for Omarchy 4's package-based distribution.

The installer checks for CachyOS x86_64, Btrfs on `/`, and a Snapper configuration named `root`. It then configures the official stable repository, installs Omarchy's base packages, applies Omarchy defaults to the current user with backups, and runs user provisioning.

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
