#!/bin/bash
# Host-only selftest for edge-sdboot-backend, RAUC's custom bootloader backend
# over systemd-boot boot counting (ADR-0016 §6).
#
# Runs the backend against a temporary ESP directory and a fake efivarfs. The
# expected primary slot of every naming case is systemd-boot 259.5's order
# for UKIs with an equal sort key and version: no tries left last, then name,
# highest strverscmp first. Each scenario also checks that nothing but the
# named files changed.
#
#   scripts/ci/edge-sdboot-backend-selftest.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BACKEND=${EDGE_SDBOOT_BACKEND:-$ROOT/meta-edge-bsp/recipes-ota/edge-sdboot-backend/files/edge-sdboot-backend}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export EDGE_SDBOOT_DIR=$T/esp/EFI/Linux
export EDGE_EFIVARS=$T/efivars
export EDGE_SDBOOT_LOCK=$T/lock
LOADER_GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# setup <file>...: fresh ESP holding exactly these entries; each holds its own name.
setup() {
  rm -rf "$T/esp" "$T/efivars"
  mkdir -p "$EDGE_SDBOOT_DIR" "$EDGE_EFIVARS"
  local f
  for f in "$@"; do printf 'MZ%s' "$f" > "$EDGE_SDBOOT_DIR/$f"; done
}

listing() { (cd "$EDGE_SDBOOT_DIR" && LC_ALL=C ls -A | tr '\n' ' '); }

# run <expected exit> <expected stdout|-> <label> <args>...
run() {
  local want_rc=$1 want_out=$2 label=$3 out rc
  shift 3
  out=$(bash "$BACKEND" "$@" 2>"$T/stderr"); rc=$?
  if [[ $rc != "$want_rc" ]]; then
    bad "$label: exit $rc, want $want_rc ($(cat "$T/stderr"))"; return
  fi
  if [[ $want_out != - && $out != "$want_out" ]]; then
    bad "$label: output '$out', want '$want_out'"; return
  fi
  ok
}

# expect_files <label> <listing>: directory holds exactly these names.
expect_files() {
  local got
  got=$(listing)
  [[ $got == "$2" ]] && ok || bad "$1: files '$got', want '$2'"
}

# --- get-primary: systemd-boot order ---------------------------------------
primary() { setup "${@:2}"; run 0 "$1" "get-primary ${*:2}" get-primary; }
primary A edge-2-a.efi edge-1-b.efi
primary B edge-1-a.efi edge-2-b.efi
primary A edge-10-a.efi edge-9-b.efi                 # numeric, not ASCII
primary B edge-9-a.efi edge-10-b.efi
primary A edge-3-a+2-1.efi edge-2-b.efi              # trial entry is not demoted
primary B edge-3-a+0-3.efi edge-2-b.efi              # exhausted sorts last
primary B edge-3-a+0.efi edge-2-b.efi
primary A edge-3-a+1-2.efi edge-2-b+0-3.efi
primary A edge-3-a+0-3.efi edge-2-b+0-3.efi          # both bad: name decides
primary B edge-2-a.efi edge-2-b.efi                  # equal gen: "edge-2-b" > "edge-2-a"
primary A edge-5-a.efi                               # one slot only
setup; run 1 - "get-primary on empty dir" get-primary

# Unrelated files are ignored; malformed slot names and duplicates are refused.
setup edge-2-a.efi edge-1-b.efi other.efi .edge-a.install
run 0 A "get-primary ignores non-edge files" get-primary
setup edge-2-a.efi edge-1-b.efi edge-3-a+1.efi
run 1 - "two entries for slot A" get-primary
setup edge-2-a.efi edge-0-b.efi
run 1 - "generation 0 refused" get-primary
setup edge-2-a.efi edge-1-c.efi
run 1 - "unknown slot letter refused" get-primary
setup edge-2-a.efi edge-1-b+x.efi
run 1 - "malformed counter refused" get-primary
rm -rf "$T/esp"; run 1 - "missing ESP dir" get-primary

# --- set-primary ------------------------------------------------------------
setup edge-2-a.efi edge-1-b.efi
run 0 "" "set-primary B" set-primary B
expect_files "set-primary B renames to next gen with +3" "edge-2-a.efi edge-3-b+3.efi "
run 0 B "get-primary after set-primary B" get-primary

setup edge-2-a.efi edge-1-b+0.efi
run 0 "" "set-primary on a bad slot" set-primary B
expect_files "bad slot re-armed" "edge-2-a.efi edge-3-b+3.efi "

setup edge-4-a.efi edge-3-b.efi
run 0 "" "set-primary of the current primary" set-primary A
expect_files "primary re-armed at next gen" "edge-3-b.efi edge-5-a+3.efi "

setup edge-2-a.efi edge-1-b.efi
EDGE_SDBOOT_TRIES=5 run 0 "" "EDGE_SDBOOT_TRIES" set-primary B
expect_files "tries from environment" "edge-2-a.efi edge-3-b+5.efi "
EDGE_SDBOOT_TRIES=0 run 1 - "EDGE_SDBOOT_TRIES=0 refused" set-primary B

# Generation boundary: the last accepted generation is written, the next one refused
# before any rename, and every call still reads the directory afterwards.
setup edge-999999998-a.efi edge-1-b.efi
run 0 "" "set-primary up to the generation limit" set-primary B
expect_files "generation 999999999 written" "edge-999999998-a.efi edge-999999999-b+3.efi "
run 0 B "get-primary at the generation limit" get-primary
run 1 - "set-primary past the generation limit refused" set-primary A
expect_files "nothing renamed at the limit" "edge-999999998-a.efi edge-999999999-b+3.efi "
run 0 B "get-primary still works after the refusal" get-primary
run 0 "" "state changes still work at the limit" set-state B good
expect_files "counter dropped at the limit" "edge-999999998-a.efi edge-999999999-b.efi "

setup edge-2-a.efi
run 1 - "set-primary of a slot without entry" set-primary B
expect_files "nothing renamed" "edge-2-a.efi "
setup edge-2-a.efi edge-1-b.efi
run 1 - "set-primary of an unknown bootname" set-primary C
run 1 - "set-primary lowercase bootname refused" set-primary b
run 1 - "get-state lowercase bootname refused" get-state a

# --- get-state / set-state ---------------------------------------------------
setup edge-3-a+2-1.efi edge-2-b+0-3.efi
run 0 good "trial entry is good" get-state A
run 0 bad "exhausted entry is bad" get-state B
setup edge-3-a.efi edge-2-b+0.efi
run 0 good "uncounted entry is good" get-state A
run 0 bad "+0 entry is bad" get-state B
setup edge-3-a.efi
run 1 - "get-state of a slot without entry" get-state B

setup edge-3-a+2-1.efi edge-2-b.efi
run 0 "" "set-state good drops the counter" set-state A good
expect_files "counter dropped" "edge-2-b.efi edge-3-a.efi "
run 0 "" "set-state good on an uncounted entry" set-state A good
expect_files "uncounted entry untouched" "edge-2-b.efi edge-3-a.efi "

setup edge-3-a.efi edge-2-b.efi
run 0 "" "set-state bad" set-state B bad
expect_files "bad = +0" "edge-2-b+0.efi edge-3-a.efi "
setup edge-3-a.efi edge-2-b+0-3.efi
run 0 "" "set-state bad on an exhausted entry" set-state B bad
expect_files "exhausted entry keeps its name" "edge-2-b+0-3.efi edge-3-a.efi "
setup edge-3-a.efi edge-2-b+2-1.efi
run 0 "" "set-state bad during a trial" set-state B bad
expect_files "trial entry to +0" "edge-2-b+0.efi edge-3-a.efi "
run 1 - "set-state with an unknown state" set-state A maybe

# RAUC's sequence for an install into B, then B's confirmation with
# prevent-late-fallback.
setup edge-2-a.efi edge-1-b.efi
run 0 "" "install: mark target bad" set-state B bad
run 0 A "install: A stays primary while B is written" get-primary
run 0 "" "install: activate B" set-primary B
run 0 B "install: B primary" get-primary
mv "$EDGE_SDBOOT_DIR/edge-3-b+3.efi" "$EDGE_SDBOOT_DIR/edge-3-b+2-1.efi"   # systemd-boot's rename
run 0 "" "mark-good B" set-state B good
run 0 "" "prevent-late-fallback marks A bad" set-state A bad
expect_files "after confirmation" "edge-2-a+0.efi edge-3-b.efi "
run 0 B "B primary after confirmation" get-primary

# A trial that exhausts its tries falls back to the other slot.
setup edge-2-a.efi edge-3-b+0-3.efi
run 0 A "exhausted trial falls back" get-primary

# --- install-uki -------------------------------------------------------------
setup edge-2-a.efi edge-1-b+0.efi
printf 'MZnew-uki' > "$T/new.efi"
run 0 "" "install-uki B" install-uki B "$T/new.efi"
expect_files "install-uki keeps the name" "edge-1-b+0.efi edge-2-a.efi "
[[ $(cat "$EDGE_SDBOOT_DIR/edge-1-b+0.efi") == MZnew-uki ]] && ok || bad "install-uki content"
[[ $(cat "$EDGE_SDBOOT_DIR/edge-2-a.efi") == MZedge-2-a.efi ]] && ok || bad "install-uki touched slot A"
printf 'ELF' > "$T/not-pe"
run 1 - "install-uki refuses a non-PE file" install-uki B "$T/not-pe"
run 1 - "install-uki of a missing file" install-uki B "$T/missing.efi"
setup edge-2-a.efi
run 1 - "install-uki without a slot entry" install-uki B "$T/new.efi"
expect_files "nothing written" "edge-2-a.efi "

# --- get-current -------------------------------------------------------------
setup edge-2-a.efi edge-3-b.efi
loader_var() { printf '\x06\x00\x00\x00'; printf '%s' "$1" | sed 's/./&\x00/g'; printf '\x00\x00'; }
loader_var edge-3-b.efi > "$EDGE_EFIVARS/LoaderEntrySelected-$LOADER_GUID"
run 0 B "get-current from LoaderEntrySelected" get-current
loader_var edge-3-b+2-1.efi > "$EDGE_EFIVARS/LoaderEntrySelected-$LOADER_GUID"
run 1 - "get-current refuses a counted id" get-current
loader_var auto-efi-default > "$EDGE_EFIVARS/LoaderEntrySelected-$LOADER_GUID"
run 1 - "get-current refuses a non-slot entry" get-current
rm -f "$EDGE_EFIVARS/LoaderEntrySelected-$LOADER_GUID"
run 1 - "get-current without systemd-boot" get-current

# --- bundle hook (bundle-hooks-uefi-uki.sh) against this backend ------------
HOOK_SRC=${EDGE_SDBOOT_HOOK:-$ROOT/meta-edge-bsp/recipes-ota/rauc/files/bundle-hooks-uefi-uki.sh}
mkdir -p "$T/bundle"
printf 'MZbundle-uki-A' > "$T/bundle/img.uki-A.efi"
printf 'MZbundle-uki-B' > "$T/bundle/img.uki-B.efi"
sed -e "s|@SDBOOT_BACKEND@|$T/backend|" -e "s|@UKI_IMAGE_A@|img.uki-A.efi|" \
    -e "s|@UKI_IMAGE_B@|img.uki-B.efi|" "$HOOK_SRC" > "$T/hook"
printf '#!/bin/bash\nexec bash %q "$@"\n' "$BACKEND" > "$T/backend"
chmod +x "$T/hook" "$T/backend"
hook() {  # hook <expected exit> <label> <bootname> <hook arg>
  local rc
  RAUC_BUNDLE_MOUNT_POINT=$T/bundle RAUC_SLOT_NAME=rootfs.x RAUC_SLOT_BOOTNAME=$3 \
    bash "$T/hook" "$4" >/dev/null 2>"$T/stderr"; rc=$?
  [[ $rc == "$1" ]] && ok || bad "$2: exit $rc, want $1 ($(cat "$T/stderr"))"
}
setup edge-2-a.efi edge-1-b+0.efi
hook 0 "hook pre-install B" B slot-pre-install
hook 0 "hook post-install B" B slot-post-install
[[ $(cat "$EDGE_SDBOOT_DIR/edge-1-b+0.efi") == MZbundle-uki-B ]] && ok || bad "hook installed B's UKI into B's entry"
[[ $(cat "$EDGE_SDBOOT_DIR/edge-2-a.efi") == MZedge-2-a.efi ]] && ok || bad "hook left A untouched"
hook 1 "hook with bootname C" C slot-post-install
hook 1 "hook with an unknown hook type" B install-check
rm "$T/bundle/img.uki-A.efi"
hook 1 "hook pre-install without the slot's UKI in the bundle" A slot-pre-install
setup edge-2-a.efi
hook 1 "hook pre-install without the target's ESP entry" B slot-pre-install
setup edge-2-a.efi edge-1-b.efi
rm "$T/backend"
hook 1 "hook on an image without the backend" B slot-pre-install

# --- usage -------------------------------------------------------------------
run 1 - "no command" ""
run 1 - "unknown command" frobnicate
run 1 - "extra argument" get-primary A

echo "edge-sdboot-backend selftest: $pass passed, $fail failed"
(( fail == 0 ))
