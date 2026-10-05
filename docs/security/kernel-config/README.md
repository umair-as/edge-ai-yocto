# Kernel hardening evidence

Per board, the expanded kernel `.config` the **prod** build produces and the
set of [KSPP](https://kspp.github.io/) checks that
[kernel-hardening-checker](https://github.com/a13xp0p0v/kernel-hardening-checker)
reports as FAIL and this platform accepts, each with its reason. Together they
make the hardened-kernel claim checkable from the repository alone.

| File | Content | Produced by |
|---|---|---|
| `<board>-prod.config` | `${B}/.config` after `bitbake virtual/kernel -c configure` at `EDGE_PROFILE=prod` | `make kernel-config-export BOARD=<board>`, then copied here |
| `<board>-prod.baseline.json` | `accepted_failures`: option → reason | `scripts/ci/khc-gate.py --update`, reasons filled in by hand |

The prod tier is the one under claim: the dev tier adds debug fragments
(`EDGE_KERNEL_DEV_FRAGMENTS`) and is not what ships.

Checks:

- `.github/workflows/kernel-hardening.yml` (hosted, on every change to this
  directory or the gate) runs the checker on the committed `.config`; a FAIL
  outside the baseline, or a baseline entry without a reason, fails the job.
- The `khc` stage of the Yocto check (`make ci CI_ARGS=--khc`, or the `khc`
  input of the dispatched workflow — `docs/dev/ci.md`) re-derives the
  `.config` from the kas stack on the build host, runs the same gate, and fails
  if the committed `.config` differs from the build.

Refreshing after a kernel config change:

```bash
make kernel-config-export BOARD=rzv2l
cp build/khc/rzv2l-prod.config docs/security/kernel-config/
scripts/ci/khc-gate.py --config docs/security/kernel-config/rzv2l-prod.config \
    --baseline docs/security/kernel-config/rzv2l-prod.baseline.json --update
# fill in the reason of every new entry, drop entries reported as now passing
```

The checker needs the expanded `.config`; a `.cfg` fragment or a defconfig
carries no architecture or version and no materialised defaults. The on-device
run (`kernel-hardening-checker -a`, adding `/proc/cmdline` and sysctl) is the
release-checklist counterpart of this directory.

## What this gate is and is not

It is an assessment and snapshot gate: it runs on the committed evidence and,
on request, on a fresh export. It is not part of the kernel build; a kernel
configuration change reaches it when the snapshot is refreshed or the `khc`
stage runs. The mandatory settings a prod kernel must carry (module signature
enforcement, dm-verity, the LSM stack) are asserted independently by
`do_edge_kernel_policy_assert` in `edge-kernel-policy.inc` and are not subject
to this baseline.

The baseline exempts an option by name. It records that the option fails and
why, not the value it fails with, so a further weakening of an exempt option
passes the gate; the snapshot diff shows such a change, and refreshing the
snapshot clears it. The accepted-failure counts are the size of the exemption
list, not a vulnerability count and not a certification: entries are
recommendations that do not apply to this hardware, that conflict with required
functionality, or that are open hardening work, and each reason says which.
