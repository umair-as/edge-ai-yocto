# RZ/V2L JTAG host enablement (OpenOCD + gdb-multiarch)

Host-side config to attach a debugger to the RZ/V2L SMARC board over JTAG.
Pairs with the debug-profile kernel (`make dev JTAG=1`, KASLR off + kgdb +
gdb scripts) — see `../jtag-kernel-debugging.md` for the kernel side and the
sustained-halt caveat (use NFS-root for breakpoints; see `../netboot-setup.md`).

## Files

| File | Purpose |
|---|---|
| `rzv2l-openocd.cfg` | Full SMP target (A55×2 + M33 + AXI), GDB servers `:3333`/`:3334`. Use for scan / registers / memory / backtrace |
| `rzv2l-core0.cfg` | **Single-core (a55.0 only)** — required for **breakpoints / single-step** (see below) |
| `rzv2l-scan.cfg` | Passive scan-chain check — reads the DAP IDCODE, no halt/reset |
| `rzv2l.gdb` | gdb-multiarch init for the KASLR-off debug kernel (no offset) |

## Which config — breakpoints need single-core

The stock Renesas RZ target groups both A55s in a `target smp` group. OpenOCD
then mirrors every breakpoint to **all** members, including the unattached
(`defer-examine`) `a55.1` — the insert fails with *"can't add breakpoint:
resource not available"* and the breakpoint dies. So:

- **`rzv2l-openocd.cfg`** (full SMP) — scan, register/CPSR read, memory read,
  backtrace, single-step on the boot core.
- **`rzv2l-core0.cfg`** (a55.0 only, no SMP group) — **hardware breakpoints**.
  Validated: `hbreak ksys_sync` → on the target `taskset -c 0 sync` (pin the
  syscall to the attached core) → fires with the full EL0 syscall backtrace.

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

Holding a breakpoint or single-stepping wedges an SD/eMMC rootfs after ~5 s
(`renesas_sdhi` controller timeout — independent of the halted CPU). Brief
sub-second halts (scan, register read, single backtrace) are fine on eMMC. For
sustained halts, two validated options:

- **Pin the eMMC IRQ to the still-running `a55.1`** (lighter; works with
  `rzv2l-core0.cfg`, which leaves a55.1 running Linux). Before halting a55.0:
  ```sh
  grep mmc /proc/interrupts                 # find the SDHI IRQ number N
  echo 2 | sudo tee /proc/irq/N/smp_affinity   # 2 = CPU mask for core 1
  ```
  Validated: a 25 s halt under active eMMC writes then produced zero timeouts.
- **NFS-root** (`make dev JTAG=1 NETBOOT=1`, then `run netboot`) — rootfs off
  eMMC entirely. Most robust for long sessions or when the IRQ can't be repinned.
  See `../netboot-setup.md`.

Note: a multi-second whole-system halt makes services with their own
`WatchdogSec=` miss their ping; systemd restarts them on resume. Harmless, but
expect a few service restarts after a long halt. (`edge-debug-mode` disables the
*hardware* runtime watchdog, not per-service software watchdogs.)

## Halt strategy: maxcpus=1 vs SMP Linux

Two ways to run the board under JTAG, with different trade-offs (both HW-validated):

**`maxcpus=1` (single Linux core) + `rzv2l-core0.cfg`** — `edge-debug-mode on
--bootargs` sets `maxcpus=1`. Cleanest for backtrace / single-step / breakpoints:
- No peer core, so a BPF/ftrace text-poke cannot deadlock. On a BPF-enabled
  image, halting one core of an *SMP* kernel hangs the running core the moment
  it frees a JIT'd program — `kick_all_cpus_sync` IPIs the halted core and never
  returns (`rcu_preempt detected stalls` / `smp_call_function_many_cond`).
  `maxcpus=1` removes the peer entirely. (IRQ-affinity does **not** help here —
  the IPI targets all CPUs regardless.)
- Use `rzv2l-core0.cfg` (declares only `a55.0`). The full-SMP `rzv2l-openocd.cfg`
  keeps polling the parked `a55.1` and spams `abort occurred - dscr=...`.
- A halt freezes the **whole board, serial console included** — there is no other
  core to run it. This is expected; the console wakes the instant you resume.
  Drive everything from gdb: `continue` (Ctrl-C to re-halt) or `detach` to free it.
- Sustained halts still wedge the eMMC (the lone core can't service the SDHI IRQ
  while halted) — NFS-root for long held breakpoints.

**SMP Linux (both cores) + `rzv2l-core0.cfg` + eMMC IRQ pinned to `a55.1`** —
keeps the console and a peer core live while `a55.0` is halted, and the IRQ pin
lets sustained halts run without wedging eMMC. The cost: a text-poke on `a55.1`
(BPF free, ftrace toggle) can RCU-stall against the halted `a55.0` as above.

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
