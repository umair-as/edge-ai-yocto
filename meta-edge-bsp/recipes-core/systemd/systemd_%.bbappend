# pstore PACKAGECONFIG enables systemd-pstore.service, which on boot
# archives kernel pstore records from /sys/fs/pstore/ to
# /var/lib/systemd/pstore. The edge-pstore-persist recipe bind-mounts
# that target onto /data/crash/pstore so archives survive RAUC slot
# switches.
PACKAGECONFIG:append = " pstore"

# openssl: systemd built against libcrypto for its crypto-backed features
# (systemd-creds, repart, hashing). Enabled distro-wide here, independent of
# meta-virtualization which also enables it under VIRT.
PACKAGECONFIG:append = " openssl"

# repart: edge-grow-data calls systemd-repart to grow /data on GPT (eMMC)
# layouts. Enabled for all targets so the unified grow service has it available
# regardless of boot target. Requires PACKAGECONFIG[openssl] (enabled above).
PACKAGECONFIG:append = " repart"
