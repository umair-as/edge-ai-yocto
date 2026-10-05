#!/usr/bin/env bash
# Export the expanded kernel .config from the build stack without compiling.
# Runs inside `kas shell` (bitbake on PATH); `make kernel-config-export` wraps
# it. The output is what the KSPP gate (files/khc/khc-gate.py in the BSP
# layer) consumes.
#
#   kernel-config-export.sh <output-path>
set -euo pipefail

out=${1:?usage: kernel-config-export.sh <output-path>}

bitbake virtual/kernel -c configure

# ${B}/.config is the expanded config after do_configure: fragments merged,
# olddefconfig run, every default materialised.
b=$(bitbake-getvar -r virtual/kernel --value -q B)
cfg="$b/.config"

[ -f "$cfg" ] || { echo "kernel-config-export: $cfg not found after do_configure" >&2; exit 1; }
grep -q '^# Linux/.* Kernel Configuration' "$cfg" \
    || { echo "kernel-config-export: $cfg has no kernel-config header" >&2; exit 1; }

install -D -m 0644 "$cfg" "$out"
echo "kernel-config-export: $(grep -c '^CONFIG_' "$out") options -> ${out##*/}"
