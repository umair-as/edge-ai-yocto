# CVE-2024-12084: heap overflow in the rsync daemon (attacker-controlled
# s2length). Fixed upstream in 3.4.0 (CERT VU#952657); this recipe builds
# 3.4.1, but the NVD range data does not exclude 3.4.1 — cpe-incorrect is
# the accurate disposition (the range, not the shipped code, is wrong).
# The image ships no rsyncd service (no unit, nothing bound to TCP/873).
CVE_STATUS[CVE-2024-12084] = "cpe-incorrect: fixed upstream in 3.4.0, recipe builds 3.4.1; NVD range wrongly includes it"

# Daemon-mode CVEs: the image installs no rsyncd service or socket unit,
# and the packaged rsyncd.conf exports no modules (use chroot = yes,
# read only = yes); rsync runs only as client / server-over-ssh. The
# dispositions below hold only while that stays true — a daemon unit,
# an exported module, a replacement rsyncd.conf, or operating
# rsync --daemon with an alternate configuration invalidates them.
CVE_STATUS[CVE-2026-29518] = "not-applicable-config: requires daemon mode with use chroot = no; image provides no rsync daemon service or exported module"
CVE_STATUS[CVE-2026-43617] = "not-applicable-config: requires daemon chroot mode with hostname ACLs; image provides no rsync daemon service, exported module, or hostname ACL"
CVE_STATUS[CVE-2026-43619] = "not-applicable-config: requires daemon mode with use chroot = no; image provides no rsync daemon service or exported module"
