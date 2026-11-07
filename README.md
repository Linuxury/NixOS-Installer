# NixOS-Installer

A guided installer for NixOS. Boot the NixOS live ISO, run one command, answer a few menus, and get a working system.

```sh
sudo nix run github:Linuxury/NixOS-Installer
```

It partitions and formats the disks you pick, installs, and writes the configuration. Nothing is touched until you confirm at the Review step and type the hostname.

## Config source

The first screen asks where the system configuration comes from.

| Source | What you get |
|---|---|
| **Starter template** (default) | A complete flake for your first NixOS host, written to `~/nixos-config` with the first git commit made. You own it; nothing of the author's is in it. |
| **Linuxury's config** | The author's own setup. The wizard clones it, adds this machine's disk layout and commits that. |

Another repo can be used with `INSTALLER_GIT=<url>`.

## Steps (starter template)

Source, Host, Disks, Filesystem, Boot, Encrypt, Swap, User, Region, Desktop, Browser, Review.

- **Disks and filesystem:** btrfs, ext4 or xfs; one disk or a btrfs mirror; optional LUKS; the data disk can be kept or formatted. Mounted disks and the install USB are never offered.
- **Desktop:** None (default), GNOME, KDE Plasma 6 or COSMIC. Each is a short file in `stacks/`, so switching later is one line in `hosts/<name>/default.nix`.
- **Browser:** Firefox, Chromium or none.

The generated flake has `flake.nix`, `hosts/<name>/` (with the disk layout, hardware config and host settings), `stacks/` and a README that explains how to rebuild.

## Options

| Command | What it does |
|---|---|
| `sudo nix run github:Linuxury/NixOS-Installer -- --resume` | Continues after a failed phase, without re-partitioning. |
| `nix run github:Linuxury/NixOS-Installer#install-demo` | Demo: every menu runs, the exact commands are printed, nothing is written. |
| `nix run .#install-demo -- --fake-disks <scenario>` | Demo with pretend disks: `2-equal`, `3-mixed`, `4-hdd`, `windows`. |

The log is `/tmp/nixos-install.log`.

## Tests

```sh
tests/smoke.sh      # whole wizard in test mode, every source and fake-disk scenario
tests/starter.sh    # generates each starter flake and has NixOS evaluate it
```

`smoke.sh` needs `INSTALLER_REPO=<path to a checkout of the config>` to cover the Linuxury source.

## License

MIT, see [LICENSE](LICENSE).
