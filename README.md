# Omarchy on CachyOS (experimental)

This installer is inspired by [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos), but follows Omarchy 4's package-based distribution instead of editing old Omarchy `install.sh` files with `sed`.

It verifies CachyOS, x86_64, Btrfs root, and a Snapper `root` config; adds the signed **stable** Omarchy package repository; then performs a full system upgrade while installing the `omarchy` package. Arch-based distributions require full upgrades rather than partial package upgrades. It does not format disks or remove KDE. It intentionally does not force a display-manager change or delete CachyOS packages. If the installed `cachyos-alacritty-config` package owns Omarchy's `/etc/skel` Alacritty template, pacman is allowed to replace only that template; the script does not remove the CachyOS package or alter the current user's Alacritty config.

Because `/etc/skel` is only copied automatically when a user is created, the installer installs Omarchy's full base package list, backs up and syncs the defaults into the existing user's home, and runs user provisioning. This includes `mise`, required by Omarchy's user setup. It keeps CachyOS `tealdeer` instead of installing the conflicting `tldr` package. For an already-installed system, rerun with `--apply-user-configs` to do this explicitly. Afterward, choose **Omarchy (Hyprland uwsm)** in SDDM, not a generic CachyOS Hyprland entry.

## Important limitations

- This is an experimental CachyOS adaptation, not an officially supported Omarchy installation method. A Btrfs root alone does not guarantee boot snapshots or a working rollback; test Snapper and keep a separate backup.
- The official stable repository installs its **current stable** package set, not a historical version selected by this script. This makes it updateable through `omarchy update`, but does not guarantee it starts specifically at 4.0.5. Do not use raw `pacman -Syu` afterward to bypass Omarchy's update guard.

## Run

Review the script, then run it as the regular CachyOS user (not via `sudo`):

```bash
bash install-omarchy-on-cachyos.sh
```

It requires the user to type `INSTALL` before system changes. Existing home files replaced during automatic config sync are backed up under `~/.local/backups/`. The standalone `--apply-user-configs` mode requires a separate typed confirmation. The installer backs up `/etc/pacman.conf` and restores it if the package installation command fails.

## Uninstall

Review and run the uninstaller as the regular user (not with `sudo`):

```bash
bash uninstall-omarchy-on-cachyos.sh
```

It removes only installed packages named `omarchy` or `omarchy-*` (without cascading into shared dependencies), removes the Omarchy pacman repository/key, and offers to archive then remove Omarchy-specific user state. It deliberately preserves KDE and shared Hyprland configuration and does not modify bootloader entries; inspect Limine/boot configuration manually before changing it.
