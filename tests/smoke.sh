#!/usr/bin/env bash
# ===========================================================================
# tests/smoke.sh — run the whole wizard end to end for every config source and
# fake-disk scenario
#
# Each run starts the install-demo app (flake.nix) in test mode: default
# answers, no keyboard, nothing written. A run passes when it exits 0, its
# output contains no error-looking text, and the wizard reaches its last step
# (Review). Not loaded by anything; run it by hand.
# Run:    tests/smoke.sh
#         INSTALLER_REPO=~/nixos-config tests/smoke.sh
#   INSTALLER_REPO  checkout of the linuxury config; without it the linuxury
#                   source is skipped (the starter source needs nothing)
# Exit:   0 all runs passed, 1 at least one failed
# ===========================================================================
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
# INSTALL_TEST=1: install.sh answers every prompt with its default (input comes
# from /dev/null) and behaves as --demo.
export INSTALL_TEST=1
fail=0
# Config sources the wizard offers; TEST_SOURCE picks one without the menu.
for src in starter linuxury; do
  if [[ $src == linuxury && -z ${INSTALLER_REPO:-} ]]; then echo "linuxury  skipped (set INSTALLER_REPO)"; continue; fi
  # Fake-disk scenarios (--fake-disks <name> replaces real disk detection;
  # each also lists the boot USB stick):
  #   2-equal  two 2 TB NVMe drives
  #   3-mixed  1 TB NVMe, 4 TB HDD with a btrfs "data" disk, 2 TB HDD with
  #            reallocated sectors, 1 TB SATA SSD
  #   4-hdd    500 GB NVMe plus four 4 TB HDDs, one failing its SMART check
  #   windows  NVMe with an existing NixOS install, NVMe with Windows (NTFS),
  #            4 TB HDD with an xfs "Games" disk
  for sc in 2-equal 3-mixed 4-hdd windows; do
    # timeout 120: a wizard stuck waiting for input counts as a failure.
    out=$(TEST_SOURCE=$src timeout 120 nix run "$root"#install-demo -- --fake-disks "$sc" 2>&1); rc=$?
    # Count output lines that look like script errors (case-insensitive).
    bad=$(grep -ci -E 'error|unbound variable|command not found|syntax error|invalid|no such file' <<<"$out")
    printf '%-9s %-9s exit=%s problems=%s\n' "$src" "$sc" "$rc" "$bad"
    # On failure, show the last 8 lines with terminal colour codes removed.
    [[ $rc -eq 0 && $bad -eq 0 ]] || { fail=1; echo "$out" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tail -8; }
    # a step returning non-zero sends the wizard backwards; the last step must be reached
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<<"$out" | grep -ao 'step [0-9]*/[0-9]*' | tail -1 | awk -F'[ /]' '{exit $2!=$3}' || { fail=1; echo "  never reached the Review step"; }
  done
done
exit $fail
