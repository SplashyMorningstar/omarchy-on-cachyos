# Omarchy on CachyOS (experimental)

This installer is inspired by [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos), but follows Omarchy 4's package-based distribution instead of editing old Omarchy `install.sh` files with `sed`.

It verifies CachyOS, x86_64, Btrfs root, and a Snapper `root` config; adds the signed **stable** Omarchy package repository; then performs a full system upgrade while installing the `omarchy` package. Arch-based distributions require full upgrades rather than partial package upgrades. It does not format disks or remove KDE. It intentionally does not force a display-manager change or delete CachyOS packages. If the installed `cachyos-alacritty-config` package owns Omarchy's `/etc/skel` Alacritty template, pacman is allowed to replace only that template; the script does not remove the CachyOS package or alter the current user's Alacritty config.

## Important limitations

- This is an experimental CachyOS adaptation, not an officially supported Omarchy installation method. A Btrfs root alone does not guarantee boot snapshots or a working rollback; test Snapper and keep a separate backup.
- The official stable repository installs its **current stable** package set, not a historical version selected by this script. This makes it updateable through `omarchy update`, but does not guarantee it starts specifically at 4.0.5. Do not use raw `pacman -Syu` afterward to bypass Omarchy's update guard.

## Run

Review the script, then run it as the regular CachyOS user (not via `sudo`):

```bash
bash install-omarchy-on-cachyos.sh
```

It requires the user to type `INSTALL` before making changes. It backs up `/etc/pacman.conf` and restores it if the package installation command fails.
