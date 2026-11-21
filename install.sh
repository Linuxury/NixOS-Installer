#!/usr/bin/env bash
# ===========================================================================
# install.sh — guided NixOS installer (with a demo mode)
#
# A full-screen wizard (bash + gum) that asks for disks, filesystem, boot
# loader, encryption, swap and the host, then writes hosts/<host>/disk.nix and
# runs the install. flake.nix packages it as the nixos-installer command:
# apps.install (alias apps.default) runs it for real, apps.install-demo runs
# it with --demo. It can also run directly: bash install.sh --demo.
#
# Real mode partitions, formats and installs. It runs as root, only on the
# live ISO, never wipes a mounted disk, and asks you to type the hostname.
# Every step is logged to /tmp/nixos-install.log; a failed phase continues
# with --resume (no re-partitioning).
#
# Demo mode runs every menu and prints the disk.nix and the exact commands
# the real mode would run — touching nothing.
#
# Two config sources (first screen):
#   Starter template  a fresh first host: the wizard writes a complete flake you own
#   Linuxury's config the Linuxury/nixos-config flake (cloned; the wizard adds
#                     the disk layout to an existing host)
#
# Options:
#   --demo               write nothing; print disk.nix and the commands instead
#   --fake-disks NAME    demo with simulated disks (implies --demo):
#                        2-equal · 3-mixed · 4-hdd · windows
#   --resume             real mode: re-run the install from the failed phase
#   --hub                main-menu mode: jump between sections in any order
#   --config FILE        replay a saved answers file (implies --hub)
#
# Environment:
#   INSTALLER_REPO       existing config checkout to use (else cloned)
#   INSTALLER_GIT        config repo URL to clone (default:
#                        https://github.com/Linuxury/nixos-config)
#   INSTALLER_TEMPLATES  starter template dir (default: templates/ beside this file)
#   INSTALLER_CHANNEL    nixpkgs branch the starter flake pins (default nixos-unstable)
#   INSTALLER_STATE_VERSION  system.stateVersion for the starter host
#   INSTALL_TEST         non-interactive test run: forces demo, takes defaults
#   TEST_IDX             with INSTALL_TEST: menu option index every pick takes
#
# Usage:
#   sudo nix run github:Linuxury/NixOS-Installer          # on the ISO: install
#   sudo nix run github:Linuxury/NixOS-Installer -- --resume
#   nix run .#install-demo                                # demo, your real disks
#   nix run .#install-demo -- --fake-disks 3-mixed        # demo, fake disks
#
# Real mode supports: btrfs/ext4/xfs · LUKS · systemd-boot/GRUB/Limine ·
# single disk, btrfs mirror · data disk keep/format · existing hosts. Other
# choices (zfs, bcachefs, rEFInd, new host) work only in the demo; real mode
# shows them as "coming soon" (see soon()).
#
# Keys: enter select · esc back one step · ctrl+c quit
# ===========================================================================
set -euo pipefail

# Tools: gum (layout), qrencode (QR codes), smartctl (disk health), jq (JSON).
# When one is missing, re-run this script inside a `nix shell` that provides
# them; _DEMO_SHELL marks the second run so a failed fetch cannot loop.
# Then require a real terminal (/dev/tty) unless INSTALL_TEST is set.
if ! command -v gum >/dev/null || ! command -v qrencode >/dev/null || ! command -v smartctl >/dev/null; then
  [[ -n "${_DEMO_SHELL:-}" ]] && { echo "gum/qrencode/smartctl unavailable" >&2; exit 1; }
  _DEMO_SHELL=1 exec nix shell nixpkgs#gum nixpkgs#qrencode nixpkgs#jq nixpkgs#smartmontools -c bash "$0" "$@"
fi
{ : </dev/tty; } 2>/dev/null || [[ -n ${INSTALL_TEST:-} ]] || { echo "the installer needs an interactive terminal" >&2; exit 1; }

REPO="${INSTALLER_REPO:-}"   # config checkout; in Linuxury mode it is cloned when not given
TEMPLATES="${INSTALLER_TEMPLATES:-$(cd "$(dirname "$0")" && pwd)/templates}"
ARGS=("$@")
# Option parsing (each flag is described in the header). ARGS keeps the
# original arguments for the sudo re-exec in main. Unknown options exit 2.
#   FAKE        fake-disk scenario name ("" = real disks)
#   DEMO        1 = write nothing
#   RESUME      1 = continue a failed install
#   HUB         1 = main-menu mode
#   CONFIG      answers file to replay
#   PICK_START  option index the next pick() starts on (reset after use)
FAKE=""; DEMO=""; RESUME=""; HUB=0; CONFIG=""; PICK_START=0
while (($#)); do
  case $1 in
    --demo) DEMO=1 ;;
    --fake-disks) FAKE="${2:?scenario: 2-equal|3-mixed|4-hdd|windows}"; DEMO=1; shift ;;
    --resume) RESUME=1 ;;
    --hub) HUB=1 ;;   # prototype: archinstall-style main menu instead of a fixed order
    --config) CONFIG="${2:?answers file}"; HUB=1; shift ;;   # prototype: replay a saved answers file
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n ${INSTALL_TEST:-} ]] && DEMO=1
# Files the real install keeps in /tmp on the live ISO:
#   LOG     full command log
#   STATE   the answers as shell assignments, sourced again by --resume
#   PHASEF  number of the last install phase reached (--resume starts there)
#   KEYDIR  the new host's SSH host key
LOG=/tmp/nixos-install.log; STATE=/tmp/nixos-install-state.sh; PHASEF=/tmp/nixos-install-phase
KEYDIR=/tmp/nixos-install-hostkey                     # survives --resume (TMP does not)
# Saved answers for the demo: one <host>.json per host in a per-user folder.
# Under sudo, OWNER_UID is the invoking user (SUDO_UID), so a sudo run reads
# and writes that user's folder. The real installer saves to
# $REPO/hosts/<host>/install.json instead.
OWNER_UID=${SUDO_UID:-$(id -u)}
ANSWERS_DIR=/tmp/install-demo-answers-$OWNER_UID
# TMP: scratch dir for this run. ALT=1 once the alternate screen is in use.
# On exit: show the cursor (tput cnorm), leave the alternate screen
# (tput rmcup) and delete TMP.
TMP="$(mktemp -d)"
ALT=0
trap '((ALT)) && { tput cnorm; tput rmcup; } 2>/dev/null; rm -rf "$TMP"' EXIT

# ANSI styles: G green, Y yellow, R red, D dim grey, B bold, P pink (accent),
# N reset.
G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' D=$'\e[90m' B=$'\e[1m' P=$'\e[38;5;212m' N=$'\e[0m'

# --------------------------------------------------------------------------
# Screen model: every prompt redraws the whole screen in place —
#   header · TITLE · CTX (step content) · NOTE (one-shot warnings) · prompt
#   … and a status bar pinned to the bottom two rows (keys, then steps).
# Menus and text input are drawn here (not gum) so the status bar can be
# repainted on every keypress. pick/ask set a variable (no subshell).
# esc → return 1 (= back), ctrl+c → quit.
# --------------------------------------------------------------------------
# Global state, shared by every step:
#   TITLE CTX NOTE   page title, page body, one-shot warnings (see compose)
#   HEADER BODY OFF AVAIL  banner text, frozen body lines, scroll offset,
#                    body rows that fit on screen
#   PICK_PREVIEW     function pick() calls to draw a preview card ("" = none)
#   PREV             last preview card drawn
#   FORMAT_CMDS      commands run by the Disks tools (listed in the demo)
#   HOME_LABEL DATA_LABEL DATA_OLDLABEL  filesystem labels for /home and data
#   STEPS STEP_NAMES step functions in order and their status-bar names
#   SOURCE SRC_LABEL config source and its banner label
#   NIXUSER DESKTOP KERNEL UNFREE TZONE KEYMAP XKB SSH PKGS  answers with defaults
#   HOSTS            "host user" lines read from the config
#   CUR HUB_IDX REVIEW_IDX  current step, index of the hub menu and of Review
#   VISITED          steps answered at least once (hub mode)
#   PKGDESC PKGUNFREE KVER COST_*  package and kernel lookup caches
#   TTY              where keys are read from (/dev/null in tests)
TITLE=""; CTX=""; NOTE=""; HOST=""; PICK_PREVIEW=""; PREV=""; HEADER=""; BODY=(); OFF=0; AVAIL=10
# Window width, read only where the terminal is attached (inside $(…) or a piped
# loop `tput cols` can't see it and silently answers 80)
TERM_COLS=$(tput cols 2>/dev/null || echo 100); FORMAT_CMDS=()
HOME_LABEL=home; DATA_LABEL=data; DATA_OLDLABEL=""
STEPS=(step_source); STEP_NAMES=(Source)   # the rest is set by set_mode once the source is chosen
SOURCE=""; SRC_LABEL="guided install"
NIXUSER=""; DESKTOP=none; KERNEL=default; UNFREE=false; TZONE=UTC; KEYMAP=us; XKB=us; SSH=false; HOSTS=(); PKGS=()
CUR=0; HUB_IDX=1; REVIEW_IDX=0; declare -A VISITED=() PKGDESC=() PKGUNFREE=() KVER=(); COST_KEY=""; COST_LINE=""; COST_PATHS=()
TTY=/dev/tty; [[ -n ${INSTALL_TEST:-} ]] && TTY=/dev/null

# card COLOR "title" "status" line… — full-width framed card, same width as the header.
# Title and status sit in the top border; the frame colour carries the meaning.
# Arguments may contain newlines; each becomes its own row. Rows without
# colour codes that are too wide are cut with "…"; a long title is cut too.
#   COLOR      ANSI escape for the frame
#   title      left text in the top border ("" with no status = plain border)
#   status     right text in the top border ("" = none)
#   CARD_W     env: card width (default terminal width - 2, max 120)
#   CARD_HEAVY env: non-empty = thick frame in the accent colour (highlight)
# Alternative: box() for a neutral grey card.
#   Example    card $'\e[38;5;110m' "sda" "✓ healthy" "row one" "row two"
card() {
  local LC_ALL=C.UTF-8 fc=$1 title=$2 st=$3 a l plain fill bar wc cols; shift 3
  local tl='╭' tr='╮' bl='╰' br='╯' hz='─' vt='│'
  if [[ -n ${CARD_HEAVY:-} ]]; then tl='┏' tr='┓' bl='┗' br='┛' hz='━' vt='┃'; fc=$'\e[1;38;5;212m'; fi
  cols=$TERM_COLS; wc=${CARD_W:-$(( cols - 2 < 120 ? cols - 2 : 120 ))}
  local -a rows=(); for a; do mapfile -t -O "${#rows[@]}" rows <<<"$a"; done
  if [[ -z $title && -z $st ]]; then printf -v bar '%*s' $(( wc - 2 )) ''; printf '%s%s%s%s%s\n' "$fc" "$tl" "${bar// /$hz}" "$tr" "$N"
  else
    fill=$(( wc - 3 - ${#title} - 2 - ${#st} - 3 )); [[ -z $st ]] && fill=$(( wc - 3 - ${#title} - 2 ))
    if (( fill < 1 )); then title="${title:0:$(( ${#title} + fill - 2 ))}…"; fill=1; fi
    printf -v bar '%*s' "$fill" ''
    if [[ -n $st ]]; then printf '%s%s%s %s%s%s %s %s%s%s%s %s%s%s\n' "$fc" "$tl" "$hz" "$N$B" "$title" "$N$fc" "${bar// /$hz}" "$B" "$st" "$N" "$fc" "$hz" "$tr" "$N"
    else printf '%s%s%s %s%s%s %s%s%s\n' "$fc" "$tl" "$hz" "$N$B" "$title" "$N$fc" "${bar// /$hz}" "$tr" "$N"; fi
  fi
  for l in "${rows[@]}"; do
    plain=$(strip_ansi <<<"$l")
    if (( ${#plain} > wc - 4 )) && [[ $plain == "$l" ]]; then l="${l:0:$(( wc - 5 ))}…"; plain=$l; fi
    printf '%s%s%s %s%*s %s%s%s\n' "$fc" "$vt" "$N" "$l" "$(( wc - 4 - ${#plain} > 0 ? wc - 4 - ${#plain} : 0 ))" "" "$fc" "$vt" "$N"
  done
  printf -v bar '%*s' $(( wc - 2 )) ''; printf '%s%s%s%s%s' "$fc" "$bl" "${bar// /$hz}" "$br" "$N"
}
# strip_ansi — remove colour codes from stdin (to measure visible width).
#   Example  plain=$(strip_ansi <<<"$line")
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
# box [-t TITLE] line… — neutral grey card (card() with no status).
#   -t TITLE  title in the top border
#   Example   box -t "Filesystems" "ext4  simple" "xfs   big files"
box() { local t=""; [[ ${1:-} == -t ]] && { t=$2; shift 2; }; card $'\e[38;5;240m' "$t" "" "$@"; }
# panel TITLE [BODY] — set the page title and body for the next prompt.
#   Example  panel "Disks" "$table"
panel() { TITLE=$1; CTX=${2:-}; }
# warn TEXT… — queue a yellow ⚠ line, shown once under the page body.
#   Example  warn "invalid hostname"
# hsize BYTES — human size in SI units with one decimal (numfmt --to=si),
# e.g. 2000398934016 → 2.1T (numfmt rounds away from zero by default; set
# --round=nearest to change that). Alternative: --to=iec for powers of 1024.
warn() { NOTE+="${Y}⚠ $*${N}"$'\n'; }
hsize() { numfmt --to=si --format=%.1f "$1"; }

# compose — freeze the page body: copy CTX and then NOTE into BODY (one
# array item per line), clear NOTE so a warning shows only once, and reset
# the scroll offset. The argument (prompt height) is accepted but unused.
#   Example  compose 3
compose() {  # $1 = prompt height · freeze the page body; NOTE is shown once
  BODY=()
  [[ -n $CTX ]] && mapfile -t BODY <<<"$CTX"
  if [[ -n $NOTE ]]; then mapfile -t -O "${#BODY[@]}" BODY <<<"${NOTE%$'\n'}"; NOTE=""; fi
  OFF=0
}

# render PROMPT HINTS — header, title, a window of the body (PgUp/PgDn scrolls
# it when the page is taller than the terminal), the prompt, the status bar.
# Draws from the top-left corner and clears the rest of each line (\e[K) and
# the screen below (\e[J) instead of clearing the screen, so redraws don't
# flicker. Under INSTALL_TEST it prints everything plainly instead.
#   PROMPT  text under the body (menu or input line)
#   HINTS   key hints for the status bar
#   Example render "$body" "↑↓ move · enter select"
render() {
  local prompt=$1 hints=$2 rows n plines win i out
  if [[ -n ${INSTALL_TEST:-} ]]; then
    printf '%s\n\n%s\n' "$HEADER" "${B}${P}${TITLE}${N}"; ((${#BODY[@]})) && printf '%s\n' "${BODY[@]}"
    printf '\n%s\n' "$prompt"; footer "$hints"; return
  fi
  rows=$(tput lines 2>/dev/null || echo 50); n=${#BODY[@]}
  local c; c=$(tput cols 2>/dev/null) && TERM_COLS=$c
  plines=$(( $(printf '%s' "$prompt" | wc -l) + 1 ))
  AVAIL=$(( rows - $(wc -l <<<"$HEADER") - 3 - plines - 4 )); ((AVAIL < 3)) && AVAIL=3
  win=$AVAIL; (( n > AVAIL )) && win=$(( AVAIL - 1 ))   # one line for the "more" hint
  (( OFF > n - win )) && OFF=$(( n - win )); ((OFF < 0)) && OFF=0
  out="$HEADER"$'\n\n'"${B}${P}${TITLE}${N}"$'\n'
  for ((i = OFF; i < n && i < OFF + win; i++)); do out+="${BODY[i]}"$'\n'; done
  if (( n > win )); then
    out+="${D}$( ((OFF > 0)) && echo "▲" || echo " ")$( ((OFF + win < n)) && echo "▼" || echo " ") more · PgUp/PgDn scroll · lines $((OFF + 1))–$((OFF + win < n ? OFF + win : n)) of $n${N}"$'\n'
    hints+=" · PgUp/PgDn scroll"
  fi
  out+=$'\n'"$prompt"
  tput cup 0 0
  printf '%s' "${out//$'\n'/$'\e[K\n'}"; printf '\e[K\e[J'
  footer "$hints"
}
# scroll pgup|pgdn — move the body window by one screen minus 2 lines of
# overlap; render() clamps the far end.
#   Example  scroll "$KEY"
scroll() { case $1 in pgup) OFF=$(( OFF - AVAIL + 2 )) ;; pgdn) OFF=$(( OFF + AVAIL - 2 )) ;; esac; ((OFF < 0)) && OFF=0; return 0; }

# footer HINTS — the status bar on the last three rows: progress legend, key
# hints, then the step chain (● done, ◉ current, ○ next). In hub mode the
# legend reads "main menu" and the chain is hidden. Line wrap is turned off
# (\e[?7l) while drawing. Terminals of 12 rows or fewer, and tests, get the
# three lines printed in the flow instead.
#   Example  footer "↑↓ move · enter select"
footer() {  # pinned bottom rows: progress legend · key hints · step chain
  local i chain="" rows; rows=$(tput lines 2>/dev/null || echo 0)
  for i in "${!STEP_NAMES[@]}"; do
    ((i)) && chain+="${D} ─ ${N}"
    local d=0
    if ((HUB)); then
      if [[ ${STEPS[i]} == step_source || -n ${VISITED[${STEPS[i]}]:-} ]]; then d=1; fi
    elif ((i < CUR)); then d=1; fi
    if ((i == CUR)); then chain+="${B}${P}◉ ${STEP_NAMES[i]}${N}"
    elif ((d)); then chain+="${G}● ${STEP_NAMES[i]}${N}"
    else chain+="${D}○ ${STEP_NAMES[i]}${N}"; fi
  done
  local legend="${D}step $((CUR + 1))/${#STEP_NAMES[@]} · ${G}●${D} done ${P}◉${D} now ○ next${N}"
  if ((HUB)); then legend="${D}main menu${N}"; chain=""; fi
  local keys="${D}$1 · esc back · ctrl+c quit${N}"
  if [[ -z ${INSTALL_TEST:-} ]] && ((rows > 12)); then
    printf '\e[?7l'   # no autowrap: a long line on the last row must clip, not scroll the screen
    tput cup $((rows - 3)) 0; printf ' %s\e[K' "$legend"
    tput cup $((rows - 2)) 0; printf ' %s\e[K' "$keys"
    tput cup $((rows - 1)) 0; printf ' %s\e[K' "$chain"
    printf '\e[?7h'
  else printf ' %s\n %s\n %s\n' "$legend" "$keys" "$chain"; fi
}

# readkey — read one key from $TTY into KEY:
#   up down pgup pgdn  arrow and page keys (ESC [ A, ESC [ B, ESC [ 5 ~, ESC [ 6 ~)
#   enter              Return
#   back               a lone ESC (nothing follows within 0.05 s)
#   bs                 Backspace (DEL or ^H)
#   char:<c>           any other key
#   none               an escape sequence not listed above
# Exits the script when the terminal is gone, so input never auto-confirms.
#   Example  readkey; [[ $KEY == enter ]] && break
readkey() {
  local k rest
  IFS= read -rsn1 k <"$TTY" || exit 1   # terminal gone (e.g. SSH dropped): never auto-confirm
  case $k in
    '') KEY=enter ;;
    $'\e') if IFS= read -rsn2 -t 0.05 rest <"$TTY"; then
             case $rest in
               '[A') KEY=up ;; '[B') KEY=down ;;
               '[5') read -rsn1 -t 0.05 _ <"$TTY" || true; KEY=pgup ;;
               '[6') read -rsn1 -t 0.05 _ <"$TTY" || true; KEY=pgdn ;;
               *) KEY=none ;;
             esac
           else KEY=back; fi ;;
    $'\x7f'|$'\b') KEY=bs ;;
    *) KEY="char:$k" ;;
  esac
}

# pick VAR "question" "label|value"... — arrow-key menu; stores the chosen
# value in VAR (via printf -v, no subshell). Returns 1 on esc.
#   VAR          name of the variable to set
#   question     dim line above the options ("" = none)
#   label|value  one option: shown label, stored value. A label written as
#                "name   description" (2+ spaces) becomes two aligned
#                columns; long descriptions wrap under their column.
# Shows 12 options at a time; ↑↓ or k/j move, PgUp/PgDn scroll the page.
#   PICK_START   env: index to start on (reset after use)
#   PICK_PREVIEW env: function called as "$PICK_PREVIEW VALUE" with CARD_W
#                set; its card is drawn right of the list for the
#                highlighted option
# Under INSTALL_TEST it takes option TEST_IDX, or the one with value "go".
# Alternatives: yesno() for No/Yes, ask() for free text.
#   Example  pick FS "Filesystem" "btrfs  snapshots|btrfs" "ext4  simple|ext4" || return 1
pick() {
  local __v=$1 h=$2; shift 2
  local LC_ALL=C.UTF-8 labels=() values=() names=() descs=() o i sel=0 top body w=0 last=-1 pad
  local re='^([^ ]+( [^ ]+)*)  +(.*)$'   # "name   description" → two aligned columns
  for o; do labels+=("${o%%|*}"); values+=("${o##*|}"); done
  sel=${PICK_START:-0}; PICK_START=0; ((sel < ${#values[@]})) || sel=0
  for i in "${!labels[@]}"; do
    if [[ ${labels[i]} =~ $re ]]; then names[i]=${BASH_REMATCH[1]}; descs[i]=${BASH_REMATCH[3]}
    else names[i]=${labels[i]}; descs[i]=""; fi
    [[ -n ${descs[i]} ]] && (( ${#names[i]} > w )) && w=${#names[i]}
  done
  if [[ -n ${INSTALL_TEST:-} ]]; then   # tests: take option $TEST_IDX, but always "Install" on review
    sel=${TEST_IDX:-0}; ((sel < ${#values[@]})) || sel=0
    for i in "${!values[@]}"; do [[ ${values[i]} == go ]] && sel=$i; done
  fi
  compose $(( (${#labels[@]} < 12 ? ${#labels[@]} : 12) + 2 ))
  while :; do
    top=$(( sel > 11 ? sel - 11 : 0 )); body=""
    [[ -n $h ]] && body+="${D}$h${N}"$'\n'
    local -a LL=() LW=()
    for ((i = top; i < ${#labels[@]} && i < top + 12; i++)); do
      pad=""; [[ -n ${descs[i]} ]] && printf -v pad '%*s' $(( w - ${#names[i]} + 3 )) ''
      # long descriptions wrap onto lines aligned under the description column
      local dw=$(( (TERM_COLS - 2 < 120 ? TERM_COLS - 2 : 120) - w - 5 )) dl ind="" first
      local -a DLINES=("${descs[i]}")
      if [[ -z ${PICK_PREVIEW:-} ]] && (( dw > 15 && ${#descs[i]} > dw )); then
        mapfile -t DLINES < <(printf '%s\n' "${descs[i]}" | fold -s -w "$dw" | sed 's/ *$//')
        printf -v ind '%*s' $(( w + 5 )) ''
      fi
      first="${DLINES[0]}"
      if ((i == sel)); then dl="${B}${P}> ${names[i]}${pad}${first}"; for x in "${DLINES[@]:1}"; do dl+=$'\n'"${ind}${x}"; done; LL+=("${dl}${N}")
      else dl="  ${names[i]}${pad}${D}${first}"; for x in "${DLINES[@]:1}"; do dl+=$'\n'"${ind}${x}"; done; LL+=("${dl}${N}"); fi
      LW+=($(( 2 + ${#names[i]} + ${#pad} + ${#descs[i]} )))
    done
    if [[ -n ${PICK_PREVIEW:-} ]]; then   # list on the left, preview card on the right
      local lw=0 x; for x in "${LW[@]}"; do (( x > lw )) && lw=$x; done
      local tw=$(( TERM_COLS - 2 < 120 ? TERM_COLS - 2 : 120 ))
      if (( sel != last )); then PREV=$(CARD_W=$(( tw - lw - 3 )) "$PICK_PREVIEW" "${values[sel]}"); last=$sel; fi
      local -a CL; mapfile -t CL <<<"$PREV"
      local rowsn=$(( ${#LL[@]} > ${#CL[@]} ? ${#LL[@]} : ${#CL[@]} ))
      for ((i = 0; i < rowsn; i++)); do
        printf -v pad '%*s' $(( lw - ${LW[i]:-0} + 3 )) ''
        body+="${LL[i]:-}${pad}${CL[i]:-}"$'\n'
      done
    else
      for i in "${!LL[@]}"; do body+="${LL[i]}"$'\n'; done
    fi
    render "$body" "↑↓ move · enter select"
    [[ -n ${INSTALL_TEST:-} ]] && break
    readkey
    case $KEY in
      up)   ((sel > 0)) && sel=$((sel - 1)) ;;
      down) ((sel < ${#labels[@]} - 1)) && sel=$((sel + 1)) ;;
      char:k) ((sel > 0)) && sel=$((sel - 1)) ;;
      char:j) ((sel < ${#labels[@]} - 1)) && sel=$((sel + 1)) ;;
      pgup|pgdn) scroll "$KEY" ;;
      enter) break ;;
      back) return 1 ;;
    esac
  done
  printf -v "$__v" '%s' "${values[sel]}"
}

# ask VAR [--header H] [--placeholder P] [--value V] [--max N] — one-line
# text input; stores the text in VAR. Returns 1 on esc.
#   --header H       dim line above the input
#   --placeholder P  grey hint shown while empty (tests use it as the answer)
#   --value V        starting text
#   --max N          character limit, shown as a counter (0 = none)
# Backspace deletes the last character; there is no cursor movement.
# Alternative: pick() when the answer comes from a fixed list.
#   Example  ask HOST --header "Hostname" --placeholder "e.g. Ryzen7700x" || return 1
ask() {
  local __v=$1 h="" ph="" val="" max=0; shift
  while (($#)); do case $1 in --header) h=$2 ;; --placeholder) ph=$2 ;; --value) val=$2 ;; --max) max=$2 ;; esac; shift 2; done
  [[ -n ${INSTALL_TEST:-} && -z $val ]] && val=$ph
  compose 3
  while :; do
    local shown="$val${P}▏${N}"; [[ -z $val ]] && shown="${P}▏${N}${D}$ph${N}"
    ((max)) && shown+="   ${D}${#val}/$max${N}"
    render "${h:+${D}$h${N}$'\n'}${B}${P}> ${N}$shown"$'\n' "type · enter confirm"
    [[ -n ${INSTALL_TEST:-} ]] && break
    readkey
    case $KEY in
      pgup|pgdn) scroll "$KEY" ;;
      enter) break ;;
      back) return 1 ;;
      bs) val=${val%?} ;;
      char:*) if ((max == 0 || ${#val} < max)); then val+=${KEY#char:}; fi ;;
    esac
  done
  printf -v "$__v" '%s' "$val"
}

# yesno "question" — No/Yes menu; returns 0 for Yes, 1 for No or esc.
# No is the default (first).
#   Example  yesno "Format sdb?" || return 1
yesno() { local a; pick a "$1" "No|n" "Yes|y" || return 1; [[ $a == y ]]; }

# --------------------------------------------------------------------------
# Hardware detection (sysfs only — works on the bare ISO)
# --------------------------------------------------------------------------
# detect_hw — fill the hardware facts shown in the banner and host cards:
#   FW       uefi when /sys/firmware/efi exists, else bios
#   RAM_B    total memory in bytes (/proc/meminfo)
#   NET      ✓ when nixos.org answers one ping within 2 s
#   HW_CPU   AMD | Intel | other (vendor_id in /proc/cpuinfo)
#   HW_GPU   vendors of PCI display devices (class 0x03…), joined with "+"
#            (e.g. Intel+NVIDIA = hybrid), or "none"
#   HW_FORM  "virtual machine" (systemd-detect-virt), laptop (a battery in
#            /sys/class/power_supply) or desktop
#   HW_WIFI  1 when any network interface is wireless
#   Example  detect_hw; echo "$HW_CPU $HW_GPU"
detect_hw() {
  [[ -d /sys/firmware/efi ]] && FW=uefi || FW=bios
  RAM_B=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
  ping -c1 -W2 nixos.org >/dev/null 2>&1 && NET="✓" || NET="✗ (would launch nmtui)"
  case $(grep -m1 vendor_id /proc/cpuinfo) in *AMD*) HW_CPU=AMD ;; *Intel*) HW_CPU=Intel ;; *) HW_CPU=other ;; esac
  local d gpus=() virt
  for d in /sys/bus/pci/devices/*; do
    [[ $(<"$d/class") == 0x03* ]] || continue
    case $(<"$d/vendor") in 0x1002) gpus+=(AMD) ;; 0x10de) gpus+=(NVIDIA) ;; 0x8086) gpus+=(Intel) ;; *) gpus+=(other) ;; esac
  done
  HW_GPU=$(printf '%s\n' "${gpus[@]:-none}" | sort -u | paste -sd+)
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -n $virt && $virt != none ]]; then HW_FORM="virtual machine"
  elif ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then HW_FORM=laptop
  else HW_FORM=desktop; fi
  HW_WIFI=0; if ls -d /sys/class/net/*/wireless >/dev/null 2>&1; then HW_WIFI=1; fi
}

# --------------------------------------------------------------------------
# Disks — real (lsblk + smartctl) or fake; both normalised to:
# [{name,size,model,serial,tran,rm,rota,segs:[{fs,label,size,uuid}],smart,parts,os,uuid}]
# --------------------------------------------------------------------------
# real_disks — JSON list of this machine's disks from lsblk, partitions as
# segs. lsblk options: -J JSON, -b sizes in bytes, -o the columns to print.
# zram, loop and optical (sr) devices are skipped. Missing model/transport
# become "?", a missing serial becomes the device name.
#   Example  real_disks | norm
real_disks() {
  lsblk -J -b -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,ROTA,TYPE,FSTYPE,LABEL,UUID | jq '
    [.blockdevices[] | select(.type=="disk" and (.name|test("^(zram|loop|sr)")|not)) |
     {name, size, model:(.model//"?"), serial:(.serial//.name), tran:(.tran//"?"), rm, rota,
      segs:[.children[]? | {name, fs:(.fstype//"raw"), label, size, uuid}]}]'
}

# smart_real DISK → JSON with the raw SMART facts (verdict is derived in norm)
# smartctl options: -j JSON output, -a all SMART information. Keys:
#   passed hours temp      overall self-assessment, power-on hours, °C
#   realloc pending uncorrect  ATA attributes 5, 197, 198 (bad sectors)
#   media crit wear spare  NVMe media errors, critical warning, % used,
#                          % spare left
#   rot                    rotation rate (0 = SSD)
# Without root, or with no SMART data, it prints {"err": "<reason>"}.
#   Example  smart_real sda
smart_real() {
  local j=""
  [[ $EUID == 0 ]] || { echo '{"err":"needs sudo"}'; return; }
  j=$(smartctl -j -a "/dev/$1" 2>/dev/null | jq -c '
    def attr($id): [.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value][0];
    (.nvme_smart_health_information_log // {}) as $n
    | {passed: .smart_status.passed, hours: .power_on_time.hours, temp: .temperature.current,
       realloc: attr(5), pending: attr(197), uncorrect: attr(198),
       media: $n.media_errors, crit: $n.critical_warning, wear: $n.percentage_used, spare: $n.available_spare,
       rot: .rotation_rate}
    | if .passed == null and .hours == null then {err: "no SMART data"} else . end' 2>/dev/null || true)
  # (not ${j:-{…}} — bash would end that expansion at the first "}" inside the JSON)
  [[ -n $j ]] || j='{"err":"no SMART data"}'
  echo "$j"
}

# fake_disks SCENARIO — JSON for a simulated machine (demo only), already in
# real_disks' shape plus a "smartd" health block; every scenario also has a
# USB boot stick (sdz):
#   2-equal  two identical 2 TB NVMe drives (mirror candidates)
#   3-mixed  NVMe + three SATA disks, one with bad sectors, one holding data
#   4-hdd    small NVMe + four 4 TB HDDs, one failing (raidz candidates)
#   windows  a previous NixOS disk, a Windows disk and an xfs games disk
# Any other name exits 1.
#   Example  fake_disks 3-mixed | norm
fake_disks() {
  local stick='{"name":"sdz","size":8004304896,"model":"SanDisk Ultra (boot USB)","serial":"4C530001","tran":"usb","rm":true,"rota":false,"smartd":{"err":"USB stick"},"segs":[{"fs":"iso9660","label":"nixos-minimal","size":1600000000}]}'
  case "$1" in
    2-equal) cat <<EOF
[{"name":"nvme0n1","size":2000398934016,"model":"Samsung 990 PRO 2TB","serial":"S6B2NS0W100001","tran":"nvme","rm":false,"rota":false,"smartd":{"passed":true,"hours":1204,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},
 {"name":"nvme1n1","size":2000398934016,"model":"Samsung 990 PRO 2TB","serial":"S6B2NS0W100002","tran":"nvme","rm":false,"rota":false,"smartd":{"passed":true,"hours":1198,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},$stick]
EOF
    ;;
    3-mixed) cat <<EOF
[{"name":"nvme0n1","size":1000204886016,"model":"WD SN850X 1TB","serial":"23170D800001","tran":"nvme","rm":false,"rota":false,"smartd":{"passed":true,"hours":3310,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},
 {"name":"sda","size":4000787030016,"model":"WD Red Plus 4TB","serial":"WD-WX12D0000001","tran":"sata","rm":false,"rota":true,"smartd":{"passed":true,"hours":21877,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[{"fs":"btrfs","label":"data","size":4000785960960,"uuid":"3f1c9a2e-5b7d-4c1e-9f0a-2d6e8b4c7a10"}]},
 {"name":"sdb","size":2000398934016,"model":"Seagate IronWolf 2TB","serial":"ZFL0000002","tran":"sata","rm":false,"rota":true,"smartd":{"passed":true,"hours":30210,"temp":41,"realloc":40,"pending":8,"uncorrect":0},"segs":[]},
 {"name":"sdc","size":1000204886016,"model":"Crucial MX500 1TB","serial":"2149E5000003","tran":"sata","rm":false,"rota":false,"smartd":{"passed":true,"hours":9021,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},$stick]
EOF
    ;;
    4-hdd) cat <<EOF
[{"name":"nvme0n1","size":500107862016,"model":"WD SN770 500GB","serial":"22451F800001","tran":"nvme","rm":false,"rota":false,"smartd":{"passed":true,"hours":820,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},
 {"name":"sda","size":4000787030016,"model":"WD Red Plus 4TB","serial":"WD-WX12D0000011","tran":"sata","rm":false,"rota":true,"smartd":{"passed":true,"hours":15002,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},
 {"name":"sdb","size":4000787030016,"model":"WD Red Plus 4TB","serial":"WD-WX12D0000012","tran":"sata","rm":false,"rota":true,"smartd":{"passed":true,"hours":15010,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},
 {"name":"sdc","size":4000787030016,"model":"WD Red Plus 4TB","serial":"WD-WX12D0000013","tran":"sata","rm":false,"rota":true,"smartd":{"passed":true,"hours":14998,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[]},
 {"name":"sdd","size":4000787030016,"model":"WD Red Plus 4TB","serial":"WD-WX12D0000014","tran":"sata","rm":false,"rota":true,"smartd":{"passed":false,"hours":41022,"temp":47,"realloc":2104,"pending":312,"uncorrect":57},"segs":[]},$stick]
EOF
    ;;
    windows) cat <<EOF
[{"name":"nvme0n1","size":2000398934016,"model":"Samsung 990 PRO 2TB","serial":"S6B2NS0W100021","tran":"nvme","rm":false,"rota":false,"smartd":{"passed":true,"hours":4120,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[{"fs":"vfat","label":"EFI","size":536870912},{"fs":"btrfs","label":"nixos","size":1999860000000,"uuid":"7f13c8ae-3795-4d20-a739-d72f40091859"}]},
 {"name":"nvme1n1","size":1000204886016,"model":"WD SN850X 1TB","serial":"23170D800022","tran":"nvme","rm":false,"rota":false,"smartd":{"passed":true,"hours":2210,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[{"fs":"vfat","label":null,"size":104857600},{"fs":"ntfs","label":"Windows","size":1000000000000,"uuid":"6A1C2D3E4F5A6B7C"}]},
 {"name":"sda","size":4000787030016,"model":"WD Red Plus 4TB","serial":"WD-WX12D0000023","tran":"sata","rm":false,"rota":true,"smartd":{"passed":true,"hours":18000,"temp":36,"realloc":0,"pending":0,"uncorrect":0},"segs":[{"fs":"xfs","label":"Games","size":4000785960960,"uuid":"a374ae2d-efab-4e1a-8af8-fe25861a9585"}]},$stick]
EOF
    ;;
    *) echo "unknown scenario: $1" >&2; exit 1 ;;
  esac
}

# norm — normalise a disk list (stdin JSON → stdout JSON). Adds per disk:
#   segs[].dev  partition device (nvme/mmcblk get a "p": nvme0n1p2)
#   parts       summary like: vfat, btrfs "nixos"
#   uuid curlabel datadev  UUID, label and device of the first non-vfat
#               partition (the one a "keep data" disk mounts)
#   smart       "level|text" verdict from smartd, level = ok | warn | fail | ?
#               fail: self-test failed or NVMe critical warning
#               warn: bad sectors, NVMe media errors, or ≥ 80 % worn
#               ok:   shows the power-on age and temperature
#   os          nixos (label nixos or nixos-luks), windows (ntfs), macos
#               (apfs), linux (ext4/btrfs/xfs next to an EFI vfat), or ""
#   Example  DISKS=$(real_disks | norm)
norm() {
  jq 'def age: if . < 720 then "\(.) h" elif . < 8766 then "\(. / 730 | floor) months" else ((. / 876.6 | floor) / 10 | tostring | if contains(".") then . else . + ".0" end) + " yrs" end;
    [.[] | ([.segs[]?.label]) as $l | ([.segs[]?.fs]) as $f | . + {
    segs: (.name as $d | [.segs // [] | to_entries[] | .value + {dev: (.value.dev // .value.name
             // ($d + (if ($d|test("^(nvme|mmcblk)")) then "p" else "" end) + ((.key + 1)|tostring)))}]),
    parts: ([.segs[]? | .fs + (if (.label//"") != "" then " \"" + .label + "\"" else "" end)] | join(", ")),
    uuid:  ([.segs[]? | select(.fs != "vfat") | .uuid // empty][0] // null),
    curlabel: ([.segs[]? | select(.fs != "vfat") | .label // empty][0] // ""),
    datadev: (.name as $d | [.segs // [] | to_entries[] | select(.value.fs != "vfat")][0] as $e
              | if $e == null then null else ($e.value.name // ($d + (if ($d|test("^(nvme|mmcblk)")) then "p" else "" end) + (($e.key + 1)|tostring))) end),
    smart: ((.smartd // {err: "needs sudo"}) as $d
      | (($d.realloc // 0) + ($d.pending // 0) + ($d.uncorrect // 0)) as $bad
      | (if $d.temp then " · \($d.temp)°C" else "" end) as $t
      | if $d.err then "?|\($d.err)"
        elif $d.passed == false or ($d.crit // 0) > 0 then "fail|FAILING · \(if $bad > 0 then "\($bad) bad sectors" else "self-test failed" end)"
        elif $bad > 0 then "warn|watch · \($bad) bad sectors"
        elif ($d.media // 0) > 0 then "warn|watch · \($d.media) media errors"
        elif ($d.wear // 0) >= 80 then "warn|watch · \($d.wear)% worn"
        else "ok|healthy · \(($d.hours // 0) | age)\($t)" end),
    os: (if ($l|index("nixos")) or ($l|index("nixos-luks")) then "nixos"
         elif ($f|index("ntfs")) then "windows"
         elif ($f|index("apfs")) then "macos"
         elif ($f|map(select(.=="ext4" or .=="btrfs" or .=="xfs"))|length) > 0 and ($f|index("vfat")) then "linux"
         else "" end)}]'
}

# health "level|text" — the smart verdict as a coloured ✓ / ⚠ / ✗ / ? line.
#   Example  health "$(disk sda .smart)"
health() {
  case ${1%%|*} in
    ok) echo "${G}✓ ${1#*|}${N}" ;; warn) echo "${Y}⚠ ${1#*|}${N}" ;;
    fail) echo "${R}✗ ${1#*|}${N}" ;; *) echo "${D}? ${1#*|}${N}" ;;
  esac
}

# fmt_seg DEV LABEL FS BYTES — one partition, fixed 43 columns:
# dev · label · filesystem · size. Long fields are cut; an empty label shows "-".
# SEG_HEAD is the matching column header; SEG_JQ is the jq filter that turns
# a disk's segs into DEV␟LABEL␟FS␟SIZE␟PURPOSE lines (␟ = \x1f).
#   Example  fmt_seg nvme0n1p2 nixos btrfs 999000000000
fmt_seg() { printf '%-10.10s %-12.12s %-11.11s %7s' "$1" "${2:--}" "$3" "$(hsize "$4")"; }
SEG_HEAD=$(printf '%-10s %-12s %-11s %7s' PARTITION LABEL FILESYSTEM SIZE)
SEG_JQ='.segs[] | [.dev, (.label // ""), .fs, (.size|tostring), (.purpose // "")] | join("\u001f")'

# disk_table <json> [after-json] — each disk: header line, then its partitions as a tree.
# With after-json (Review): NOW → AFTER INSTALL side by side, plus what each partition is for.
#   json        normalised disk list (see norm)
#   after-json  planned layout: per disk .action (status text), .same (true =
#               unchanged) and .segs with .purpose
# Without after-json each disk is a card() framed by health: red failing,
# orange worn, blue another OS, grey otherwise.
#   Example  disk_table "$DISKS"
disk_table() {
  local before=$1 after=${2:-} n s t m h o note status i d l f z u tree same card_seen=""
  local -a LS RS
  if [[ -z $after ]]; then echo "     ${D}$SEG_HEAD${N}"; else echo "            ${D}$SEG_HEAD   USED FOR${N}"; fi
  while IFS=$'\x1f' read -r n s t m h o; do
    mapfile -t LS < <(jq -r --arg n "$n" ".[] | select(.name==\$n) | $SEG_JQ" <<<"$before")
    if [[ -z $after ]]; then   # Disks screen: one card per disk, frame coloured by health / other OS
      local fc st title rows=()
      case ${h%%|*} in
        fail) fc=$'\e[38;5;203m'; st="✗ ${h#*|}" ;;
        warn) fc=$'\e[38;5;214m'; st="⚠ ${h#*|}" ;;
        ok)   fc=$'\e[38;5;242m'; st="✓ ${h#*|}" ;;
        *)    fc=$'\e[38;5;242m'; st="? ${h#*|}" ;;
      esac
      title="$n · $(hsize "$s") ${t^^} · $m"
      case $o in
        windows|macos|linux) title+=" · other OS: $o"; [[ ${h%%|*} == fail ]] || fc=$'\e[38;5;117m' ;;
        nixos) title+=" · previous NixOS" ;;
      esac
      (( ${#LS[@]} )) || rows+=("  ${D}(empty — no partitions)${N}")
      for i in "${!LS[@]}"; do
        IFS=$'\x1f' read -r d l f z u <<<"${LS[i]}"; tree="├"; ((i == ${#LS[@]} - 1)) && tree="└"
        rows+=(" $tree $(fmt_seg "$d" "$l" "$f" "$z")")
      done
      card "$fc" "$title" "$st" "${rows[@]}"; echo
      continue
    fi
    # Review: one card per disk — now, then after (fits ~80 columns)
    status=$(jq -r --arg n "$n" '.[] | select(.name==$n) | .action' <<<"$after")
    same=$(jq -r --arg n "$n" '.[] | select(.name==$n) | .same' <<<"$after")
    mapfile -t RS < <(jq -r --arg n "$n" ".[] | select(.name==\$n) | $SEG_JQ" <<<"$after")
    local warnh=""; [[ ${h%%|*} == warn || ${h%%|*} == fail ]] && warnh="  $(health "$h")"
    [[ -n ${card_seen:-} ]] && echo; card_seen=1
    printf "${B}%s${N} · %s %s · %.34s%s   %s\n" "$n" "$(hsize "$s")" "${t^^}" "$m" "$warnh" "$status"
    if [[ $same == true ]]; then
      if (( ${#LS[@]} == 0 )); then echo "          ${D}(empty — unchanged)${N}"; fi
      for i in "${!LS[@]}"; do
        IFS=$'\x1f' read -r d l f z u <<<"${LS[i]}"
        tree="├"; ((i == ${#LS[@]} - 1)) && tree="└"
        printf "          %s %s   ${D}%s${N}\n" "$tree" "$(fmt_seg "$d" "$l" "$f" "$z")" "$( ((i == 0)) && echo "(unchanged)" || true)"
      done
      continue
    fi
    if (( ${#LS[@]} == 0 )); then echo "   ${D}now      (empty — no partitions)${N}"; fi
    for i in "${!LS[@]}"; do
      IFS=$'\x1f' read -r d l f z u <<<"${LS[i]}"
      tree="├"; ((i == ${#LS[@]} - 1)) && tree="└"
      printf "   ${D}%-6s${N} %s ${D}%s${N}\n" "$( ((i == 0)) && echo now || true)" "$tree" "$(fmt_seg "$d" "$l" "$f" "$z")"
    done
    for i in "${!RS[@]}"; do
      IFS=$'\x1f' read -r d l f z u <<<"${RS[i]}"
      tree="├"; ((i == ${#RS[@]} - 1)) && tree="└"
      printf "   ${B}%-6s${N} %s %s   ${G}%s${N}\n" "$( ((i == 0)) && echo after || true)" "$tree" "$(fmt_seg "$d" "$l" "$f" "$z")" "$u"
    done
  done < <(jq -r '.[] | [.name, .size, .tran, .model, .smart, .os] | map(tostring) | join("\u001f")' <<<"$before")
}

# Small lookups on the current disk list ($DISKS):
#   disk NAME FIELD   one field, e.g. disk sda .model ("" when null)
#   uid_of USER       the user's UID from the config's modules/users/uids.nix
#                     (prints nothing when that file does not exist)
#   part DISK N       partition N's device path: part nvme0n1 2 → /dev/nvme0n1p2
#   is_foreign DISK   true when the disk holds Windows, macOS or another Linux
disk() { jq -r --arg n "$1" ".[] | select(.name==\$n) | $2 // \"\"" <<<"$DISKS"; }
uid_of() { [[ -f $REPO/modules/users/uids.nix ]] || return 0; awk -v u="$1" '$1 == u { gsub(/;/, "", $3); print $3 }' "$REPO/modules/users/uids.nix"; }
part() { [[ $1 == nvme* || $1 == mmcblk* ]] && echo "/dev/${1}p$2" || echo "/dev/$1$2"; }
is_foreign() { [[ $(disk "$1" .os) =~ ^(windows|macos|linux)$ ]]; }

# health_ok DISK — refuse failing disks unless confirmed; just warn on worn ones.
# Returns 1 when a failing disk is not confirmed.
#   Example  health_ok sdb || return 0
health_ok() {
  local s; s=$(disk "$1" .smart)
  case ${s%%|*} in
    fail) warn "$1: ${s#*|} — data on this disk is at risk"
          yesno "Use $1 anyway?" ;;
    warn) warn "$1: ${s#*|} — usable, but keep an eye on it"; return 0 ;;
    *)    return 0 ;;
  esac
}

# confirm_wipe_foreign DISK — before wiping a disk with another OS, the user
# must type the disk's model exactly. Returns 1 on esc or a mismatch.
#   Example  confirm_wipe_foreign nvme1n1 || return 1
confirm_wipe_foreign() {
  local model typed keep=$CTX; model=$(disk "$1" .model)
  CTX="$keep"$'\n'"$(box -t "Wipe & reuse $1" "$1 has another OS ($(disk "$1" .os)). To reuse it, type its model exactly:" "$model")"
  ask typed --placeholder "$model" || { CTX=$keep; return 1; }
  CTX=$keep
  [[ $typed == "$model" ]] || { warn "model didn't match — keeping $1 untouched"; return 1; }
}

# --------------------------------------------------------------------------
# Labels — the name a file manager shows. Limits are per filesystem.
# --------------------------------------------------------------------------
# label_max FS — longest label the installer allows: xfs 12, ext4 16, vfat 11,
# exfat 11, anything else 32 (btrfs and ntfs allow more; 32 is the cap here).
#   Example  label_max xfs   # → 12
label_max() { case $1 in xfs) echo 12 ;; ext4) echo 16 ;; vfat) echo 11 ;; exfat) echo 11 ;; *) echo 32 ;; esac; }
# relabel_cmd FS DEV LABEL — print the command that renames a filesystem
# label in place without touching data: xfs_admin -L, btrfs filesystem
# label, e2label, fatlabel, ntfslabel or exfatlabel. Other filesystems get a
# "# relabel not supported" comment line.
#   Example  relabel_cmd ext4 sdb1 games   # → e2label /dev/sdb1 games
relabel_cmd() {  # fs dev label
  case $1 in
    xfs) echo "xfs_admin -L $3 /dev/$2" ;; btrfs) echo "btrfs filesystem label /dev/$2 $3" ;;
    ext4) echo "e2label /dev/$2 $3" ;; vfat) echo "fatlabel /dev/$2 $3" ;;
    ntfs) echo "ntfslabel /dev/$2 $3" ;; exfat) echo "exfatlabel /dev/$2 $3" ;;
    *) echo "# relabel not supported for $1" ;;
  esac
}
# mkfs_cmd FS DEV LABEL — print the command that formats DEV with LABEL.
# Options: -L / -n label; -f (xfs, btrfs) and -F (ext4) force over an
# existing filesystem; mkfs.fat -F32 picks FAT32; mkfs.ntfs -f is a quick
# format (no zeroing).
#   Example  mkfs_cmd xfs sdb1 games   # → mkfs.xfs -f -L games /dev/sdb1
mkfs_cmd() {  # fs dev label
  case $1 in
    vfat) echo "mkfs.fat -F32 -n $3 /dev/$2" ;; ntfs) echo "mkfs.ntfs -f -L $3 /dev/$2" ;;
    xfs|btrfs) echo "mkfs.$1 -f -L $3 /dev/$2" ;; ext4) echo "mkfs.ext4 -F -L $3 /dev/$2" ;; *) echo "mkfs.$1 -L $3 /dev/$2" ;;
  esac
}

# ask_label VAR fs default — validated, vfat forced to UPPERCASE
# Asks until the label uses only letters, digits, . _ - and fits label_max.
# For zfs the prompt reads "Pool name". Returns 1 on esc.
#   Example  ask_label lbl ext4 data || return 1
ask_label() {
  local __lv=$1 fs=$2 def=$3 max __lbl what="Label (name shown in the file manager)"
  [[ $fs == zfs ]] && what="Pool name"
  max=$(label_max "$fs")
  while :; do
    ask __lbl --header "$what · $fs: max $max characters · letters, digits, . _ -" --value "$def" --max "$max" || return 1
    [[ $fs == vfat ]] && __lbl=${__lbl^^}
    if [[ ! $__lbl =~ ^[A-Za-z0-9._-]+$ ]]; then warn "use letters, digits, . _ - only (no spaces)"; continue; fi
    break
  done
  printf -v "$__lv" '%s' "$__lbl"
}

# Disk tool: format any disk right now, then return to the Disks screen.
# Real installer runs the commands immediately; the demo only updates its view.
# Steps: pick a disk, a filesystem and a label, confirm (or type the model
# for another OS's disk), then wipefs -a + one GPT partition over the whole
# disk (parted -s mklabel gpt mkpart data 1MiB 100%) + mkfs. A disk with
# mounted partitions is refused. ALL, VISIBLE and DISKS are updated to the
# new layout. Returns 1 on esc or refusal.
#   Example  format_tool || true
format_tool() {
  local n fs lbl dopts=() keep=$CTX
  TITLE="Disks · format a disk"
  for n in "${NAMES[@]}"; do dopts+=("$(printf '%-9s %-7s %-28.28s %s' "$n" "$(hsize "$(disk "$n" .size)")" "$(disk "$n" .model)" "$(disk "$n" .parts)")|$n"); done
  pick n "Which disk? (esc = cancel)" "${dopts[@]}" || return 1
  CTX="$keep"$'\n'"$(box -t "Filesystems" \
    "ext4   Linux. Simple and very reliable." \
    "xfs    Linux. Great for big files (games, media). Cannot shrink." \
    "btrfs  Linux. Snapshots + compression." \
    "exfat  Shared with Windows/macOS. Big files OK. Best for drives you move around." \
    "ntfs   Windows' own filesystem. Linux reads/writes it (ntfs3)." \
    "vfat   FAT32 — works everywhere, but 4G max file size.")"
  pick fs "Format $n as…" "ext4|ext4" "xfs|xfs" "btrfs|btrfs" "exfat|exfat" "ntfs|ntfs" "vfat (FAT32)|vfat" || { CTX=$keep; return 1; }
  ask_label lbl "$fs" "$(disk "$n" .curlabel | tr -cd 'A-Za-z0-9._-' | cut -c1-"$(label_max "$fs")")" || { CTX=$keep; return 1; }
  [[ -z $lbl ]] && lbl=data
  CTX=$keep
  if is_foreign "$n"; then confirm_wipe_foreign "$n" || return 1
  else yesno "Format $n as $fs \"$lbl\"? Everything on it is ERASED. (demo: simulated)" || return 1; fi
  local p; p=$(part "$n" 1); p=${p#/dev/}
  FORMAT_CMDS+=("wipefs -a /dev/$n && parted -s /dev/$n -- mklabel gpt mkpart data 1MiB 100%" "udevadm settle" "$(mkfs_cmd "$fs" "$p" "$lbl")")
  if [[ -z $DEMO ]]; then
    if disk_busy "$n"; then warn "$n has mounted partitions — not formatting it"; return 1; fi
    run_now "wipefs -a /dev/$n && parted -s /dev/$n -- mklabel gpt mkpart data 1MiB 100%" "udevadm settle" "$(mkfs_cmd "$fs" "$p" "$lbl")" || return 1
  fi
  local seg; seg=$(jq -nc --arg p "$p" --arg fs "$fs" --arg l "$lbl" --argjson s "$(disk "$n" .size)" --arg u "$(cat /proc/sys/kernel/random/uuid)" \
    '[{name:$p, fs:$fs, label:$l, size:($s - 1048576), uuid:$u}]')
  local j; for j in ALL VISIBLE DISKS; do
    printf -v "$j" '%s' "$(jq --arg n "$n" --argjson g "$seg" '(.[] | select(.name==$n)).segs = $g' <<<"${!j}" | norm)"
  done
  NOTE+="${G}✓ $n formatted as $fs \"$lbl\"${N} ${D}$([[ -n $DEMO ]] && echo "(demo: simulated)" || echo "(done)")${N}"$'\n'
}

# Disk tool: SMART health per disk, every value explained
# One card per disk: self-test, power-on time, temperature (SSD and HDD
# limits differ), bad sectors, and for NVMe wear, media errors and spare.
#   Example  health_view || true
health_view() {
  local n out="" fc st d v
  out=$(box -t "What is SMART?" \
    "Every disk keeps its own health log (SMART). The installer reads it so a dying disk never" \
    "ends up holding your system or half of a mirror." \
    "" \
    "${G}✓ healthy${N}   nothing worrying" \
    "${Y}⚠ watch${N}     early damage — still usable, but keep backups and don't mirror onto it" \
    "${R}✗ FAILING${N}   replace it — never install on it" \
    "${D}? unknown${N}   no data: needs sudo, or the device has no SMART (USB stick, VM disk)")
  for n in "${NAMES[@]}"; do
    d=$(jq -c --arg n "$n" '.[] | select(.name==$n) | (.smartd // {err: "needs sudo"}) + {ssd: (.rota | not)}' <<<"$DISKS")
    v=$(disk "$n" .smart)
    case ${v%%|*} in ok) fc=$'\e[38;5;114m' ;; warn) fc=$'\e[38;5;214m' ;; fail) fc=$'\e[38;5;203m' ;; *) fc=$'\e[38;5;242m' ;; esac
    st=$(health "$v" | strip_ansi)
    if [[ $(jq -r '.err // ""' <<<"$d") != "" ]]; then
      out+=$'\n'$(card "$fc" "$n · $(disk "$n" .model)" "$st" \
        "No health data: $(jq -r .err <<<"$d")$([[ $(jq -r .err <<<"$d") == "needs sudo" ]] && echo " — restart the demo with sudo to read it" || true)")
      continue
    fi
    out+=$'\n'$(card "$fc" "$n · $(hsize "$(disk "$n" .size)") · $(disk "$n" .model)" "$st" "$(jq -r '
      def age: if . < 720 then "\(.) h" elif . < 8766 then "\(. / 730 | floor) months" else ((. / 876.6 | floor) / 10 | tostring | if contains(".") then . else . + ".0" end) + " yrs" end;
      def row($k; $v; $why): ($k + "                ")[0:16] + ($v + "                    ")[0:20] + $why;
      [ row("Self-test"; (if .passed == true then "PASSED" elif .passed == false then "FAILED" else "-" end); "the disk'"'"'s own overall verdict"),
        row("Powered on"; (if .hours then "\(.hours) h (\(.hours | age))" else "-" end); "time spent running — drives often last 5+ years"),
        row("Temperature"; (if .temp then "\(.temp) °C" else "-" end); (if .ssd then "fine below ~70 °C (SSD/NVMe)" else "fine below ~50 °C (HDD)" end)),
        row("Bad sectors"; "\((.realloc // 0) + (.pending // 0) + (.uncorrect // 0))"; "realloc \(.realloc // 0) · pending \(.pending // 0) · uncorr. \(.uncorrect // 0) — want 0")
      ] + (if .wear != null then [row("Wear"; "\(.wear) % used"; "SSD lifetime used — replace near 100 %")] else [] end)
        + (if .media != null then [row("Media errors"; "\(.media)"; "NVMe data-integrity errors — want 0")] else [] end)
        + (if .spare != null then [row("Spare blocks"; "\(.spare) % left"; "reserve for worn cells — want high")] else [] end)
      | .[]' <<<"$d")")
  done
  panel "Disks · health (SMART)" "$out"
  pick LAYOUT "" "Back to disks|back" || return 1
}

# Disk tool: rename a partition's label in place (no data touched).
# Offers partitions with ext4, xfs, btrfs, vfat, ntfs or exfat. The system
# labels nixos, nixos-luks* and EFI* are refused, because host configs find
# the system disk by them. Asks to confirm on another OS's disk.
#   Example  rename_tool || true
rename_tool() {
  local n i d fs cur lbl dopts=() popts=() PARTS=()
  TITLE="Disks · rename a label"
  for n in "${NAMES[@]}"; do dopts+=("$(printf '%-9s %-7s %-28.28s %s' "$n" "$(hsize "$(disk "$n" .size)")" "$(disk "$n" .model)" "$(disk "$n" .parts)")|$n"); done
  pick n "Which disk? (esc = cancel)" "${dopts[@]}" || return 1
  mapfile -t PARTS < <(jq -r --arg n "$n" '.[] | select(.name==$n) | .segs[] | select(.fs | test("^(ext4|xfs|btrfs|vfat|ntfs|exfat)$"))
                                      | [.dev, .fs, (.label // "")] | join("\u001f")' <<<"$DISKS")
  if (( ${#PARTS[@]} == 0 )); then warn "$n has no partition with a renameable filesystem (ext4, xfs, btrfs, FAT, NTFS, exFAT)"; return 1; fi
  i=0
  if (( ${#PARTS[@]} > 1 )); then
    for i in "${!PARTS[@]}"; do IFS=$'\x1f' read -r d fs cur <<<"${PARTS[i]}"; popts+=("$(printf '%-11s %-6s %s' "$d" "$fs" "${cur:-—}")|$i"); done
    pick i "Which partition on $n?" "${popts[@]}" || return 1
  fi
  IFS=$'\x1f' read -r d fs cur <<<"${PARTS[i]}"
  if [[ $cur =~ ^(nixos|nixos-luks.*|EFI[0-9]*)$ ]]; then
    warn "\"$cur\" is a system label — your host configs find the system disk by this name, so it stays as is"; return 1
  fi
  ask_label lbl "$fs" "$cur" || return 1
  [[ $lbl == "$cur" ]] && return 1
  if is_foreign "$n"; then yesno "$n belongs to another OS ($(disk "$n" .os)). Rename \"${cur:-no label}\" → \"$lbl\"?" || return 1; fi
  FORMAT_CMDS+=("$(relabel_cmd "$fs" "$d" "$lbl")   # rename only — data untouched")
  if [[ -z $DEMO ]]; then run_now "$(relabel_cmd "$fs" "$d" "$lbl")" || return 1; fi
  local j; for j in ALL VISIBLE DISKS; do
    printf -v "$j" '%s' "$(jq --arg d "$d" --arg l "$lbl" 'map(.segs |= map(if .dev == $d then .label = $l else . end))' <<<"${!j}" | norm)"
  done
  NOTE+="${G}✓ $d renamed ${cur:-(no label)} → $lbl${N} ${D}$([[ -n $DEMO ]] && echo "(demo: simulated)" || echo "(done)")${N}"$'\n'
}

# --------------------------------------------------------------------------
# RAID suggestions — sizes on stdin → "id|usable|survives|note|star" / "-|id|reason"
# --------------------------------------------------------------------------
# raid_options system|data — one line per layout, read by choose_raid:
#   id|usable bytes|disks that may die|note|1 = recommended (★)
#   -|id|reason           a layout these disks cannot do
# Layouts and usable space (sum = all sizes, min/max = smallest/largest disk):
#   btrfs-raid1    2 copies     min(sum/2, sum-max)
#   btrfs-raid1c3  3 copies     min(sum/3, sum-max-max2)          (≥ 3 disks)
#   btrfs-raid10   striped 2 copies, min(sum/2, sum-max)          (≥ 4 disks)
#   zfs-mirror     n-way mirror min                               (any count)
#   zfs-raidz1/2/3 parity       (n-1/2/3) × min      (data only, ≥ 3/4/5 disks)
# Disks within 5 % of each other count as equal sizes. zfs counts every disk
# as the smallest one, so mixed sizes add a "wasted" note. The ★ goes to:
# 2 disks zfs-mirror, 3 zfs-raidz1, 4+ zfs-raidz2 when sizes are equal, else
# btrfs-raid1 (btrfs-raid10 for 4+); for the system scope raidz becomes
# zfs-mirror.
#   Example  printf '%s\n' 2000398934016 2000398934016 | raid_options data
raid_options() {
  awk -v scope="$1" '
    { s[NR]=$1; sum+=$1; if (NR==1 || $1<min) min=$1
      if ($1>max) { max2=max; max=$1 } else if ($1>max2) max2=$1 }
    function lo(a,b) { return a<b ? a : b }
    function opt(id,u,f,note,star) { printf "%s|%.0f|%d|%s|%s\n", id,u,f,note,star }
    END {
      n=NR; eq=(max/min<=1.05); waste=sum-n*min
      zn = eq ? "" : sprintf("⚠ every disk counted as %.1fT → %.1fT wasted", min/1e12, waste/1e12)
      best = n==2 ? (eq?"zfs-mirror":"btrfs-raid1") : n==3 ? (eq?"zfs-raidz1":"btrfs-raid1") : (eq?"zfs-raidz2":"btrfs-raid10")
      if (scope=="system" && best ~ /raidz/) best = eq ? "zfs-mirror" : "btrfs-raid1"
      opt("btrfs-raid1",  lo(sum/2, sum-max), 1, eq?"flexible, add any size disk later":"mixed sizes — btrfs uses all of them", best=="btrfs-raid1")
      if (n>=3) opt("btrfs-raid1c3", lo(sum/3, sum-max-max2), 2, "3 copies of everything", 0); else print "-|btrfs-raid1c3|needs ≥ 3 disks"
      if (n>=4) opt("btrfs-raid10", lo(sum/2, sum-max), 1, "striped mirrors — faster", best=="btrfs-raid10"); else print "-|btrfs-raid10|needs ≥ 4 disks"
      opt("zfs-mirror", min, n-1, (n>2 ? n "-way, " : "") "fastest reads " zn, best=="zfs-mirror")
      if (scope=="data") {
        if (n>=3) opt("zfs-raidz1", (n-1)*min, 1, "best space with protection " zn, best=="zfs-raidz1"); else print "-|zfs-raidz1|needs ≥ 3 disks"
        if (n>=4) opt("zfs-raidz2", (n-2)*min, 2, "any 2 disks can die " zn, best=="zfs-raidz2"); else print "-|zfs-raidz2|needs ≥ 4 disks"
        if (n>=5) opt("zfs-raidz3", (n-3)*min, 3, "for very large pools " zn, 0); else print "-|zfs-raidz3|needs ≥ 5 disks"
      }
    }'
}

# choose_raid <system|data> disk… → RAID_CHOICE
# Shows the layouts from raid_options with usable size and how many disks may
# die, plus warnings: SSD + HDD mixed, worn disks, USB disks, and disks with
# data that will be wiped. Returns 1 on esc.
#   Example  choose_raid data sda sdb sdc || return 1
choose_raid() {
  local scope=$1; shift
  local sizes rows labels=() blocked="" warns="" d s
  sizes=$(for d in "$@"; do disk "$d" .size; done)
  rows=$(raid_options "$scope" <<<"$sizes")
  while IFS='|' read -r id u f note star; do
    if [[ $id == - ]]; then blocked+=$(printf "\n   %-16s %s" "$u" "$f"); continue; fi
    labels+=("$(printf "%-16s %-8s %-10s %s %s" "$id" "$(hsize "$u")" "$f disk$([[ $f == 1 ]] || echo s)" "$([[ $star == 1 ]] && echo ★ || true)" "$note")|$id")
  done <<<"$rows"
  [[ $(for d in "$@"; do disk "$d" .rota; done | sort -u | wc -l) -gt 1 ]] && warns+="⚠ SSD + HDD mixed — pool runs at HDD speed"$'\n'
  for d in "$@"; do
    s=$(disk "$d" .smart)
    [[ ${s%%|*} == warn ]] && warns+="⚠ $d: ${s#*|} — weakest disk in the pool"$'\n'
    [[ $(disk "$d" .tran) == usb ]] && warns+="⚠ $d is USB-attached — USB disks drop out of pools at random"$'\n'
    [[ -n $(disk "$d" .parts) ]] && warns+="⚠ $d has data ($(disk "$d" .parts)) — will be WIPED"$'\n'
  done
  CTX=$(box -t "RAID layout" "$# disks: $(for d in "$@"; do printf '%s %s · ' "$d" "$(hsize "$(disk "$d" .size)")"; done)" \
       "" "Mirror = every block on 2+ disks. Parity (raidz) = data + parity spread over 3+ disks." \
       "★ = best fit for these disks. RAID is NOT a backup — it survives dead disks, not rm -rf." \
       "${warns%$'\n'}" "${blocked:+unavailable:$blocked}")
  pick RAID_CHOICE "   LAYOUT           USABLE   SURVIVES" "${labels[@]}"
}

# --------------------------------------------------------------------------
# Saved answers — choices stored per host, disks matched by SERIAL
# (device names like sda/nvme0n1 can swap between boots)
# --------------------------------------------------------------------------
# serial_of DISK → its serial; name_of SERIAL → its current device name in
# $ALL (empty when that disk is not in this machine).
serial_of() { disk "$1" .serial; }
name_of() { jq -r --arg s "$1" '.[] | select(.serial==$s) | .name' <<<"$ALL"; }

# answers_json — print every current answer as JSON (format version 1):
# host, user, layout, disks (by serial: system, mirrors, home, data, other
# with "serial|role"), fs, RAID, labels, data pool options, boot, enc, swap,
# region, desktop, kernel, unfree, ssh and extra packages. load_answers
# reads it back.
#   Example  answers_json >"$ANSWERS_DIR/$HOST.json"
answers_json() {
  local o ser=() m mir=() dat=() d
  for m in "${MIRRORS[@]}"; do mir+=("$(serial_of "$m")"); done
  for d in "${DATA[@]}"; do dat+=("$(serial_of "$d")"); done
  for o in "${OTHER[@]}"; do ser+=("$(serial_of "${o%%|*}")|${o#*|}"); done
  jq -n --arg host "$HOST" --arg user "$NIXUSER" --arg layout "$LAYOUT" \
    --arg sys "$(serial_of "$SYS")" --arg home "$([[ -n $HOME_DISK ]] && serial_of "$HOME_DISK" || true)" \
    --arg fs "$FS" --arg sysraid "$SYS_RAID" --arg homefs "$HOME_FS" --arg homelabel "$HOME_LABEL" --arg dlabel "$DATA_LABEL" \
    --arg draid "$DATA_RAID" --arg dfs "$DATA_FS" --arg dkeep "$DATA_KEEP" --arg dmnt "$DATA_MNT" \
    --arg boot "$BOOT" --arg enc "$ENC" --arg swap "$SWAP" \
    --arg source "$SOURCE" --arg tz "$TZONE" --arg keymap "$KEYMAP" --arg xkb "$XKB" \
    --arg desktop "$DESKTOP" --arg kernel "$KERNEL" --arg unfree "$UNFREE" --arg ssh "$SSH" --arg pk "${PKGS[*]:-}" \
    --args '{version: 1, source: $source, host: $host, user: $user, layout: $layout,
      disks: {system: $sys, mirrors: ($ARGS.positional[0] | split(" ") | map(select(. != ""))),
              home: $home, data: ($ARGS.positional[1] | split(" ") | map(select(. != ""))),
              other: ($ARGS.positional[2] | split(" ") | map(select(. != "")))},
      fs: $fs, sys_raid: $sysraid, home_fs: $homefs, home_label: $homelabel,
      data: {raid: $draid, fs: $dfs, keep: ($dkeep == "1"), mount: $dmnt, label: $dlabel},
      boot: $boot, enc: $enc, swap: $swap,
      region: {timezone: $tz, keymap: $keymap, xkb: $xkb}, desktop: $desktop, kernel: $kernel, unfree: ($unfree == "true"), ssh: ($ssh == "true"), packages: ($pk | split(" ") | map(select(. != "")))}' "${mir[*]}" "${dat[*]}" "${ser[*]}"
}

# load_answers <file> — sets every choice; returns 1 if a saved disk is missing
# Disks are found by serial. A missing system, mirror, data or home disk is
# listed in LOAD_MISSING; a missing "other" disk is dropped silently.
#   Example  load_answers "$ANSWERS_DIR/$HOST.json" || echo "$LOAD_MISSING"
load_answers() {
  local f=$1 s n missing=()
  a() { jq -r "$1 // \"\"" "$f"; }
  SYS=$(name_of "$(a .disks.system)"); [[ -n $SYS ]] || missing+=("system $(a .disks.system)")
  MIRRORS=(); for s in $(a '.disks.mirrors[]'); do n=$(name_of "$s"); if [[ -n $n ]]; then MIRRORS+=("$n"); else missing+=("mirror $s"); fi; done
  DATA=();    for s in $(a '.disks.data[]');    do n=$(name_of "$s"); if [[ -n $n ]]; then DATA+=("$n"); else missing+=("data $s"); fi; done
  OTHER=();   for s in $(a '.disks.other[]');   do n=$(name_of "${s%%|*}"); [[ -n $n ]] && OTHER+=("$n|${s#*|}"); done
  HOME_DISK=""; s=$(a .disks.home); if [[ -n $s ]]; then HOME_DISK=$(name_of "$s"); [[ -n $HOME_DISK ]] || missing+=("home $s"); fi
  LAYOUT=$(a .layout); FS=$(a .fs); SYS_RAID=$(a .sys_raid); HOME_FS=$(a .home_fs); HOME_LABEL=$(a .home_label); HOME_LABEL=${HOME_LABEL:-home}
  DATA_RAID=$(a .data.raid); DATA_FS=$(a .data.fs); DATA_MNT=$(a .data.mount); DATA_LABEL=$(a .data.label); DATA_LABEL=${DATA_LABEL:-data}
  DATA_KEEP=0; [[ $(a .data.keep) == true ]] && DATA_KEEP=1
  BOOT=$(a .boot); ENC=$(a .enc); SWAP=$(a .swap)
  PKGS=(); for s in $(a '.packages[]?'); do PKGS+=("$s"); done
  DISKS=$ALL; mapfile -t NAMES < <(jq -r '.[].name' <<<"$VISIBLE")
  if ((DATA_KEEP)) && ((${#DATA[@]})); then DATA_OLDLABEL=$(disk "${DATA[0]}" .curlabel); fi
  if (( ${#missing[@]} )); then LOAD_MISSING=$(printf '  ✗ %s\n' "${missing[@]}"); return 1; fi
}

# --------------------------------------------------------------------------
# Banner — framed 3-line header in the two NixOS logo blues
# (light "NixOS", dark "-Installer", as 256-colour approximations). Width
# follows the terminal (72–120 cols); narrower terminals get a one-line version.
# Line 1: logo, config source and MODE_TAG (orange in the demo, red for a
# real install). Line 2: firmware, CPU, GPU, RAM, form factor, WiFi, network
# and disk source.
# C.UTF-8 is built into glibc, so ${#s} counts characters even on the ISO.
#   Example  HEADER=$(banner)
# --------------------------------------------------------------------------
banner() {
  local LC_ALL=C.UTF-8
  local lb=$'\e[38;5;110m' db=$'\e[38;5;68m' tb=$'\e[1;38;5;117m' or=$'\e[38;5;214m'
  local facts
  facts="${FW^^} · $HW_CPU CPU · $HW_GPU GPU · $(hsize "$RAM_B") RAM · $HW_FORM$([[ $HW_WIFI == 1 ]] && echo " · WiFi" || true) · network $NET · disks ${FAKE:-real}"
  local cols=$TERM_COLS
  local logo="${tb}NixOS${N}${db}${B}-Installer${N}"
  if (( cols < 72 )); then
    printf ' %s  %sinstaller · %s%s' "$logo" "$D" "$MODE_TAG" "$N"; return
  fi
  local w=$(( cols - 2 < 120 ? cols - 2 : 120 ))
  local mid=" ── $SRC_LABEL " tail=" $MODE_TAG ─╮"
  local fill=$(( w - 3 - 15 - ${#mid} - ${#tail} ))   # 3 = "╭─ ", 15 = "NixOS-Installer"
  if (( fill < 2 )); then mid=" ── installer "; fill=$(( w - 3 - 15 - ${#mid} - ${#tail} )); fi
  local line; printf -v line '%*s' "$fill" ''; line=${line// /─}
  local bar; printf -v bar '%*s' "$(( w - 2 ))" ''; bar=${bar// /─}
  (( ${#facts} > w - 4 )) && facts="${facts:0:$(( w - 5 ))}…"
  local tagc=$or; [[ -n $DEMO ]] || tagc=$'\e[1;38;5;203m'
  printf '%s╭─ %s%s%s%s %s%s%s%s ─╮%s\n' "$lb" "$logo" "$lb" "$mid" "$line" "$tagc" "$MODE_TAG" "$N" "$lb" "$N"
  printf '%s│%s %s%s%*s %s│%s\n' "$lb" "$N" "$D$facts$N" "" "$(( w - 4 - ${#facts} ))" "" "$lb" "$N"
  printf '%s╰%s╯%s' "$lb" "$bar" "$N"
}

# host_cfg HOST — the host's main file: <Host>.nix (Linuxury's config), else default.nix
host_cfg() { local f="$REPO/hosts/$1/$1.nix"; [[ -f $f ]] || f="$REPO/hosts/$1/default.nix"; echo "$f"; }

# Host facts read from its config (default: the chosen $HOST)
#   host_desktop [HOST]  desktop/compositor/shell modules the host imports,
#                        joined with "+", or "headless"
#   host_profile [HOST]  server (headless), laptop (tlp, battery or laptop
#                        in its config) or desktop; a new host uses PROFILE
#   host_kernel [HOST]   kernel flavour from boot.kernelPackages (default
#                        zen); for the chosen host with zfs: the LTS kernel
host_desktop() {
  local f; f=$(host_cfg "${1:-$HOST}"); local d
  [[ -f $f ]] || { echo "${PROFILE:-?} (new host)"; return; }
  d=$(grep -E '^\s*\.\./\.\./modules/(desktops|compositors|shells)/[a-z0-9-]+' "$f" | sed -E 's#.*modules/[a-z]+/([a-z0-9-]+).*#\1#' | sort -u | paste -sd+)
  echo "${d:-headless}"
}
host_profile() {
  local h=${1:-$HOST}
  if [[ -z ${1:-} && $NEWHOST == 1 ]]; then echo "$PROFILE"
  elif [[ $(host_desktop "$h") == headless* ]]; then echo server
  elif grep -qiE 'services\.tlp|battery|laptop' "$(host_cfg "$h")" 2>/dev/null; then echo laptop
  else echo desktop; fi
}
host_kernel() {
  [[ -z ${1:-} && ${FS:-} == zfs ]] && { echo "LTS (ZFS-supported)"; return; }
  local k; k=$(grep -hoE '^\s*boot.kernelPackages = pkgs\.linuxPackages_[a-z]+' "$(host_cfg "${1:-$HOST}")" 2>/dev/null | sed 's/.*_//')
  echo "${k:-zen}"
}

# kv KEY "a, b, c" — one card row; long lists wrap onto aligned continuation rows
# An empty list shows "—". Width follows CARD_W like card().
#   Example  kv Services "samba, jellyfin"
kv() {
  local width=$(( ${CARD_W:-$(( TERM_COLS - 2 < 120 ? TERM_COLS - 2 : 120 ))} - 4 - 10 ))
  local first=1 l
  while IFS= read -r l; do
    if ((first)); then printf '%-9s %s\n' "$1" "$l"; first=0; else printf '%-9s %s\n' "" "$l"; fi
  done < <(printf '%s\n' "${2:-—}" | fold -s -w "$width")   # trailing \n: read drops an unterminated last line
}

# host_card HOST — what the config says about this host (shown live while picking)
# Used as pick()'s PICK_PREVIEW. Reads the host file with grep: user + UID,
# desktop, GPU, kernel, filesystem + LUKS, boot loader, services, apps,
# development tools, extras (gaming, fingerprint, tlp, openrgb) and whether
# saved answers exist. HOST=NEW shows the detected hardware instead.
#   Example  host_card Ryzen5900x
host_card() {
  local h=$1 f; f=$(host_cfg "$1"); local u gpu fs enc loader saved svc apps dev extras mods
  if [[ $h == NEW ]]; then
    box -t "New host" "Creates hosts/<name>/<name>.nix from a template and adds it to flake.nix." "" \
      "Detected on this machine (used to fill in the template):" \
      "$(printf '%-9s %-26s %-9s %s' CPU "$HW_CPU + microcode" GPU "$HW_GPU$([[ $HW_GPU == *+* ]] && echo " (hybrid/PRIME)" || true)")" \
      "$(printf '%-9s %-26s %-9s %s' Type "$HW_FORM" WiFi "$([[ $HW_WIFI == 1 ]] && echo yes || echo no)")" \
      "$(printf '%-9s %s' RAM "$(hsize "$RAM_B")")"
    return
  fi
  local l hh uu; for l in "${HOSTS[@]}"; do read -r hh uu <<<"$l"; [[ $hh == "$h" ]] && u=$uu; done
  gpu=$(grep -oE '^\s*hardware\.gpu\s*=\s*"[a-z+-]+"' "$f" | grep -oE '"[^"]+"' | tr -d '"')
  fs=$(grep -m1 -oE 'fsType\s*=\s*"[a-z0-9]+"' "$f" | grep -oE '"[^"]+"' | tr -d '"')
  enc=no; grep -q 'luks.devices' "$f" && enc="LUKS"
  loader=systemd-boot; grep -qE 'boot\.loader\.grub\s*=\s*\{|boot\.loader\.grub\.enable\s*=\s*true' "$f" && loader=GRUB
  # imported modules, minus comments: "services/samba", "development/ai-tools/claude", …
  mods=$(grep -E '^\s*\.\./\.\./modules/' "$f" | sed -E 's#^\s*\.\./\.\./modules/##; s#/default\.nix$##; s#/([a-z0-9-]+)/\1\.nix$#/\1#; s#\.nix$##; s#/(app|service|greeter|shell|theme)-([a-z0-9-]+)$#/\2#')
  list() { sort -u | paste -sd, | sed 's/,/, /g'; }
  svc=$( { grep -oE '^services/[a-z0-9-]+' <<<"$mods" | sed 's#services/##'
           grep -oE '^\s*services\.[a-zA-Z0-9-]+(\s*=\s*\{|\.enable\s*=\s*true)' "$f" | sed -E 's/^\s*services\.//; s/[ .=].*//'
           grep -qE 'virtualisation\.docker\.enable\s*=\s*true' "$f" && echo docker
           grep -oE '(^\s*containers\.|oci-containers\.containers\.)[a-zA-Z0-9-]+\s*=\s*\{' "$f" | sed -E 's/.*containers\.([a-zA-Z0-9-]+).*/\1 (container)/'
         } | grep -vxE 'libinput|logind|udev|journald|xserver|pipewire|openssh|fprintd|tlp|fstrim|printing|resolved' | list)
  apps=$(grep -oE '^system/graphical/[a-z0-9-]+' <<<"$mods" | sed 's#system/graphical/##' | list)
  dev=$(grep -oE '^development/[a-z-]+/[a-z0-9-]+' <<<"$mods" | sed 's#.*/##' | list)
  extras=$( { grep -q '^gaming' <<<"$mods" && echo gaming
              grep -qE 'services\.fprintd\.enable\s*=\s*true' "$f" && echo "fingerprint (fprintd)"
              grep -qE 'services\.tlp\s*=|services\.tlp\.enable' "$f" && echo "battery care (tlp)"
              grep -qE 'hardware\.openrgb\.enable\s*=\s*true' "$f" && echo "RGB (openrgb)"
            } | list)
  saved="none yet"; [[ -f $ANSWERS_DIR/$h.json ]] && saved="↻ yes — 1-key reinstall with the same disks"
  card $'\e[38;5;110m' "$h" "$(host_profile "$h")" \
    "$(printf '%-9s %-26s %-9s %s' User "$u ($(uid_of "$u"))" Desktop "$(host_desktop "$h")")" \
    "$(printf '%-9s %-26s %-9s %s' GPU "${gpu:-?}" Kernel "$(host_kernel "$h")")" \
    "$(printf '%-9s %-26s %-9s %s' Storage "${fs:-?}$([[ $enc == LUKS ]] && echo " + LUKS" || true) (config)" Boot "$loader")" \
    "$(kv Services "$svc")" "$(kv Apps "$apps")" "$(kv Dev "$dev")" "$(kv Extras "$extras")" \
    "$(printf '%-9s %s' Saved "$saved")"
}

# soon VALUE — true (and warns) when real mode doesn't support VALUE
# Demo-only values: zfs, zfs-*, bcachefs, refind, NEW (new host). Always
# false in the demo.
#   Example  if soon "$FS"; then JUMP=$CUR; return 3; fi
soon() {
  [[ -n $DEMO ]] && return 1
  case $1 in
    zfs|zfs-*|bcachefs|refind|NEW) warn "\"$1\" is coming soon — the real installer v1 doesn't do it yet (try it with --demo)"; return 0 ;;
  esac
  return 1
}

# ==========================================================================
# Steps — each returns 0 = next, 1 = back, 3 = jump to $JUMP
# ==========================================================================
# host_linuxury — Host step for the Linuxury config: pick a host from its
# flake.nix (↻ = saved answers exist), with host_card as preview. "+ New
# host" asks for a hostname, primary user and profile (laptop, desktop,
# server; ★ follows the detected form factor). An existing host with saved
# answers offers a reinstall that loads them and jumps ahead (hub: back to
# the menu; otherwise step index 6).
host_linuxury() {
  panel "Which host are you installing?"
  local opts=() l h u
  for l in "${HOSTS[@]}"; do
    read -r h u <<<"$l"
    opts+=("$h$([[ -f $ANSWERS_DIR/$h.json ]] && echo " ↻" || true)|$h")
  done
  PICK_PREVIEW=host_card
  pick HOST "${#HOSTS[@]} hosts in flake.nix" "${opts[@]}" "+ New host$([[ -z $DEMO ]] && echo "  (coming soon)" || true)|NEW" || { PICK_PREVIEW=""; return 1; }
  if soon "$HOST"; then PICK_PREVIEW=""; JUMP=$CUR; return 3; fi
  PICK_PREVIEW=""
  NEWHOST=0; PROFILE=""
  if [[ $HOST == NEW ]]; then
    panel "New host" "$(box -t "Detected hardware" "Detected on this machine — used to fill in the new host's template:" \
         "CPU $HW_CPU (microcode) · GPU $HW_GPU (drivers$([[ $HW_GPU == *+* ]] && echo ", hybrid/PRIME" || true))" \
         "Form $HW_FORM$([[ $HW_FORM == laptop ]] && echo " (battery found → power management, LUKS suggested)" || true) · WiFi $([[ $HW_WIFI == 1 ]] && echo yes || echo no)")"
    while :; do
      ask HOST --header "Hostname (letters, digits, dashes)" --placeholder "e.g. Ryzen7700x" || return 1
      [[ $HOST =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] || { warn "invalid hostname"; continue; }
      if printf '%s\n' "${HOSTS[@]}" | grep -q "^$HOST "; then warn "$HOST already exists"; continue; fi
      break
    done
    pick NIXUSER "Primary user" "linuxury   admin/dev|linuxury" "babylinux  daily driver|babylinux" "alex       restricted child account|alex" || return 1
    local lp="laptop   graphical + power management|laptop" dp="desktop  graphical, Home Manager|desktop" sp="server   headless, no Home Manager|server"
    if [[ $HW_FORM == laptop ]]; then pick PROFILE "Profile" "${lp/management/management ★}" "$dp" "$sp" || return 1
    else pick PROFILE "Profile" "${dp/Manager/Manager ★}" "$lp" "$sp" || return 1; fi
    NEWHOST=1; return 0
  fi
  for l in "${HOSTS[@]}"; do read -r h u <<<"$l"; if [[ $h == "$HOST" ]]; then NIXUSER=$u; fi; done

  local f=$ANSWERS_DIR/$HOST.json
  [[ -f $f ]] || return 0
  local summary r
  summary=$(jq -r '"saved: \(.fs)\(if .sys_raid != "" then " (" + .sys_raid + ")" else "" end) · \(.boot) · encryption \(.enc) · swap \(.swap)"' "$f")
  if load_answers "$f"; then
    panel "Reinstall $HOST" "$(box -t "Saved answers" "$summary" "All saved disks found (matched by serial number):" \
      "$(printf '  ✓ %s\n' "$SYS" "${MIRRORS[@]}" "${DATA[@]}" ${HOME_DISK:+"$HOME_DISK"})")"
    pick r "" "Reinstall with saved answers ★   → new host key, then review|saved" "Start fresh|fresh" || return 1
    if [[ $r == saved ]]; then
      if ((HUB)); then local s; for s in "${STEPS[@]}"; do VISITED[$s]=1; done; JUMP=$HUB_IDX
      else
        # Continue at the Secrets step (new host key), looked up by name.
        local i; JUMP=$REVIEW_IDX
        for i in "${!STEPS[@]}"; do if [[ ${STEPS[$i]} == step_secrets ]]; then JUMP=$i; fi; done
      fi
      return 3
    fi
  else
    panel "Reinstall $HOST" "$(box -t "Saved answers" "$summary" "Some saved disks are not in this machine anymore:" "$LOAD_MISSING" "" "→ starting fresh")"
    pick r "" "Continue|fresh" || return 1
  fi
}

# step_disks — Disks step: the disk cards, then a menu: Single disk, Multi-disk
# (more than one disk), the Format / Rename / Disk health tools, and "Show
# removable disks too" when some are hidden. Tools and "show" come back to
# this screen (return 3 with JUMP=$CUR); both layouts continue to
# roles_screen.
step_disks() {
  MIRRORS=(); HOME_DISK=""; DATA=(); OTHER=(); LAYOUT=single
  DISKS=$VISIBLE
  local top=""
  [[ -n $HIDDEN ]] && top+="${D}hidden: $HIDDEN (boot USB / removable)${N}"$'\n'
  [[ -z $FAKE && $EUID != 0 ]] && top+="${D}SMART health needs root — run with sudo to see it${N}"$'\n'
  local table; table="${top}$(disk_table "$DISKS")"
  panel "Disks" "$table"
  mapfile -t NAMES < <(jq -r '.[].name' <<<"$DISKS")
  local opts=("Single disk   everything on one disk, other disks untouched|single")
  (( ${#NAMES[@]} > 1 )) && opts+=("Multi-disk    give every disk a role (mirror, /home, data pool, other OS…)|multi")
  opts+=("Format a disk…   erase + new filesystem now, then back to this screen|format")
  opts+=("Rename a label…  change the name a disk shows in the file manager (data untouched)|rename")
  opts+=("Disk health…     SMART details for every disk, explained|health")
  [[ -n $HIDDEN ]] && opts+=("Show removable disks too|show")
  pick LAYOUT "Disk layout" "${opts[@]}" || return 1
  if [[ $LAYOUT == show ]]; then VISIBLE=$ALL; HIDDEN=""; JUMP=$CUR; return 3; fi
  if [[ $LAYOUT == format ]]; then format_tool || true; JUMP=$CUR; return 3; fi
  if [[ $LAYOUT == rename ]]; then rename_tool || true; JUMP=$CUR; return 3; fi
  if [[ $LAYOUT == health ]]; then health_view || true; JUMP=$CUR; return 3; fi

  roles_screen || { JUMP=$CUR; return 3; }   # esc → back to the layout menu
}

# --------------------------------------------------------------------------
# Disk roles — the disk cards ARE the selection. ↑↓ highlights a card,
# enter opens its role menu under the cards; the corner shows the role.
# --------------------------------------------------------------------------
# ROLE[disk]: system | mirror | home | data | untouched | another-OS action
# (boot, mount-ro, mount-rw, boot+mount-ro) | "" (not chosen yet).
declare -A ROLE=()
# role_status ROLE — frame colour and corner text for a disk card: red for
# roles that wipe the disk, green data, blue other-OS actions, grey otherwise.
role_status() {  # role → "colour|corner text"
  case $1 in
    system)   echo $'\e[38;5;203m'"|● System ★ (wiped)" ;;
    mirror)   echo $'\e[38;5;203m'"|● Mirror of $SYS (wiped)" ;;
    home)     echo $'\e[38;5;203m'"|● /home (wiped)" ;;
    data)     echo $'\e[38;5;114m'"|● Data pool" ;;
    untouched) echo $'\e[38;5;242m'"|○ untouched" ;;
    boot|mount-ro|mount-rw|boot+mount-ro) echo $'\e[38;5;117m'"|◆ $(other_action "$1")" ;;
    *)        echo $'\e[38;5;242m'"|○ choose a role" ;;
  esac
}
# role_card DISK HIGHLIGHT — a disk's card with its role in the corner, model,
# other OS, health problems and partitions. HIGHLIGHT 1 draws it heavy.
#   Example  role_card sda 1
role_card() {  # role_card DISK HIGHLIGHT(0|1)
  local n=$1 fc st h o title i d l f z u tree; local -a LS rows=()
  IFS='|' read -r fc st <<<"$(role_status "${ROLE[$n]:-}")"
  h=$(disk "$n" .smart); o=$(disk "$n" .os)
  local tr; tr=$(disk "$n" .tran)
  title="$n · $(hsize "$(disk "$n" .size)") ${tr^^} · $(disk "$n" .model)"
  case $o in windows|macos|linux) title+=" · other OS: $o" ;; nixos) title+=" · previous NixOS" ;; esac
  case ${h%%|*} in warn) title+=" · ⚠ ${h#*|}" ;; fail) title+=" · ✗ ${h#*|}" ;; esac
  mapfile -t LS < <(jq -r --arg n "$n" ".[] | select(.name==\$n) | $SEG_JQ" <<<"$DISKS")
  (( ${#LS[@]} )) || rows+=("  ${D}(empty — no partitions)${N}")
  for i in "${!LS[@]}"; do
    IFS=$'\x1f' read -r d l f z u <<<"${LS[i]}"; tree="├"; ((i == ${#LS[@]} - 1)) && tree="└"
    rows+=(" $tree $(fmt_seg "$d" "$l" "$f" "$z")")
  done
  if (( $2 )); then CARD_HEAVY=1 card "$fc" "$title" "$st" "${rows[@]}"; else card "$fc" "$title" "$st" "${rows[@]}"; fi
}
# role_plan — one line summing up the roles: "Plan: System sda · Data sdb · …"
role_plan() {
  local n parts=()
  for n in "${NAMES[@]}"; do
    case ${ROLE[$n]:-} in
      system) parts+=("System $n") ;; mirror) parts+=("Mirror $n") ;; home) parts+=("/home $n") ;;
      data) parts+=("Data $n") ;; untouched) parts+=("untouched $n") ;; "") parts+=("? $n") ;;
      *) parts+=("$(other_action "${ROLE[$n]}") $n") ;;
    esac
  done
  local out; printf -v out '%s · ' "${parts[@]}"; echo "Plan: ${out% · }"
}

# --------------------------------------------------------------------------
# Role guide — speed, pros/cons and a recommendation for the disk being set
# --------------------------------------------------------------------------
# disk_kind DISK — nvme (transport nvme), usb (transport usb), hdd
# (rotational) or ssd. kind_speed KIND — one line of typical speed.
# kind_rank KIND — 3 nvme, 2 ssd, 1 hdd, 0 usb (higher = faster).
#   Example  kind_speed "$(disk_kind sda)"
disk_kind() {  # nvme | ssd | hdd | usb
  local t; t=$(disk "$1" .tran)
  if [[ $t == usb ]]; then echo usb; elif [[ $t == nvme ]]; then echo nvme
  elif [[ $(disk "$1" .rota) == true ]]; then echo hdd; else echo ssd; fi
}
kind_speed() {
  case $1 in
    nvme) echo "NVMe SSD — very fast (≈3,000–7,000 MB/s, instant random access)" ;;
    ssd)  echo "SATA SSD — fast (≈550 MB/s, instant random access)" ;;
    hdd)  echo "Hard drive — slow (≈150–250 MB/s, slow random access)" ;;
    *)    echo "USB — speed varies, and it can drop out" ;;
  esac
}
kind_rank() { case $1 in nvme) echo 3 ;; ssd) echo 2 ;; hdd) echo 1 ;; *) echo 0 ;; esac; }
# best_system — fastest healthy non-OS disk (biggest wins a tie)
best_system() {
  local n best="" br=-1 bs=0 r sz
  for n in "${NAMES[@]}"; do
    [[ $(disk "$n" .smart) == fail* ]] && continue; is_foreign "$n" && continue
    r=$(kind_rank "$(disk_kind "$n")"); sz=$(disk "$n" .size)
    if (( r > br || (r == br && sz > bs) )); then best=$n; br=$r; bs=$sz; fi
  done
  echo "$best"
}
# rec_role DISK → "role|reason"
# First match wins: failing or worn → untouched; another OS (not yet
# cleared for wiping) → untouched; no System disk yet and this is
# best_system → system; multi-disk with the same kind and size within ±10 %
# of the System disk → mirror; single-disk layout → untouched; HDD → data;
# USB → untouched; any other SSD → data.
#   Example  IFS='|' read -r rec why <<<"$(rec_role sdb)"
rec_role() {
  local n=$1 k h ks sz ss; k=$(disk_kind "$n"); h=$(disk "$n" .smart)
  [[ ${h%%|*} == fail ]] && { echo "untouched|it is failing — keep data off it and replace it"; return; }
  [[ ${h%%|*} == warn ]] && { echo "untouched|it shows wear (${h#*|}) — don't trust it with anything you need"; return; }
  if is_foreign "$n" && [[ -z ${WIPEOK[$n]:-} ]]; then echo "untouched|leaves your other OS exactly as it is"; return; fi
  if [[ -z $SYS || $SYS == "$n" ]]; then
    [[ $n == "$(best_system)" ]] && { echo "system|it's the fastest healthy disk here"; return; }
  fi
  if [[ -n $SYS && $SYS != "$n" && $LAYOUT == multi ]]; then
    ks=$(disk_kind "$SYS"); sz=$(disk "$n" .size); ss=$(disk "$SYS" .size)
    if [[ $k == "$ks" ]] && (( sz * 100 >= ss * 90 && sz * 100 <= ss * 110 )); then
      echo "mirror|same kind and size as $SYS — a perfect mirror pair"; return
    fi
  fi
  [[ $LAYOUT == multi ]] || { echo "untouched|single-disk layout uses only the System disk"; return; }
  case $k in
    hdd) echo "data|big and cheap per TB — ideal for media, backups and archives" ;;
    usb) echo "untouched|USB disks are unreliable as permanent storage" ;;
    *)   echo "data|fast extra space — great for a game library or projects" ;;
  esac
}

# role_info ROLE — the guide card shown beside the role list (ROLE_DISK = disk)
# Used as pick()'s PICK_PREVIEW in set_role: what the role does, + pros and
# − cons, speed or fit for this disk, its health, and ★ when it matches
# rec_role. ROLE is any value set_role offers (system, mirror, home, data,
# untouched, boot, mount-ro, mount-rw, boot+mount-ro, wipe).
#   Example  ROLE_DISK=sda CARD_W=60 role_info system
role_info() {
  local r=$1 n=$ROLE_DISK k rec why w l out=()
  k=$(disk_kind "$n"); IFS='|' read -r rec why <<<"$(rec_role "$n")"
  w=$(( ${CARD_W:-80} - 6 ))
  local G2=$'\e[38;5;114m' R2=$'\e[38;5;203m'
  add() { while IFS= read -r l; do out+=("$1$l${N}"); done < <(printf '%s\n' "$2" | fold -s -w "$w"); }
  pro() { add "${G2}+ ${N}" "$1"; }
  con() { add "${R2}− ${N}" "$1"; }
  case $r in
    system)
      add "" "Holds NixOS itself: / , /nix (every package), the boot loader — and /home unless another disk takes it."
      pro "Everything you run loads from here: a fast disk makes the whole system feel fast"
      pro "btrfs snapshots let you roll back a bad update"
      con "This disk is wiped"
      con "Only one System disk — add a Mirror if you want it protected"
      case $k in nvme) add "${B}Speed: ${N}" "excellent — NVMe is the best place for the system" ;;
                 ssd)  add "${B}Speed: ${N}" "good — boots and updates quickly" ;;
                 *)    add "${B}Speed: ${N}" "works, but boot, updates and app starts will feel slow — prefer an SSD" ;; esac ;;
    mirror)
      add "" "A live copy of the System disk (RAID1): every write goes to both disks."
      pro "If either disk dies, the machine keeps running and still boots"
      pro "Reads can come from both disks (btrfs/zfs) — slightly faster reads"
      con "You only get the space of ONE disk ($(hsize "$(( $(disk "$n" .size) < $(disk "$SYS" .size) ? $(disk "$n" .size) : $(disk "$SYS" .size) ))"))"
      con "Writes run at the speed of the slower disk — NVMe + HDD makes the system HDD-slow"
      con "Not a backup: deleting a file deletes it on both disks"
      add "${B}Fit: ${N}" "$n is $(disk_kind "$n") $(hsize "$(disk "$n" .size)"), $SYS is $(disk_kind "$SYS") $(hsize "$(disk "$SYS" .size)")$([[ $rec == mirror ]] && echo " — a good match" || echo " — not an ideal pair")" ;;
    home)
      add "" "Your personal files (/home) on their own disk; the system stays on $SYS."
      pro "Reinstall or re-partition the system without touching personal files"
      pro "Keeps big personal data off a small, fast system disk"
      con "This disk is wiped now"
      con "On NixOS the system is rebuilt from the config anyway — the gain is mostly for frequent reinstalls"
      con "Space is split: a full /home can't borrow free space from the system disk" ;;
    data)
      add "" "Extra storage at a folder you choose (/data, /mnt/Games…). Next step: keep the existing files or format, and RAID if more disks join the pool."
      pro "Can KEEP the files already on it (mounted as they are)"
      pro "Several disks can be pooled (mirror / raidz) for safety or size"
      pro "Great for media, backups and game libraries"
      [[ $k == hdd ]] && con "Hard drive: fine for media and backups, slow for games and VMs"
      con "Not part of the system's snapshots" ;;
    untouched)
      add "" "NixOS leaves this disk completely alone — not formatted, not mounted."
      pro "Zero risk to what's on it"
      con "Not usable from NixOS until you mount it later (or re-run the installer)" ;;
    boot)
      add "" "Adds the other OS to the NixOS boot menu so you pick it at startup."
      pro "No need for the firmware's F8/F11/F12 boot menu"; con "Its disk stays unmounted in NixOS" ;;
    mount-ro)
      add "" "Mounts the other OS's files read-only at /mnt/<name>."
      pro "Copy files over with zero risk to the other OS"; con "You can't change anything on it" ;;
    mount-rw)
      add "" "Mounts the other OS's files writable at /mnt/<name>."
      pro "Edit files from NixOS"; con "Refused if Windows hibernated / used Fast Startup — writing then corrupts it" ;;
    boot+mount-ro)
      add "" "Boot menu entry plus a read-only mount — the comfortable dual-boot setup."
      pro "Both conveniences, still zero risk"; con "Read-only from NixOS" ;;
    wipe)
      add "" "Erase the other OS and give this disk a NixOS role. You must type the disk model to confirm."
      pro "The whole disk becomes usable by NixOS"; con "The other OS and its files are gone for good" ;;
  esac
  add "${B}This disk: ${N}" "$(kind_speed "$k")"
  local hh; hh=$(disk "$n" .smart)
  case ${hh%%|*} in
    warn) add "${Y}⚠ Health: ${N}" "${hh#*|} — usable, but don't trust it with the system or a mirror" ;;
    fail) add "${R2}✗ Health: ${N}" "${hh#*|} — this disk is dying; keep your data off it" ;;
  esac
  [[ $r == "$rec" ]] && add "${Y}★ Recommended: ${N}" "$why"
  local title="System"; case $r in system) ;; mirror) title="Mirror of $SYS" ;; home) title="/home" ;; data) title="Data pool" ;;
    untouched) title="Untouched" ;; *) title=$(other_action "$r") ;; esac
  [[ $r == wipe ]] && title="Wipe & reuse"
  card $'\e[38;5;110m' "$title" "$([[ $r == "$rec" ]] && echo "★ recommended" || true)" "${out[@]}"
}

# set_role DISK — role window: the disk's card on top, role list left, guide right
# A disk with another OS first offers: untouched, boot menu entry, mount
# read-only / read-write, boot entry + mount, or wipe & reuse (typed model
# confirms; WIPEOK then unlocks the normal roles). Normal roles: System, and
# for multi-disk Mirror of the System disk, /home and Data pool; Untouched.
# Only one System and one /home disk: choosing it again moves the role.
# Losing the System disk clears every Mirror. esc keeps the old role.
#   Example  set_role sdb
set_role() {
  local n=$1 r opts=() m rec why star
  ROLE_DISK=$n; IFS='|' read -r rec why <<<"$(rec_role "$n")"
  star() { [[ $1 == "$rec" ]] && echo " ★" || true; }
  CTX="$(role_card "$n" 1)"
  if is_foreign "$n" && [[ -z ${WIPEOK[$n]:-} ]]; then
    PICK_PREVIEW=role_info
    pick r "What to do with $n (other OS: $(disk "$n" .os))" \
      "Untouched$(star untouched)|untouched" "Boot menu entry$(star boot)|boot" "Mount read-only|mount-ro" \
      "Mount read-write|mount-rw" "Boot entry + mount|boot+mount-ro" "Wipe & reuse…|wipe" || { PICK_PREVIEW=""; return 0; }
    PICK_PREVIEW=""
    if [[ $r != wipe ]]; then ROLE[$n]=$r; return 0; fi
    confirm_wipe_foreign "$n" || return 0
    WIPEOK[$n]=1; IFS='|' read -r rec why <<<"$(rec_role "$n")"; CTX="$(role_card "$n" 1)"
  fi
  opts=("System$(star system)|system")
  if [[ $LAYOUT == multi ]]; then
    [[ -n $SYS && $SYS != "$n" ]] && opts+=("Mirror of $SYS$(star mirror)|mirror")
    opts+=("/home$(star home)|home" "Data pool$(star data)|data")
  fi
  opts+=("Untouched$(star untouched)|untouched")
  PICK_PREVIEW=role_info
  pick r "Role for $n — ↑↓ to compare, the card explains each" "${opts[@]}" || { PICK_PREVIEW=""; return 0; }
  PICK_PREVIEW=""
  if [[ $r != untouched ]] && ! health_ok "$n"; then return 0; fi
  case $r in
    system) for m in "${!ROLE[@]}"; do [[ ${ROLE[$m]} == system || ${ROLE[$m]} == mirror && $m == "$n" ]] && ROLE[$m]=""; done; SYS=$n ;;
    home)   for m in "${!ROLE[@]}"; do [[ ${ROLE[$m]} == home ]] && ROLE[$m]=""; done ;;
  esac
  [[ $n == "$SYS" && $r != system ]] && SYS=""
  ROLE[$n]=$r
  [[ -z $SYS ]] && for m in "${!ROLE[@]}"; do [[ ${ROLE[$m]} == mirror ]] && ROLE[$m]=""; done
  return 0
}

# roles_screen — the Disks · assign roles page: every disk as a card, ↑↓
# highlights one, enter opens set_role, "Continue →" below the cards needs a
# System disk. The page scrolls to keep the highlighted card visible. Single
# layout starts every disk as untouched. Under INSTALL_TEST the first disk is
# System and, for multi, the next disk without another OS is Data.
# On continue it sets SYS, MIRRORS, HOME_DISK, DATA and OTHER ("disk|role").
# Returns 1 on esc.
#   Example  roles_screen || { JUMP=$CUR; return 3; }
roles_screen() {
  local idx=0 n i cards start=() ends=() line=0 c prompt
  declare -gA WIPEOK=(); ROLE=(); SYS=""
  for n in "${NAMES[@]}"; do ROLE[$n]=""; done
  [[ $LAYOUT == single ]] && for n in "${NAMES[@]}"; do ROLE[$n]=untouched; done
  if [[ -n ${INSTALL_TEST:-} ]]; then   # tests: first disk System; multi → next non-OS disk Data
    SYS=${NAMES[0]}; ROLE[$SYS]=system
    if [[ $LAYOUT == multi ]]; then for n in "${NAMES[@]:1}"; do is_foreign "$n" || { ROLE[$n]=data; break; }; done; fi
  else
    while :; do
      cards=""; line=0; start=(); ends=()
      for i in "${!NAMES[@]}"; do
        c=$(role_card "${NAMES[i]}" $(( i == idx ))); start[i]=$line
        line=$(( line + $(wc -l <<<"$c") + 1 )); ends[i]=$line; cards+="$c"$'\n'
      done
      panel "Disks · assign roles" "${D}↑↓ highlight a disk · enter sets its role · ★ = the System disk (required)${N}"$'\n'"$cards"
      compose
      if (( idx < ${#NAMES[@]} )); then   # keep the highlighted card on screen
        (( start[idx] < OFF )) && OFF=${start[idx]}
        (( ends[idx] > OFF + AVAIL - 2 )) && OFF=$(( ends[idx] - AVAIL + 2 ))
      else OFF=9999; fi
      prompt="${B}$(role_plan)${N}"$'\n'
      if (( idx == ${#NAMES[@]} )); then prompt+="${B}${P}> Continue →${N}"; else prompt+="  Continue →"; fi
      [[ -z $SYS ]] && prompt+="   ${D}(needs a System disk)${N}"
      render "$prompt" "↑↓ highlight · enter set role"
      readkey
      case $KEY in
        up) ((idx > 0)) && idx=$((idx - 1)) ;;
        down) ((idx < ${#NAMES[@]})) && idx=$((idx + 1)) ;;
        pgup|pgdn) scroll "$KEY" ;;
        back) return 1 ;;
        enter)
          if (( idx == ${#NAMES[@]} )); then
            [[ -n $SYS ]] && break
            warn "Pick a System disk first: highlight a disk, enter, System"
          else
            TITLE="Disks · role for ${NAMES[idx]}"; set_role "${NAMES[idx]}"
            (( idx < ${#NAMES[@]} - 1 )) && [[ -n ${ROLE[${NAMES[idx]}]} ]] && idx=$((idx + 1))
          fi ;;
      esac
    done
  fi
  # roles → the variables the later steps use
  MIRRORS=(); HOME_DISK=""; DATA=(); OTHER=()
  for n in "${NAMES[@]}"; do
    case ${ROLE[$n]:-untouched} in
      system) ;; mirror) MIRRORS+=("$n") ;; home) HOME_DISK=$n ;; data) DATA+=("$n") ;;
      ""|untouched) OTHER+=("$n|untouched") ;; *) OTHER+=("$n|${ROLE[$n]}") ;;
    esac
  done
}

# FS_INFO — the filesystem guide box step_fs shows above the choice.
FS_INFO=(
  "btrfs     Snapshots (snapper, hourly), compression, subvolumes. Roll back a bad update."
  "          ★ Recommended for desktops/laptops — what every host uses today."
  "ext4      The Linux default. Very stable and simple. No snapshots."
  "xfs       Fast with big files and parallel IO. Cannot shrink. No snapshots."
  "bcachefs  In-kernel, snapshots + compression like btrfs. Still young — expect rough edges."
  "zfs       Best data integrity, pools/raidz, native encryption. Built for servers/NAS."
  "          ⚠ Out-of-tree module: kernel is held to the newest version ZFS supports"
  "            (your hosts run _latest/_zen). Uses a lot of RAM for its cache.")

# step_fs — choose the filesystem for every disk role picked in step_disks.
#   System disk  with mirrors: choose_raid picks a RAID layout and FS is its
#                prefix (btrfs-raid1 → btrfs); without: btrfs, ext4, xfs,
#                bcachefs or zfs
#   /home disk   btrfs, ext4 or xfs, plus a label (default "home")
#   Data disks   a mount point (default /data); several disks → a RAID
#                layout; one disk that already has partitions → keep it
#                (DATA_KEEP=1, mounted as-is by UUID, its current label
#                offered) or format it with btrfs, ext4, xfs or zfs
#   Labels default to "data", or "tank" for a ZFS pool.
#   Sets     FS SYS_RAID HOME_FS HOME_LABEL DATA_MNT DATA_RAID DATA_FS
#            DATA_KEEP DATA_LABEL DATA_OLDLABEL
#   Returns  0 next, 1 back (esc), 3 stay on this step when soon() rejects a
#            choice real mode cannot install yet
#   Example  step_fs
step_fs() {
  SYS_RAID=""; HOME_FS=""; DATA_RAID=""; DATA_FS=""; DATA_KEEP=0; DATA_MNT=""; HOME_LABEL=home; DATA_LABEL=data; DATA_OLDLABEL=""
  if (( ${#MIRRORS[@]} )); then
    TITLE="Filesystem · system disk + mirror"
    choose_raid system "$SYS" "${MIRRORS[@]}" || return 1; SYS_RAID=$RAID_CHOICE; FS=${SYS_RAID%%-*}
    if soon "$SYS_RAID"; then JUMP=$CUR; return 3; fi
  else
    panel "Filesystem for $SYS" "$(box -t "Filesystems" "${FS_INFO[@]}")"
    pick FS "" "btrfs ★|btrfs" "ext4|ext4" "xfs|xfs" "bcachefs|bcachefs" "zfs  (servers)|zfs" || return 1
    if soon "$FS"; then JUMP=$CUR; return 3; fi
  fi
  if [[ -n $HOME_DISK ]]; then
    panel "Filesystem for /home on $HOME_DISK" "$(box -t "Filesystems" "${FS_INFO[@]:0:4}")"
    pick HOME_FS "" "btrfs  snapshots of user files|btrfs" "ext4|ext4" "xfs|xfs" || return 1
    ask_label HOME_LABEL "$HOME_FS" home || return 1
  fi
  if (( ${#DATA[@]} )); then
    panel "Data pool · ${DATA[*]}"
    ask DATA_MNT --header "Mount point for the data pool (${DATA[*]})" --value "/data" || return 1
    if (( ${#DATA[@]} > 1 )); then
      TITLE="Data pool · $DATA_MNT"
      choose_raid data "${DATA[@]}" || return 1; DATA_RAID=$RAID_CHOICE; DATA_FS=${DATA_RAID%%-*}
      if soon "$DATA_RAID"; then JUMP=$CUR; return 3; fi
      ask_label DATA_LABEL "$DATA_FS" "$([[ $DATA_FS == zfs ]] && echo tank || echo data)" || return 1
    else
      local d=${DATA[0]} k=format
      if [[ -n $(disk "$d" .parts) ]]; then
        panel "Data disk $d → $DATA_MNT" "$(disk_table "$(jq --arg n "$d" '[.[] | select(.name==$n)]' <<<"$DISKS")")"
        pick k "$d already contains: $(disk "$d" .parts)" \
          "Keep existing data   mount it as-is by UUID (reinstall-safe)|keep" \
          "Format               wipe it and start fresh|format" || return 1
      fi
      if [[ $k == keep ]]; then
        DATA_KEEP=1; DATA_FS=$(jq -r --arg n "$d" '.[] | select(.name==$n) | [.segs[] | select(.fs != "vfat")][0].fs' <<<"$DISKS")
        DATA_OLDLABEL=$(disk "$d" .curlabel)
        ask_label DATA_LABEL "$DATA_FS" "${DATA_OLDLABEL:-data}" || return 1
      else
        panel "Filesystem for $d → $DATA_MNT" "$(box -t "Filesystems" "${FS_INFO[@]}")"
        pick DATA_FS "" "btrfs|btrfs" "ext4|ext4" "xfs  good for big media files|xfs" "zfs|zfs" || return 1
        if soon "$DATA_FS"; then JUMP=$CUR; return 3; fi
        ask_label DATA_LABEL "$DATA_FS" "$([[ $DATA_FS == zfs ]] && echo tank || echo data)" || return 1
      fi
    fi
  fi
}

# step_boot — choose the bootloader and set BOOT.
#   systemd-boot  UEFI only, the default
#   grub          UEFI and legacy BIOS; handles mirrored boot partitions
#   limine        UEFI and legacy BIOS
#   refind        UEFI only; soon() rejects it in real mode
#   On legacy BIOS (FW=bios) the UEFI-only entries are hidden with a warning.
#   Returns  0 next, 1 back, 3 stay (choice not supported yet)
#   Example  step_boot
step_boot() {
  panel "Bootloader  (${FW^^} detected)" "$(box -t "Bootloaders" \
       "systemd-boot  Minimal and fast, lists every generation. UEFI only. ★ current default" \
       "GRUB          Most compatible: UEFI + legacy BIOS. Themeable, a bit slower." \
       "              Best at mirrored boot (mirroredBoots) and finding other OSes (os-prober)." \
       "Limine        Modern, fast, nice menu. UEFI + BIOS. Newer NixOS module." \
       "rEFInd        Graphical, auto-detects OSes on other disks. UEFI only." \
       "              Good if you boot Windows from its own disk through the menu.")"
  local o=()
  [[ $FW == uefi ]] && o+=("systemd-boot ★|systemd-boot")
  o+=("GRUB|grub" "Limine|limine")
  [[ $FW == uefi ]] && o+=("rEFInd|refind")
  [[ $FW == bios ]] && warn "Legacy BIOS: systemd-boot and rEFInd need UEFI — hidden"
  pick BOOT "" "${o[@]}" || return 1
  if soon "$BOOT"; then JUMP=$CUR; return 3; fi
}

# step_enc — choose disk encryption and set ENC.
#   luks  LUKS2 on the system disk (and its mirrors, same passphrase)
#   zfs   ZFS native encryption; offered instead of luks when FS is zfs
#   none  no passphrase at boot
#   The encrypted entry is starred when HW_FORM is laptop.
#   Returns  0 next, 1 back
#   Example  step_enc
step_enc() {
  local lstar=""; [[ $HW_FORM == laptop ]] && lstar=" ★ (laptop detected)"
  if [[ $FS == zfs ]]; then
    panel "Encryption" "$(box -t "Encryption" "ZFS has its own encryption — used instead of LUKS." "Passphrase at every boot; protects data if the machine is stolen.")"
    pick ENC "" "ZFS native encryption$lstar|zfs" "None   boots straight to login|none" || return 1
  else
    panel "Encryption" "$(box -t "Encryption" "LUKS2  Passphrase at every boot. Protects your data if the device is stolen." \
         "       Recommended for laptops. With a mirror, both disks unlock with the same passphrase." \
         "None   Boots straight to login. Fine for desktops/servers that never leave the house.")"
    pick ENC "" "LUKS2$lstar|luks" "None|none" || return 1
  fi
}

# step_swap — choose swap and set SWAP (size in GB; 0 = zram only).
#   N       a swapfile of N GB; the default is the RAM size, capped at 16
#   custom  asks for the size in GB
#   0       zram only (compressed RAM swap), no swapfile; the only choice
#           when FS is zfs
#   Returns  0 next, 1 back
#   Example  step_swap
step_swap() {
  local def=$(( RAM_B/1000000000 < 16 ? RAM_B/1000000000 : 16 ))
  if [[ $FS == zfs ]]; then
    panel "Swap  (RAM $(hsize "$RAM_B"))" "$(box -t "Swap" "Swap on ZFS can deadlock under memory pressure — zram (compressed RAM) is used instead.")"
    pick SWAP "" "OK|0" || return 1
  else
    panel "Swap  (RAM $(hsize "$RAM_B"))"
    pick SWAP "" "${def}G swapfile ★   (RAM, capped at 16G — hibernate needs ≥ RAM)|$def" \
      "Custom size|custom" "zram only   compressed RAM swap, no disk swap|0" || return 1
    if [[ $SWAP == custom ]]; then
      while :; do
        ask SWAP --header "Swapfile size in GB (whole number)" --value "$def" || return 1
        [[ $SWAP =~ ^[1-9][0-9]*$ ]] && break
        warn "enter a whole number of GB, e.g. 8"
      done
    fi
  fi
}

# --------------------------------------------------------------------------
# Config source and the starter-template steps
# --------------------------------------------------------------------------

# set_mode — build the step list for the chosen SOURCE and display mode.
#   SOURCE=starter   asks user, region, desktop, kernel and unfree questions
#   SOURCE=linuxury  takes those from the cloned config and asks for secrets
#   HUB=1            replaces the linear disk steps with a menu (step_hub) and
#                    one step_diskconf; kernel, unfree and packages count as
#                    visited because their defaults are valid
#   Sets     SRC_LABEL STEPS STEP_NAMES REVIEW_IDX HEADER, and UNFREE=true when
#            an NVIDIA GPU was detected
#   Example  SOURCE=starter; set_mode
set_mode() {
  if [[ $SOURCE == starter ]]; then
    SRC_LABEL="starter template"
    STEPS=(step_source step_host step_disks step_fs step_boot step_enc step_swap step_user step_region step_desktop step_kernel step_unfree step_review)
    STEP_NAMES=(Source Host Disks Filesystem Boot Encrypt Swap User Region Desktop Kernel Unfree Review)
  else
    SRC_LABEL="Linuxury's config"
    STEPS=(step_source step_host step_disks step_fs step_boot step_enc step_swap step_secrets step_review)
    STEP_NAMES=(Source Host Disks Filesystem Boot Encrypt Swap Secrets Review)
  fi
  if ((HUB)); then
    if [[ $SOURCE == starter ]]; then
      STEPS=(step_source step_hub step_host step_diskconf step_user step_region step_desktop step_kernel step_unfree step_packages step_review)
      STEP_NAMES=(Source Menu Host Disks User Region Desktop Kernel Unfree Packages Review)
    else
      STEPS=(step_source step_hub step_host step_diskconf step_secrets step_review)
      STEP_NAMES=(Source Menu Host Disks Secrets Review)
    fi
    VISITED[step_kernel]=1; VISITED[step_unfree]=1; VISITED[step_packages]=1   # optional: the defaults are valid answers
  fi
  if [[ $HW_GPU == *NVIDIA* ]]; then UNFREE=true; fi   # the NVIDIA driver is unfree
  REVIEW_IDX=$(( ${#STEPS[@]} - 1 ))
  HEADER=$(banner)
}

# load_config — Linuxury mode: get the config (a given checkout, or a shallow clone) and its hosts
#   INSTALLER_REPO  use this checkout instead of cloning
#   otherwise       git clone --depth 1 of CFG_URL into $TMP/config (reused if
#                   already there)
#   Each "<Host> = mkHost" block in flake.nix with a "user =" line becomes one
#   "Host user" entry in HOSTS.
#   Sets     REPO HOSTS
#   Returns  1 (with a warning) when the clone fails or no hosts are found
#   Example  load_config || return 1
load_config() {
  if [[ -n ${INSTALLER_REPO:-} ]]; then REPO=$INSTALLER_REPO
  else
    REPO=$TMP/config
    [[ -d $REPO/.git ]] || git clone -q --depth 1 "$CFG_URL" "$REPO" 2>/dev/null || { warn "could not download $CFG_URL (network?)"; return 1; }
  fi
  mapfile -t HOSTS < <(awk '/^ *[A-Za-z0-9-]+ = mkHost/{h=$1} h && /user *=/{gsub(/[";]/,"",$3); print h" "$3; h=""}' "$REPO/flake.nix")
  (( ${#HOSTS[@]} )) || { warn "no hosts found in $CFG_URL"; return 1; }
}

# step_source — first step: choose where the system config comes from.
#   starter   a fresh flake for one host, written to the new user's home
#   linuxury  clone the existing config (load_config) and add this machine
#   CONFIG=<file>  replay a saved answers file: read .source, load the config,
#                  restore the answers (config_replay) and jump to the review;
#                  on any failure CONFIG is cleared and the menu is shown
#   INSTALL_TEST + TEST_SOURCE  override the choice in automated tests
#   Returns  0 next, 1 back, 3 jump (replay → review; failure → this step)
#   Example  step_source
step_source() {
  if [[ -n $CONFIG ]]; then   # replay: no questions, straight to the review
    [[ -f $CONFIG ]] || { warn "answers file not found: $CONFIG"; CONFIG=""; JUMP=$CUR; return 3; }
    SOURCE=$(jq -r '.source // "starter"' "$CONFIG"); set_mode
    if [[ $SOURCE == linuxury ]]; then load_config || { CONFIG=""; JUMP=$CUR; return 3; }; fi
    config_replay "$CONFIG" || { warn "some disks from $CONFIG are not in this machine:"$'\n'"$LOAD_MISSING"; CONFIG=""; JUMP=$CUR; return 3; }
    JUMP=$REVIEW_IDX; return 3
  fi
  panel "Where should the system configuration come from?" "$(box -t "Config source" \
    "Starter template   None of my setup: you get a complete NixOS flake for a first host," \
    "                   written to your home folder with the first git commit already made." \
    "Linuxury's config  My own setup (desktops, services, secrets), made for my machines." \
    "                   Clones it and adds this machine's disk layout.")"
  pick SOURCE "" "Starter template ★   a fresh first host; you own the result|starter" \
                 "Linuxury's config   my own setup, tuned for my machines|linuxury" || return 1
  [[ -n ${INSTALL_TEST:-} && -n ${TEST_SOURCE:-} ]] && SOURCE=$TEST_SOURCE
  set_mode
  if [[ $SOURCE == linuxury ]]; then load_config || { JUMP=$CUR; return 3; }; fi
}

# step_host — name the machine: host_starter for a new host, host_linuxury to
# pick one of the config's hosts.
#   Example  step_host
step_host() { if [[ $SOURCE == starter ]]; then host_starter; else host_linuxury; fi; }

# host_starter — show the detected hardware and ask for a hostname (a letter,
# then letters, digits or dashes; asked again until valid).
#   Sets     HOST, NEWHOST=1, PROFILE (laptop or desktop, from HW_FORM)
#   Returns  0 next, 1 back
#   Example  host_starter
host_starter() {
  panel "Name this computer" "$(box -t "Detected hardware" "Used to fill in the hardware settings of your starter config:" \
    "$(printf '%-9s %-26s %-9s %s' CPU "$HW_CPU + microcode" GPU "$HW_GPU")" \
    "$(printf '%-9s %-26s %-9s %s' Type "$HW_FORM" WiFi "$([[ $HW_WIFI == 1 ]] && echo yes || echo no)")" \
    "$(printf '%-9s %s' RAM "$(hsize "$RAM_B")")")"
  while :; do
    ask HOST --header "Hostname (letters, digits, dashes)" --value "${HOST:-nixos}" || return 1
    [[ $HOST =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] && break
    warn "invalid hostname"
  done
  NEWHOST=1; PROFILE=$([[ $HW_FORM == laptop ]] && echo laptop || echo desktop)
}

# step_user — starter mode: the admin account and SSH.
#   NIXUSER  lowercase letter, then up to 30 lowercase letters, digits or
#            dashes; "root" is refused; asked again until valid
#   SSH      false (default) or true to enable the OpenSSH server
#   The password is set at the end of the install, not stored in the config.
#   Returns  0 next, 1 back
#   Example  step_user
step_user() {
  panel "Your account" "$(box -t "Account" \
    "The first user is an administrator (can use sudo)." \
    "The password is asked at the end of the install and is not stored in the config." \
    "More users can be added later in hosts/<host>/default.nix.")"
  while :; do
    ask NIXUSER --header "Username (lowercase letters, digits, dashes)" --value "${NIXUSER:-user}" || return 1
    [[ $NIXUSER =~ ^[a-z][a-z0-9-]{0,30}$ && $NIXUSER != root ]] && break
    warn "invalid username"
  done
  pick SSH "Remote login (SSH)" "No   recommended unless you need it|false" "Yes  log in from another computer|true" || return 1
}

# step_region — starter mode: timezone and keyboard layout.
#   TZONE   a listed tz database name, or "Other…" to type one (letters,
#           digits, _ + / -); `timedatectl list-timezones` lists them all
#   KEYMAP  console keymap (console.keyMap), e.g. us, de-latin1
#   XKB     desktop layout (services.xserver.xkb.layout), e.g. us, gb
#   Menu values are "keymap:xkb" pairs because the two names differ
#   (uk:gb, la-latin1:latam); "Other…" asks for each name.
#   Returns  0 next, 1 back
#   Example  step_region
step_region() {
  panel "Region" "$(box -t "Timezone and keyboard" \
    "The timezone sets the clock. The keyboard layout is used at the login screen and in the terminal." \
    "The locale is en_US.UTF-8; change it later in default.nix.")"
  pick TZONE "Timezone" "UTC   change later|UTC" "US Eastern   New York|America/New_York" "US Central   Chicago|America/Chicago" \
    "US Mountain   Denver|America/Denver" "US Pacific   Los Angeles|America/Los_Angeles" "UK   London|Europe/London" \
    "Spain   Madrid|Europe/Madrid" "Germany   Berlin|Europe/Berlin" "France   Paris|Europe/Paris" "Japan   Tokyo|Asia/Tokyo" \
    "Other…   type a name, e.g. America/Puerto_Rico|other" || return 1
  if [[ $TZONE == other ]]; then
    while :; do
      ask TZONE --header "Timezone name (see: timedatectl list-timezones)" --value UTC || return 1
      [[ $TZONE =~ ^[A-Za-z][A-Za-z0-9_+/-]*$ ]] && break
      warn "invalid timezone name"
    done
  fi
  local kb
  pick kb "Keyboard layout" "US English|us:us" "UK English|uk:gb" "German|de:de" "French|fr:fr" "Spanish|es:es" \
    "Latin American|la-latin1:latam" "Portuguese (Brazil)|br-abnt2:br" "Other…   type the names|other" || return 1
  if [[ $kb == other ]]; then
    ask KEYMAP --header "Console keymap (e.g. us, de-latin1)" --value us || return 1
    ask XKB --header "Desktop layout (e.g. us, de)" --value "$KEYMAP" || return 1
  else KEYMAP=${kb%%:*}; XKB=${kb##*:}; fi
}

# step_desktop — starter mode: choose the desktop stack and set DESKTOP.
#   none    text login only (default)
#   gnome   stacks/gnome.nix
#   kde     stacks/kde.nix (Plasma 6)
#   cosmic  stacks/cosmic.nix
#   The chosen stack's import is uncommented in the host file (stack_mark);
#   the others stay commented so switching later is one line.
#   INSTALL_TEST + TEST_DESKTOP  override the choice in automated tests
#   Returns  0 next, 1 back
#   Example  step_desktop
step_desktop() {
  panel "Desktop" "$(box -t "Desktop stacks" \
    "None        Text login only. Good for servers, or if you will build your own desktop." \
    "GNOME       Simple and polished. GDM login, sound, Bluetooth, printing." \
    "KDE Plasma  Customisable and familiar. SDDM login (Wayland), sound, Bluetooth, printing." \
    "COSMIC      New Rust desktop by System76. Sound, Bluetooth, printing." \
    "" "Each stack is a short file in stacks/. Switching later is one line in default.nix.")"
  pick DESKTOP "" "None ★   text login only|none" "GNOME|gnome" "KDE Plasma 6|kde" "COSMIC|cosmic" || return 1
  if [[ -n ${INSTALL_TEST:-} && -n ${TEST_DESKTOP:-} ]]; then DESKTOP=$TEST_DESKTOP; fi
}

# kernel_attr KEY — the nixpkgs package set for a kernel choice.
#   latest → linuxPackages_latest, zen → linuxPackages_zen, anything else →
#   linuxPackages (the LTS default)
#   Example  kernel_attr zen   # prints linuxPackages_zen
kernel_attr() { case $1 in latest) echo linuxPackages_latest ;; zen) echo linuxPackages_zen ;; *) echo linuxPackages ;; esac; }
# kernel_version KEY — the Linux version that choice has in the nixpkgs the new system will be locked to ("" if offline)
#   Evaluates github:NixOS/nixpkgs/<nixpkgs_channel>#<attr>.kernel.version
#   once per KEY and caches it in KVER ("-" marks a failed lookup, so it is
#   not retried).
#   Example  kernel_version latest   # e.g. 6.17.8
kernel_version() {
  local k=$1 v
  if [[ -z ${KVER[$k]:-} ]]; then
    v=$(nixc eval --raw "github:NixOS/nixpkgs/$(nixpkgs_channel)#$(kernel_attr "$k").kernel.version" 2>/dev/null) || v=""
    KVER[$k]=${v:--}
  fi
  if [[ ${KVER[$k]} != - ]]; then echo "${KVER[$k]}"; fi
}
# kernel_label — short form for the menu and review, e.g. "7.3.3 latest"
#   Uses KERNEL, or "default (ZFS)" when FS is zfs; the version is left out
#   when offline.
#   Example  kernel_label
kernel_label() {
  local k=$KERNEL v z=""
  if [[ ${FS:-} == zfs ]]; then k=default; z=" (ZFS)"; fi
  v=$(kernel_version "$k")
  echo "${v:+$v }$k$z"
}

# step_kernel — starter mode: choose the kernel and set KERNEL.
#   default  linuxPackages, long-term support
#   latest   linuxPackages_latest, newest stable
#   zen      linuxPackages_zen, desktop-tuned
#   Each entry shows the version from kernel_version. With FS=zfs only
#   "default" is offered.
#   INSTALL_TEST + TEST_KERNEL  override the choice in automated tests
#   Returns  0 next, 1 back
#   Example  step_kernel
step_kernel() {
  local vd vl vz
  printf '  checking the kernel versions …\r' >"$TTY"
  vd=$(kernel_version default); vl=$(kernel_version latest); vz=$(kernel_version zen)
  if [[ ${FS:-} == zfs ]]; then
    panel "Kernel" "$(box -t "Kernel" "ZFS only works with some kernels, so the default kernel ${vd:+(Linux $vd) }is used.")"
    pick KERNEL "" "OK|default" || return 1
    return 0
  fi
  panel "Kernel" "$(box -t "Linux kernel" \
    "$(printf '%-8s %-13s %s' Default "${vd:+Linux $vd}" "Long-term support. Most tested.")" \
    "$(printf '%-8s %-13s %s' Latest "${vl:+Linux $vl}" "Newest stable. New hardware sooner.")" \
    "$(printf '%-8s %-13s %s' Zen "${vz:+Linux $vz}" "Desktop-tuned (gaming, audio).")" \
    "" "Versions in nixpkgs ($(nixpkgs_channel)) today. The install uses the same." \
    "It is one line in your host file, so you can change it later.")"
  pick KERNEL "" "Default ★   ${vd:+$vd · }long-term support|default" "Latest      ${vl:+$vl · }newest stable|latest" "Zen         ${vz:+$vz · }desktop-tuned|zen" || return 1
  if [[ -n ${INSTALL_TEST:-} && -n ${TEST_KERNEL:-} ]]; then KERNEL=$TEST_KERNEL; fi
}

# step_unfree — starter mode: set UNFREE (nixpkgs.config.allowUnfree).
#   false  free software only (default)
#   true   allow unfree packages; the only choice when an NVIDIA GPU was
#          detected, because its driver is unfree
#   INSTALL_TEST + TEST_UNFREE  override the choice in automated tests
#   Returns  0 next, 1 back
#   Example  step_unfree
step_unfree() {
  if [[ $HW_GPU == *NVIDIA* ]]; then
    panel "Unfree software" "$(box -t "Unfree software" "Your NVIDIA graphics card needs its proprietary driver, so unfree software is allowed.")"
    pick UNFREE "" "OK|true" || return 1
    return 0
  fi
  panel "Unfree software" "$(box -t "Unfree software" \
    "Some programs are free to use but not open source: Steam, Discord, Spotify," \
    "Google Chrome, VS Code and the NVIDIA driver. NixOS refuses to install them" \
    "unless you allow it here. Free software only is the default." \
    "" "It is one line in your host file (nixpkgs.config.allowUnfree).")"
  pick UNFREE "" "No ★   free software only|false" "Yes   allow unfree programs|true" || return 1
  if [[ -n ${INSTALL_TEST:-} && -n ${TEST_UNFREE:-} ]]; then UNFREE=$TEST_UNFREE; fi
}

# step_secrets — linuxury mode: create the new host's SSH host key so agenix
# secrets can be re-keyed for it.
#   Generates $KEYDIR/ssh_host_ed25519_key once (ed25519, no passphrase,
#   comment root@HOST); KEYDIR lives outside TMP so --resume keeps the key.
#   Shows the public key as an add-host command and as a QR code (qrencode).
#   SECRETS  done  add-host was run; the re-keyed secrets are pulled
#            skip  install anyway; secrets fail to decrypt until re-keyed
#   Returns  0 next, 1 back
#   Example  step_secrets
step_secrets() {
  mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
  [[ -f $KEYDIR/ssh_host_ed25519_key ]] || ssh-keygen -q -t ed25519 -N "" -C "root@$HOST" -f "$KEYDIR/ssh_host_ed25519_key"
  local pub; pub=$(cut -d' ' -f1,2 "$KEYDIR/ssh_host_ed25519_key.pub")
  local keybox qr
  keybox=$(box -t "Host key" "New host key for $HOST → /mnt/etc/ssh/ssh_host_ed25519_key" \
      "install-host (SSH) registers it by itself. At the console, run on your admin machine:" \
      "  add-host $HOST \\" "    '$pub'")
  qr=$(qrencode -t ansiutf8 -m 1 "$pub")
  panel "Secrets (agenix)" "$keybox"$'\n'"${D}or scan the key:${N}"$'\n'"$qr"
  pick SECRETS "" "I ran add-host — pull the re-keyed secrets|done" "Skip — secrets fail until re-keyed later (docs/04)|skip" || return 1
}

# other_action ROLE — plain words for what happens to a disk that is not
# formatted (role boot, mount-ro, mount-rw or boot+mount-ro); any other value
# is printed as-is.
#   Example  other_action mount-rw   # prints "mounted read-write"
other_action() {  # boot+mount-ro → "in boot menu + mounted read-only"
  case $1 in
    boot) echo "in boot menu" ;; mount-ro) echo "mounted read-only" ;; mount-rw) echo "mounted read-write" ;;
    boot+mount-ro) echo "in boot menu + mounted read-only" ;; *) echo "$1" ;;
  esac
}

# planned — the disk list after the install, for the review screen.
# Takes DISKS and the answers (SYS MIRRORS HOME_DISK DATA OTHER FS ENC FW ...)
# and prints a JSON array with one object per disk:
#   name size  as in DISKS
#   segs       the partitions after the install; each has .purpose (what it is
#              used for, "not mounted" by default)
#   action     coloured label: WIPE (system, mirror, /home, formatted data),
#              keep (data disk kept by UUID; shows a label change if any),
#              or other_action's text for other disks
#   same       true when the disk is not changed at all
# System and mirror disks get a 1 GiB EFI partition + root on UEFI, or a
# 1 MiB bios_grub area + root on BIOS; root shows as luks+FS when encrypted.
#   Example  planned | jq '.[] | select(.same == false) | .name'
planned() {  # DISKS + choices → same JSON shape; .segs = new layout (with .purpose), .action, .same
  local n p=() fsl sz segs act o same rootp dd
  fsl=$([[ $ENC == luks ]] && echo "luks+$FS" || echo "$FS")
  for n in "${NAMES[@]}"; do
    act="${D}untouched${N}"; same=true; sz=$(disk "$n" .size)
    segs=$(jq -c --arg n "$n" '.[] | select(.name==$n) | .segs | map(. + {purpose: "not mounted"})' <<<"$DISKS")
    if [[ " $SYS ${MIRRORS[*]} " == *" $n "* ]]; then
      act="${R}WIPE${N}"; same=false
      rootp="/ system"; [[ -z $HOME_DISK ]] && rootp+=" + /home"
      [[ $n != "$SYS" ]] && rootp="mirror copy of $SYS"
      segs=$(jq -nc --arg fs "$fsl" --arg l "nixos" --argjson s "$sz" --arg fw "$FW" \
        --arg p1 "$(part "$n" 1 | sed 's#/dev/##')" --arg p2 "$(part "$n" 2 | sed 's#/dev/##')" --arg rp "$rootp" \
        --arg bp "$([[ $n == "$SYS" ]] && echo "boot loader" || echo "boot loader (copy)")" \
        'if $fw == "uefi" then [{dev:$p1,fs:"vfat",label:"EFI",size:1073741824,purpose:$bp},{dev:$p2,fs:$fs,label:$l,size:($s-1073741824),purpose:$rp}]
         else [{dev:$p1,fs:"bios_grub",label:"",size:1048576,purpose:"GRUB boot area"},{dev:$p2,fs:$fs,label:$l,size:($s-1048576),purpose:$rp}] end')
    elif [[ $n == "$HOME_DISK" ]]; then
      act="${R}WIPE${N}"; same=false
      segs=$(jq -nc --arg n "$n" --arg fs "$HOME_FS" --arg l "$HOME_LABEL" --argjson s "$sz" '[{dev:$n,fs:$fs,label:$l,size:$s,purpose:"/home"}]')
    elif [[ " ${DATA[*]} " == *" $n "* ]]; then
      same=false
      if [[ $DATA_KEEP == 1 ]]; then
        act="${G}keep${N}"; dd=$(disk "$n" .datadev)
        [[ $DATA_LABEL != "$DATA_OLDLABEL" ]] && act+=" · label ${DATA_OLDLABEL:-—} → $DATA_LABEL"
        segs=$(jq -c --arg d "$dd" --arg l "$DATA_LABEL" --arg m "$DATA_MNT" 'map(if .dev == $d then .label = $l | .purpose = $m else . end)' <<<"$segs")
      else
        act="${R}WIPE${N}"
        segs=$(jq -nc --arg n "$n" --arg fs "${DATA_RAID:-$DATA_FS}" --arg l "$DATA_LABEL" --argjson s "$sz" \
          --arg m "$DATA_MNT$([[ -n $DATA_RAID ]] && echo " (pool member)" || true)" '[{dev:$n,fs:$fs,label:$l,size:$s,purpose:$m}]')
      fi
    else
      for o in "${OTHER[@]}"; do
        [[ ${o%%|*} == "$n" ]] || continue
        act="${D}$(other_action "${o#*|}")${N}"
        [[ ${o#*|} == untouched ]] && continue
        same=false; dd=$(disk "$n" .datadev)
        local pu=""; [[ ${o#*|} == *boot* ]] && pu="in boot menu"
        [[ ${o#*|} == *mount* ]] && pu+="${pu:+ + }/mnt/$(disk "$n" .os | sed 's/./\u&/') ($([[ ${o#*|} == *rw ]] && echo rw || echo ro))"
        segs=$(jq -c --arg d "$dd" --arg p "$pu" 'map(if .dev == $d then .purpose = $p else . end)' <<<"$segs")
      done
    fi
    p+=("$(jq -nc --arg n "$n" --argjson s "$sz" --argjson g "$segs" --arg a "$act" --argjson same "$same" '{name:$n,size:$s,segs:$g,action:$a,same:$same}')")
  done
  printf '%s\n' "${p[@]}" | jq -s .
}

# review_cards BEFORE AFTER — one framed card per disk, frame + status coloured by
# what happens to it (red WIPE · green keep · gray untouched · blue other OS)
#   BEFORE  the DISKS JSON as scanned
#   AFTER   planned's output
#   Unchanged disks list their partitions once; changed disks show "now" and
#   "after" rows, the after rows with their purpose. A SMART warn/fail status
#   is added to the card title.
#   Example  review_cards "$DISKS" "$(planned)"
review_cards() {
  local before=$1 after=$2 n s t m h o act same i d l f z u tree fc st title
  local -a LS RS rows
  printf "  ${D}%-10s%s   USED FOR${N}\n" "" "$SEG_HEAD"
  while IFS=$'\x1f' read -r n s t m h o; do
    act=$(jq -r --arg n "$n" '.[] | select(.name==$n) | .action' <<<"$after" | strip_ansi)
    same=$(jq -r --arg n "$n" '.[] | select(.name==$n) | .same' <<<"$after")
    case $act in
      WIPE*)      fc=$'\e[38;5;203m'; st="● WIPE" ;;
      keep*)      fc=$'\e[38;5;114m'; st="● $act" ;;
      untouched*) fc=$'\e[38;5;242m'; st="○ untouched" ;;
      *)          fc=$'\e[38;5;117m'; st="◆ $act" ;;
    esac
    mapfile -t LS < <(jq -r --arg n "$n" ".[] | select(.name==\$n) | $SEG_JQ" <<<"$before")
    mapfile -t RS < <(jq -r --arg n "$n" ".[] | select(.name==\$n) | $SEG_JQ" <<<"$after")
    rows=()
    if [[ $same == true ]]; then
      (( ${#LS[@]} )) || rows+=("         ${D}(empty)${N}")
      for i in "${!LS[@]}"; do
        IFS=$'\x1f' read -r d l f z u <<<"${LS[i]}"; tree="├"; ((i == ${#LS[@]} - 1)) && tree="└"
        rows+=("        $tree $(fmt_seg "$d" "$l" "$f" "$z")   ${D}$( ((i == 0)) && echo "(unchanged)" || true)${N}")
      done
    else
      (( ${#LS[@]} )) || rows+=(" ${D}now    (empty — no partitions)${N}")
      for i in "${!LS[@]}"; do
        IFS=$'\x1f' read -r d l f z u <<<"${LS[i]}"; tree="├"; ((i == ${#LS[@]} - 1)) && tree="└"
        rows+=(" ${D}$(printf '%-6s' "$( ((i == 0)) && echo now || true)") $tree $(fmt_seg "$d" "$l" "$f" "$z")${N}")
      done
      for i in "${!RS[@]}"; do
        IFS=$'\x1f' read -r d l f z u <<<"${RS[i]}"; tree="├"; ((i == ${#RS[@]} - 1)) && tree="└"
        rows+=(" ${B}$(printf '%-6s' "$( ((i == 0)) && echo after || true)")${N} $tree $(fmt_seg "$d" "$l" "$f" "$z")   ${G}$u${N}")
      done
    fi
    title="$n · $(hsize "$s") ${t^^} · $m"
    [[ ${h%%|*} == warn || ${h%%|*} == fail ]] && title+=" · ${h#*|}"
    card "$fc" "$title" "$st" "${rows[@]}"; echo
  done < <(jq -r '.[] | [.name, .size, .tran, .model, .smart, .os] | map(tostring) | join("\u001f")' <<<"$before")
}

# review_summary AFTER — one line listing every change in planned's output:
# wiped disks, kept disks with their mount point, other changed disks with
# their action, and a count of untouched disks.
#   Example  review_summary "$(planned)"
review_summary() {  # "Changes: wipe nvme0n1 · keep sda → /data · 1 untouched"
  jq -r '[.[] | (.action | gsub("\u001b\\[[0-9;]*m"; "")) as $a
          | if ($a|startswith("WIPE")) then "wipe \(.name)"
            elif ($a|startswith("keep")) then "keep \(.name)" + ([.segs[] | select(.purpose|startswith("/")) | " → " + .purpose][0] // "")
            elif .same then empty else "\(.name): \($a)" end] as $c
        | ([.[] | select(.same)] | length) as $u
        | "Changes: " + (($c + (if $u > 0 then ["\($u) untouched"] else [] end)) | join(" · "))' <<<"$1"
}

# enc_label — ENC as shown in the review: none, LUKS2 or ZFS native.
#   Example  enc_label
enc_label() {
  case $ENC in none) echo none ;; luks) echo "LUKS2" ;; *) echo "ZFS native" ;; esac
}

# panel_box WIDTH "Title" "label value"… — lines longer than the box get "…", never wrap
#   A fixed-width gum box (rounded border, bold title) so two can sit side by
#   side in the review.
#   Example  panel_box 40 "System" "Host    $HOST" "Boot    $BOOT"
panel_box() {
  local LC_ALL=C.UTF-8 w=$1 t=$2 l out=(); shift 2
  for l; do (( ${#l} > w - 4 )) && l="${l:0:$(( w - 5 ))}…"; out+=("$l"); done
  gum style --border rounded --border-foreground 240 --padding "0 1" --width "$w" \
    "$(gum style --bold --foreground 212 "$t")" "${out[@]}"
}

# review_last — the last review line: SSH on/off for a starter config, or
# whether secrets were re-keyed in linuxury mode.
#   Example  review_last
review_last() {
  if [[ $SOURCE == starter ]]; then echo "Config  starter flake, SSH $([[ $SSH == true ]] && echo on || echo off)"
  else echo "Secrets $([[ $SECRETS == "done" ]] && echo "re-keyed ✓" || echo "skipped")"; fi
}

# review_warnings — print one warning per risk in the current answers:
#   - a SMART warn/fail on any disk that will be used
#   - ZFS holding the kernel back
#   - a laptop without encryption
#   - secrets skipped in linuxury mode
#   - a btrfs system mirror (boot once with -o degraded after a disk dies)
#   - another OS on a disk that is kept, with what happens to it
#   Prints "✓ No warnings" when the list is empty.
#   Example  review_warnings
review_warnings() {
  local w=() n s
  for n in "$SYS" "${MIRRORS[@]}" "${DATA[@]}" ${HOME_DISK:+"$HOME_DISK"}; do
    s=$(disk "$n" .smart)
    case ${s%%|*} in warn) w+=("$n: ${s#*|}") ;; fail) w+=("$n: ${s#*|} — data at risk") ;; esac
  done
  [[ $FS == zfs || $DATA_FS == zfs ]] && w+=("ZFS holds the kernel to the newest version it supports")
  [[ $HW_FORM == laptop && $ENC == none ]] && w+=("laptop without encryption — data readable if it's stolen")
  [[ $SOURCE != starter && $SECRETS != "done" ]] && w+=("secrets skipped — they fail until re-keyed (docs/04)")
  [[ $FS == btrfs && -n $SYS_RAID ]] && w+=("btrfs mirror: after a disk dies, boot once with -o degraded")
  for n in "${OTHER[@]}"; do is_foreign "${n%%|*}" && w+=("${n%%|*} has another OS ($(disk "${n%%|*}" .os)) — $(other_action "${n#*|}")"); done
  if (( ${#w[@]} == 0 )); then echo "${G}✓ No warnings${N}"; else printf "${Y}⚠ %s${N}\n" "${w[@]}"; fi
}

# ---- main menu (HUB=1) -----------------------------------------------------
# HUB=1 shows a menu of sections (step_hub) instead of a linear walk; each
# section runs its step and returns to the menu.

# hub_section STEP — true when STEP is a menu entry (not source, the menu
# itself or the review).
#   Example  hub_section step_user && echo listed
hub_section() { [[ $1 != step_source && $1 != step_hub && $1 != step_review ]]; }

# hub_label STEP — the menu name of a section; empty for other steps.
#   Example  hub_label step_diskconf   # prints "Disk configuration"
hub_label() {
  case $1 in
    step_host) echo "Hostname" ;; step_diskconf) echo "Disk configuration" ;; step_user) echo "User account" ;;
    step_region) echo "Region & keyboard" ;; step_desktop) echo "Desktop" ;; step_kernel) echo "Kernel" ;; step_unfree) echo "Unfree software" ;;
    step_packages) echo "Additional packages" ;; step_secrets) echo "Secrets" ;;
  esac
}
# hub_value STEP — what that entry currently says
#   Example  hub_value step_user   # e.g. "user · SSH off"
hub_value() {
  case $1 in
    step_host)     echo "${HOST:-}$([[ ${NEWHOST:-0} == 1 ]] && echo " (new)" || true)" ;;
    step_diskconf) echo "${SYS:-} · ${FS:-} · $(enc_label) · $([[ ${SWAP:-0} == 0 ]] && echo zram || echo "${SWAP}G swap")$( ((${#MIRRORS[@]})) && echo " · +${#MIRRORS[@]} mirror" || true)" ;;
    step_user)     echo "${NIXUSER:-} · SSH $([[ $SSH == true ]] && echo on || echo off)" ;;
    step_region)   echo "$TZONE · $KEYMAP" ;;
    step_desktop)  echo "$DESKTOP" ;;
    step_kernel)   kernel_label ;;
    step_unfree)   if [[ $UNFREE == true ]]; then echo "allowed"; else echo "not allowed"; fi ;;
    step_packages) if ((${#PKGS[@]})); then echo "${PKGS[*]}"; else echo "none"; fi ;;
    step_secrets)  echo "${SECRETS:-}" ;;
  esac
}
# the disk screens depend on each other, so they run as one entry (like archinstall's "Disk configuration")
# step_diskconf — run step_disks, step_fs, step_boot, step_enc and step_swap in
# order as one menu section.
#   A sub-step's 0 moves on, 3 shows that sub-step again, anything else goes
#   back one sub-step; back from step_disks leaves the section.
#   Returns  0 when all five are answered, 1 back to the menu
#   Example  step_diskconf
step_diskconf() {
  local g=(step_disks step_fs step_boot step_enc step_swap) i=0 rc
  while ((i < ${#g[@]})); do
    rc=0; "${g[i]}" || rc=$?
    case $rc in
      0) i=$((i + 1)) ;;
      3) ;;   # a sub-screen asked to be shown again
      *) if ((i == 0)); then return 1; fi; i=$((i - 1)) ;;
    esac
  done
}
# config_replay FILE — answers file → every setting; returns 1 if a saved disk is missing
#   load_answers restores the disk answers by serial; host, user, region,
#   desktop, kernel, unfree and ssh are read here. Every step is marked
#   visited so the review accepts the result.
#   Example  config_replay "$CONFIG" || echo "$LOAD_MISSING"
config_replay() {
  local f=$1 s
  load_answers "$f" || return 1
  IFS=$'\t' read -r HOST NIXUSER TZONE KEYMAP XKB DESKTOP KERNEL UNFREE SSH \
    < <(jq -r '[.host, .user, .region.timezone, .region.keymap, .region.xkb, .desktop, (.kernel // "default"), ((.unfree // false) | tostring), (.ssh | tostring)] | @tsv' "$f")
  NEWHOST=1
  for s in "${STEPS[@]}"; do VISITED[$s]=1; done
}

# nixpkgs search: type a word, pick from the matches (nix search is slow the first time)
# pkg_search — ask for a word, run `nix search nixpkgs WORD --json`, and list
# up to 25 matches: exact name first, then names starting with the word, then
# shortest names.
#   Returns  0 always (empty query, esc and no matches all go back quietly)
#   Example  pkg_search
pkg_search() {
  local q out rows=() choice
  ask q --header "Search nixpkgs" --placeholder "a program name or a word from its description" || return 0
  [[ -n $q ]] || return 0
  out=$(gum spin --title "Searching nixpkgs for \"$q\" …" --show-output -- \
        nix --extra-experimental-features "nix-command flakes" search nixpkgs "$q" --json 2>/dev/null) || out=""
  mapfile -t rows < <(jq -r --arg q "$q" 'to_entries | map(.n = (.key | split(".") | .[2:] | join("."))) |
      sort_by([(.n != $q), (.n | startswith($q) | not), (.n | length)]) | .[:25][] |
      "\(.n)  \((.value.description // "") | gsub("\\|"; "/") | .[0:78])|\(.n)"' <<<"${out:-{\}}" 2>/dev/null)
  if ((${#rows[@]} == 0)); then warn "no package matches \"$q\" (or nix search could not reach nixpkgs)"; return 0; fi
  local r n d
  for r in "${rows[@]}"; do n=${r##*|}; d=${r%|*}; PKGDESC[$n]=${d#*  }; done
  pick choice "Matches for \"$q\" — enter adds it, esc cancels" "${rows[@]}" || return 0
  local x; for x in "${PKGS[@]}"; do [[ $x == "$choice" ]] && return 0; done
  PKGS+=("$choice")
}

# nixc ARGS… — nix with flakes and nix-command enabled for this call only, so
# the live ISO needs no nix.conf change.
#   Example  nixc eval --raw nixpkgs#git.outPath
nixc() { nix --extra-experimental-features "nix-command flakes" "$@"; }
# closure_info OUTPATH… — the binary cache's JSON for those paths and everything they depend on (download + unpacked size)
#   nix path-info -r (recursive: the whole closure) --json against
#   cache.nixos.org; fails when a path is not in the cache or it is offline.
#   Example  closure_info "$(nixc eval --raw nixpkgs#git.outPath)"
closure_info() { nixc path-info --store https://cache.nixos.org -r --json "$@" 2>/dev/null; }
# pkg_unfree PKG — true if nixpkgs marks it unfree (asks the package's metadata, so no unfree opt-in needed)
#   The answer is cached in PKGUNFREE; a failed lookup counts as free.
#   Example  pkg_unfree steam && echo unfree
pkg_unfree() {
  local v
  if [[ -z ${PKGUNFREE[$1]:-} ]]; then
    v=$(nixc eval --json "nixpkgs#$1.meta.unfree" 2>/dev/null) || v=false
    if [[ $v == true ]]; then PKGUNFREE[$1]=1; else PKGUNFREE[$1]=0; fi
  fi
  [[ ${PKGUNFREE[$1]} == 1 ]]
}
# unfree_picked — the selected packages that need allowUnfree
#   Example  mapfile -t unf < <(unfree_picked)
unfree_picked() { local p; for p in "${PKGS[@]}"; do if pkg_unfree "$p"; then echo "$p"; fi; done; }
# pkg_cost — what the chosen packages add on top of a bare install (git + vim): sets COST_LINE and COST_PATHS
#   Skipped when PKGS has not changed since the last run (COST_KEY).
#   Evaluates each package's outPath (unfree allowed, --impure), then
#   subtracts the git + vim closure (cached in $TMP/base.json) from the
#   packages' closure and sums downloadSize of what is left.
#   COST_LINE   one sentence: the count and MiB to download, or why the size
#               is unknown (broken package, not in the cache, offline)
#   COST_PATHS  store names (without hash) of the added paths
#   Example  pkg_cost; echo "$COST_LINE"
pkg_cost() {
  local key="${PKGS[*]:-}" p op ops=() bad=() uncached=() all res mib; local -A opof=()
  [[ $key == "$COST_KEY" ]] && return 0
  COST_KEY=$key; COST_PATHS=(); COST_LINE=""
  [[ -n $key ]] || return 0
  printf '  working out what these packages pull in …\r' >"$TTY"
  for p in "${PKGS[@]}"; do
    if op=$(NIXPKGS_ALLOW_UNFREE=1 nixc eval --impure --raw "nixpkgs#$p.outPath" 2>/dev/null); then ops+=("$op"); opof[$p]=$op; else bad+=("$p"); fi
  done
  if ((${#bad[@]})); then COST_LINE="Cannot size ${bad[*]}: broken or unavailable in nixpkgs."; return 0; fi
  if [[ -z ${BASE_INFO:-} ]]; then
    BASE_INFO=$TMP/base.json
    closure_info "$(nixc eval --raw nixpkgs#git.outPath)" "$(nixc eval --raw nixpkgs#vim.outPath)" >"$BASE_INFO" || true
  fi
  if ! all=$(closure_info "${ops[@]}") || [[ ! -s $BASE_INFO ]]; then
    for p in "${!opof[@]}"; do closure_info "${opof[$p]}" >/dev/null || uncached+=("$p"); done
    if ((${#uncached[@]})); then COST_LINE="Not in the binary cache: ${uncached[*]}. Fetched from the vendor or built."
    else COST_LINE="Size unknown: cache.nixos.org could not be reached."; fi
    return 0
  fi
  res=$(jq -r --slurpfile base "$BASE_INFO" '. as $all | ($base[0] | keys) as $bk | (keys - $bk) as $new |
        "\([$new[] | $all[.].downloadSize] | add // 0)",
        ($new[] | sub("^/nix/store/[a-z0-9]{32}-"; ""))' <<<"$all")
  mib=$(( $(head -1 <<<"$res") / 1048576 ))
  mapfile -t COST_PATHS < <(tail -n +2 <<<"$res" | sort -u)
  COST_LINE="Together they add ${#COST_PATHS[@]} package$([[ ${#COST_PATHS[@]} == 1 ]] || echo s) and about ${mib} MiB to download."
}
# pkg_lines — "name  description", one per chosen package
#   The description comes from the search results or meta.description,
#   prefixed "unfree ·" when needed, cut to 58 characters.
#   Example  mapfile -t pl < <(pkg_lines)
pkg_lines() {
  local p d
  for p in "${PKGS[@]}"; do
    d=${PKGDESC[$p]:-}
    if [[ -z $d ]]; then d=$(nixc eval --raw "nixpkgs#$p.meta.description" 2>/dev/null) || d=""; PKGDESC[$p]=$d; fi
    if pkg_unfree "$p"; then d="unfree · $d"; fi
    printf '%-18s %s\n' "$p" "${d:0:58}"
  done
}

# step_packages — starter mode: extra nixpkgs packages for every user (PKGS).
# Shows the selection, its download cost (pkg_cost) and unfree status, then:
#   search  pkg_search adds a package
#   unfree  sets UNFREE=true (offered when a pick needs it)
#   deps    lists COST_PATHS, what the picks pull in
#   remove  drops one package
#   done    finish the step
#   INSTALL_TEST + TEST_PKGS     preset PKGS in automated tests (no TEST_PKGS:
#                                skip the step); TEST_PKG_IDX picks the entry
#   Returns  0 done, 1 back
#   Example  step_packages
step_packages() {
  [[ -n ${INSTALL_TEST:-} && -n ${TEST_PKGS:-} && ${#PKGS[@]} -eq 0 ]] && read -ra PKGS <<<"$TEST_PKGS"   # tests only
  [[ -n ${INSTALL_TEST:-} && -z ${TEST_PKGS:-} ]] && return 0
  local a r o l pl lines unf
  while :; do
    pkg_cost
    mapfile -t pl < <(pkg_lines)
    mapfile -t unf < <(unfree_picked)
    lines=("Extra programs, installed for every user on top of the desktop you chose.")
    if ((${#PKGS[@]})); then
      lines+=("" "Selected (${#PKGS[@]})")
      for l in "${pl[@]:0:8}"; do lines+=("  $l"); done
      if ((${#pl[@]} > 8)); then lines+=("  … and $(( ${#pl[@]} - 8 )) more"); fi
      lines+=("" "$COST_LINE")
      if ((${#unf[@]})) && [[ $UNFREE != true ]]; then lines+=("" "⚠ Unfree software is off, but ${unf[*]} needs it.")
      elif ((${#unf[@]})); then lines+=("" "Unfree, allowed: ${unf[*]}"); fi
    else lines+=("" "Nothing selected yet.")
    fi
    panel "Additional packages" "$(box -t "Packages" "${lines[@]}")"
    o=("Search nixpkgs…  find a program by name or description|search")
    if ((${#unf[@]})) && [[ $UNFREE != true ]]; then o+=("Allow unfree software  needed by ${unf[*]}|unfree"); fi
    if ((${#PKGS[@]})); then
      if ((${#COST_PATHS[@]})); then o+=("What gets pulled in…  the ${#COST_PATHS[@]} packages these depend on|deps"); fi
      o+=("Remove a package…  ${#PKGS[@]} selected|remove")
    fi
    o+=("Done|done")
    TEST_IDX=${TEST_PKG_IDX:-0} pick a "" "${o[@]}" || return 1
    case $a in
      search) pkg_search ;;
      unfree) UNFREE=true ;;
      deps)   if ((${#COST_PATHS[@]})); then
                o=(); for r in "${COST_PATHS[@]}"; do o+=("$r|$r"); done
                pick r "Pulled in by ${PKGS[*]} — ${#COST_PATHS[@]} packages (esc closes)" "${o[@]}" || true
              else warn "nothing to list (size unknown, or no extra dependencies)"; fi ;;
      remove) o=(); for r in "${PKGS[@]}"; do o+=("$r|$r"); done
              if pick r "Remove which one?" "${o[@]}"; then
                local keep=(); for a in "${PKGS[@]}"; do [[ $a == "$r" ]] || keep+=("$a"); done; PKGS=("${keep[@]}")
              fi ;;
      done) return 0 ;;
    esac
  done
}

# step_hub — the main menu (HUB=1): one entry per section with its current
# value or "(not set)", the cursor on the first unanswered entry.
#   <section>  JUMP to that step; it returns here when done
#   save       write answers_json to ANSWERS_OUT (default ./answers.json) for
#              `install --config FILE`
#   go         Install: JUMP to the review; refused while a picked package
#              needs unfree and UNFREE is off
#   locked     Install while entries are unset: warns and stays
#   abort      leave the alternate screen and exit 0 without changes
#   INSTALL_TEST  picks the first unset entry, else go; TEST_VISIT opens one
#                 named section once; TEST_HUB_SHOW shows the real menu
#   Returns  3 always (JUMP set), or 1 on esc
#   Example  step_hub
step_hub() {
  local i fn val opts=() choice next="" nmiss=0 cursor=0
  for ((i = 2; i < REVIEW_IDX; i++)); do
    fn=${STEPS[i]}
    if [[ -n ${VISITED[$fn]:-} ]]; then val=$(hub_value "$fn")
    else val="(not set)"; nmiss=$((nmiss + 1)); if [[ -z $next ]]; then next=$i; fi; fi
    opts+=("$(hub_label "$fn")  $val|$i")
  done
  opts+=("Save configuration  answers.json for --config|save")
  if ((nmiss)); then opts+=("Install  ($nmiss missing)|locked"); else opts+=("Install  ready|go"); fi
  opts+=("Abort|abort")
  if [[ -n $next ]]; then cursor=$((next - 2)); else cursor=$((REVIEW_IDX - 1)); fi   # first unanswered entry, else Install
  panel "Main menu" ""
  if [[ -n ${INSTALL_TEST:-} && -z ${TEST_HUB_SHOW:-} ]]; then
    choice=${next:-go}
    if [[ -z $next && -n ${TEST_VISIT:-} ]]; then   # tests only: open one named section once
      for ((i = 2; i < REVIEW_IDX; i++)); do if [[ ${STEPS[i]} == "$TEST_VISIT" ]]; then choice=$i; fi; done
      TEST_VISIT=""
    fi
  else PICK_START=$cursor; pick choice "" "${opts[@]}" || return 1; fi
  case $choice in
    go)     local unf; mapfile -t unf < <(unfree_picked)
            if ((${#unf[@]})) && [[ $UNFREE != true ]]; then
              warn "${unf[*]} needs unfree software. Turn on \"Unfree software\" or remove it from the packages."; JUMP=$CUR
            else JUMP=$REVIEW_IDX; fi ;;
    locked) warn "Install is locked: ${nmiss} entries still say (not set)."; JUMP=$CUR ;;
    save)   if ((nmiss)); then warn "Answer every entry first, then save."
            else local f=${ANSWERS_OUT:-$PWD/answers.json}; answers_json >"$f"; NOTE+="${G}✓ saved $f — replay with: install --config $f${N}"$'\n'; fi
            JUMP=$CUR ;;
    abort)  ((ALT)) && { tput cnorm; tput rmcup; } 2>/dev/null; ALT=0; echo "aborted, nothing was changed"; exit 0 ;;
    *)      JUMP=$choice ;;
  esac
  return 3
}

# step_review — the last step: everything that will happen, on one screen.
#   Top row   three panel_box panels: System (starter answers, or the chosen
#             host's desktop/kernel/profile), Hardware, Boot & security
#   Below     review_warnings, review_summary and review_cards for the disks
#             listed in NAMES
#   Install   asks to type the hostname; a mismatch stays on the review
#   Edit      HUB=1: back to the menu; otherwise pick any earlier step
#   Returns  0 confirmed, 1 back, 3 jump (edit or mismatch)
#   Example  step_review
step_review() {
  local plan; plan=$(planned)
  local shown; shown=$(jq --argjson keep "$(printf '%s\n' "${NAMES[@]}" | jq -R . | jq -s .)" '[.[] | select(.name as $n | $keep | index($n))]' <<<"$DISKS")
  local p1 p2 p3
  # three panels in one row, together exactly as wide as the header frame
  local cols=$TERM_COLS pw
  pw=$(( ( (cols - 2 < 120 ? cols - 2 : 120) - 2 ) / 3 )); (( pw < 29 )) && pw=29
  if [[ $SOURCE == starter ]]; then
    p1=$(panel_box $pw "System" \
      "Host    $HOST (new)" \
      "User    $NIXUSER (administrator)" \
      "Desktop $DESKTOP" \
      "Kernel  $(kernel_label)" \
      "Region  $TZONE · $KEYMAP" \
      "Extras  ${#PKGS[@]} pkg · unfree $([[ $UNFREE == true ]] && echo yes || echo no)")
  else
    p1=$(panel_box $pw "System" \
      "Host    $HOST$([[ $NEWHOST == 1 ]] && echo " (new)" || true)" \
      "User    $NIXUSER ($(uid_of "$NIXUSER"))" \
      "Desktop $(host_desktop)" \
      "Kernel  $(host_kernel)" \
      "Profile $(host_profile)")
  fi
  p2=$(panel_box $pw "Hardware" \
    "CPU     $HW_CPU + microcode" \
    "GPU     $HW_GPU" \
    "RAM     $(hsize "$RAM_B") · $HW_FORM" \
    "Network $NET$([[ $HW_WIFI == 1 ]] && echo " · WiFi" || true)" \
    "Firmw.  ${FW^^}")
  p3=$(panel_box $pw "Boot & security" \
    "Boot    $BOOT" \
    "Mirror  $( (( ${#MIRRORS[@]} )) && echo "ESP on $(( ${#MIRRORS[@]} + 1 )) disks" || echo "no")" \
    "Encrypt $(enc_label)" \
    "Swap    $([[ $SWAP == 0 ]] && echo "zram" || echo "${SWAP}G swapfile")" \
    "$(review_last)")
  local grid; grid=$(gum join --horizontal "$p1" " " "$p2" " " "$p3")
  panel "Review — $HOST" \
"$grid
$(review_warnings)

${B}$(review_summary "$plan")${N}
$(review_cards "$shown" "$plan")"
  local a; pick a "" "Install|go" "Edit a step…|edit" || return 1
  if [[ $a == edit ]] && ((HUB)); then JUMP=$HUB_IDX; return 3; fi
  if [[ $a == edit ]]; then
    local i o=(); for ((i = 0; i < ${#STEP_NAMES[@]} - 1; i++)); do o+=("${STEP_NAMES[i]}|$i"); done
    pick JUMP "Jump to" "${o[@]}" || return 1; return 3
  fi
  local typed; ask typed --header "Type \"$HOST\" to install$([[ -n $DEMO ]] && echo " (DEMO: nothing happens)" || echo " — disks marked WIPE are erased")" --placeholder "$HOST" || return 1
  [[ $typed == "$HOST" ]] || { warn "Didn't match"; JUMP=$CUR; return 3; }
}

# ==========================================================================
# Output generators
# ==========================================================================
# Turn the answers into files and commands: gen_disk_nix writes the host's
# disk.nix, gen_commands the shell commands that partition, format, mount
# and install.

# uefi — true when the machine booted in UEFI mode (FW=uefi), false on BIOS.
#   Example  uefi && echo "1 GiB EFI partition"
uefi() { [[ $FW == uefi ]]; }

# gen_disk_nix — print hosts/$HOST/disk.nix for the answers, to stdout.
# Every mount uses a label or UUID, so device names may change.
#   Boot loader    systemd-boot; grub (efiSupport on UEFI, mirroredBoots with
#                  one entry per system disk, useOSProber when another disk
#                  has the boot role); limine (biosDevice on BIOS); refind.
#                  With another OS to boot, systemd-boot gets the EDK2 UEFI
#                  shell and limine a commented extraEntries example
#   ESP mirror     non-GRUB loaders with mirrors on UEFI: an activation
#                  script rsyncs /boot/ to every /bootN/
#   LUKS           boot.initrd.luks.devices.cryptrootN on label nixos-luksN,
#                  one per system disk, allowDiscards on
#   Root           btrfs subvolumes @ @home @nix @log @cache @snapshots
#                  @home_snapshots @swap (compress=zstd:1, noatime; @home*
#                  skipped with a /home disk, @swap when SWAP=0); ZFS
#                  datasets rpool/{root,home,nix,log} with a random
#                  networking.hostId and the LTS kernel forced; otherwise one
#                  filesystem on label nixos
#   /boot          label EFI, plus EFI2… on mirrors (nofail), umask=0077
#   /home, data    by label; a kept data disk by UUID; a ZFS data pool via
#                  boot.zfs.extraPools; data mounts are nofail
#   Other disks    mount roles become ntfs3 mounts at /mnt/<OS name>, ro or rw
#   Swap           zram when SWAP=0; /swap/swapfile on btrfs; otherwise
#                  /swapfile of SWAP GB (swapDevices size is in MiB)
#   Example  gen_disk_nix >"$REPO/hosts/$HOST/disk.nix"
gen_disk_nix() {
  local i n
  cat <<EOF
# ===========================================================================
# hosts/$HOST/disk.nix — generated by install.sh on $(date +%F)
# Disks: ${SYS_DISKS[*]}${HOME_DISK:+ · home $HOME_DISK}${DATA[*]:+ · data ${DATA[*]}}
# Everything is referenced by label/UUID — device names don't matter.
# ===========================================================================
{ config, lib, pkgs, ... }:

{
EOF
  case $BOOT in
    systemd-boot) echo '  boot.loader.systemd-boot.enable = true;'
                  echo '  boot.loader.efi.canTouchEfiVariables = true;' ;;
    grub)  echo '  boot.loader.systemd-boot.enable = lib.mkForce false;'
           echo '  boot.loader.grub.enable = true;'
           if uefi; then echo '  boot.loader.grub.efiSupport = true;'; echo '  boot.loader.efi.canTouchEfiVariables = true;'; fi
           if (( ${#MIRRORS[@]} )); then
             echo '  boot.loader.grub.mirroredBoots = ['
             if uefi; then
               # UEFI: one ESP per disk, mounted at /boot, /boot2, …
               for i in "${!SYS_DISKS[@]}"; do
                 n=$((i+1))
                 echo "    { path = \"/boot$([[ $n == 1 ]] || echo $n)\"; devices = [ \"nodev\" ]; }"
               done
             else
               # BIOS: a single /boot; GRUB goes into every disk's MBR. Paths
               # must be unique, so all disks share one entry.
               printf '    { path = "/boot"; devices = ['
               for i in "${!SYS_DISKS[@]}"; do printf ' "%s"' "$(disk_byid "${SYS_DISKS[$i]}")"; done
               echo ' ]; }'
             fi
             echo '  ];'
           elif uefi; then echo '  boot.loader.grub.device = "nodev";'
           else echo "  boot.loader.grub.device = \"$(disk_byid "$SYS")\";"; fi
           if [[ " ${OTHER[*]} " == *"|boot"* ]]; then echo '  boot.loader.grub.useOSProber = true;   # adds the other-OS disk(s) to the menu'; fi ;;
    limine) echo '  boot.loader.systemd-boot.enable = lib.mkForce false;'
            echo '  boot.loader.limine.enable = true;'
            if uefi; then echo '  boot.loader.limine.efiSupport = true;'; else echo "  boot.loader.limine.biosDevice = \"$(disk_byid "$SYS")\";"; fi
            if [[ " ${OTHER[*]} " == *"|boot"* ]]; then echo '  # boot.loader.limine.extraEntries = "/Windows\n  protocol: efi\n  path: guid(<ESP-GUID>):/EFI/Microsoft/Boot/bootmgfw.efi";'; fi ;;
    refind) echo '  boot.loader.systemd-boot.enable = lib.mkForce false;'
            echo '  boot.loader.refind.enable = true;   # scans every disk for other OSes on its own'
            echo '  boot.loader.efi.canTouchEfiVariables = true;' ;;
  esac
  if [[ $BOOT == systemd-boot && " ${OTHER[*]} " == *"|boot"* ]]; then
    echo '  boot.loader.systemd-boot.edk2-uefi-shell.enable = true;'
    echo '  # boot.loader.systemd-boot.windows."11".efiDeviceHandle = "HD1b";  # find with `map -c` in the EFI shell'
  fi
  if (( ${#MIRRORS[@]} )) && [[ $BOOT != grub ]] && uefi; then
    echo; echo '  # Keep the mirror ESPs identical so either disk can boot alone'
    echo '  system.activationScripts.espMirror.text = '"''"
    for i in "${!MIRRORS[@]}"; do echo "    \${pkgs.rsync}/bin/rsync -a --delete /boot/ /boot$((i+2))/ || true"; done
    echo "  '';"
  fi
  if [[ $ENC == luks ]]; then
    echo
    for i in "${!SYS_DISKS[@]}"; do n=$((i+1))
      echo "  boot.initrd.luks.devices.\"cryptroot$n\" = { device = \"/dev/disk/by-label/nixos-luks$n\"; allowDiscards = true; };"
    done
  fi
  echo
  case $FS in
    btrfs)
      local mo='"compress=zstd:1" "noatime"' sv mp
      [[ -n $SYS_RAID ]] && echo "  # btrfs ${SYS_RAID#btrfs-} across ${#SYS_DISKS[@]} disks — one label covers every member"
      for sv in "@:/" "@home:/home" "@nix:/nix" "@log:/var/log" "@cache:/var/cache" "@snapshots:/.snapshots" "@home_snapshots:/home/.snapshots" "@swap:/swap"; do
        mp=${sv#*:}; [[ -n $HOME_DISK && $mp == /home* ]] && continue
        if [[ $mp == /swap ]]; then [[ $SWAP == 0 ]] && continue; mo='"noatime"'; fi
        echo "  fileSystems.\"$mp\" = { device = \"/dev/disk/by-label/nixos\"; fsType = \"btrfs\"; options = [ \"subvol=${sv%%:*}\" $mo ]; };"
      done ;;
    zfs)
      echo '  boot.supportedFilesystems = [ "zfs" ];'
      echo "  networking.hostId = \"$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')\";   # required by ZFS, random per host"
      echo '  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;   # ZFS-supported kernel (overrides _latest/_zen)'
      local ds; for ds in "root:/" "home:/home" "nix:/nix" "log:/var/log"; do
        [[ -n $HOME_DISK && ${ds#*:} == /home ]] && continue
        echo "  fileSystems.\"${ds#*:}\" = { device = \"rpool/${ds%%:*}\"; fsType = \"zfs\"; options = [ \"zfsutil\" ]; };"
      done ;;
    *) echo "  fileSystems.\"/\" = { device = \"/dev/disk/by-label/nixos\"; fsType = \"$FS\"; options = [ \"noatime\" ]; };" ;;
  esac
  if uefi; then
    echo "  fileSystems.\"/boot\" = { device = \"/dev/disk/by-label/EFI\"; fsType = \"vfat\"; options = [ \"umask=0077\" ]; };"
    for i in "${!MIRRORS[@]}"; do n=$((i+2))
      echo "  fileSystems.\"/boot$n\" = { device = \"/dev/disk/by-label/EFI$n\"; fsType = \"vfat\"; options = [ \"umask=0077\" \"nofail\" ]; };"
    done
  fi
  if [[ -n $HOME_DISK ]]; then echo; echo "  fileSystems.\"/home\" = { device = \"/dev/disk/by-label/$HOME_LABEL\"; fsType = \"$HOME_FS\"; options = [ \"noatime\" ]; };"; fi
  if (( ${#DATA[@]} )); then
    echo
    if [[ $DATA_KEEP == 1 ]]; then
      echo "  fileSystems.\"$DATA_MNT\" = { device = \"/dev/disk/by-uuid/$(disk "${DATA[0]}" .uuid)\"; fsType = \"$DATA_FS\"; options = [ \"nofail\" ]; };   # kept as-is, label $DATA_LABEL"
    elif [[ $DATA_FS == zfs ]]; then
      [[ $FS == zfs ]] || echo '  boot.supportedFilesystems = [ "zfs" ];'
      echo "  boot.zfs.extraPools = [ \"$DATA_LABEL\" ];   # ${DATA_RAID:-single disk}"
      echo "  fileSystems.\"$DATA_MNT\" = { device = \"$DATA_LABEL/data\"; fsType = \"zfs\"; options = [ \"zfsutil\" \"nofail\" ]; };"
    else
      echo "  fileSystems.\"$DATA_MNT\" = { device = \"/dev/disk/by-label/$DATA_LABEL\"; fsType = \"$DATA_FS\"; options = [ \"noatime\" \"nofail\" ]; };   # ${DATA_RAID:-single disk}"
    fi
  fi
  local o2 dn act
  for o2 in "${OTHER[@]}"; do
    dn=${o2%%|*} act=${o2#*|}
    [[ $act == *mount* ]] || continue
    echo "  fileSystems.\"/mnt/$(disk "$dn" .os | sed 's/./\u&/')\" = { device = \"/dev/disk/by-uuid/$(disk "$dn" .uuid)\"; fsType = \"ntfs3\"; options = [ \"$([[ $act == *rw ]] && echo rw || echo ro)\" \"nofail\" ]; };"
  done
  echo
  if [[ $SWAP == 0 ]]; then echo '  zramSwap.enable = true;'
  elif [[ $FS == btrfs ]]; then echo '  swapDevices = [ { device = "/swap/swapfile"; } ];'
  else echo "  swapDevices = [ { device = \"/swapfile\"; size = $((SWAP*1024)); } ];"; fi
  echo '}'
}

# gen_commands — the install, as runnable lines. The demo prints them; real mode
# runs them (run_install). "# [n/7] …" lines are phase checkpoints for --resume;
# phase 3 (unlock + mount) is idempotent and re-runs on every resume.
#   [1/7] partition   wipefs + a GPT on every system disk: UEFI gets a 1 GiB
#                     ESP + root, BIOS a 1 MiB bios_grub area + root; the
#                     ESPs are formatted FAT32 as EFI, EFI2…
#   [2/7] format      LUKS2 (label nixos-luksN) when ENC=luks, then the root
#                     filesystem, /home, the data disks, and a relabel of a
#                     kept data disk
#   [3/7] mount       unlock, mount everything under /mnt, create the btrfs
#                     swapfile
#   [4/7] config      write_starter, or fetch_config + write_config
#   [5/7] secrets     linuxury mode: copy the host key; pull re-keyed secrets
#                     when SECRETS=done
#   [6/7] install     nixos-install --flake …#HOST --no-root-passwd, then set
#                     the user's password with nixos-enter
#   [7/7] finish      copy the log, fix home ownership, unmount
#   Example  gen_commands | grep -v '^#'
gen_commands() {
  local i n d p2 root=()
  # System disks: GPT; parted's "esp" flag marks the EFI partition and
  # "bios_grub" the area GRUB embeds itself in on BIOS
  echo "# [1/7] partition"
  for i in "${!SYS_DISKS[@]}"; do d=${SYS_DISKS[$i]}
    echo "wipefs -a /dev/$d && parted -s /dev/$d -- mklabel gpt"
    if uefi; then echo "parted -s /dev/$d -- mkpart ESP fat32 1MiB 1GiB set 1 esp on mkpart root 1GiB 100%"
    else echo "parted -s /dev/$d -- mkpart bios 1MiB 2MiB set 1 bios_grub on mkpart root 2MiB 100%"; fi
  done
  echo "udevadm settle"
  if uefi; then
    for i in "${!SYS_DISKS[@]}"; do echo "mkfs.fat -F32 -n EFI$([[ $i == 0 ]] || echo $((i+1))) $(part "${SYS_DISKS[$i]}" 1)"; done
  fi
  # Root: luksFormat each system disk's partition 2 and open it as
  # cryptrootN; btrfs -d/-m set the data/metadata RAID profile; zpool
  # ashift=12 = 4 KiB sectors, compression=zstd, and ENC=zfs adds native
  # passphrase encryption
  echo "# [2/7] encryption + filesystems"
  for i in "${!SYS_DISKS[@]}"; do d=${SYS_DISKS[$i]}; n=$((i+1)); p2=$(part "$d" 2)
    if [[ $ENC == luks ]]; then
      echo "cryptsetup luksFormat --type luks2 --label nixos-luks$n $p2"
      echo "luks_open $p2 cryptroot$n"; root+=("/dev/mapper/cryptroot$n")
    else root+=("$p2"); fi
  done
  case $FS in
    btrfs) echo "mkfs.btrfs -f -L nixos ${SYS_RAID:+-d ${SYS_RAID#btrfs-} -m ${SYS_RAID#btrfs-} }${root[*]}"
           echo "udevadm settle"
           echo "mount ${root[0]} /mnt && for s in @ @home @nix @log @cache @snapshots @home_snapshots @swap; do btrfs subvolume create /mnt/\$s; done && umount /mnt" ;;
    zfs)   echo "zpool create -f -o ashift=12 -O compression=zstd -O acltype=posixacl -O xattr=sa -O mountpoint=none \\"
           if [[ $ENC == zfs ]]; then echo "  -O encryption=on -O keyformat=passphrase \\"; fi
           echo "  rpool $([[ -n $SYS_RAID ]] && echo mirror || true) ${root[*]}"
           echo "for d in root home nix log; do zfs create -o mountpoint=legacy rpool/\$d; done" ;;
    ext4)  echo "mkfs.ext4 -F -L nixos ${root[0]}" ;;
    *)     echo "mkfs.$FS -f -L nixos ${root[0]}" ;;
  esac
  if [[ -n $HOME_DISK ]]; then echo "wipefs -a /dev/$HOME_DISK && $(mkfs_cmd "$HOME_FS" "$HOME_DISK" "$HOME_LABEL")"; fi
  # Data disks (not when kept): a btrfs RAID, a ZFS pool (raid layout or one
  # disk) with a legacy-mounted <label>/data dataset, or one mkfs_cmd
  if (( ${#DATA[@]} )) && [[ $DATA_KEEP == 0 ]]; then
    local devs l; devs=$(printf '/dev/%s ' "${DATA[@]}")
    case ${DATA_RAID:-$DATA_FS} in
      btrfs-*) echo "mkfs.btrfs -f -L $DATA_LABEL -d ${DATA_RAID#btrfs-} -m ${DATA_RAID#btrfs-} $devs" ;;
      zfs-*)   l=${DATA_RAID#zfs-}; echo "zpool create -f -o ashift=12 -O compression=zstd -O mountpoint=none $DATA_LABEL $l $devs"
               echo "zfs create -o mountpoint=legacy $DATA_LABEL/data" ;;
      zfs)     echo "zpool create -f -o ashift=12 -O mountpoint=none $DATA_LABEL $devs && zfs create -o mountpoint=legacy $DATA_LABEL/data" ;;
      *)       echo "wipefs -a ${devs% } && $(mkfs_cmd "$DATA_FS" "${DATA[0]}" "$DATA_LABEL")" ;;
    esac
  fi
  if [[ $DATA_KEEP == 1 && $DATA_LABEL != "$DATA_OLDLABEL" ]]; then
    relabel_cmd "$DATA_FS" "$(disk "${DATA[0]}" .datadev)" "$DATA_LABEL"
  fi
  echo "udevadm settle"
  # Every mount goes through mnt, so a resumed install can run this phase
  # again; a ZFS data pool is not mounted here (fileSystems mounts it later)
  echo "# [3/7] unlock + mount + swap"
  if [[ $ENC == luks ]]; then
    for i in "${!SYS_DISKS[@]}"; do echo "luks_open $(part "${SYS_DISKS[$i]}" 2) cryptroot$((i+1))"; done
  fi
  case $FS in
    btrfs)
      local sv mp o
      for sv in "@:/" "@home:/home" "@nix:/nix" "@log:/var/log" "@cache:/var/cache" "@snapshots:/.snapshots" "@home_snapshots:/home/.snapshots" "@swap:/swap"; do
        mp=${sv#*:}; [[ -n $HOME_DISK && $mp == /home* ]] && continue
        [[ $mp == /swap && $SWAP == 0 ]] && continue
        o="subvol=${sv%%:*},compress=zstd:1,noatime"; [[ $mp == /swap ]] && o="subvol=@swap,noatime"
        echo "mnt $o /dev/disk/by-label/nixos /mnt${mp%/}"
      done ;;
    zfs) local ds; for ds in "root:/" "home:/home" "nix:/nix" "log:/var/log"; do echo "mnt zfsutil rpool/${ds%%:*} /mnt${ds#*:}"; done ;;
    *)   echo "mnt noatime /dev/disk/by-label/nixos /mnt" ;;
  esac
  if uefi; then
    echo "mnt umask=0077 /dev/disk/by-label/EFI /mnt/boot"
    for i in "${!MIRRORS[@]}"; do echo "mnt umask=0077 /dev/disk/by-label/EFI$((i+2)) /mnt/boot$((i+2))"; done
  fi
  if [[ -n $HOME_DISK ]]; then echo "mnt noatime /dev/disk/by-label/$HOME_LABEL /mnt/home"; fi
  if (( ${#DATA[@]} )); then
    if [[ $DATA_KEEP == 1 ]]; then echo "mnt defaults /dev/disk/by-uuid/$(disk "${DATA[0]}" .uuid) /mnt$DATA_MNT"
    elif [[ $DATA_FS != zfs ]]; then echo "mnt noatime /dev/disk/by-label/$DATA_LABEL /mnt$DATA_MNT"; fi
  fi
  if [[ $SWAP != 0 && $FS == btrfs ]]; then echo "[[ -e /mnt/swap/swapfile ]] || btrfs filesystem mkswapfile --size ${SWAP}G /mnt/swap/swapfile"; fi
  echo "# [4/7] config"
  if [[ $SOURCE == starter ]]; then
    echo "write_starter   # starter flake in /mnt/home/$NIXUSER/nixos-config, git init + first commit"
    echo "# [5/7] secrets"
    echo "# (the starter template uses no secrets)"
  else
    echo "fetch_config   # clone into /mnt/home/$NIXUSER/nixos-config"
    echo "write_config   # hosts/$HOST/disk.nix + install.json, git commit (+ push if an SSH agent is forwarded)"
    echo "# [5/7] secrets"
    echo "install -Dm600 $KEYDIR/ssh_host_ed25519_key /mnt/etc/ssh/ssh_host_ed25519_key"
    echo "install -Dm644 $KEYDIR/ssh_host_ed25519_key.pub /mnt/etc/ssh/ssh_host_ed25519_key.pub"
    if [[ $SECRETS == "done" ]]; then echo "git -C /mnt/home/$NIXUSER/nixos-config pull --rebase   # add-host's re-keyed secrets"; fi
  fi
  # grow_live_store lets the live ISO's RAM-backed store spill to swap on the
  # new disk; root gets no password, the user's is asked here
  echo "# [6/7] install"
  echo "grow_live_store   # the ISO's package store lives in RAM — let it spill to swap on the new disk"
  echo "nixos-install --flake /mnt/home/$NIXUSER/nixos-config#$HOST --no-root-passwd"
  echo "nixos-enter --root /mnt -- passwd $NIXUSER"
  # The log is kept on the new system; the starter user is the first normal
  # user (uid 1000), a linuxury-mode user gets the uid from the config
  echo "# [7/7] finish"
  echo "cp $LOG /mnt/var/log/nixos-install.log"
  if [[ $SOURCE == starter ]]; then
    echo "finish_starter   # commit flake.lock"
    echo "chown -R 1000:100 /mnt/home/$NIXUSER"   # the first normal user gets uid 1000
  else echo "chown -R $(uid_of "$NIXUSER"):100 /mnt/home/$NIXUSER"; fi
  echo "swapoff -a; rm -f /mnt/.installer-swap; umount -R /mnt"
}

# ---- helpers the command list calls ---------------------------------------
# gen_commands prints these names; run_install runs the lines, so they must
# be defined in this shell.

# mnt OPTS DEVICE DIR — idempotent mount (re-run safely by --resume)
#   OPTS  mount -o options, e.g. subvol=@,compress=zstd:1,noatime or zfsutil
#   Creates DIR and skips it when something is already mounted there.
#   Example  mnt noatime /dev/disk/by-label/nixos /mnt
mnt() { mkdir -p "$3"; mountpoint -q "$3" || mount -o "$1" "$2" "$3"; }
# luks_open PARTITION NAME — cryptsetup open PARTITION as /dev/mapper/NAME
# (asks for the passphrase) unless it is already open.
#   Example  luks_open /dev/nvme0n1p2 cryptroot1
luks_open() { [[ -e /dev/mapper/$2 ]] || cryptsetup open "$1" "$2"; }
# CFG_URL — the config repo for linuxury mode; INSTALLER_GIT overrides it.
CFG_URL=${INSTALLER_GIT:-https://github.com/Linuxury/nixos-config}
# fetch_config — full clone of CFG_URL into the user's home on the new
# system (kept if already there) and mark it a git safe.directory, since root
# runs git on a tree the user will own.
#   Example  fetch_config
fetch_config() {
  local c=/mnt/home/$NIXUSER/nixos-config
  [[ -d $c/.git ]] || git clone "$CFG_URL" "$c"
  git config --global --add safe.directory "$c" 2>/dev/null || true
}
# write_config — linuxury mode: add this machine to the cloned config.
#   Writes hosts/$HOST/disk.nix (gen_disk_nix) and hosts/$HOST/install.json
#   (answers_json) and commits them as "nixos installer".
#   With a forwarded SSH agent (SSH_AUTH_SOCK) a github.com HTTPS remote is
#   switched to SSH and the commit is pushed; otherwise it stays local.
#   Example  write_config
write_config() {
  local c=/mnt/home/$NIXUSER/nixos-config
  gen_disk_nix >"$c/hosts/$HOST/disk.nix"
  answers_json >"$c/hosts/$HOST/install.json"
  git -C "$c" add "hosts/$HOST/disk.nix" "hosts/$HOST/install.json"
  git -C "$c" -c user.name="nixos installer" -c user.email="installer@$HOST" \
    commit -q -m "$HOST: disk layout from installer" -- "hosts/$HOST/disk.nix" "hosts/$HOST/install.json" || true
  if [[ -n ${SSH_AUTH_SOCK:-} ]]; then
    local ssh_url; ssh_url=$(sed -E 's#^https://github\.com/([^/]+/[^/]+)$#git@github.com:\1#; s#(\.git)?$#.git#' <<<"$CFG_URL")
    [[ $ssh_url == git@github.com:* ]] && git -C "$c" remote set-url origin "$ssh_url"   # push back to the repo that was cloned
    git -C "$c" push || echo "push failed — push it after first boot"
  else echo "no forwarded SSH agent — the commit stays local; push it after first boot"; fi
}
# ---- starter template ------------------------------------------------------
# The files under templates/starter with their @NAME@ blanks filled in.

# nixpkgs_channel — the nixpkgs branch the new system follows;
# INSTALLER_CHANNEL overrides the default nixos-unstable.
#   Example  nixpkgs_channel
nixpkgs_channel() { echo "${INSTALLER_CHANNEL:-nixos-unstable}"; }
# state_version — system.stateVersion for the new host as YY.MM, from
# INSTALLER_STATE_VERSION or the live ISO's `nixos-version --release`
# (falls back to 26.05).
#   Example  state_version
state_version() { local v=${INSTALLER_STATE_VERSION:-$(nixos-version --release 2>/dev/null)}; v=$(sed -nE 's/^([0-9]{2}\.[0-9]{2}).*/\1/p' <<<"$v"); echo "${v:-26.05}"; }   # YY.MM only; the release string can carry a date and codename
# stack_mark NAME — "" for the chosen desktop stack, "# " for the others;
# fills @GNOME@ @KDE@ @COSMIC@ in front of each stack import.
#   Example  stack_mark kde
stack_mark() { [[ $DESKTOP == "$1" ]] && echo "" || echo "# "; }   # chosen stack uncommented, the others commented out
# extra_pkgs — PKGS as " a b c" for the @EXTRA_PKGS@ list (empty if none).
#   Example  extra_pkgs
extra_pkgs() { if ((${#PKGS[@]})); then printf ' %s' "${PKGS[@]}"; fi; }
# kernel_line — the @KERNEL@ line of the host file: boot.kernelPackages for
# latest or zen with the version as a trailing note; for default, a
# commented example so the LTS kernel stays in use.
#   Example  kernel_line
kernel_line() {
  local v; v=$(kernel_version "$KERNEL")
  case $KERNEL in
    latest|zen) printf '  boot.kernelPackages = pkgs.linuxPackages_%s;%s' "$KERNEL" "${v:+   # Linux $v when this was written}" ;;
    *) printf '  # boot.kernelPackages = pkgs.linuxPackages_latest;   # the default kernel is used%s; _latest and _zen also exist' "${v:+ (Linux $(kernel_version default))}" ;;
  esac
}

# starter_fill FILE — fill the @…@ blanks of a template file
#   @HOST@ @USER@ @TZ@ @KEYMAP@ @XKB@ @SSH@ @CHANNEL@ @STATEVERSION@ @DATE@
#   @GNOME@ @KDE@ @COSMIC@ (stack_mark) @KERNEL@ (kernel_line) @UNFREE@
#   @EXTRA_PKGS@ (extra_pkgs); the result goes to stdout.
#   Example  starter_fill templates/starter/host.nix >"$dir/hosts/$HOST/default.nix"
starter_fill() {
  sed -e "s|@HOST@|$HOST|g" -e "s|@USER@|$NIXUSER|g" -e "s|@TZ@|$TZONE|g" -e "s|@KEYMAP@|$KEYMAP|g" -e "s|@XKB@|$XKB|g" \
      -e "s|@SSH@|$SSH|g" -e "s|@CHANNEL@|$(nixpkgs_channel)|g" -e "s|@STATEVERSION@|$(state_version)|g" -e "s|@DATE@|$(date +%F)|g" \
      -e "s|@GNOME@|$(stack_mark gnome)|" -e "s|@KDE@|$(stack_mark kde)|" -e "s|@COSMIC@|$(stack_mark cosmic)|" \
      -e "s|@KERNEL@|$(kernel_line)|" -e "s|@UNFREE@|$UNFREE|" -e "s|@EXTRA_PKGS@|$(extra_pkgs)|" "$1"
}

# gen_hardware_nix — CPU, GPU, laptop and VM settings from what detect_hw found
#   always       hardware.enableRedistributableFirmware
#   AMD / Intel  hardware.cpu.<vendor>.updateMicrocode
#   any GPU      hardware.graphics.enable
#   NVIDIA       allowUnfree, the nvidia video driver, modesetting, the
#                closed kernel module (open = true suits RTX 20 and newer);
#                a hybrid GPU (HW_GPU contains "+") gets a PRIME note
#   laptop       services.power-profiles-daemon
#   VM           services.qemuGuest
#   Example  gen_hardware_nix >"$dir/hosts/$HOST/hardware.nix"
gen_hardware_nix() {
  cat <<EOF
# Hardware settings for $HOST found by the installer on $(date +%F): $HW_CPU CPU, $HW_GPU GPU, $HW_FORM.
{ ... }:

{
  hardware.enableRedistributableFirmware = true;
EOF
  case $HW_CPU in
    AMD)   echo '  hardware.cpu.amd.updateMicrocode = true;' ;;
    Intel) echo '  hardware.cpu.intel.updateMicrocode = true;' ;;
  esac
  [[ $HW_GPU != none ]] && echo '  hardware.graphics.enable = true;'
  if [[ $HW_GPU == *NVIDIA* ]]; then
    cat <<'EOF'

  nixpkgs.config.allowUnfree = true;   # the NVIDIA driver is not free software
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;   # true works for the RTX 20 series and newer
    modesetting.enable = true;
  };
EOF
    [[ $HW_GPU == *+* ]] && echo '  # Hybrid graphics also needs hardware.nvidia.prime.* (bus IDs): see the NixOS wiki.'
  fi
  [[ $HW_FORM == laptop ]] && echo '  services.power-profiles-daemon.enable = true;'
  [[ $HW_FORM == "virtual machine" ]] && echo '  services.qemuGuest.enable = true;'
  echo '}'
}

# emit_starter DIR — every file of the starter flake except hardware-configuration.nix
#   flake.nix, README.md and hosts/HOST/default.nix from the templates
#   (starter_fill), stacks/*.nix copied as-is, and hosts/HOST/disk.nix and
#   hardware.nix generated.
#   Example  emit_starter "$TMP/preview"
emit_starter() {
  local c=$1 h=hosts/$HOST f
  mkdir -p "$c/$h" "$c/stacks"
  starter_fill "$TEMPLATES/starter/flake.nix" >"$c/flake.nix"
  starter_fill "$TEMPLATES/starter/host.nix" >"$c/$h/default.nix"
  starter_fill "$TEMPLATES/starter/README.md" >"$c/README.md"
  for f in "$TEMPLATES"/starter/stacks/*.nix; do install -Dm644 "$f" "$c/stacks/$(basename "$f")"; done
  gen_disk_nix >"$c/$h/disk.nix"
  gen_hardware_nix >"$c/$h/hardware.nix"
}
# write_starter — starter mode: emit_starter into the user's home on the new
# system, add hardware-configuration.nix from
# `nixos-generate-config --no-filesystems` (disk.nix already has the mounts),
# then git init -b main and make the first commit.
#   Example  write_starter
write_starter() {
  local c=/mnt/home/$NIXUSER/nixos-config
  emit_starter "$c"
  nixos-generate-config --root /mnt --no-filesystems --dir "$c/hosts/$HOST" >/dev/null
  rm -f "$c/hosts/$HOST/configuration.nix"   # we write our own default.nix
  git -C "$c" init -q -b main
  git -C "$c" add -A
  git -C "$c" -c user.name="nixos installer" -c user.email="installer@$HOST" commit -q -m "$HOST: initial configuration from the NixOS installer"
}
# finish_starter — commit the flake.lock that nixos-install created, if any.
#   Example  finish_starter
finish_starter() {
  local c=/mnt/home/$NIXUSER/nixos-config
  if [[ -f $c/flake.lock ]]; then
    git -C "$c" add flake.lock
    git -C "$c" -c user.name="nixos installer" -c user.email="installer@$HOST" commit -q -m "Add flake.lock" || true
  fi
}

# grow_live_store — the live ISO keeps /nix/store in a RAM disk (half of RAM).
# Evaluating the flake copies the whole repo (wallpapers included) into it, so
# a small-RAM machine runs out. Swap on the target + a bigger RAM disk fixes it.
#   Uses the btrfs /mnt/swap/swapfile if one was made, else creates an 8 GB
#   /mnt/.installer-swap (btrfs mkswapfile, or fallocate + mkswap), swaps on,
#   and when / is a tmpfs remounts it at RAM + 8 GB.
#   Example  grow_live_store
grow_live_store() {
  local sw=/mnt/swap/swapfile
  if [[ ! -e $sw ]]; then
    sw=/mnt/.installer-swap
    if [[ ! -e $sw ]]; then
      if [[ $(findmnt -no FSTYPE /mnt) == btrfs ]]; then btrfs filesystem mkswapfile --size 8G "$sw" >/dev/null
      else fallocate -l 8G "$sw" && chmod 600 "$sw" && mkswap "$sw" >/dev/null; fi
    fi
  fi
  swapon "$sw" 2>/dev/null || true
  if [[ $(findmnt -no FSTYPE /) == tmpfs ]]; then
    mount -o remount,size=$(( RAM_B / 1024 / 1024 / 1024 + 8 ))G / && echo "live store can now grow to $(findmnt -no SIZE /)"
  fi
}

# disk_byid DISK — stable /dev/disk/by-id path (GRUB/Limine on BIOS need one)
#   Skips partition, wwn- and nvme-eui. links; falls back to /dev/DISK.
#   Example  disk_byid sda   # e.g. /dev/disk/by-id/ata-Samsung_SSD_870_…
disk_byid() {
  local l
  for l in /dev/disk/by-id/*; do
    [[ $l == *-part* || $l == */wwn-* || $l == */nvme-eui.* ]] && continue
    [[ $(readlink -f "$l") == "/dev/$1" ]] && { echo "$l"; return; }
  done
  echo "/dev/$1"
}
# disk_busy DISK — true if anything on it is mounted (never wipe a live disk)
#   Example  disk_busy sda && echo "in use"
disk_busy() { lsblk -nro MOUNTPOINTS "/dev/$1" 2>/dev/null | grep -q .; }
# run_now CMD… — run immediately (disk tools), logged
#   Each CMD is a string run with eval; output goes to $LOG. Stops at the
#   first failure with a warning and returns 1.
#   Example  run_now "wipefs -a /dev/sdb" "mkfs.ext4 -F -L data /dev/sdb"
run_now() {
  local c
  for c; do echo "\$ $c" >>"$LOG"; eval "$c" >>"$LOG" 2>&1 || { warn "failed: $c (see $LOG)"; return 1; }; done
}

# save_state — write every answer to $STATE as `declare -p` lines, so
# --resume can source them and continue without the menus.
#   Example  save_state
save_state() {
  declare -p HOST NIXUSER NEWHOST PROFILE SYS MIRRORS HOME_DISK DATA OTHER FS SYS_RAID HOME_FS HOME_LABEL \
    DATA_RAID DATA_FS DATA_KEEP DATA_MNT DATA_LABEL DATA_OLDLABEL BOOT ENC SWAP SECRETS FW DISKS NAMES LAYOUT \
    SOURCE DESKTOP KERNEL UNFREE PKGS TZONE KEYMAP XKB SSH >"$STATE"
}

# preflight — refuse anything that could hurt a running system
#   - must run as root
#   - must run on the NixOS live ISO (/iso exists); INSTALL_ALLOW_NON_ISO=1
#     skips this check, for VM testing only
#   - no system, /home or to-be-formatted data disk may have anything mounted
#   Returns  1 with a message on the first failed check
#   Example  preflight || exit 1
preflight() {
  local d bad=()
  [[ $EUID == 0 ]] || { echo "${R}✗ the installer must run as root (sudo)${N}"; return 1; }
  if [[ ! -d /iso && -z ${INSTALL_ALLOW_NON_ISO:-} ]]; then
    echo "${R}✗ not on the NixOS live ISO — refusing to touch disks${N}"
    echo "  (INSTALL_ALLOW_NON_ISO=1 overrides this, for VM testing only)"; return 1
  fi
  for d in "${SYS_DISKS[@]}" ${HOME_DISK:+"$HOME_DISK"}; do disk_busy "$d" && bad+=("$d"); done
  if [[ $DATA_KEEP == 0 ]]; then for d in "${DATA[@]}"; do disk_busy "$d" && bad+=("$d"); done; fi
  (( ${#bad[@]} == 0 )) || { echo "${R}✗ mounted, refusing to wipe: ${bad[*]}${N}"; return 1; }
}

# run_install — execute gen_commands phase by phase; checkpoint after each phase
#   The last finished phase is written to $PHASEF. With --resume, phases up
#   to that number are skipped, except phase 3 (unlock + mount), which every
#   later phase needs. Lines that read the keyboard (cryptsetup, luks_open,
#   passwd) get /dev/tty; all others get /dev/null as stdin and are logged.
#   Returns  0 when all 7 phases ran, 1 after install_failed
#   Example  run_install || exit 1
run_install() {
  local line ph=0 done_ph=0 skip=0
  [[ -n $RESUME && -f $PHASEF ]] && done_ph=$(<"$PHASEF")
  echo "== install of $HOST started $(date -Is) (after phase $done_ph)" >>"$LOG"
  # The list comes in on fd 3: commands must never read their stdin from it
  # (cryptsetup would swallow the next line as its passphrase).
  while IFS= read -r line <&3; do
    if [[ $line =~ ^#\ \[([0-9]+)/7\]\ (.*)$ ]]; then
      if (( ph > 0 && !skip )); then echo "$ph" >"$PHASEF"; fi
      ph=${BASH_REMATCH[1]}; skip=0
      if (( ph <= done_ph && ph != 3 )); then skip=1; fi
      gum style --bold --foreground 212 "[$ph/7] ${BASH_REMATCH[2]}$( ((skip)) && echo "  (done — skipped)" || true)"
      echo "== [$ph/7] ${BASH_REMATCH[2]}" >>"$LOG"; continue
    fi
    [[ -z $line || $line == \#* ]] && continue
    ((skip)) && continue
    printf '%s$ %s%s\n' "$D" "$line" "$N"; echo "\$ $line" >>"$LOG"
    if [[ $line == cryptsetup* || $line == luks_open* || $line == *passwd* ]]; then   # needs the keyboard
      eval "$line" </dev/tty || { install_failed "$line"; return 1; }
    else
      eval "$line" </dev/null > >(tee -a "$LOG") 2>&1 || { install_failed "$line"; return 1; }
    fi
  done 3< <(gen_commands)
  echo 7 >"$PHASEF"
}
# install_failed LINE — print the failed command, the log path and how to
# --resume; adds a hint when the live ISO's RAM disk is full.
#   Example  install_failed "nixos-install --flake …"
install_failed() {
  echo; echo "${R}✗ failed:${N} $1"
  echo "  Log: $LOG"
  echo "  Fix the cause, then run the installer again with ${B}--resume${N}: it continues after the last"
  echo "  finished phase. Disks are not re-partitioned; LUKS is re-opened and everything re-mounted."
  if tail -20 "$LOG" | grep -q 'No space left on device'; then
    echo "  ${Y}The live ISO's RAM disk is full.${N} Free it first:  ${B}nix-collect-garbage${N}  — then --resume."
  fi
}

# checklist — the first-boot to-do list from $REPO/docs/04-first-boot.md:
# the "## All Machines" section's ### steps plus the steps under a ## heading
# that names HOST. Secret steps are ticked when SECRETS=done; the password
# step notes the primary user is done.
#   Example  checklist
checklist() {  # post-install steps for this host, straight from docs/04
  [[ -f $REPO/docs/04-first-boot.md ]] || return 0  # older config without the doc: no list
  awk -v host="$HOST" -v sec="$SECRETS" '
    /^## / { s = ($0 ~ /^## All Machines/) ? "all" : ((host != "" && index($0, host)) ? "host" : ""); if (s == "host") print "\n" substr($0, 4); next }
    /^### / && s { t = substr($0, 5)
                   if (sec == "done" && t ~ /secrets\.nix|apply secrets/) print "  ☑ " t "  (done by installer)"
                   else if (t ~ /Set user passwords/) print "  ☐ " t "  (primary user done by installer)"
                   else print "  ☐ " t }' "$REPO/docs/04-first-boot.md"
}

# ==========================================================================
# Main
# ==========================================================================
# Detect hardware and disks, ask the steps, then install (real mode) or
# show what would be done (--demo), and print the after-install notes.

# Hardware from sysfs (detect_hw; TEST_FW overrides uefi/bios in tests),
# then disks: fake scenarios (--fake-disks) or the real disks with SMART data
# each. The ISO's own boot device, USB and removable disks are hidden from the
# disk steps.
detect_hw
if [[ -n ${INSTALL_TEST:-} && -n ${TEST_FW:-} ]]; then FW=$TEST_FW; fi   # tests: pretend to boot as uefi or bios
if [[ -n $FAKE ]]; then ALL=$(fake_disks "$FAKE" | norm)
else
  ALL=$(real_disks)
  for n in $(jq -r '.[].name' <<<"$ALL"); do
    d=$(smart_real "$n"); jq -e . >/dev/null 2>&1 <<<"$d" || d='{"err":"unreadable SMART output"}'
    ALL=$(jq --arg n "$n" --argjson d "$d" '(.[] | select(.name==$n)).smartd = $d' <<<"$ALL")
  done
  ALL=$(norm <<<"$ALL")
fi
BOOTDEV=$(findmnt -no SOURCE /iso 2>/dev/null | sed -E 's#/dev/##; s/p?[0-9]+$//' || true)
VISIBLE=$(jq --arg b "$BOOTDEV" '[.[] | select(.name != $b and .tran != "usb" and (.rm|not))]' <<<"$ALL")
HIDDEN=$(jq -r --arg b "$BOOTDEV" '[.[] | select(.name == $b or .tran == "usb" or .rm) | "\(.name) \(.model)"] | join(", ")' <<<"$ALL")
SECRETS=skip
# Saved answers are per disk set — keep fake scenarios apart from real disks
[[ -n $FAKE ]] && ANSWERS_DIR+="/$FAKE"

# Demo without root: offer to re-exec under sudo for SMART data. Real mode
# without root: re-exec under sudo, keeping the SSH agent and installer
# variables.
MODE_TAG=$([[ -n $DEMO ]] && echo DEMO || echo INSTALL)
HEADER=$(banner)
# alternate screen + hidden cursor: menus don't litter scrollback
if [[ -z ${INSTALL_TEST:-} ]] && tput smcup 2>/dev/null; then ALT=1; tput civis; clear; fi
# Not root on real disks: offer to restart under sudo (SMART needs it; the real
# installer always runs as root because it partitions disks)
if [[ $EUID != 0 && -z $FAKE && -z ${INSTALL_TEST:-} && -n $DEMO ]]; then
  panel "Administrator access" "$(box -t "Why sudo?" \
    "Reading disk health (SMART) needs root. Without it the Disks step shows \"? needs sudo\"." \
    "The real installer always runs as root — it partitions and formats disks." \
    "" "Re-running restarts the demo with the same options and asks for your password.")"
  r=skip; pick r "Run as administrator?" "Re-run with sudo ★   (asks for your password)|sudo" "Continue without disk health|skip" || true
  if [[ $r == sudo ]]; then
    ((ALT)) && { tput cnorm; tput rmcup; } 2>/dev/null; ALT=0
    exec sudo --preserve-env=TERM,COLORTERM,LANG "$0" "${ARGS[@]}"
  fi
fi

if [[ -z $DEMO && $EUID != 0 ]]; then   # the real installer partitions disks → root
  ((ALT)) && { tput cnorm; tput rmcup; } 2>/dev/null; ALT=0
  echo "The installer partitions disks, so it runs as root."
  exec sudo --preserve-env=TERM,COLORTERM,LANG,SSH_AUTH_SOCK,INSTALL_ALLOW_NON_ISO,INSTALLER_GIT "$0" "${ARGS[@]}"
fi
if [[ -n $RESUME ]]; then   # skip the menus: same answers, continue the install
  ((ALT)) && { tput cnorm; tput rmcup; } 2>/dev/null; ALT=0
  [[ -f $STATE ]] || { echo "nothing to resume ($STATE missing)"; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE"; SYS_DISKS=("$SYS" "${MIRRORS[@]}")
  [[ $SOURCE == linuxury ]] && { load_config || exit 1; }
  echo "Resuming the install of $HOST after phase $(cat "$PHASEF" 2>/dev/null || echo 0)…"
  if run_install; then echo "${G}${B}✓ $HOST is installed.${N} Remove the USB stick and reboot."; exit 0; fi
  exit 1
fi

# The step loop: run STEPS[CUR] and move by its return code (0 next or back
# to the menu, 3 jump to JUMP, anything else back one step or to the menu).
while (( CUR < ${#STEPS[@]} )); do
  rc=0; fn=${STEPS[CUR]}; "$fn" || rc=$?
  case $rc in
    0) if ((HUB)) && hub_section "$fn"; then   # menu mode: an answered section goes back to the menu
         VISITED[$fn]=1
         CUR=$HUB_IDX
       else CUR=$((CUR + 1)); fi ;;
    3) CUR=$JUMP ;;
    *) if ((HUB)) && hub_section "$fn"; then CUR=$HUB_IDX
       elif ((CUR > 0)); then CUR=$((CUR - 1)); fi ;;
  esac
done
if ((ALT)); then tput cnorm; tput rmcup; ALT=0; fi

# Real mode: preflight, save the answers for --resume, clear the phase
# checkpoint and install. Both modes then save the answers to ANSWERS_DIR.
SYS_DISKS=("$SYS" "${MIRRORS[@]}")
if [[ -z $DEMO ]]; then   # ---- the real install
  preflight || exit 1
  save_state; rm -f "$PHASEF"
  if run_install; then echo; echo "${G}${B}✓ $HOST is installed.${N} Remove the USB stick and reboot."
  else exit 1; fi
fi
if mkdir -p "$ANSWERS_DIR" && answers_json > "$ANSWERS_DIR/$HOST.json" 2>/dev/null; then
  [[ -n ${SUDO_UID:-} ]] && chown -R "$SUDO_UID" "/tmp/install-demo-answers-$OWNER_UID" 2>/dev/null
else echo "${Y}⚠ could not save answers to $ANSWERS_DIR (continuing)${N}"; fi
# The closing screen. Demo: show the generated files and the command list.
# Both modes: what was written, where the log is, how to resume; linuxury
# mode adds the first-boot checklist.
if [[ $SOURCE == starter ]]; then
  if [[ -n $DEMO ]]; then
    OUT=${STARTER_OUT:-$TMP/starter}; emit_starter "$OUT"
    gum style --bold --foreground 212 "Your starter flake  (would be written to /home/$NIXUSER/nixos-config)"
    (cd "$OUT" && find . -type f | sed 's|^\./||' | sort) | sed 's/^/  /'
    echo "  hosts/$HOST/hardware-configuration.nix   (made at install time by nixos-generate-config)"
    for f in hosts/$HOST/default.nix hosts/$HOST/hardware.nix hosts/$HOST/disk.nix; do
      echo; gum style --bold --foreground 212 "$f"; cat "$OUT/$f"
    done
    echo; gum style --bold --foreground 212 "Commands  (would be run — the real installer runs exactly these)"
    gen_commands | gum style --foreground 245
  fi
  echo; gum style --bold --foreground 212 "After install"
  printf '  %-9s %s\n' \
    "Wrote" "/home/$NIXUSER/nixos-config: flake.nix, hosts/$HOST/, stacks/, README.md (first git commit made)" \
    "Password" "asked for $NIXUSER at the end of the install; it is not stored in the config" \
    "Log" "/tmp/nixos-install.log → /mnt/var/log/nixos-install.log" \
    "Resume" "a failed phase continues with: --resume (no re-partitioning)" \
    "Next" "read /home/$NIXUSER/nixos-config/README.md: rebuild, change desktop, back it up to git"
  [[ -n $DEMO ]] && { echo; gum style --foreground 82 "✓ Demo complete — nothing was written to disk." \
    "Real run, from the ISO:  sudo nix run github:Linuxury/NixOS-Installer"; }
else
  if [[ -n $DEMO ]]; then
    gum style --bold --foreground 212 "hosts/$HOST/disk.nix  (would be written)"
    gen_disk_nix
    echo; gum style --bold --foreground 212 "hosts/$HOST/install.json  (saved answers — would be committed)"
    cat "$ANSWERS_DIR/$HOST.json"
    echo; gum style --bold --foreground 212 "Commands  (would be run — the real installer runs exactly these)"
    gen_commands | gum style --foreground 245
  fi
  echo; gum style --bold --foreground 212 "After install"
  printf '  %-8s %s\n' \
    "Wrote" "hosts/$HOST/disk.nix + hosts/$HOST/install.json (git commit)$([[ $NEWHOST == 1 ]] && echo "; still to add by hand: hosts/$HOST/$HOST.nix + its flake.nix entry" || true)" \
    "Log" "/tmp/nixos-install.log → /mnt/var/log/nixos-install.log" \
    "Resume" "a failed phase continues with: --resume (no re-partitioning)" \
    "Saved" "answers in install.json — next reinstall of $HOST is one keypress" \
    "Secrets" "$([[ $SECRETS == "done" ]] && echo "re-keyed — they decrypt on first boot" || echo "skipped — run add-host $HOST, then nru (docs/04)")"
  echo; gum style --bold --foreground 212 "After first boot — checklist for $HOST  (from docs/04-first-boot.md)"
  checklist
  [[ -n $DEMO ]] && { echo; gum style --foreground 82 "✓ Demo complete — nothing was written to disk or repo." \
    "Run the demo again and pick $HOST: it offers ↻ reinstall with these saved answers." \
    "Real run, from the ISO:  sudo nix run github:Linuxury/NixOS-Installer" \
    "Or from your admin PC:  install-host <ip>"; }
fi
