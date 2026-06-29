# Enable the x264 H.264 software encoder (x264enc). The upstream recipe
# ships the x264 PACKAGECONFIG off by default, so gstreamer1.0-plugins-ugly-x264
# is never produced. The camera packagegroup (dev profile) needs it for H.264
# encode/stream demos. x264 is GPL + carries the `commercial` LICENSE_FLAG
# (H.264 patents); accepted at the dev profile in edge-profile-dev.inc.
PACKAGECONFIG:append = " x264"
