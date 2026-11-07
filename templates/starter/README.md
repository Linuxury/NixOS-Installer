# NixOS configuration for @HOST@

Written by the NixOS installer on @DATE@. This is a normal NixOS flake: everything the
installer asked you is now a file you can read and change.

## Rebuild after a change

```sh
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#@HOST@
```

## What is where

| File | What it holds |
| --- | --- |
| `flake.nix` | the nixpkgs version (`@CHANNEL@`) and this one host |
| `hosts/@HOST@/default.nix` | name, user, timezone, keyboard, packages, desktop choice |
| `hosts/@HOST@/disk.nix` | boot loader, encryption, filesystems and swap, as you chose them |
| `hosts/@HOST@/hardware-configuration.nix` | kernel modules found by `nixos-generate-config` |
| `hosts/@HOST@/hardware.nix` | CPU, GPU and laptop settings the installer detected |
| `stacks/` | one short file per desktop; `default.nix` imports the one you picked |

To change desktop, comment out one line in the `imports` list of `default.nix` and
uncomment another. Use only one: they conflict.

## Keep it in git

The installer already made the first commit. To back it up, create an empty repository on
your git host, then:

```sh
git remote add origin <your-repo-url>
git push -u origin main
```

## Use these files in a config you already have

`disk.nix`, `hardware-configuration.nix` and `hardware.nix` do not depend on anything in
this repo. Copy them into a host of your own and import them:

```nix
imports = [ ./disk.nix ./hardware-configuration.nix ./hardware.nix ];
```

## After the first boot

- **WiFi:** the connection made on the install USB is not kept. Reconnect with
  `nmtui` or the desktop's network menu.
- **More users, packages, Home Manager:** add them in `hosts/@HOST@/default.nix`.
