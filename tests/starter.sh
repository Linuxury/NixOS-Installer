#!/usr/bin/env bash
# ===========================================================================
# tests/starter.sh — generate a starter flake for each desktop/kernel/unfree/
# firmware combination and have NixOS evaluate it
#
# For every case listed at the bottom: run the wizard (install-demo app in
# flake.nix) in test mode so it writes the starter flake into a temp dir, check
# that the desktop stack file it imports matches the choice, then evaluate the
# system with `nix build --dry-run` (evaluates, builds nothing). Catches wrong
# option names and broken templates. Not loaded by anything; run it by hand.
# Run:    tests/starter.sh
# Exit:   0 all cases passed, 1 at least one failed
# Output: "ok    <desktop> <kernel> <unfree> <fw> imports=<stack>" per passing case,
#         "FAIL ..." plus the last lines of the error otherwise.
# ===========================================================================
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
# INSTALL_TEST=1: install.sh answers every prompt with its default and behaves
# as --demo; the TEST_* variables below override individual answers.
export INSTALL_TEST=1
# nixpkgs revision pinned in this repo's flake.lock; the generated flake is
# built against the same one (--override-input below).
rev=$(nix flake metadata "$root" --json | jq -r '.locks.nodes.nixpkgs.locked.rev')
fail=0
# Case columns (see CASES at the bottom):
#   desk    desktop stack: none | gnome | kde | cosmic
#   kernel  default | latest | zen
#   unfree  true or false: allow unfree packages
#   fw      firmware the machine pretends to boot with: uefi | bios
while read -r desk kernel unfree fw; do
  dir=$(mktemp -d)
  # Wizard overrides: TEST_SOURCE config source; TEST_DESKTOP/KERNEL/UNFREE/FW
  # the answers for each column; STARTER_OUT where the starter flake is written
  # (otherwise a temp dir that is removed). --fake-disks 3-mixed supplies disks.
  TEST_SOURCE=starter TEST_DESKTOP=$desk TEST_KERNEL=$kernel TEST_UNFREE=$unfree TEST_FW=$fw STARTER_OUT=$dir \
    nix run "$root"#install-demo -- --fake-disks 3-mixed >/dev/null 2>&1 || { echo "FAIL wizard  $desk $kernel $unfree $fw"; fail=1; continue; }
  host=$(ls "$dir/hosts")
  # The wizard omits hardware-configuration.nix (nixos-generate-config makes it at
  # install time), so write a minimal stand-in the evaluation can use.
  cat >"$dir/hosts/$host/hardware-configuration.nix" <<'NIX'
{ lib, ... }: { nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux"; }
NIX
  # Stack files the host's default.nix imports (comma-separated); must equal the desktop choice.
  chosen=$(grep -E '^\s+\.\./\.\./stacks/' "$dir/hosts/$host/default.nix" | sed -E 's#.*/([a-z]+)\.nix#\1#' | paste -sd,)
  [[ ${chosen:-none} == "${desk/none/none}" || $desk == none && -z $chosen ]] || { echo "FAIL stack  wanted $desk, file imports '$chosen'"; fail=1; }
  # --no-write-lock-file keeps the temp flake free of a lock file; the
  # --override-input pins nixpkgs to $rev instead of resolving a new one.
  if out=$(nix build --dry-run --no-write-lock-file --override-input nixpkgs "github:nixos/nixpkgs/$rev" \
      "path:$dir#nixosConfigurations.$host.config.system.build.toplevel" 2>&1); then
    printf 'ok    %-7s %-9s %-5s %-5s imports=%s\n' "$desk" "$kernel" "$unfree" "$fw" "${chosen:-none}"
  else
    printf 'FAIL  %-7s %-9s %-5s %-5s\n' "$desk" "$kernel" "$unfree" "$fw"; echo "$out" | tail -6; fail=1
  fi
  rm -rf "$dir"
# CASES: one "desk kernel unfree fw" row per run. Add a row to cover a new combination.
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
