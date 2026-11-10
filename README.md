# NixOS-Installer

A guided installer for NixOS. Boot the NixOS live ISO, run one command, answer a few menus, and get a working system.

```sh
sudo nix run github:Linuxury/NixOS-Installer
```

It partitions and formats the disks you pick, installs, and writes the configuration. Nothing is touched until you confirm at the Review step and type the hostname.

## Main menu and saved answers

By default the installer asks its questions in order. Two options change that:

```sh
sudo nix run github:Linuxury/NixOS-Installer -- --hub                 # one main menu, open any entry in any order
sudo nix run github:Linuxury/NixOS-Installer -- --config answers.json # replay a saved answers file
```

- **`--hub`** shows every question as one list with its current value on the right, like archinstall. "Install" stays locked until the required entries are set. "Save configuration" writes `answers.json`.
- **`--config answers.json`** loads a saved file and goes straight to the Review step. You still type the hostname to confirm, so nothing is installed by accident. The disks in the file are matched by serial number.
- **Additional packages** (starter template, `--hub`): search nixpkgs, see the selected list and what each choice pulls in (download size from the binary cache). Unfree packages are flagged and need "Unfree software" switched on.

Add `--demo` (or `--fake-disks 3-mixed`) to try any of this without touching a disk.

## Config source

The first screen asks where the system configuration comes from.

| Source | What you get |
|---|---|
| **Starter template** (default) | A complete flake for your first NixOS host, written to `~/nixos-config` with the first git commit made. You own it; none of my own setup is in it. |
| **Linuxury's config** | My own setup (desktops, services, secrets), made for my machines. The wizard clones it, adds this machine's disk layout and commits that. |

### Using your own config repo

Point the installer at any git repo with `INSTALLER_GIT`, and choose "Linuxury's config" at the first screen (the name is just the option's label):

```sh
sudo INSTALLER_GIT=https://github.com/you/nixos-config nix run github:Linuxury/NixOS-Installer
```

The installer clones the repo, adds `hosts/<host>/disk.nix` and `install.json` for the machine, commits them, and runs `nixos-install --flake .#<host>`. If you forwarded an SSH agent (`ssh -A`) it also pushes back to the repo it cloned. For that to work the repo needs:

- a `flake.nix` where each host is written as `<Name> = mkHost { ... user = "<login>"; ... };`, which is how the installer lists your hosts (a different style of flake will show "no hosts found");
- a folder `hosts/<Name>/` for each host whose main file (`<Name>.nix`, or `default.nix`) imports `./disk.nix` (the installer writes that file and a `hardware-configuration.nix`, so don't commit your own copies).

A minimal example:

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }:
    let
      mkHost = { hostname, user }: nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/${hostname}/default.nix { _module.args.user = user; } ];
      };
    in {
      nixosConfigurations = {
        Desktop = mkHost {
          hostname = "Desktop";
          user     = "you";
        };
      };
    };
}
```

```nix
# hosts/Desktop/default.nix
{ ... }: {
  imports = [ ./disk.nix ./hardware-configuration.nix ];
  networking.hostName = "Desktop";
  # users, desktop, services ...
  system.stateVersion = "26.05";
}
```

## Steps (starter template)

Source, Host, Disks, Filesystem, Boot, Encrypt, Swap, User, Region, Desktop, Kernel, Unfree software, Review. With `--hub` the same questions are one main menu you can open in any order, plus Additional packages (see below).

- **Disks and filesystem:** btrfs, ext4 or xfs; one disk or a btrfs mirror; optional LUKS; the data disk can be kept or formatted. Mounted disks and the install USB are never offered.
- **Desktop:** None (default), GNOME, KDE Plasma 6 or COSMIC. Each is a short file in `stacks/`, so switching later is one line in `hosts/<name>/default.nix`.
- **Kernel:** Default (long-term support), Latest or Zen, each shown with its real Linux version from the nixpkgs channel the new system is locked to (for example Default 6.18, Latest 7.3). One line in the host file, `boot.kernelPackages`. ZFS always uses the default kernel.
- **Unfree software:** off by default (`nixpkgs.config.allowUnfree`). Switched on automatically when an NVIDIA card is found. Needed for Steam, Discord, Spotify and similar.
- **Additional packages** (`--hub`): search nixpkgs, see the selected list and what each choice pulls in (size from the binary cache). Browsers are installed this way, for example `firefox` or `chromium`. Unfree packages are flagged.

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
