# Board serial console runbook

One tool drives every board console: `scripts/dev/serial-console-tee.py`. It owns
the port, so a person can `tail -f` the log while a script types. Board facts
(stop string, prompts, markers, eMMC hardware-partition numbers, adapter match)
live in that file (`serial-console-tee.py profiles`); other scripts call the tool
instead of re-encoding them.

## Session

```bash
T=scripts/dev/serial-console-tee.py; L=console.log
setsid nohup $T serve --board rzv2l --log $L >/dev/null 2>&1 &   # or --port /dev/serial/by-id/<adapter>
$T status --log $L
```

`serve` refuses a port that another process holds (`tio`, an MCP serial session,
`serial-boot-capture.py`); close those first. The input FIFO `<log>.in` is
write-only: do not `cat`, `wc` or `tail` it, and glob logs by `*.log`.

## Procedures

| Goal | Command |
|---|---|
| Reboot and read the boot | `off=$($T offset --log $L)`, trigger the reboot, `$T wait-boot --log $L --since $off` |
| Stop at the U-Boot prompt | start `$T stop-autoboot --log $L` before the board powers up |
| U-Boot commands | `$T uboot --log $L 'mmc dev 0 boot1' 'mmc info'` |
| Console address of the board | `$T ip --log $L` (console logged in) |
| Free-form input | `$T send --log $L --expect 'RE' 'text'` |

- `wait-boot` prints `boot-source:`, the BL2, U-Boot, `[EDGE]` and FIT-verify
  lines, and exits 0 on a login prompt, 1 on timeout, 3 on a kernel panic or FIT
  hash failure. `--until autoboot|uboot` stops at an earlier stage.
- `stop-autoboot` types the string the countdown line names (`Type '<s>' within
  N seconds to stop autoboot`; a space only for a `Hit any key` prompt), and
  exits 3 when the board booted past U-Boot. It waits up to 15 minutes, so it
  can be started before a physical power-up.
- With a person at the switches the order is: switches set with power off,
  `stop-autoboot` started, then power on. Started after power-on it misses the
  3-second countdown (the USB-serial adapter enumerates about 3 s after power
  is applied on the RZ/V2L).
- `uboot` refuses commands that write, erase or reconfigure storage or the
  environment (`mmc write|erase|partconf|bootpart`, `sf write|erase|update`,
  `env save|erase`, `ums`, `dfu`, …), including after a `;`, unless
  `--allow-destructive` is given. `mmc dev 0 user|boot0|boot1` is translated to
  `mmc dev 0 0|1|2`: U-Boot hardware partition 1 is `boot0`, 2 is `boot1`.
- The board address changes with the install; `ip` reads the current one.

## Limits

- The USB-serial adapter is powered by the board. On a power cycle it
  re-enumerates a few seconds after power-on and the BL2/TF-A banner of that
  boot never reaches the log (`wait-boot` warns). Soft reboots keep the banner.
  After a power cycle, prove the boot chain from U-Boot-and-later markers
  (`[EDGE] UBOOT boot-source=`, `/proc/device-tree/chosen/edge,boot-source`) or
  EXT_CSD `PARTITION_CONFIG`, not from BL2.
- The RZ/V2L has no power control: power-ups and SW11 changes are manual.
- Boot source on the RZ/V2L follows SW11 (`docs/dev/bootchain/rzv2l.md`).
