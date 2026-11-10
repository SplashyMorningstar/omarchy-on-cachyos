# Omarchy on CachyOS (experimental)

An experimental way to try Omarchy on an existing CachyOS installation. This project is inspired by [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos), but adapts its package-based setup for Omarchy 4.5 and newer. It installs Omarchy's official stable packages on top of CachyOS; it is **not** an official Omarchy installer or a replacement for installing from the official ISO.

The installer configures Omarchy's signed stable package repository, checks that the available Omarchy release is at least 4.5.0, performs a full system upgrade, installs the base package list shipped by that Omarchy release, backs up and applies the shipped defaults to the current user, and runs Omarchy's user-provisioning steps. It prepares the Omarchy session for SDDM or registers a standard Wayland session entry for compatible managers, while leaving CachyOS and its existing desktop installed. The version is not pinned: later stable releases are accepted automatically.

## Desktop environment compatibility

- **CachyOS without a desktop environment:** This is a suitable starting point. Omarchy installs SDDM as an upstream package dependency. If no enabled display manager is detected, the installer explicitly asks whether to enable SDDM for the next boot; if necessary, it also changes the default target to `graphical.target`. Neither change is made without confirmation.
- **KDE Plasma, XFCE, or another desktop:** The installer does not remove the existing desktop or switch an enabled display manager. Omarchy/Hyprland is added as another session. Log out and choose the Omarchy Wayland session in your login manager. Coexistence is experimental; applications and shared settings may behave differently between desktops.
- **Shared user account:** Omarchy's defaults are copied into the account that runs the installer. Matching files are backed up, then replaced with Omarchy defaults; unrelated files are left in place. This can change settings for applications used from KDE, XFCE, or other desktops. For stronger separation, use a dedicated CachyOS user for Omarchy rather than sharing one home directory.

### Display manager compatibility

| Login manager | Expected behavior |
| --- | --- |
| **SDDM** | Native Omarchy path. Omarchy configures SDDM to read the shipped session entry from `/usr/local/share/wayland-sessions`. |
| **GDM** | The installer adds a compatibility entry under `/usr/share/wayland-sessions`, which is the standard directory GDM reads. |
| **LightDM** | The installer adds the same standard Wayland session entry. The selected LightDM greeter must list Wayland sessions; support can vary by greeter and setup. |
| **Ly** | The installer adds the standard session entry Ly scans. Ly may need a restart or reboot before the new session appears. |
| **LXDM** | Not reliably compatible: LXDM is primarily an X11 login manager and may not launch Omarchy's Wayland session. Switch to SDDM, GDM, LightDM, or Ly if the session is missing. |
| **greetd or another/custom manager** | The installer does not replace or reconfigure it. It adds a standard session file where possible, but you may need to configure the greeter to expose and launch Wayland sessions. |

SDDM is the login manager Omarchy configures upstream. Support for GDM, LightDM, and Ly here is best-effort session discovery only; the installer does not modify their greeter, PAM, or environment settings.

Omarchy's package depends on SDDM, so installing Omarchy can install SDDM even when another manager is in use. The installer does not enable or select SDDM when it detects another manager. It also does not disable, remove, or rewrite the other manager's configuration.

Desktop coexistence is experimental and does not guarantee every application, theme, or desktop integration behaves identically in both sessions.

## Requirements

- CachyOS on **x86_64**. Other Arch-based distributions are not accepted by the installer.
- Btrfs mounted as the root filesystem (`/`).
- Snapper installed and configured with a configuration named `root`. The installer checks for this, but you should verify that snapshots and rollback actually work.
- A regular user with working `sudo` access. Do not run either script as root or with `sudo`.
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

Review the notice and type `INSTALL` to confirm. The script upgrades the system and installs Omarchy. Existing configuration files it replaces are backed up under `~/.local/backups/`.

When it finishes, log out and select **Omarchy (Hyprland uwsm)** in SDDM, or the Omarchy Wayland session in a compatible manager. Do not select CachyOS's generic Hyprland session; that may load CachyOS's Hyprland configuration instead. If the installer enabled SDDM, reboot to start it.

The Omarchy session entry is installed at `/usr/local/share/wayland-sessions/omarchy.desktop`. For GDM, LightDM, Ly, and other managers using the standard Wayland session directory, the installer creates `/usr/share/wayland-sessions/omarchy-cachyos.desktop` when that path is available. The uninstaller removes this link if it created it.

### Repair/apply user configuration

If Omarchy is already installed but user setup did not complete, update the repository and run:

```bash
git pull
./install-omarchy-on-cachyos.sh --apply-user-configs
```

First update Omarchy itself from its session with `omarchy update`. Then type `APPLY-OMARCHY-CONFIGS` to confirm. The script installs any missing base packages, backs up matching files, applies the defaults shipped by the installed Omarchy package, and reruns user provisioning. If it detects no display manager, it also offers the same explicit SDDM enablement option as the main installer. This repair option does not upgrade Omarchy.

## Uninstallation

From the repository directory, run as your regular user:

```bash
./uninstall-omarchy-on-cachyos.sh
```

Type `REMOVE-OMARCHY` to confirm. The uninstaller archives Omarchy-specific user data and removes packages named `omarchy` or `omarchy-*`, the pacman repository, and its signing key. It does not remove existing desktops or shared dependencies, preserves Hyprland configuration that may belong to CachyOS, removes the compatibility session link if the installer created it, and **does not modify the bootloader**. If the installer enabled SDDM or changed the default target, the uninstaller asks whether to keep those changes.

## Important limitations

- This is experimental and unofficial. Btrfs alone does not guarantee that Snapper or boot recovery is configured correctly; keep an external backup.
- The installer uses the **current stable** Omarchy release and requires 4.5.0 or newer; it has no upper version pin. The package list is read from the installed Omarchy release, so new base apps are not maintained in a separate hardcoded list.
- The official package set and shipped defaults provide Omarchy 4.5 features, including floating workspaces/dock, per-monitor workspaces, updated notifications and appearance controls, language/input-method support, and the new default apps. Hardware-specific support still depends on upstream and this script only targets CachyOS x86_64.
- After installing Omarchy, use `omarchy update` from the Omarchy session to upgrade it. This uses Omarchy's supported update/migration flow and follows future stable versions. Do not rerun this installer or run `pacman -Syu` directly to bypass that flow.
- The installation does not format or repartition disks, uninstall KDE, or automatically configure the bootloader.
- Omarchy includes Limine/Snapper integration, but this installer does not configure an Omarchy boot entry. A Limine/Snapper notification may report that the `Omarchy` target is missing. Do not edit boot settings or change bootloaders without verifying the machine's active boot setup.
