# pstore PACKAGECONFIG enables systemd-pstore.service, which on boot
# archives kernel pstore records from /sys/fs/pstore/ to
# /var/lib/systemd/pstore. The edge-pstore-persist recipe bind-mounts
# that target onto /data/crash/pstore so archives survive RAUC slot
# switches.
PACKAGECONFIG:append = " pstore"
