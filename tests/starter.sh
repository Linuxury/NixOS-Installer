#!/usr/bin/env bash
# Generates a starter flake for each desktop/kernel/unfree/firmware combination and asks NixOS
# to evaluate it (nix build --dry-run). Catches wrong option names and broken templates.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
export INSTALL_TEST=1
rev=$(nix flake metadata "$root" --json | jq -r '.locks.nodes.nixpkgs.locked.rev')
fail=0
while read -r desk kernel unfree fw; do
  dir=$(mktemp -d)
  TEST_SOURCE=starter TEST_DESKTOP=$desk TEST_KERNEL=$kernel TEST_UNFREE=$unfree TEST_FW=$fw STARTER_OUT=$dir \
    nix run "$root"#install-demo -- --fake-disks 3-mixed >/dev/null 2>&1 || { echo "FAIL wizard  $desk $kernel $unfree $fw"; fail=1; continue; }
  host=$(ls "$dir/hosts")
  cat >"$dir/hosts/$host/hardware-configuration.nix" <<'NIX'
{ lib, ... }: { nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux"; }
NIX
  chosen=$(grep -E '^\s+\.\./\.\./stacks/' "$dir/hosts/$host/default.nix" | sed -E 's#.*/([a-z]+)\.nix#\1#' | paste -sd,)
  [[ ${chosen:-none} == "${desk/none/none}" || $desk == none && -z $chosen ]] || { echo "FAIL stack  wanted $desk, file imports '$chosen'"; fail=1; }
  if out=$(nix build --dry-run --no-write-lock-file --override-input nixpkgs "github:nixos/nixpkgs/$rev" \
      "path:$dir#nixosConfigurations.$host.config.system.build.toplevel" 2>&1); then
    printf 'ok    %-7s %-9s %-5s %-5s imports=%s\n' "$desk" "$kernel" "$unfree" "$fw" "${chosen:-none}"
  else
    printf 'FAIL  %-7s %-9s %-5s %-5s\n' "$desk" "$kernel" "$unfree" "$fw"; echo "$out" | tail -6; fail=1
  fi
  rm -rf "$dir"
done <<'CASES'
none   default   false uefi
none   latest    false bios
gnome  zen       true  uefi
gnome  default   false bios
kde    zen       false uefi
kde    latest    true  bios
cosmic default   false uefi
cosmic zen       true  bios
CASES
exit $fail
