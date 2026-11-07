#!/usr/bin/env bash
# Runs the whole wizard in test mode (default answers, no keyboard, nothing written)
# for every fake-disk scenario. Needs a config checkout: INSTALLER_REPO=~/nixos-config
set -u
: "${INSTALLER_REPO:?set INSTALLER_REPO to a config checkout}"
export INSTALL_TEST=1
fail=0
for sc in 2-equal 3-mixed 4-hdd windows; do
  out=$(timeout 120 nix run "$(dirname "$0")/.."#install-demo -- --fake-disks "$sc" 2>&1); rc=$?
  bad=$(grep -ci -E 'error|unbound variable|command not found|syntax error' <<<"$out")
  printf '%-9s exit=%s problems=%s\n' "$sc" "$rc" "$bad"
  [[ $rc -eq 0 && $bad -eq 0 ]] || fail=1
done
exit $fail
