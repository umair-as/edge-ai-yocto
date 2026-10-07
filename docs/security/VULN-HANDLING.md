# Vulnerability handling

How a CVE finding is assessed, fixed, verified and recorded for an image built from this
repository. The decisions behind this process are in
[ADR-0013](../adr/0013-vulnerability-handling-cadence-and-release-gate.md). The scanner
pipeline is in [`vuln-mgmt-architecture.md`](vuln-mgmt-architecture.md), and the
`CVE_STATUS` vocabulary and its rules are in [`cve-triage.md`](cve-triage.md).

This is a reference implementation with one maintainer. The process gives no response-time
commitment and does not cover report intake or coordinated disclosure.

## 1. Terms

Each term has one meaning in this document.

| Term | Meaning |
|---|---|
| **Finding** | One scanner result: one CVE for one component in one image. |
| **Applicable** | The vulnerable code is in the image as built. |
| **Reachable** | An attacker of a named class can make the vulnerable code run with data that the attacker controls, on this image, in its shipped configuration. Section 3 defines the procedure. |
| **Attacker class** | The position and privilege of the attacker. Section 3.3 lists the classes. |
| **Exploited** | There is credible evidence of exploitation in the wild, for example an entry in the CISA KEV catalogue or the "exploited" flag in the ENISA EU Vulnerability Database. An entry in a database without that flag is not this evidence. |
| **Fixed** | The upstream fix, or an equivalent change, is in the source that was built. This is a state of the finding for one image. Whether a device is protected is a separate question (section 8.4). |
| **Mitigated** | The finding is applicable, and a control in the image reduces the risk. The finding stays open. |
| **Accepted** | The finding is applicable and unfixed, and the maintainer decided to ship it. The finding stays open. |
| **Not affected** | Build-time evidence shows that the finding cannot apply to this image: the component or the vulnerable code is not in the build (section 3, steps 1 and 2). |
| **Not reachable** | The vulnerable code is in the image, but no attacker class in scope can run it or control its input (section 3, steps 3 and 4). The finding stays open with the lowest priority. |
| **Under investigation** | No state yet. The finding has a review date and counts as open. |

Not reachable, mitigated, accepted and under-investigation findings are never reported as not
affected. They stay visible as open in every report.

### 1.1 Where the component lives

A Yocto build produces more than the root filesystem. Each finding is labelled with the
place where its component lives, because each place has a different risk and check.

| Location | Examples | Risk | Handling |
|---|---|---|---|
| **Installed** in the root filesystem | openssl, glibc, expat, the kernel and its modules | Runtime exposure on the device | Image scan and the reachability ladder. The kernel has its own method: [`kernel-cve-triage.md`](kernel-cve-triage.md). |
| **Deployed**, not installed | bootloader, trusted firmware, secure OS | Runtime exposure, often before the operating system starts | Same ladder. These components are scanned separately from the image report. |
| **Embedded** in another binary | Go modules, Rust crates, static libraries | Runtime exposure that is not visible as its own recipe | Language-level dependency lists (`go.mod`, `Cargo.lock`) and a rootfs scan for vendored copies |
| **Build-only**: `-native`, `-cross` | compilers, code generators, signing and image tools | No exposure on the device. Risk to build integrity and to the artifacts that the tool makes | Pinned sources and checksums, trusted shared state. Triage only the tools that make shipped artifacts or read untrusted input. |
| **SDK**: `nativesdk-` | the cross-development SDK | Exposure for whoever receives the SDK | A separate product, if the SDK is distributed |

The image tier also sets the scope. A package that only the development image contains
(for example binutils or a debugger) is exposure on development images only. A build-only
finding is not ignored: a defect in a compiler or in a signing tool can reach the shipped
artifact.

## 2. Principles

1. **The total CVE count is not the goal.** A wrong suppression also makes the count go
   down. Measure states and evidence, not totals.
2. **A "Patched" label from the scanner is not proof.** A fix is complete only when this
   chain is true: upstream fix → correct change in the resolved source → built artifact →
   tested release → installed device. A successful `do_patch` proves only the second step.
3. **Investigation, remediation and release are three decisions.** Investigation: how
   fast must the finding be understood? Remediation: how long may the exposure stay?
   Release: may this artifact ship? A planned fix date is not evidence that an image is
   safe.
4. **Every state is scoped to one configuration.** A state for one board, image tier and
   set of build flags does not apply to another. For example, NFS is off in the normal
   kernel and on in the netboot development kernel.

## 3. Reachability

### 3.1 Why each user decides

The Linux kernel CVE team assigns a CVE to almost every bug fix. Its process document
says:

> "the CVE assignment team is overly cautious and assign CVE numbers to any bugfix that
> they identify."
>
> "the applicability of any specific CVE is up to the user of Linux to determine, it is
> not up to the CVE assignment team."
>
> — `Documentation/process/cve.rst`, Linux kernel source tree

A CVSS score describes the worst reasonable deployment, not this image. Many kernel
networking CVEs score 9.8 but need a feature that this image does not use. Each finding
therefore needs a reachability decision for this image.

### 3.2 The reachability ladder

![Reachability ladder: four questions in order, each with its evidence; "no" leads to not affected with a VEX justification; "unknown" leads to under investigation unless a later step gives "no"; the "yes" chain ends at reachable, which is affected; a control in the image is recorded as a mitigation and the finding stays affected](diagrams/cve-reachability-ladder.svg)

Ask the questions in this order. A "no" with evidence ends the ladder. Only steps 1 and 2
give "not affected". Steps 3 and 4 give "not reachable": the finding stays open with the
lowest priority. The justification names follow the CISA VEX status justifications.

| Step | Question | If "no" | Evidence for "no" |
|---|---|---|---|
| 1 | Is the component in the image? | Not affected: `component_not_present` | SBOM and image manifest, **plus** the language-level dependency lists and a scan for vendored copies (section 1.1) |
| 2 | Is the vulnerable code in the binary? | Not affected: `vulnerable_code_not_present` | The config symbol is off in the built `.config`; the vulnerable function is inside an `#ifdef` that is off; the object is not in the build |
| 3 | Can the vulnerable code run on this image? | Not reachable (`vulnerable_code_not_in_execute_path` as evidence, not as a suppression) | No hardware for the driver; the feature is off **and** no attacker class in scope can turn it on |
| 4 | Can the attacker control the input to that code? | Not reachable (`vulnerable_code_cannot_be_controlled_by_adversary` as evidence) | The code path takes data only from a trusted source, for every attacker class in scope |

Rules:

- **Unknown is an answer.** If a step has no evidence either way, go to the next step. If a
  later step gives "no" with evidence, that step decides the state. If no later step gives
  "no", the finding is under investigation.
- **Steps 3 and 4 are answered for each attacker class in scope** (section 3.3). Not
  reachable needs "no" for every class. A "no" for a remote attacker alone is not enough
  when a local user or a container can reach the code.
- **An absent introducing commit is supporting evidence only.** Vendor trees often carry a
  vulnerable change as a backport or a squashed commit with a different ID. The upstream
  ID can be absent while the vulnerable code is present. Confirm in the source or in the
  built objects.
- **Runtime evidence never suppresses.** A "no" at step 3 or 4 rests on a runtime property
  that can change after release: a service that is not installed today, a sysctl, a
  missing device. The finding stays open. Its record names the image property that the
  claim rests on and a trigger that can be checked by machine (section 10).
- A finding is **reachable** for an attacker class when steps 1 to 4 are all "yes" for that
  class. A reachable finding is affected.
- **Mitigation comes after the ladder.** If a control in the image (a hardening option, a
  policy, isolation) reduces the risk of a reachable finding, record it as a mitigation.
  The finding stays affected and keeps its priority (section 5). A mitigation never makes
  a finding not affected or not reachable.

### 3.3 Attacker classes

The classes follow CVSS v3.1 "Attack Vector" and "Privileges Required".

| Attacker class | CVSS equivalent | Example on this platform |
|---|---|---|
| Remote unauthenticated | AV:N, PR:N | Packets to the board's IPv4 or global IPv6 address |
| Adjacent network | AV:A, PR:N | Multicast, IPv6 neighbour discovery, DHCP options on the same link |
| Local unprivileged user, user namespace | AV:L, PR:L | `unshare -Urn`, then create a tunnel or enable a sysctl in the new namespace |
| Container workload | AV:L, PR:L | Code that runs in a rootless container |
| Physical | AV:P | Serial console, USB ports, SD card |
| Root | AV:L, PR:H | Load a BPF program, attach XDP |

Classes in scope: remote, adjacent, container workload and physical apply to every image
tier. Local unprivileged user applies to every image that has interactive non-root
accounts. The finding record names the classes that were assessed.

Root is a special case. With root in scope, step 4 is nearly always "yes". A finding that
only root can reach gets a low priority (section 5). It is not a route to not affected.

### 3.4 Rules for evidence

- **Use the strongest evidence.** Build-time evidence (step 2) is stronger than runtime
  evidence (step 3). Where possible, remove unused code with a config change instead of a
  runtime gate.
- **A file-level check is not enough.** A file can be compiled while the vulnerable
  function in it is not. Check the function.
- **A runtime gate counts only if no attacker class in scope can change it.** A sysctl that
  is off by default is not a gate against a user who can turn it on in a new network
  namespace.
- **Test claims on the target.** The board is the source of truth for hardware, loaded
  drivers, sysctls, setuid files and listening services. The defconfig is not. In a
  BitBake root filesystem on disk, file modes and owners come from the pseudo database, so
  setuid bits are read on the board.
- **Read the precondition from the CVE record or the advisory.** The Linux kernel CNA gives
  a CVSS rationale for each metric for many records. Its attack-vector (AV) and
  privileges-required (PR) notes name the precondition, for example "on an IOAM-enabled
  interface". For other components, use the advisory text.
- **Read version ranges exactly.** In a CVE JSON 5 record, `lessThan: X` means that X is
  outside the range: X is fixed. `lessThanOrEqual: X` means that X is the greatest affected
  version: X is still affected. An inclusive bound at the newest release names no fixed
  version. A version update is a fix only if it reaches a `lessThan` boundary on the branch
  that the image uses.
- **A CVE ID in a commit message is a claim; its absence proves nothing.** Fix commits can
  omit the CVE ID, and patches can carry the wrong one. Confirm the fix commit in the
  source, and compare the patch with the fix that the CVE record or the upstream advisory
  names.

## 4. Recording the state

States are recorded as `CVE_STATUS` keywords. The rules for authoring them are in
[`cve-triage.md`](cve-triage.md#disposition-policy). The export to VEX is described in
[`vex-and-cve-status.md`](vex-and-cve-status.md).

| State | `CVE_STATUS` keyword | Report status | Exported VEX justification |
|---|---|---|---|
| Fixed | `backported-patch`, `fixed-version`, `cpe-stable-backport` (or detected automatically) | Patched | — |
| Not affected, step 1 | `cpe-incorrect`, `not-applicable-platform` | Ignored | none, or `vulnerableCodeNotPresent` |
| Not affected, step 2 | `not-applicable-config` | Ignored | `vulnerableCodeNotPresent` |
| Not reachable (steps 3 and 4), mitigated, accepted, under investigation | `vulnerable-investigating` | Unpatched | — |

`not-applicable-config` is used only for build-time evidence (step 2): the feature is
compiled out or the object is not built. Its exported justification,
`vulnerableCodeNotPresent`, is then true. A runtime claim is never recorded as
`not-applicable-config`, because the exported justification would state that the code is
absent when it is present, and because the runtime property can change after release. The
free-text reason on each `CVE_STATUS` line names the ladder step and the evidence.

## 5. Priority

Priority comes from three inputs: exploitation evidence, attacker class, and impact.

| Condition | Response |
|---|---|
| Exploited, and the image is affected or possibly affected | First priority when found. Contain the exposure on boards that run the image. Continue the investigation. |
| Reachable by a remote, adjacent or physical attacker, high impact | Before feature work. Fix it, or confirm that containment is in place before the image runs on a network-connected board. |
| Reachable by a local user or a container, high impact (privilege escalation, escape) | As the previous row when the image runs untrusted containers or has untrusted local users. Otherwise, batch into the next maintenance release. |
| Reachable by root only | Low. Record it. |
| Not reachable (steps 3 and 4) | Lowest. Record the image property and the trigger. Check the trigger at each milestone. |
| Applicable, other | Assign a next action and a review date. Batch suitable fixes. |
| Not affected | Record the evidence and the condition that would make it invalid. |

A prepared fix does not lower the priority of a finding on a running device. Until the
fixed image is installed, an exploited finding stays first priority for that device, and
its containment stays in place.

Record the time from discovery to assessment, to verified mitigation, and to installed fix.
These times describe the process. They are not commitments. If a planned date slips,
record the reason, the current exposure and the next action. Keep the original discovery
date.

## 6. Monitor and release

The two loops and the reasons for them are in
[ADR-0013](../adr/0013-vulnerability-handling-cadence-and-release-gate.md).

- **Monitor** scans the SBOM of the image that is installed on a board, and of the newest
  hardware-validated image, against the current CVE feeds. There is no build. The feed
  revisions of each scan are recorded, so the scan can be repeated
  ([`vuln-mgmt-architecture.md`](vuln-mgmt-architecture.md), D7). The tooling is
  `scripts/cve-monitor.py` (`make cve-monitor`): it rescans, diffs against the release
  report and writes the worklist.
- **Exploitation review** is a separate manual step after each monitor scan. The open
  findings of both images are checked against the exploitation signals (CISA KEV, EUVD
  exploited flag), and the date of the signal snapshot is recorded. The check covers every
  open finding, not only the new ones: a finding can become exploited while its scanner
  status stays the same, and such a finding does not appear in the monitor diff.
- **Release** changes, builds, compares, passes the release gate (section 9), and installs.

The monitor runs weekly while the project is active, at the start of each security work
session, and before a release. Releases happen at validated milestones. Vendor, kernel and
layer pins and the carried backports are reviewed at each milestone.

The date of the last scan is recorded. An old scan is not current: when work starts again
after a break, the images are scanned again before an old assessment is reused.

## 7. Choosing a fix

### 7.1 Options

1. **Update a pin.** Move to a newer vendor branch, stable release or layer revision that
   already contains the fix.
2. **Backport.** Carry the upstream fix as a patch on the current pin.
3. **Remove the feature.** Turn off the code with a configuration change, when the image
   does not need it.
4. **Mitigate.** Add a control that reduces the risk. The finding stays open.

### 7.2 Decision rule

- First check whether the vendor branch or the layer already has the fix and its follow-up
  fixes.
- Backport when the fix is urgent, small, and its dependencies are understood.
- Update the pin when the fix needs many prerequisites or an adaptation, or when the
  number of carried backports grows. The kernel process document gives the same advice:

  > "it is best to take all released kernel changes, as they are tested together in a
  > unified whole by many community members, and not as individual cherry-picked
  > changes."

- Remove the feature when it is not used and the removal is a deliberate product decision.
  Prove the effect of the change (section 8.2) and test on hardware.
- A backport is debt. It is checked again, and usually dropped, at the next pin update.

### 7.3 Checks before a backport

"The patch applies" is necessary but not sufficient.

1. **Prerequisites.** If a hunk does not apply, find the reason. If the missing context is
   only formatting or annotations, adapt the patch. If the fix depends on code that is not
   in the tree (for example a locking section), the missing code is a prerequisite.
2. **Introducer check.** A commit that you take can be the introducing commit of another
   CVE. The Linux kernel CNA publishes `introduced:fixed` commit pairs for each CVE
   (`.dyad` files in `vulns.git`). Look up each commit that you take on both sides of the
   pair. If a commit introduces a CVE, take its follow-up fix with it.
3. **Follow-up fixes and reverts.** Check the stable branch for later fixes or reverts of
   the commit.
4. **Adapted patches keep the same change.** Compare the added and removed lines of the
   adapted patch with the upstream fix (an interdiff). Only context may differ.
5. **Merge commits.** A CVE record can cite a merge commit. Backport the content commit and
   name the merge in the header.
6. **Header.** Keep the upstream header and its `Signed-off-by:` chain unchanged. Add only
   the `Upstream-Status: Backport […]` line, which names the upstream commit or release.
   Take commit IDs from `git rev-parse`. Do not type them.

## 8. Verifying a change

### 8.1 Scanner inputs

Before a comparison, confirm that the scan used the recorded CVE database revisions.
sbom-cve-check before 1.3.4 resets its deployed database to the newest revision, whatever
revision is configured. Compare `HEAD` of each database with the recorded revision, and
keep the scanner's reproducibility output with the report.

### 8.2 Controlled comparisons

Change one variable at a time. Use the same scanner and rules for each comparison.

| Comparison | What it measures |
|---|---|
| Previous image, previous feeds → previous image, current feeds | Newly disclosed or reclassified findings |
| Previous image, current feeds → candidate image, current feeds | The effect of the changes to the image |
| Candidate source and test evidence → candidate report | Whether each claimed fix is real |

A scanner upgrade is one more variable, measured separately.

Changes in both directions need an explanation. A finding that disappears, or that changes
to Ignored or Patched, is examined like a new finding. A wrong suppression makes the total
better and the evidence worse.

For a configuration change, compare the resolved configurations before and after. For the
kernel: `olddefconfig` with the build's cross-compiler, then `scripts/diffconfig`. Explain
every line of the difference, including symbols that drop as dependencies.

### 8.3 Archive for each release

Artifact hashes, SBOM, source and layer pins, patches, resolved kernel configuration,
scanner version, CVE database revisions, states, and test results.

### 8.4 Fix, release, device

"Fix available", "release available" and "device updated" are three states. A fixed image
does not protect a device that still runs an older image. The monitor loop scans what is
installed, not only what is built.

## 9. Release gate

A release is a **source checkpoint** (built and scanned) or a **validated image** (also
tested on hardware). The release says which one it is. Neither is a claim of production
readiness.

A validated image ships when all of these are true:

1. Each fixed or not-affected state has evidence for this image and configuration.
2. No exploited, reachable finding is open in the image, unless the affected function is
   disabled or removed in that image. Such a finding cannot ship as accepted.
3. Each reachable high-impact finding has an explicit state.
4. Each finding in the assessed scope has one state: fixed, not affected, not reachable,
   mitigated, accepted, or under investigation.
5. Overdue investigations and expired assumptions have been reassessed.
6. The comparisons in section 8.2 show no unexplained change in either direction.
7. The scan used the recorded database revisions (section 8.1).
8. Each finding is labelled with where its component lives (section 1.1) and with the image
   tiers that ship it.
9. The required hardware tests passed.

An older backlog does not block a source checkpoint. The checkpoint states the assessed
scope and the open unknowns. Full evidence is required for the changed findings and their
delta. The rest of the backlog is tracked separately.

An available upstream patch does not close a finding. A missing upstream patch does not
remove the exposure.

## 10. Record for each finding

For each finding that is not closed automatically:

- Affected image, configuration and source identity.
- Location (section 1.1) and image tiers.
- Evidence for each ladder step, and the attacker classes assessed.
- Exploitation evidence and its source.
- Priority and the reason for it.
- Upstream fix, prerequisites, and any CVE that the fix introduces.
- Chosen action, owner and dates.
- Verification evidence.
- The condition that would make the state invalid. For a not-reachable finding: the image
  property that the claim rests on and a trigger that can be checked by machine (for
  example: a unit file is installed, a config symbol changes, a sysctl default changes).

Unknowns stay recorded as unknowns.

## 11. Metrics

- Open findings by priority and attacker class.
- Age of open findings.
- Time to verified mitigation and time to installed fix.
- Expired states.
- Number of carried backports.
- Unexplained changes between reports.

The total CVE count is context. It is not an acceptance criterion.

## 12. Limitations

- The image CVE report does not cover deployed boot-chain components; they need a separate
  scan.
- Kernel "not compiled" suppressions whose program files include headers are not accepted
  as not affected without a check for each CVE
  ([`kernel-cve-triage.md`](kernel-cve-triage.md)).
- The process has no response-time commitment, no report intake and no coordinated
  disclosure procedure ([`CRA-CONTROLS.md`](CRA-CONTROLS.md), Part II).

## References

- Linux kernel CVE process: `Documentation/process/cve.rst` in the kernel source tree.
- Linux kernel CNA data: <https://git.kernel.org/pub/scm/linux/security/vulns.git>
- CISA, Vulnerability Exploitability eXchange (VEX) — Status Justifications (June 2022):
  <https://www.cisa.gov/sites/default/files/publications/VEX_Status_Justification_Jun22.pdf>
- OpenVEX specification: <https://github.com/openvex/spec>
- FIRST, CVSS v3.1 specification: <https://www.first.org/cvss/v3.1/specification-document>
- CVE JSON 5 record format: <https://github.com/CVEProject/cve-schema>
- CISA Known Exploited Vulnerabilities catalogue:
  <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>
- ENISA EU Vulnerability Database: <https://euvd.enisa.europa.eu>
