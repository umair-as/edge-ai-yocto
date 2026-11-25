#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Record the task hashes of the board's kernel recipe, without building.
# Runs inside `kas shell` (bitbake on PATH); `make kernel-hash` wraps it.
#
# `bitbake -S none` computes every task signature and writes one sigdata file
# per task, named <stamp>.<task>.sigdata.<taskhash>. The output has one line
# per kernel task, "<task> <taskhash>", sorted, so two runs (before and after
# a change elsewhere) can be compared with diff. An empty diff means no
# kernel task reruns.
#
# bitbake-diffsigs and the stale-output side effect: docs/dev/build-system.md.
#
#   kernel-hash.sh <output-file>
set -euo pipefail

usage() {
    echo "usage: kernel-hash.sh <output-file>" >&2
    echo "  writes '<task> <taskhash>' for each task of virtual/kernel, sorted" >&2
    exit 2
}

[ $# -eq 1 ] || usage
case $1 in -h | --help) usage ;; esac
out=$1

pn=$(bitbake-getvar -r virtual/kernel --value -q PN)
stamp=$(bitbake-getvar -r virtual/kernel --value -q STAMP)
if [ -z "$pn" ] || [ -z "$stamp" ]; then
    echo "kernel-hash: PN or STAMP of virtual/kernel is empty" >&2
    exit 1
fi

# Sigdata from earlier runs stays in the stamp directory under the old hash;
# only files written by this run count. bitbake writes each file afresh, so
# its mtime is after the marker even when the hash is unchanged.
marker=$(mktemp)
trap 'rm -f "$marker"' EXIT

bitbake -S none virtual/kernel >/dev/null

lines=$(find "$(dirname "$stamp")" -maxdepth 1 -type f \
    -name "$(basename "$stamp").do_*.sigdata.*" -newer "$marker" -printf '%f\n' \
    | sed -E 's/^.*\.(do_[A-Za-z0-9_]+)\.sigdata\.([0-9a-f]+)$/\1 \2/' | LC_ALL=C sort -u)

[ -n "$lines" ] || { echo "kernel-hash: no sigdata written for $pn under $(dirname "$stamp")" >&2; exit 1; }
if [ "$(cut -d' ' -f1 <<<"$lines" | uniq -d | wc -l)" -ne 0 ]; then
    echo "kernel-hash: a task has more than one fresh sigdata file; rerun" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"
printf '%s\n' "$lines" >"$out"
echo "kernel-hash: $pn, $(wc -l <"$out") tasks -> ${out##*/}"
