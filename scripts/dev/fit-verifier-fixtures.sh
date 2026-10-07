#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build negative-test FIT fixtures for a U-Boot FIT signature verifier from a
# signed FIT the build produced. Host-side only; nothing touches a board.
#
#   v0-control.itb      the source FIT, unchanged             -> must verify
#   v1-kernel-byte.itb  one bit flipped inside kernel data    -> must be rejected
#   v2-config-byte.itb  one bit flipped in the signed config  -> must be rejected
#   v3-uncovered.itb    re-signed with the real key, but the config's fdt is
#                       outside sign-images                   -> must be rejected
#                       by a verifier that hashes the images the config
#                       references (CVE-2026-46728 fix); a pre-fix verifier
#                       accepts it
#
# v1/v2 are byte edits of a signed image and are deliberately not re-signed.
# v3 needs the FIT signing key; without --key-dir it is skipped.
#
# Usage:
#   fit-verifier-fixtures.sh --fit <signed fitImage> --out <dir> \
#       [--conf <config>] [--key-dir <dir> [--key-name <name>]] \
#       [--tools <dir with mkimage, dumpimage, fit_check_sign>] \
#       [--check <dtb holding the public key>]
#
# --check runs fit_check_sign on every fixture against the given key DTB
# (e.g. U-Boot's control DTB) and prints accept/reject per fixture.
# Requires: python3, fdtget (dtc), mkimage/dumpimage (U-Boot tools).

set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
FIT="" OUT="" CONF="" KEYDIR="" KEYNAME="" TOOLS="" CHECK=""

usage() { sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }
die()   { echo "fit-verifier-fixtures: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --fit)      FIT=$2; shift 2 ;;
        --out)      OUT=$2; shift 2 ;;
        --conf)     CONF=$2; shift 2 ;;
        --key-dir)  KEYDIR=$2; shift 2 ;;
        --key-name) KEYNAME=$2; shift 2 ;;
        --tools)    TOOLS=$2; shift 2 ;;
        --check)    CHECK=$2; shift 2 ;;
        -h|--help)  usage 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
done
[ -n "$FIT" ] && [ -n "$OUT" ] || usage 1
[ -f "$FIT" ] || die "no such FIT: $FIT"

tool() { if [ -n "$TOOLS" ]; then echo "$TOOLS/$1"; else command -v "$1" || die "$1 not found (use --tools)"; fi; }
MKIMAGE=$(tool mkimage); DUMPIMAGE=$(tool dumpimage)
command -v fdtget >/dev/null || die "fdtget not found (dtc package)"

locate() { python3 -I "$HERE/fit-locate-prop.py" "$@"; }
flip() {  # flip bit 0 of the byte at offset $2 in file $1
    python3 -I - "$1" "$2" <<'EOF'
import sys
f, pos = sys.argv[1], int(sys.argv[2])
b = bytearray(open(f, 'rb').read())
old = b[pos]; b[pos] ^= 1
open(f, 'wb').write(b)
print(f'  {f}: byte {pos} {old:#04x} -> {b[pos]:#04x}')
EOF
}

[ -n "$CONF" ] || CONF=$(fdtget -t s "$FIT" /configurations default)
C=/configurations/$CONF
KIMG=$(fdtget -t s "$FIT" "$C" kernel)
FIMG=$(fdtget -t s "$FIT" "$C" fdt)
SIGNODE=$(fdtget -l "$FIT" "$C" | grep -m1 '^signature') || die "$C has no signature node"
ALGO=$(fdtget -t s "$FIT" "$C/$SIGNODE" algo)
[ -n "$KEYNAME" ] || KEYNAME=$(fdtget -t s "$FIT" "$C/$SIGNODE" key-name-hint)
echo "source $FIT: config $CONF, kernel $KIMG, fdt $FIMG, $ALGO key '$KEYNAME'"

mkdir -p "$OUT"
install -m 0644 "$FIT" "$OUT/v0-control.itb"

install -m 0644 "$FIT" "$OUT/v1-kernel-byte.itb"
read -r off len < <(locate "$OUT/v1-kernel-byte.itb" "/images/$KIMG" data)
flip "$OUT/v1-kernel-byte.itb" $((off + len / 2))

install -m 0644 "$FIT" "$OUT/v2-config-byte.itb"
read -r off len < <(locate "$OUT/v2-config-byte.itb" "$C" description)
flip "$OUT/v2-config-byte.itb" $((off + len / 2))

if [ -n "$KEYDIR" ]; then
    KEYDIR=$(readlink -f "$KEYDIR")
    [ -f "$KEYDIR/$KEYNAME.key" ] || die "no $KEYDIR/$KEYNAME.key"
    # dumpimage -p takes the image's position under /images.
    idx() { fdtget -l "$FIT" /images | grep -nx "$1" | cut -d: -f1 | awk '{print $1 - 1}'; }
    "$DUMPIMAGE" -T flat_dt -p "$(idx "$KIMG")" -o "$OUT/kernel.bin" "$FIT" >/dev/null
    "$DUMPIMAGE" -T flat_dt -p "$(idx "$FIMG")" -o "$OUT/fdt.dtb" "$FIT" >/dev/null
    k() { fdtget -t "$1" "$FIT" "/images/$KIMG" "$2"; }
    cat > "$OUT/v3-uncovered.its" <<EOF
/dts-v1/;
/ {
    description = "fdt referenced by the config but outside sign-images";
    #address-cells = <1>;
    images {
        $KIMG {
            data = /incbin/("kernel.bin");
            type = "kernel"; arch = "$(k s arch)"; os = "$(k s os)";
            compression = "$(k s compression)";
            load = <0x$(k x load)>; entry = <0x$(k x entry)>;
            hash-1 { algo = "sha256"; };
        };
        $FIMG {
            data = /incbin/("fdt.dtb");
            type = "flat_dt"; arch = "$(k s arch)"; compression = "none";
            hash-1 { algo = "sha256"; };
        };
    };
    configurations {
        default = "$CONF";
        $CONF {
            kernel = "$KIMG"; fdt = "$FIMG";
            signature-1 { algo = "$ALGO"; key-name-hint = "$KEYNAME"; sign-images = "kernel"; };
        };
    };
};
EOF
    (cd "$OUT" && "$MKIMAGE" -f v3-uncovered.its -k "$KEYDIR" v3-uncovered.itb >/dev/null) \
        || die "mkimage failed to build v3"
    # mkimage can report a signing failure and still write the image.
    fdtget "$OUT/v3-uncovered.itb" "$C/signature-1" value >/dev/null 2>&1 \
        || die "v3 was written without a signature (key $KEYDIR/$KEYNAME.key)"
    echo "  $OUT/v3-uncovered.itb: signed, sign-images = kernel only"
else
    echo "  v3 skipped (no --key-dir)"
fi

if [ -n "$CHECK" ]; then
    FCS=$(tool fit_check_sign)
    echo "fit_check_sign against $CHECK:"
    for f in "$OUT"/v*.itb; do
        if "$FCS" -f "$f" -k "$CHECK" -c "$CONF" >"${f%.itb}.check.log" 2>&1; then r=ACCEPT; else r=REJECT; fi
        printf '  %-22s %s\n' "$(basename "$f")" "$r"
    done
fi
