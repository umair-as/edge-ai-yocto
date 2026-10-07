# CVE-2024-12084: heap overflow in the rsync daemon (attacker-controlled
# s2length). Fixed upstream in 3.4.0 (CERT VU#952657); this recipe builds
# 3.4.1, but the NVD range data does not exclude 3.4.1 — cpe-incorrect is
# the accurate disposition (the range, not the shipped code, is wrong).
# The image ships no rsyncd service (no unit, nothing bound to TCP/873).
CVE_STATUS[CVE-2024-12084] = "cpe-incorrect: fixed upstream in 3.4.0, recipe builds 3.4.1; NVD range wrongly includes it"

# Daemon-mode CVEs: not reachable, not suppressed. The image installs no
# rsyncd service or socket unit and the packaged rsyncd.conf exports no
# modules (use chroot = yes, read only = yes), but the daemon code is in
# the shipped binary, so these stay Unpatched at the lowest priority.
# Trigger: a daemon unit, an exported module, a replacement rsyncd.conf,
# or operating rsync --daemon with an alternate configuration.
CVE_STATUS[CVE-2026-29518] = "vulnerable-investigating: not reachable - requires daemon mode with use chroot = no; image provides no rsync daemon service or exported module"
CVE_STATUS[CVE-2026-43617] = "vulnerable-investigating: not reachable - requires daemon chroot mode with hostname ACLs; image provides no rsync daemon service, exported module, or hostname ACL"
CVE_STATUS[CVE-2026-43619] = "vulnerable-investigating: not reachable - requires daemon mode with use chroot = no; image provides no rsync daemon service or exported module"
