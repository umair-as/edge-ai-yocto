#!/bin/sh
# Configure the rzg2l-cru media pipeline so /dev/video0 can stream from
# the OV5645 CSI sensor. CRU + CSI-2 receiver pads default to the
# driver's safe boot resolution (320x240) and the sensor's source pad
# is "unknown" until set; VIDIOC_STREAMON fails (Broken pipe) until
# every pad along the chain advertises the same format/resolution.
set -e

# OV5645 sensor-native UYVY modes: 2592x1944, 1920x1080, 1280x960, 640x480.
# Asking for an unsupported mode (e.g. 1280x720) makes the driver round to
# the nearest sensor mode on the source pad, breaking the format chain.
W=${EDGE_OV5645_WIDTH:-1920}
H=${EDGE_OV5645_HEIGHT:-1080}
FMT="UYVY8_1X16/${W}x${H}"
MEDIA=${EDGE_OV5645_MEDIA:-/dev/media0}
VIDEO=${EDGE_OV5645_VIDEO:-/dev/video0}

# Entity names are the rzg2l-cru media-controller defaults. They are
# defined by the device tree (csi2@10830400, video@10830000) so the
# device-side IDs are stable across boots.
media-ctl -d "${MEDIA}" --set-v4l2 "'ov5645 0-003c':0 [fmt:${FMT}]"
media-ctl -d "${MEDIA}" --set-v4l2 "'csi-10830400.csi2':0 [fmt:${FMT}]"
media-ctl -d "${MEDIA}" --set-v4l2 "'csi-10830400.csi2':1 [fmt:${FMT}]"
media-ctl -d "${MEDIA}" --set-v4l2 "'cru-ip-10830000.video':0 [fmt:${FMT}]"
media-ctl -d "${MEDIA}" --set-v4l2 "'cru-ip-10830000.video':1 [fmt:${FMT}]"
v4l2-ctl --device "${VIDEO}" --set-fmt-video "width=${W},height=${H},pixelformat=UYVY"

echo "[edge-ov5645-init] ${MEDIA} pipeline set to ${FMT}"
