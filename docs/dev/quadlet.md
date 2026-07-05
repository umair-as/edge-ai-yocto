# Quadlet container deployment — usage notes

Quadlet is podman's systemd-native container management. Drop a `.container`
file in the right directory; `systemd-generator` converts it to a real
`.service` unit at boot. No `podman run` invocations, no hand-written unit
files.

## Drop directories (wired by edge-containers-config)

| Path | Who | Generator |
|---|---|---|
| `/etc/containers/systemd/` | root (rootful containers) | `podman-system-generator` |
| `~/.config/containers/systemd/` | devel (rootless containers) | `podman-user-generator` |

## Rootful container — inference service

```ini
# /etc/containers/systemd/inference.container
[Container]
Image=registry.example.com/drp-ai-inference:latest
PublishPort=8080:8080
Volume=/data/models:/models:ro

[Service]
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

After placing the file:

```bash
systemctl daemon-reload
systemctl enable --now podman-inference
systemctl status podman-inference
journalctl -u podman-inference -f
```

## Rootless container — devel user

```ini
# /home/devel/.config/containers/systemd/myapp.container
[Container]
Image=registry.example.com/myapp:latest
PublishPort=8080:8080

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

Reload as devel (loginctl session required for user systemd):

```bash
systemctl --user daemon-reload
systemctl --user enable --now podman-myapp
journalctl --user -u podman-myapp -f
```

## Companion unit types

Quadlet handles more than `.container`:

```ini
# myapp.volume  — named volume, created before the container starts
[Volume]
```

```ini
# myapp.network — CNI network, created before the container starts
[Network]
Subnet=10.89.0.0/24
```

Reference them in the `.container` file:

```ini
[Container]
Volume=myapp.volume:/data
Network=myapp.network
```

## Updating a running container

```bash
# Pull new image
podman pull registry.example.com/drp-ai-inference:latest
# Restart the systemd unit — podman-system-generator does NOT auto-update
systemctl restart podman-inference
```

For automated updates, `podman auto-update` reads the `io.containers.autoupdate`
label; pair with a systemd timer if needed.

## Checking what Quadlet generated

The generator writes units to a volatile directory at boot:

```bash
/usr/lib/systemd/system-generators/podman-system-generator --dry-run
# or inspect what's live
systemctl cat podman-inference
```
