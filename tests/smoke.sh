#!/usr/bin/env bash
# Runs the whole wizard in test mode (default answers, no keyboard, nothing written)
# for every config source and fake-disk scenario.
# Linuxury's config needs a checkout: INSTALLER_REPO=~/nixos-config
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
export INSTALL_TEST=1
fail=0
for src in starter linuxury; do
  if [[ $src == linuxury && -z ${INSTALLER_REPO:-} ]]; then echo "linuxury  skipped (set INSTALLER_REPO)"; continue; fi
  for sc in 2-equal 3-mixed 4-hdd windows; do
    out=$(TEST_SOURCE=$src timeout 120 nix run "$root"#install-demo -- --fake-disks "$sc" 2>&1); rc=$?
    bad=$(grep -ci -E 'error|unbound variable|command not found|syntax error|invalid|no such file' <<<"$out")
    printf '%-9s %-9s exit=%s problems=%s\n' "$src" "$sc" "$rc" "$bad"
    [[ $rc -eq 0 && $bad -eq 0 ]] || { fail=1; echo "$out" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tail -8; }
    # a step returning non-zero sends the wizard backwards; the last step must be reached
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<<"$out" | grep -ao 'step [0-9]*/[0-9]*' | tail -1 | awk -F'[ /]' '{exit $2!=$3}' || { fail=1; echo "  never reached the Review step"; }
  done
done
exit $fail
