# NixOS-Installer

A full-screen terminal installer for NixOS. It is a bash script that draws its menus with gum. You boot the NixOS live ISO, run one command, answer the menus, and it partitions, formats and installs. Disks use btrfs, ext4 or xfs, with optional LUKS2 encryption.

```sh
sudo nix run github:Linuxury/NixOS-Installer
```

## Contents

1. [What it is](#1-what-it-is)
2. [Requirements and how to run](#2-requirements-and-how-to-run)
3. [The two config sources](#3-the-two-config-sources)
4. [The wizard, step by step](#4-the-wizard-step-by-step)
5. [What gets written](#5-what-gets-written)
6. [Installing from another machine](#6-installing-from-another-machine)
7. [Resume and reinstall](#7-resume-and-reinstall)
8. [After the install](#8-after-the-install)
9. [Testing and development](#9-testing-and-development)
10. [Troubleshooting](#10-troubleshooting)

## 1. What it is

The wizard asks for the disks, filesystem, boot loader, encryption, swap and the host. Then it writes `disk.nix` for the host and runs the install. It can start from a fresh starter flake or from an existing config repo (see section 3).

Keys: `enter` selects, `esc` goes back one step, `ctrl+c` quits. In menus, up and down (or `k` and `j`) move, and PgUp and PgDn scroll.

**It does**

- Reads the hardware (firmware, CPU, GPU, RAM, laptop or desktop, WiFi) and the disks with their SMART health.
- Partitions, formats, mounts and runs `nixos-install --flake`.
- Writes the host's `disk.nix` and a saved answers file.
- Asks for the new user's password at the end of the install. The password is not stored in the config.

**It does not**

- Install anything other than what real mode supports. Some choices work only in the demo (see below).
- Store passwords.
- Touch anything in `--demo`. The demo writes nothing.

**Real mode supports**: btrfs, ext4 and xfs; LUKS; systemd-boot, GRUB and Limine; a single disk or a btrfs mirror; a data disk kept or formatted; existing hosts. These choices work only in `--demo`; real mode shows them as "coming soon": zfs (system or data pool, including `zfs-*` layouts), bcachefs, rEFInd and "+ New host" in Linuxury mode.

**Safety**

- Real mode runs as root and only on the live ISO. It checks for `/iso` and refuses otherwise (`INSTALL_ALLOW_NON_ISO=1` skips the check, for VM testing only).
- It never wipes a mounted disk. Before the install it refuses if any system disk, `/home` disk or to-be-formatted data disk has something mounted.
- The disk the ISO booted from, USB disks and removable disks are hidden from the disk steps. "Show removable disks too" brings them back.
- Failing disks (SMART) ask "Use X anyway?". Disks with another OS are left alone by default. To wipe one you must type its model exactly.
- Nothing is written by the install until the Review step: you pick "Install" and type the hostname.
- One exception: the Disks tools "Format a disk..." and "Rename a label..." act at once in real mode, after their own confirmation, before the Review step. See [Disk tools](#disk-tools).

## 2. Requirements and how to run

Requirements:

- An x86_64-linux machine booted from a NixOS live ISO, with a network connection. The flake outputs are x86_64-linux only.
- A real terminal. Without `/dev/tty` the script exits with "the installer needs an interactive terminal".
- `nix` with flakes. The wizard enables `nix-command flakes` for its own calls, so the ISO needs no nix.conf change.

The packaged command (`nixos-installer`) carries its own tools: gum, jq, qrencode, smartmontools, openssh, util-linux, gawk, iputils, git, parted, dosfstools, btrfs-progs, e2fsprogs, xfsprogs and cryptsetup. When you run `install.sh` directly and gum, qrencode or smartctl is missing, it re-runs itself inside `nix shell nixpkgs#gum nixpkgs#qrencode nixpkgs#jq nixpkgs#smartmontools`.

### Commands

```sh
sudo nix run github:Linuxury/NixOS-Installer                 # on the ISO: install
sudo nix run github:Linuxury/NixOS-Installer -- --resume     # continue a failed install
nix run .#install-demo                                       # demo with your real disks
nix run .#install-demo -- --fake-disks 3-mixed               # demo with fake disks
bash install.sh --demo                                       # run the script directly
```

If you start real mode without root, the script says so and re-runs itself under `sudo`, keeping `TERM`, `COLORTERM`, `LANG`, `SSH_AUTH_SOCK`, `INSTALL_ALLOW_NON_ISO` and `INSTALLER_GIT`.

A demo without root offers "Re-run with sudo" so the Disks step can read SMART data. Without root, SMART shows "? needs sudo".

### Options

Pass options after `--` when you use `nix run`.

| Option | What it does |
|---|---|
| `--demo` | Write nothing. Run every menu, then print the generated files and the exact commands real mode would run. |
| `--fake-disks NAME` | Demo with simulated disks. Implies `--demo`. |
| `--resume` | Real mode: re-run the install from the failed phase. Skips the menus. |
| `--hub` | Main-menu mode: one list of sections you can open in any order. |
| `--config FILE` | Replay a saved answers file and go straight to the Review step. Implies `--hub`. |

An unknown option prints `unknown option: ...` and exits with status 2.

Fake disk sets (every set also has an 8 GB boot USB stick, `sdz`):

| Name | Disks |
|---|---|
| `2-equal` | Two identical 2 TB NVMe drives (mirror candidates). |
| `3-mixed` | 1 TB NVMe plus three SATA disks: a 4 TB with a btrfs "data" partition, a 2 TB with bad sectors, a 1 TB SSD. |
| `4-hdd` | 500 GB NVMe plus four 4 TB HDDs, one failing its self-test (raidz candidates). |
| `windows` | A previous NixOS disk, a Windows (NTFS) disk and a 4 TB xfs "Games" disk. |

Any other name prints `unknown scenario: NAME` and exits 1.

### Environment variables

| Variable | Meaning |
|---|---|
| `INSTALLER_REPO` | An existing config checkout to use instead of cloning (Linuxury mode). |
| `INSTALLER_GIT` | Config repo URL to clone. Default `https://github.com/Linuxury/nixos-config`. |
| `INSTALLER_TEMPLATES` | Starter template directory. Default: `templates/` beside `install.sh`. The packaged command sets it to the store copy. |
| `INSTALLER_CHANNEL` | nixpkgs branch the starter flake follows. Default `nixos-unstable`. |
| `INSTALLER_STATE_VERSION` | `system.stateVersion` for the starter host. Default: the ISO's `nixos-version --release`, cut to `YY.MM`; falls back to `26.05`. |
| `INSTALL_ALLOW_NON_ISO` | Set to skip the "must be on the live ISO" check. For VM testing only. |
| `ANSWERS_OUT` | Where the hub's "Save configuration" writes. Default `./answers.json`. |
| `INSTALL_TEST`, `TEST_*` | Non-interactive test runs. See [section 9](#9-testing-and-development). |

## 3. The two config sources

The first screen, Source, asks where the system configuration comes from.

| Source | What you get |
|---|---|
| **Starter template** (default) | A complete flake for a first host, written to `/home/<user>/nixos-config` with the first git commit made. You own it. |
| **Linuxury's config** | An existing config repo. The wizard clones it and adds this machine's disk layout to a host. The label is fixed; the repo can be your own (see below). |

The source changes which steps you see. Starter asks for user, region, desktop, kernel and unfree software. The repo mode takes those from the repo and asks for secrets.

### Starter template

The template lives in `templates/starter/`:

| File | Becomes |
|---|---|
| `flake.nix` | `flake.nix` with one input (nixpkgs, `INSTALLER_CHANNEL`) and one `nixosConfigurations.<host>`. |
| `host.nix` | `hosts/<host>/default.nix`: host name, NetworkManager, timezone, locale, keyboard, the user, SSH, kernel line, unfree, extra packages, `stateVersion`. |
| `stacks/gnome.nix`, `kde.nix`, `cosmic.nix` | Copied as they are. One short file per desktop. |
| `README.md` | `README.md`: how to rebuild, what is where, how to keep it in git. |

The installer fills the `@NAME@` blanks in these files. It also generates `hosts/<host>/disk.nix` and `hosts/<host>/hardware.nix`, and calls `nixos-generate-config` for `hardware-configuration.nix` (see [section 5](#5-what-gets-written)).

### An existing config repo (Linuxury mode)

Choose "Linuxury's config" at the first screen. By default it clones `https://github.com/Linuxury/nixos-config`. Point it at another repo with `INSTALLER_GIT`:

```sh
sudo INSTALLER_GIT=https://github.com/you/nixos-config nix run github:Linuxury/NixOS-Installer
```

Or use a checkout you already have:

```sh
sudo INSTALLER_REPO=/path/to/checkout nix run github:Linuxury/NixOS-Installer
```

How it works:

1. The host list is read from `flake.nix` in a shallow clone (`git clone --depth 1`) in a temp directory. Each `<Name> = mkHost` block with a `user =` line becomes one host entry.
2. After the install, the repo is cloned in full to `/home/<user>/nixos-config` on the new system. The wizard adds `hosts/<host>/disk.nix` and `hosts/<host>/install.json` and commits them.
3. If an SSH agent is forwarded, it pushes the commit (see [section 5](#5-what-gets-written)).

A repo must meet these requirements:

- A `flake.nix` where each host is written as `<Name> = mkHost { ... user = "<login>"; ... };`. That is how the installer finds hosts. A different style shows "no hosts found in <url>".
- A folder `hosts/<Name>/` per host whose main file (`<Name>.nix`, else `default.nix`) imports `./disk.nix`. The installer writes `disk.nix`, so do not commit your own copy.
- Optional: `modules/users/uids.nix` with lines like `<user> = <uid>;`. The installer uses it to set the home directory's owner and to show the UID. Without it the owner is empty.
- Optional: `docs/04-first-boot.md` for the first-boot checklist (see [section 8](#8-after-the-install)).
- Optional: agenix secrets keyed to each host's SSH host key, if you use the Secrets step (see [section 6](#6-installing-from-another-machine)).

Details the host picker reads from the host file (for its preview card): the user, desktop and compositor modules under `../../modules/{desktops,compositors,shells}/`, `hardware.gpu`, `boot.kernelPackages`, `fsType`, `luks.devices`, the boot loader, services and a few extras. These only feed the preview. Missing items show as `?` or empty.

A minimal repo:

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
  system.stateVersion = "26.05";
}
```

In repo mode the installer writes no `hardware-configuration.nix`. Commit your own, or generate it on the new machine.

## 4. The wizard, step by step

A ★ in the UI marks the default. The status bar at the bottom shows the keys and the step names.

Step order without `--hub`:

| Source | Steps |
|---|---|
| Starter template | Source, Host, Disks, Filesystem, Boot, Encrypt, Swap, User, Region, Desktop, Kernel, Unfree, Review |
| Linuxury's config | Source, Host, Disks, Filesystem, Boot, Encrypt, Swap, Secrets, Review |

With `--hub` the steps after Source are one main menu (section 4.14).

The banner at the top shows what was detected: firmware (UEFI or BIOS: `/sys/firmware/efi`), CPU (AMD, Intel or other), GPU vendors (a hybrid shows as `Intel+NVIDIA`), RAM, form factor (virtual machine, laptop if a battery exists, else desktop), WiFi, whether nixos.org answers a ping, and the disk source (`real` or the fake set name). The detected values feed the defaults below.

### 4.1 Source

See [section 3](#3-the-two-config-sources). Options: "Starter template" ★ and "Linuxury's config". In Linuxury mode a failed clone shows "could not download <url> (network?)" and stays on this step.

### 4.2 Host

**Starter.** Shows the detected CPU, GPU, type, WiFi and RAM, then asks for a hostname. Default `nixos`. It must start with a letter, then letters, digits or dashes. The profile is "laptop" when a battery was found, else "desktop".

**Linuxury mode.** Lists the hosts found in `flake.nix` ("N hosts in flake.nix") with a preview card for the highlighted one. A `↻` after a name means saved answers exist for it (see [section 7](#7-resume-and-reinstall)). The last entry is "+ New host". In real mode it reads "(coming soon)". In the demo it asks for hostname, primary user (linuxury, babylinux or alex) and profile (laptop, desktop or server; ★ follows the detected form factor).

### 4.3 Disks

Shows one card per disk: size, transport, model, a SMART verdict and the partitions. The frame colour follows health (red failing, orange worn, blue another OS, grey otherwise). Titles also say "previous NixOS" or "other OS: windows | macos | linux".

Disks come from `lsblk` (JSON, bytes) with `zram`, `loop` and `sr` devices skipped. SMART data comes from `smartctl -j -a`, which needs root. A disk is labelled:

| Verdict | Meaning |
|---|---|
| ✓ healthy | Shows power-on age and temperature. |
| ⚠ watch | Bad sectors (reallocated, pending or uncorrectable), NVMe media errors, or 80% worn or more. |
| ✗ FAILING | Self-test failed or NVMe critical warning. |
| ? | No data: needs sudo, or no SMART (USB stick, VM disk). |

Another OS is detected from filesystems and labels: `nixos` (label `nixos` or `nixos-luks`), `windows` (ntfs), `macos` (apfs), `linux` (ext4, btrfs or xfs next to an EFI vfat partition).

The disk layout menu:

| Choice | Meaning |
|---|---|
| Single disk | Everything on one disk. Other disks stay untouched. |
| Multi-disk | Only when more than one disk is visible. Give every disk a role. |
| Format a disk... | Erase a disk and make one filesystem now. See below. |
| Rename a label... | Change a partition's label in place. |
| Disk health... | SMART details for every disk, explained. |
| Show removable disks too | Only when some are hidden. |

#### Roles

After the layout choice, the "assign roles" page shows every disk as a card. Highlight a disk and press enter to set its role. `Continue` needs a System disk. The role card beside the list explains pros and cons, the disk's speed class and a recommendation (★).

| Role | Meaning |
|---|---|
| System | Holds `/`, `/nix`, the boot loader, and `/home` unless another disk takes it. Wiped. Only one. |
| Mirror of <system disk> | Multi-disk only. A live copy of the System disk (RAID1). Wiped. You get the space of one disk. |
| /home | Multi-disk only. Personal files on their own disk. Wiped. Only one. |
| Data pool | Multi-disk only. Extra storage at a folder you choose. Several disks can be pooled. |
| Untouched | Not formatted, not mounted. |

A disk with another OS first offers other choices:

| Role | Meaning |
|---|---|
| Untouched | Leave it as it is. Recommended. |
| Boot menu entry (`boot`) | Add the other OS to the boot menu. |
| Mount read-only (`mount-ro`) | Mount its files at `/mnt/<OS name>`, read-only. |
| Mount read-write (`mount-rw`) | Same, writable. The help text warns: refused if Windows hibernated or used Fast Startup. |
| Boot entry + mount (`boot+mount-ro`) | Boot entry plus a read-only mount. |
| Wipe & reuse... | Type the disk's model exactly to confirm. Then the normal roles are offered. |

The recommendation (first match wins): a failing or worn disk, or another OS not cleared for wiping, is "untouched"; the best healthy disk (fastest kind, bigger wins a tie: NVMe, SSD, HDD, USB) is "system"; in a multi-disk layout, a disk of the same kind and within 10% of the System disk's size is "mirror"; a single-disk layout leaves the rest "untouched"; HDDs are "data", USB is "untouched", any other SSD is "data".

Choosing a System disk with a failing health verdict asks "Use X anyway?". A worn disk only warns. Choosing a new System disk clears the old one and every Mirror.

#### Disk tools

- **Format a disk...** pick a disk, a filesystem (ext4, xfs, btrfs, exfat, ntfs, vfat) and a label, then confirm. For a disk with another OS you type its model instead. It runs `wipefs -a`, one GPT partition over the whole disk (`parted -s ... mklabel gpt mkpart data 1MiB 100%`), then `mkfs`. A disk with mounted partitions is refused. In real mode this runs immediately. In the demo it only updates the view.
- **Rename a label...** offers partitions with ext4, xfs, btrfs, vfat, ntfs or exfat. Data is untouched. The labels `nixos`, `nixos-luks*` and `EFI*` are refused, because host configs find the system disk by them.
- **Disk health...** shows one card per disk: self-test, power-on time, temperature, bad sectors, and for NVMe the wear, media errors and spare blocks.

Label rules: letters, digits, `.`, `_`, `-`. Maximum length: xfs 12, ext4 16, vfat 11 (forced uppercase), exfat 11, others 32.

### 4.4 Filesystem

| Disk | Choices |
|---|---|
| System, no mirror | btrfs ★, ext4, xfs, bcachefs, zfs (servers). |
| System with a mirror | A RAID layout from the list below. The filesystem is its prefix (`btrfs-raid1` gives btrfs). |
| /home disk | btrfs, ext4 or xfs, then a label (default `home`). |
| Data pool | A mount point (default `/data`). Several disks: a RAID layout and a label. One disk with existing partitions: "Keep existing data" (mounted as it is, by UUID) or "Format". One empty disk, or Format: btrfs, ext4, xfs or zfs, and a label. |

Data labels default to `data`, or `tank` for a ZFS pool. When you keep a data disk you can also rename its label.

RAID layouts (`choose_raid` lists usable space and how many disks may die; ★ marks the best fit):

| Layout | Notes |
|---|---|
| `btrfs-raid1` | 2 copies. Any disk sizes. |
| `btrfs-raid1c3` | 3 copies. At least 3 disks. |
| `btrfs-raid10` | Striped mirrors. At least 4 disks. |
| `zfs-mirror` | n-way mirror. |
| `zfs-raidz1`, `zfs-raidz2`, `zfs-raidz3` | Data pools only. At least 3, 4 and 5 disks. |

Disks within 5% of each other count as equal sizes. ZFS counts every disk as the smallest one, so mixed sizes show a "wasted" note. The ★ goes to `zfs-mirror` for 2 equal disks, `zfs-raidz1` for 3 and `zfs-raidz2` for 4 or more when sizes are equal; otherwise to `btrfs-raid1` (`btrfs-raid10` for 4 or more). For a system pool raidz becomes a mirror. The screen also warns about SSD plus HDD mixed, worn disks, USB-attached disks, and disks with data that will be wiped. RAID is not a backup. In real mode only the btrfs layouts install.

### 4.5 Boot

| Choice | Notes |
|---|---|
| systemd-boot ★ | Minimal and fast. UEFI only. |
| GRUB | UEFI and legacy BIOS. Best at mirrored boot (`mirroredBoots`) and finding other OSes (`os-prober`). |
| Limine | UEFI and BIOS. |
| rEFInd | UEFI only. Demo only. |

On legacy BIOS the UEFI-only entries are hidden, with the warning "Legacy BIOS: systemd-boot and rEFInd need UEFI".

### 4.6 Encrypt

| Choice | Notes |
|---|---|
| LUKS2 | A passphrase at every boot. ★ and "(laptop detected)" on a laptop. With a mirror, both disks unlock with the same passphrase. |
| None | Boots straight to login. |

With ZFS the entries are "ZFS native encryption" and "None" (demo only).

### 4.7 Swap

| Choice | Notes |
|---|---|
| `NG swapfile` ★ | RAM size in GB, capped at 16. Hibernate needs at least RAM size. |
| Custom size | Asks for a whole number of GB. |
| zram only | Compressed RAM swap, no disk swap. |

With ZFS only zram is offered, because swap on ZFS can deadlock.

### 4.8 User (starter only)

The first user is an administrator (`wheel`). The username starts with a lowercase letter, then up to 30 lowercase letters, digits or dashes. `root` is refused. Default `user`.

Then "Remote login (SSH)": "No" is the default, "Yes" enables the OpenSSH server.

### 4.9 Region (starter only)

Timezone: UTC ★, US Eastern, US Central, US Mountain, US Pacific, UK London, Spain Madrid, Germany Berlin, France Paris, Japan Tokyo, or "Other..." to type a tz database name.

Keyboard layout (console keymap and X layout): US English, UK English, German, French, Spanish, Latin American, Portuguese (Brazil), or "Other..." to type both names. The locale is `en_US.UTF-8`.

### 4.10 Desktop (starter only)

| Choice | File |
|---|---|
| None ★ | Text login only. |
| GNOME | `stacks/gnome.nix` |
| KDE Plasma 6 | `stacks/kde.nix` |
| COSMIC | `stacks/cosmic.nix` |

The chosen stack's import is uncommented in `hosts/<host>/default.nix`. The others stay commented, so switching later is one line.

### 4.11 Kernel (starter only)

| Choice | Package set |
|---|---|
| Default ★ | `linuxPackages` (long-term support) |
| Latest | `linuxPackages_latest` |
| Zen | `linuxPackages_zen` |

Each entry shows its real Linux version, read from the nixpkgs channel the new system uses (`nix eval`). Offline, the versions are left out. With ZFS only the default is offered. Default is written as a commented example, so the LTS kernel stays in use. Latest and Zen write `boot.kernelPackages`.

### 4.12 Unfree software (starter only)

"No" ★ (free software only) or "Yes" (`nixpkgs.config.allowUnfree`). When an NVIDIA GPU is detected, unfree is switched on and the only choice is "OK", because the driver is unfree. Needed for Steam, Discord, Spotify and similar.

### 4.13 Secrets (Linuxury mode only)

Creates the new host's SSH host key in `/tmp/nixos-install-hostkey/` (ed25519, no passphrase, comment `root@<host>`) unless one is already there. It shows the public key as an `add-host` command and as a QR code. The key is copied to `/mnt/etc/ssh/ssh_host_ed25519_key` during the install so the host can decrypt its agenix secrets.

| Choice | Meaning |
|---|---|
| I ran add-host - pull the re-keyed secrets | The install pulls the re-keyed secrets from the repo. |
| Skip - secrets fail until re-keyed later (docs/04) | Install anyway. Secrets fail to decrypt until re-keyed. |

See [section 6](#6-installing-from-another-machine) for add-host.

### 4.14 Main menu (`--hub`)

With `--hub` the steps after Source become one main menu. Each entry shows its current value or "(not set)", and the cursor starts on the first unset one.

| Source | Menu entries |
|---|---|
| Starter | Hostname, Disk configuration, User account, Region & keyboard, Desktop, Kernel, Unfree software, Additional packages |
| Linuxury | Hostname, Disk configuration, Secrets |

"Disk configuration" runs Disks, Filesystem, Boot, Encrypt and Swap as one section. Kernel, Unfree and Additional packages count as set, because their defaults are valid.

Below the entries:

| Entry | What it does |
|---|---|
| Save configuration | Writes the answers to `answers.json` (or `ANSWERS_OUT`). Only when every entry is set. |
| Install | Shows "ready" when everything is set, else "(N missing)" and stays locked. Goes to Review. Refused while a chosen package needs unfree software and unfree is off. |
| Abort | Leaves the alternate screen and exits 0, changing nothing. |

**Additional packages** (starter, hub only): search nixpkgs (`nix search`, 25 matches, exact name first), see the selected list with each description, the download size from `cache.nixos.org` and what the picks pull in. Unfree packages are flagged, and "Allow unfree software" appears when one needs it. Options are "Search nixpkgs...", "Allow unfree software", "What gets pulled in...", "Remove a package..." and "Done". Packages are installed for every user on top of the desktop (`environment.systemPackages`).

### 4.15 Review

One screen with everything that will happen:

- Three panels: System (host, user, desktop, kernel, region, extra packages and unfree), Hardware, and Boot & security (boot loader, mirror, encryption, swap, and SSH or secrets state).
- Warnings, or "No warnings". It warns about: SMART warn or fail on a used disk, ZFS holding the kernel back, a laptop without encryption, secrets skipped, a btrfs mirror ("after a disk dies, boot once with -o degraded"), and another OS on a kept disk.
- A one-line summary like `Changes: wipe nvme0n1 · keep sda → /data · 1 untouched`.
- One card per disk with "now" and "after" rows and what each partition is for. Frame colour: red WIPE, green keep, grey untouched, blue other OS.

Then choose "Install" or "Edit a step...". Edit jumps to any earlier step (or back to the main menu with `--hub`). Install asks you to type the hostname. A mismatch stays on the Review. In real mode the prompt says "disks marked WIPE are erased". After it, the install starts.

## 5. What gets written

### The install, in seven phases

Real mode and the demo use the same command list (`gen_commands`). The demo prints it; real mode runs it. Phases are checkpoints for `--resume`.

| Phase | What happens |
|---|---|
| 1 partition | `wipefs -a` and a GPT on every system disk. UEFI: a 1 GiB ESP plus root. BIOS: a 1 MiB `bios_grub` area plus root. ESPs are formatted FAT32 as `EFI`, `EFI2`, ... |
| 2 encryption + filesystems | `cryptsetup luksFormat --type luks2 --label nixos-luksN` when encrypted, then the root filesystem, `/home`, data disks, and a relabel of a kept data disk. |
| 3 unlock + mount + swap | Unlock LUKS, mount everything under `/mnt`, create the btrfs swapfile. Safe to run again. |
| 4 config | Starter: write the flake and make the first commit. Linuxury: clone the repo and write `disk.nix` and `install.json`. |
| 5 secrets | Linuxury: copy the host key to `/mnt/etc/ssh/`, and `git pull --rebase` the re-keyed secrets when you chose "I ran add-host". Starter: nothing. |
| 6 install | `grow_live_store`, `nixos-install --flake /mnt/home/<user>/nixos-config#<host> --no-root-passwd`, then `nixos-enter --root /mnt -- passwd <user>`. |
| 7 finish | Copy the log, commit `flake.lock` (starter), fix home ownership, unmount. |

`grow_live_store` exists because the live ISO keeps its package store in RAM. It swaps on a file on the new disk (the btrfs swapfile, else an 8 GB `/mnt/.installer-swap`) and, if `/` is a tmpfs, grows it to RAM plus 8 GB.

### `hosts/<host>/disk.nix`

Generated for both sources. Every mount uses a label or UUID, so device names do not matter.

| Part | What is written |
|---|---|
| Labels | Root `nixos`, LUKS partitions `nixos-luks1`, `nixos-luks2`, ..., ESPs `EFI`, `EFI2`, ... |
| btrfs subvolumes | `@` `@home` `@nix` `@log` `@cache` `@snapshots` `@home_snapshots` `@swap`, mounted at `/`, `/home`, `/nix`, `/var/log`, `/var/cache`, `/.snapshots`, `/home/.snapshots`, `/swap`. Options `compress=zstd:1` and `noatime` (`@swap`: `noatime` only). `@home` and `@home_snapshots` are skipped with a `/home` disk. `@swap` is skipped when swap is zram. |
| ext4, xfs | One filesystem on label `nixos`, option `noatime`. |
| zfs (demo) | Datasets `rpool/root`, `rpool/home`, `rpool/nix`, `rpool/log`, a random `networking.hostId`, and the LTS kernel forced. |
| `/boot` | Label `EFI`, `umask=0077`. Mirrors add `/boot2`, ... from `EFI2`, ... with `nofail`. |
| LUKS | `boot.initrd.luks.devices.cryptrootN` on `/dev/disk/by-label/nixos-luksN`, one per system disk, `allowDiscards`. |
| Boot loader | systemd-boot, GRUB (`efiSupport` on UEFI; `mirroredBoots` with one entry per system disk when mirrored; `useOSProber` when another disk has the boot role), Limine (`biosDevice` on BIOS), rEFInd. With another OS to boot, systemd-boot gets the EDK2 UEFI shell and Limine a commented `extraEntries` example. |
| ESP mirror | For loaders other than GRUB on UEFI with mirrors: an activation script that rsyncs `/boot/` to each `/bootN/`. |
| `/home`, data | By label. A kept data disk by UUID. All data mounts use `nofail`. |
| Other OS | Mount roles become `ntfs3` mounts at `/mnt/<OS name>`, read-only or writable, `nofail`. |
| Swap | `zramSwap.enable` for zram; `/swap/swapfile` on btrfs; otherwise `/swapfile` of the chosen size. |

On BIOS, GRUB and Limine use a stable `/dev/disk/by-id/...` path.

### Starter flake

Written to `/home/<user>/nixos-config` on the new system:

```
flake.nix
README.md
hosts/<host>/default.nix
hosts/<host>/disk.nix
hosts/<host>/hardware.nix              CPU, GPU, laptop, VM settings the installer detected
hosts/<host>/hardware-configuration.nix  from nixos-generate-config --no-filesystems
stacks/gnome.nix  stacks/kde.nix  stacks/cosmic.nix
```

`hardware.nix` always enables redistributable firmware. It adds the CPU microcode for AMD or Intel, `hardware.graphics.enable` when any GPU is found, the NVIDIA driver settings (and a PRIME note for hybrid graphics), `services.power-profiles-daemon` on a laptop and `services.qemuGuest` in a VM. `hardware-configuration.nix` comes from `nixos-generate-config --no-filesystems`, because `disk.nix` already has the mounts. The installer then makes `git init -b main`, a first commit ("<host>: initial configuration from the NixOS installer") and, after the install, a second commit with `flake.lock`. The home directory is chowned to `1000:100`.

### Linuxury mode: repo files

`hosts/<host>/disk.nix` and `hosts/<host>/install.json` are written into the full clone at `/home/<user>/nixos-config` and committed with the message `<host>: disk layout from installer`. The installer writes no other file.

If `SSH_AUTH_SOCK` is set (an SSH agent was forwarded), a `https://github.com/...` remote is switched to `git@github.com:...` and the commit is pushed. If the push fails: "push failed - push it after first boot". With no agent: "no forwarded SSH agent - the commit stays local; push it after first boot". A new host (demo only) also needs `hosts/<host>/<host>.nix` and a `flake.nix` entry by hand.

### `install.json`

The answers as JSON, format version 1: source, host, user, layout, disks (by serial number: system, mirrors, home, data, other), filesystem and RAID, labels, data pool options, boot, encryption, swap, region, desktop, kernel, unfree, SSH and extra packages. Disks are matched by serial, because `sda` and `nvme0n1` can swap between boots. You can replay it with `--config` (see [section 7](#7-resume-and-reinstall)).

### Logs and temporary files

| Path | Content |
|---|---|
| `/tmp/nixos-install.log` | Every command and its output. Copied to `/mnt/var/log/nixos-install.log` in phase 7. |
| `/tmp/nixos-install-state.sh` | The answers as shell assignments, read by `--resume`. |
| `/tmp/nixos-install-phase` | The last finished phase. |
| `/tmp/nixos-install-hostkey/` | The new host's SSH host key. Kept for `--resume`. |
| `/tmp/install-demo-answers-<uid>/<host>.json` | Saved answers for the reinstall shortcut. Under `sudo`, `<uid>` is the invoking user. Fake disks use a subfolder named after the set. |

## 6. Installing from another machine

`install-host` and `add-host` are for the linuxury setup. They live in the NixOS-Config repo (`scripts/install-host`, `scripts/add-host`), not here. They matter when you use "Linuxury's config" with agenix secrets.

**`install-host <ip> [Host] [-- <args>]`** runs from an admin machine. It logs into the ISO over SSH and starts this installer there.

| Form | What it does |
|---|---|
| `install-host <ip>` | Runs the installer remotely. For the starter config, or when you register the key by hand at the Secrets step. |
| `install-host <ip> <Host>` | Also makes `<Host>`'s new SSH host key on the admin machine, runs `add-host`, and copies the key to the ISO. |
| `install-host <ip> <Host> -- <args>` | Passes `<args>` to the installer, for example `--hub`. |

On the target first: boot the live ISO, connect to the network, and set a password for the `nixos` user with `passwd`, so SSH can log in.

**`add-host <Host> '<ssh-ed25519 KEY>'`** runs on an admin machine whose personal key is in `secrets.nix`. It adds or replaces the host's key in `secrets/secrets.nix`, re-encrypts the secrets (ragenix), commits and pushes. `--no-push` stops after the commit. For a new host it stops after adding the key, so you can add the host to the recipient lists of its secrets and run it again.

### The host-key hand-off

1. `install-host` puts the key in `/tmp/nixos-install-hostkey/` on the ISO (root-owned, mode 0600). The installer only creates a key when none is there.
2. The installer's Secrets step shows the same key. Pick "I ran add-host - pull the re-keyed secrets". Phase 5 copies the key to `/mnt/etc/ssh/` and pulls the re-keyed secrets.
3. The local copy of the private key on the admin machine is deleted on exit.

To do it by hand at the ISO's console, run the `add-host <Host> '<key>'` command the Secrets step prints on your admin machine (or scan the QR code), then pick "I ran add-host".

### Agent forwarding

`install-host` connects with `ssh -A`. The installer keeps `SSH_AUTH_SOCK` when it re-runs under `sudo`, so the forwarded agent reaches `git push` in phase 4. Host-key checking is off for that session only, because a live ISO makes a new SSH host key on every boot.

## 7. Resume and reinstall

### `--resume`

A failed phase prints the failed command, the log path and how to continue. Fix the cause, then run the installer again with `--resume`:

```sh
sudo nix run github:Linuxury/NixOS-Installer -- --resume
```

`--resume` skips the menus. It loads the saved answers from `/tmp/nixos-install-state.sh` and continues after the last finished phase, from `/tmp/nixos-install-phase`. Finished phases are skipped, except phase 3 (unlock + mount + swap), which always runs again, so LUKS is re-opened and everything is re-mounted. Disks are not re-partitioned. Without a state file it prints "nothing to resume (/tmp/nixos-install-state.sh missing)" and exits 1. In Linuxury mode it loads the config repo again first.

State files live in `/tmp` on the live ISO, so `--resume` works only until you reboot the ISO.

### Reinstall with saved answers

After a successful run, the answers are saved to `/tmp/install-demo-answers-<uid>/<host>.json`. In Linuxury mode, the Host step then shows `↻` after that host. Picking it offers:

| Choice | What it does |
|---|---|
| Reinstall with saved answers ★ | Loads the answers, then jumps to the Secrets step for a new host key (without `--hub`) or to the main menu (with `--hub`). Review follows. |
| Start fresh | Ignores the saved answers. |

The disks are found by serial number. If one of them is missing from this machine, the step lists the missing disks and starts fresh.

### Replay an answers file

`--config FILE` loads a file in the `install.json` format, then goes straight to the Review step. You still type the hostname to confirm. The hub's "Save configuration" writes such a file. The file in a repo's `hosts/<host>/install.json` works too:

```sh
sudo nix run github:Linuxury/NixOS-Installer -- --config hosts/Desktop/install.json
```

If a saved system, mirror, data or home disk is not in this machine, it shows "some disks from FILE are not in this machine" with the list, and returns to the first screen. A missing "other" disk is dropped without a message.

## 8. After the install

The closing screen lists what was written, the log path, how to resume and the first-boot notes.

**Starter.** It names `/home/<user>/nixos-config` and says to read its `README.md` for how to rebuild, change the desktop and back it up to git. The password was set in phase 6. WiFi made on the USB is not kept: reconnect with `nmtui` or the desktop's network menu.

**Linuxury mode.** It also prints a first-boot checklist for the host, read from the config repo's `docs/04-first-boot.md`. If the file does not exist, the checklist is skipped.

The file needs this shape:

```markdown
## All Machines

### Set user passwords
...

### Register the host key in secrets.nix and apply secrets
...

## <Host>

### A host-specific step
...
```

- The `## All Machines` section's `###` headings are listed for every host.
- A `## ` heading whose text contains the host name adds that host's `###` headings.
- When you chose "I ran add-host", steps whose title matches `secrets.nix` or `apply secrets` are ticked and marked "(done by installer)".
- A step titled "Set user passwords" says the primary user is done by the installer.

Remove the USB stick and reboot when it prints "<host> is installed".

## 9. Testing and development

Run the demo to try the wizard safely:

```sh
nix run .#install-demo                          # your real disks, nothing written
nix run .#install-demo -- --fake-disks 3-mixed  # fake disks
```

The demo prints the generated `disk.nix` (and, for starter, the whole starter flake) and the exact commands real mode would run. It also saves the answers, so you can run it again, pick a host and try the reinstall shortcut.

The flake outputs (x86_64-linux): `packages.default` (the `nixos-installer` command), `apps.install` (alias `apps.default`) and `apps.install-demo`. The build runs shellcheck on `install.sh` with SC2016, SC2028 and SC2059 switched off (jq programs in single quotes, literal `\n` in `echo`, colour codes in `printf` formats).

### Test mode

`INSTALL_TEST=1` makes the wizard non-interactive: it forces `--demo`, reads no keyboard and takes the default of every menu. Variables that override single answers:

| Variable | Effect |
|---|---|
| `TEST_IDX` | Menu option index every pick takes. |
| `TEST_SOURCE` | `starter` or `linuxury`. |
| `TEST_DESKTOP`, `TEST_KERNEL`, `TEST_UNFREE` | The starter answers. |
| `TEST_FW` | Pretend to boot as `uefi` or `bios`. |
| `TEST_PKGS`, `TEST_PKG_IDX` | Preset the extra packages (space-separated). Without `TEST_PKGS` the packages step is skipped. |
| `TEST_VISIT`, `TEST_HUB_SHOW` | Hub: open one named section once; show the real menu. |
| `STARTER_OUT` | Directory where the demo writes the starter flake. |

### `tests/smoke.sh`

Runs the whole wizard end to end for each source (starter, linuxury) and each fake-disk set (`2-equal`, `3-mixed`, `4-hdd`, `windows`). A run passes when it exits 0, prints no error-looking text and reaches the Review step. Each run has `timeout 120`.

```sh
tests/smoke.sh
INSTALLER_REPO=~/nixos-config tests/smoke.sh   # also test the linuxury source
```

`INSTALLER_REPO` is a checkout of the config repo. Without it the linuxury source is skipped. Exit 0 if all runs pass, 1 otherwise.

### `tests/starter.sh`

Generates a starter flake for 8 desktop, kernel, unfree and firmware combinations, checks that the imported stack file matches the desktop, and evaluates each system with `nix build --dry-run` against the nixpkgs pinned in this repo's `flake.lock`. It catches wrong option names and broken templates. It writes a stand-in `hardware-configuration.nix` for the evaluation, because the real one is made at install time.

```sh
tests/starter.sh
```

It prints `ok  <desktop> <kernel> <unfree> <fw> imports=<stack>` per case or `FAIL ...` with the last error lines. Exit 0 if all pass, 1 otherwise. To cover a new combination, add a row to `CASES` at the end of the file.

## 10. Troubleshooting

| Message | Cause and fix |
|---|---|
| `the installer needs an interactive terminal` | No `/dev/tty`. Run it in a real terminal, or use `install-host` (which passes `ssh -t`). |
| `gum/qrencode/smartctl unavailable` | The script tried to re-run itself in a `nix shell` and that failed. Check the network. |
| `unknown option: ...` | Exit 2. See the option list in section 2. |
| `the installer must run as root (sudo)` | Run it with `sudo`. |
| `not on the NixOS live ISO - refusing to touch disks` | `/iso` is missing. Boot the live ISO. `INSTALL_ALLOW_NON_ISO=1` overrides this, for VM testing only. |
| `mounted, refusing to wipe: <disks>` | Something on a system, `/home` or to-be-formatted data disk is mounted. Unmount it, or pick other disks. |
| `"<value>" is coming soon - the real installer v1 doesn't do it yet (try it with --demo)` | zfs, bcachefs, rEFInd or "+ New host" in real mode. Pick another value. |
| `could not download <url> (network?)` | The config repo clone failed. Check the network and `INSTALLER_GIT`. |
| `no hosts found in <url>` | The repo's `flake.nix` has no `<Name> = mkHost` block with a `user =` line (section 3). |
| `answers file not found: FILE` | Wrong `--config` path. The menu is shown instead. |
| `some disks from FILE are not in this machine` | The saved disks (by serial) are not here. Answer the menus fresh. |
| `Install is locked: N entries still say (not set)` | Hub: answer every entry first. |
| `X needs unfree software. Turn on "Unfree software" or remove it from the packages.` | Hub: a chosen package is unfree and unfree is off. |
| `Didn't match` | The typed hostname did not match. You stay on the Review step. |
| `? needs sudo` in the Disks step | SMART needs root. Re-run with sudo. |
| `X failed: <command> (see /tmp/nixos-install.log)` for a disk tool, or `failed:` for the install | Read `/tmp/nixos-install.log`. For the install, fix the cause and run `--resume`. |
| `The live ISO's RAM disk is full` | `nix-collect-garbage`, then `--resume`. |
| `nothing to resume (/tmp/nixos-install-state.sh missing)` | No install has reached the install stage in this ISO session. Start normally. |
| `push failed - push it after first boot` | The forwarded agent could not push. After first boot, run `git push` in `~/nixos-config`. |
| `no forwarded SSH agent - the commit stays local` | Connect with `ssh -A`, or push after first boot. |
| `could not save answers to <dir> (continuing)` | The saved-answers folder is not writable. The install is not affected. |
| Secrets fail to decrypt after first boot | You skipped re-keying. Run `add-host <Host> '<key>'` on the admin machine, then rebuild (`nru`). |
