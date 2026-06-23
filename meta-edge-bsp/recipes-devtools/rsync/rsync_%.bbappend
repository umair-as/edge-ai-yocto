# CVE-2024-12084: heap overflow in the rsync daemon (attacker-controlled
# s2length). Present in rsync <= 3.3.0; fixed upstream in 3.4.0
# (CERT VU#952657, oss-security 2025-01-14). This recipe builds 3.4.1,
# which carries the fix. Independently, the image ships no rsyncd service
# (no unit, not running, nothing bound to TCP/873), so the daemon-only
# vulnerable path is unreachable.
CVE_STATUS[CVE-2024-12084] = "fixed-version: fixed upstream in rsync 3.4.0, recipe builds 3.4.1"
