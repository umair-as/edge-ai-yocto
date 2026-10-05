# Kernel hardening evidence

Per board, the expanded kernel `.config` the **prod** build produces, checked
against the [KSPP](https://kspp.github.io/) recommendations with
[kernel-hardening-checker](https://github.com/a13xp0p0v/kernel-hardening-checker).
The failures this platform accepts, each with its reason, are the board's
baseline in the BSP layer. Together they make the hardened-kernel claim
checkable from the repository alone.

| File | Content | Produced by |
|---|---|---|
| `<board>-prod.config` (here) | `${B}/.config` after `bitbake virtual/kernel -c configure` at `EDGE_PROFILE=prod` | `make kernel-config-export BOARD=<board>`, then copied here |
| `meta-edge-bsp/recipes-kernel/linux/files/khc/<board>-prod.baseline.json` | `accepted_failures`: option → reason; `tool_version` of the checker | `khc-gate.py --update`, reasons filled in by hand |
| `meta-edge-bsp/recipes-kernel/linux/files/khc/khc-gate.py` | the gate: fails on a failure outside the baseline, on a reason that is not a non-empty string, and on a checker version other than the recorded one | — |

The prod tier is the one under claim: the dev tier adds debug fragments
(`EDGE_KERNEL_DEV_FRAGMENTS`) and is not what ships.

## Where the gate runs

- **Every prod kernel build.** `do_edge_khc_gate` (`edge-kernel-policy.inc`,
  both kernel providers) runs the gate from `kernel-hardening-checker-native`
  on the resolved `.config` after `do_configure` and before `do_compile`. A
  failure stops the build. The gate script and the baseline enter the task
  signature by checksum, so a change to either re-runs the gate and the
  compile after it; an old stamp or sstate object cannot hide a policy change.
  The checker version is pinned in the distro
  (`PREFERRED_VERSION_kernel-hardening-checker-native`) to the version the
  baselines record. Dev kernels are not gated. The mandatory symbols a prod
  kernel must carry (module signature enforcement, dm-verity, the LSM stack)
  are asserted independently by `do_edge_kernel_policy_assert`; a baseline
  entry cannot waive them.
- **Hosted, on every change to this directory, the gate or a baseline**
  (`.github/workflows/kernel-hardening.yml`): the same gate on the committed
  snapshot, seconds, no build host.
- **`khc` stage of the Yocto check** (`make ci CI_ARGS=--khc`, or the `khc`
  input of the dispatched workflow — `docs/dev/ci.md`): re-derives the
  `.config` on the build host, runs the gate, and fails if the snapshot here
  differs from the build. Snapshot freshness and hardening policy are
  different checks: an unrelated config change stales the snapshot without
  violating policy.

## Refreshing after a kernel config change

```bash
make kernel-config-export BOARD=rzv2l
cp build/khc/rzv2l-prod.config docs/security/kernel-config/
meta-edge-bsp/recipes-kernel/linux/files/khc/khc-gate.py \
    --config docs/security/kernel-config/rzv2l-prod.config \
    --baseline meta-edge-bsp/recipes-kernel/linux/files/khc/rzv2l-prod.baseline.json --update
# fill in the reason of every new entry, drop entries reported as now passing
```

The checker needs the expanded `.config`; a `.cfg` fragment or a defconfig
carries no architecture or version and no materialised defaults. The on-device
run (`kernel-hardening-checker -a`, adding `/proc/cmdline` and sysctl) is the
release-checklist counterpart of this directory.

## What the baseline is and is not

The baseline exempts an option by name. It records that the option fails and
why, not the value it fails with, so a further weakening of an exempt option
passes the gate; the snapshot diff shows such a change, and refreshing the
snapshot clears it. Snapshot of 2026-10-05, checker 0.6.17.1: rzv2l 229
checks, 49 accepted failures; raspberrypi5 229 checks, 53 accepted failures.
The accepted-failure counts are the size of the exemption
list, not a vulnerability count and not a certification: entries are
recommendations that do not apply to this hardware, that conflict with required
functionality, or that are open hardening work, and each reason says which.
