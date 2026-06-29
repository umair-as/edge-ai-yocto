# Source-level kernel debugging (JTAG / kgdb) on RZ/V2L

This note records how to run interactive kernel-debug and trace exercises on
the edge image: halting the SoC over JTAG, attaching `gdb-multiarch` to the
running kernel, and using `kgdb` over the serial console. It exists so anyone
can follow a kernel-debug lab on this board without re-discovering why the
hardened image fights an interactive debugger.

## Why a debug profile is needed

The production posture actively breaks interactive debugging, in four ways:

- **Runtime watchdog.** When systemd's runtime watchdog is armed and a core
  is halted at a JTAG breakpoint, PID 1 stops pinging `/dev/watchdog0` and
  the hardware resets the board out from under the session.
- **Lockup detectors.** Halting one Cortex-A55 core stalls its peer; on
  resume the soft-lockup / hung-task detectors fire and the SD/eMMC path
  wedges (I/O timeouts, soft-lockup spew).
- **Sysctl clamps.** `kptr_restrict`, `perf_event_paranoid`, `dmesg_restrict`
  hide the kernel pointers, perf counters, and `dmesg` a debugger needs;
  `sysrq` is off.
- **Kernel build.** KASLR randomises symbol addresses, and reduced/stripped
  DWARF makes source-level stepping and local-variable inspection unreliable.

The debug profile addresses these in two independent layers, both **off by
default** — the production configuration is never altered.

## Layer 1 — runtime debug mode (no rebuild)

`edge-debug-mode` flips the runtime hazards live and reversibly. This is
enough to **halt the board safely** and read kernel state on the stock
image; no kernel rebuild is required.

```sh
sudo edge-debug-mode on        # enter debug mode
sudo edge-debug-mode status    # show current state
sudo edge-debug-mode off       # restore the hardened baseline
```

What `on` changes (and `off` reverts):

| Setting | Baseline | Debug mode | Effect |
|---|---|---|---|
| systemd `RuntimeWatchdogSec` | (armed if enabled) | `0` | a halt cannot reset the board |
| `kernel.watchdog` | `1` | `0` | soft/hard-lockup detectors off |
| `kernel.hung_task_timeout_secs` | `120` | `0` | no hung-task panic/spew on resume |
| `kernel.kptr_restrict` | `2` | `0` | kernel pointers visible to the debugger |
| `kernel.perf_event_paranoid` | `3` | `-1` | unrestricted perf/tracing |
| `kernel.dmesg_restrict` | `1` | `0` | `dmesg` readable |
| `kernel.sysrq` | `0` | `1` | Magic SysRq enabled (incl. `g` → kgdb) |

The relaxations are written as drop-ins (`/etc/sysctl.d/99-edge-debug.conf`,
`/etc/systemd/system.conf.d/20-edge-debug-watchdog.conf`) **and** applied
live, so they survive a reboot until you run `off`. `off` removes the
drop-ins and reapplies the hardened baseline.

Optionally update the kernel command line for the next boot:

```sh
sudo edge-debug-mode on --bootargs    # adds: nokaslr maxcpus=1  (reboot to apply)
sudo edge-debug-mode off --bootargs   # strips them again
```

`maxcpus=1` boots a single core — the most reliable way to avoid the
SMP-halt rootfs-wedge described above. `nokaslr` is only meaningful on a
stock (KASLR-on) kernel; see Layer 2.

## Layer 2 — debug-profile image (build toggle)

For the easiest source-level experience, build the kernel with the debug
fragment via the `JTAG=1` make flag (a kas capability overlay that sets
`EDGE_ENABLE_JTAG_DEBUG`; a bare `EDGE_ENABLE_JTAG_DEBUG=1` shell var does **not**
reach bitbake through the kas wrapper):

```sh
make dev JTAG=1
```

This adds `jtag-debug.cfg` to the kernel and pre-places the Layer-1 drop-ins so
the image boots debug-safe. The fragment:

- turns **KASLR off** (`# CONFIG_RANDOMIZE_BASE is not set`) so runtime
  addresses match `vmlinux` symbols 1:1;
- emits un-reduced DWARF, frame pointers and `-Og` so single-stepping and
  locals behave (DWARF version left to the toolchain default; if the BTF
  toggle is also on, its DWARF4 is used);
- ships the in-tree GDB scripts (`lx-ps`, `lx-dmesg`, `lx-symbols`) and the
  complete symbol table (`KALLSYMS_ALL`);
- compiles the **lockup detectors out** entirely;
- builds in **`kgdb` / `kdb`** with the serial-console backend;
- enables Magic SysRq.

For on-target `-dbg` symbol packages (userspace backtraces; ≈3× rootfs,
optional) set `EDGE_DEV_DBG_PKGS = "1"` in `kas/local.yml`'s `local_conf_header`.

The kernel-config items above **cannot** be applied at runtime — they need
this build. The stock dev kernel can still be debugged "KASLR-correct" (read
the runtime KASLR offset and relocate symbols in the debugger); the debug
build just removes that step.

The `vmlinux` with symbols is the build artifact at:

```
build/tmp/work/<machine>/linux-renesas/<version>/build/vmlinux
```

Point the debugger at this file (it is never stripped, regardless of image
packaging).

## Walkthrough A — OpenOCD + gdb-multiarch over JTAG

Hardware: an Olimex ARM-USB-TINY-H on the carrier's 10-pin Cortex debug
header, with `SW1-1 = OFF` on the SMARC module (asserts `RZ_DEBUGEN`). The
ready-to-use OpenOCD/gdb configs live in `jtag/` — see `jtag/README.md` for
the full host setup. Summary:

1. **Enter debug mode** (Layer 1) so a halt cannot reset/wedge the board.
   Single-core is the calmest target:

   ```sh
   sudo edge-debug-mode on --bootargs && sudo reboot   # boots maxcpus=1
   ```

2. **Scan, then bring up the target.** A bare scan enumerates the ARM DAP
   (IDCODE `0x6ba00477`); the board config then starts a GDB server on `:3333`:

   ```sh
   openocd -f interface/ftdi/olimex-arm-usb-tiny-h.cfg -f docs/dev/jtag/rzv2l-scan.cfg
   openocd -f docs/dev/jtag/rzv2l-openocd.cfg -c init -c "targets r9a07g044l.a55.0" -c halt
   ```

3. **Attach.** The `jtag/rzv2l.gdb` init handles arch, source remapping, and
   `target extended-remote :3333` (KASLR off → no offset):

   ```sh
   VM=$(find build/tmp/work -path '*linux-renesas*standard-build/vmlinux' | head -1)
   gdb-multiarch "$VM" -x docs/dev/jtag/rzv2l.gdb
   (gdb) bt                 # source-level kernel backtrace, no offset
   ```

   For `lx-ps`/`lx-dmesg`, `source` the build-dir `vmlinux-gdb.py` (the JTAG
   build generates its `constants.py`) — see `jtag/README.md`. On a *stock*
   KASLR kernel you'd instead `add-symbol-file vmlinux -o <slide>` after reading
   runtime `_text`; the debug-profile kernel needs none of that.

**Two load-bearing gotchas** (both validated, both covered in `jtag/README.md`):
- **Breakpoints need the single-core config** (`jtag/rzv2l-core0.cfg`). The
  full SMP target mirrors the breakpoint to the unattached `a55.1` and the
  insert fails; declaring only `a55.0` lets `hbreak` land. Use the full
  `rzv2l-openocd.cfg` for scan/registers/backtrace, `rzv2l-core0.cfg` for
  breakpoints/stepping.
- **Sustained halts wedge an eMMC rootfs** (`renesas_sdhi` timeout). Either pin
  the eMMC IRQ to the still-running `a55.1` (`echo 2 > /proc/irq/<N>/smp_affinity`
  — validated to zero timeouts over a 25 s halt) or boot NFS-root (`NETBOOT=1`).
  Brief sub-second halts on eMMC are fine.

When finished, exit debug mode:

```sh
sudo edge-debug-mode off --bootargs && sudo reboot
```

## Walkthrough B — kgdb over the serial console

`kgdb` is built into the debug-profile kernel; on the stock kernel enable it
at runtime via the boot args. It shares the primary serial console
(`ttySC0`, 115200).

1. Tell the kernel which port carries kgdb. For the next boot:

   ```sh
   sudo fw_setenv EXTRA_KERNEL_ARGS "$(fw_printenv -n EXTRA_KERNEL_ARGS) kgdboc=ttySC0,115200"
   sudo reboot
   ```

   Add `kgdbwait` to break at boot before the console comes up.

2. Drop into the debugger. With Magic SysRq enabled (`edge-debug-mode on`):

   ```sh
   echo g | sudo tee /proc/sysrq-trigger      # enter kgdb/kdb
   ```

3. From a second host on the same serial line, attach `gdb-multiarch` to the
   port and `target remote /dev/ttyUSB0`, then `bt` / `continue`.

Because kgdb and the login console share `ttySC0`, the console is
unavailable while the debugger is attached.

## Other debug facilities already present

The dev image already ships the tracing/profiling surface (ftrace, kprobes,
uprobes, perf, eBPF, LTTng) via the observability kernel fragment and the dev
tool buckets, plus `bpftool`. `edge-debug-mode on` lifts the
`perf_event_paranoid` and `kptr_restrict` clamps those tools need. No separate
step is required for ftrace/perf/eBPF labs beyond entering debug mode.

**BTF / CO-RE.** Gated by its own toggle, **off by default** — kernel BTF
needs un-reduced DWARF and embeds per-module `.BTF` in `/lib/modules`, which
grows the image and OTA bundle noticeably. Enable it only for libbpf/CO-RE
labs, independently of JTAG:

```sh
make dev BPF=1                          # adds kernel BTF + bpftool
```

Then confirm after boot:

```sh
ls -l /sys/kernel/btf/vmlinux
bpftool btf dump file /sys/kernel/btf/vmlinux format c | head
bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h   # for libbpf
```

This cannot be enabled at runtime. Keep it off for DRP-AI/edge-AI builds.

## Toggle summary

The debug capabilities are independent build flags, all off by default, so a
plain `make dev` stays lean. They compose: `make dev JTAG=1 BPF=1`.

| Flag | Sets | Enables | OTA size impact |
|---|---|---|---|
| `JTAG=1` | `EDGE_ENABLE_JTAG_DEBUG` | KASLR off, un-reduced DWARF, `-Og`, kgdb, lockup detectors out; boots debug-safe | low — debug DWARF stays in the build-tree `vmlinux`, stripped from the image |
| `BPF=1` | `EDGE_ENABLE_BTF_CORE_DEV` | kernel BTF (`/sys/kernel/btf/vmlinux`) + `bpftool` | **high** — module BTF ships in `/lib/modules` |
| `EDGE_DEV_DBG_PKGS = "1"` (local.yml) | — | on-target `-dbg` symbol packages | **high** — ≈3× rootfs |

The `JTAG=1`/`BPF=1` flags are kas capability overlays (`kas/jtag-debug.yml`,
`kas/bpf-labs.yml`) that inject the toggle into `local.conf`. A bare
`EDGE_ENABLE_*=1` shell variable does not survive the kas/bitbake env filter.

Runtime debug mode (`edge-debug-mode on`) is orthogonal and needs no rebuild.

## Safety and reverting

- `edge-debug-mode off` is always the clean exit; a plain reboot does **not**
  revert (the drop-ins persist by design) — run `off` to re-harden.
- Debug mode lowers the security posture (visible kernel pointers, SysRq,
  unrestricted perf). Use it only on a bench/dev board, never a fielded unit.
- SELinux is permissive on the dev EVK, so the script's `/etc` writes and
  `fw_setenv` only log AVCs. Under enforcing, the env-write and
  daemon-reexec paths would need policy.
