# RZ/V2L JTAG host enablement (OpenOCD + gdb-multiarch)

Host-side config to attach a debugger to the RZ/V2L SMARC board over JTAG.
Pairs with the debug-profile kernel (`make dev JTAG=1`, KASLR off + kgdb +
gdb scripts) — see `../jtag-kernel-debugging.md` for the kernel side and the
sustained-halt caveat (use NFS-root for breakpoints; see `../netboot-setup.md`).

## Files

| File | Purpose |
|---|---|
| `rzv2l-openocd.cfg` | Full target bring-up: Olimex interface + Renesas RZ target (A55×2 + M33 + AXI), GDB servers on `:3333` (A55) / `:3334` (M33) |
| `rzv2l-scan.cfg` | Passive scan-chain check — reads the DAP IDCODE, no halt/reset |
| `rzv2l.gdb` | gdb-multiarch init for the KASLR-off debug kernel (no offset) |

## Hardware

- **Adapter:** Olimex ARM-USB-TINY-H → ARM-JTAG-20-10 adapter → the carrier's
  10-pin Cortex debug header.
- **Board switch:** `SW1-1 = OFF` on the SMARC module asserts `RZ_DEBUGEN` —
  without it the DAP does not respond.
- **DAP:** Arm CoreSight, TAP id `0x6ba00477` (Cortex-A class).

## OpenOCD

Ubuntu 24.04 ships OpenOCD **0.12.0**, which already carries both the Olimex
interface (`interface/ftdi/olimex-arm-usb-tiny-h.cfg`) and the Renesas target
(`target/renesas_rz_g2.cfg`) on its default search path:

```sh
sudo apt install openocd
```

Only the newer `SOC=V2L` target file (`renesas_rz.cfg`, added after 0.12.0)
needs a source-built OpenOCD (`-s <build>/tcl`). The validated path is
`SOC=G2L` on 0.12.0 — RZ/G2L and RZ/V2L share the A55 DAP, CTI, and debug
bases (the config header documents the swap).

## Connect

```sh
# 1. Sanity scan (no halt):
openocd -f interface/ftdi/olimex-arm-usb-tiny-h.cfg -f docs/dev/jtag/rzv2l-scan.cfg
#    expect: r9a07g054l.cpu, IDCODE 0x6ba00477

# 2. Bring up the target + GDB server (leaves :3333 listening):
openocd -f docs/dev/jtag/rzv2l-openocd.cfg -c init -c "targets r9a07g044l.a55.0" -c halt

# 3. Attach gdb-multiarch (KASLR off → no offset):
VM=$(find build/tmp/work -path '*linux-renesas*standard-build/vmlinux' | head -1)
gdb-multiarch "$VM" -x docs/dev/jtag/rzv2l.gdb
(gdb) bt          # symbolized kernel backtrace
```

## Sustained halts

Holding a breakpoint or single-stepping for more than ~1 s wedges an SD/eMMC
rootfs (`renesas_sdhi` controller timeout — independent of the halted CPU).
Boot the JTAG image over **NFS-root** (`make dev JTAG=1 NETBOOT=1`, then
`run netboot`) so the rootfs survives sustained halts. Brief sub-second halts
(scan, register read, single backtrace) are fine on eMMC.

## lx-ps / lx-dmesg / lx-symbols

The JTAG build generates `scripts/gdb/linux/constants.py` (`oe_runmake
scripts_gdb`). Source the build-dir `vmlinux-gdb.py` after connecting:

```sh
find build/tmp/work -path '*standard-build/vmlinux-gdb.py'   # locate it
```
```
(gdb) source <that path>
(gdb) lx-ps
```
