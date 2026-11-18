# Hexagon NPU (QNN HTP v75) on EDGE AI OS

The Arduino VENTUNO Q's Qualcomm QCS8275 carries a Hexagon NPU. EDGE AI OS
drives it through Qualcomm's QNN runtime (QAIRT) with the HTP backend, over
FastRPC to the compute DSP. It is the board's accelerator, composed by the
machine fragment the way the RZ/V2L composes DRP-AI: `make dev BOARD=ventuno-q`
builds it in, with no separate toggle. Inference runs rootless as `edge-ctr`
through a shipped Quadlet. The model is compiled on the host from ONNX.

## At a glance

| | |
|---|---|
| Board | Arduino VENTUNO Q (QCS8275), compute DSP `cdsp` (Hexagon v75), remoteproc `qcom/qcs8300/cdsp0.mbn` |
| Composition | `kas/accel/qnn-htp-v75.yml`, included by `kas/machines/ventuno-q.yml`; `EDGE_ACCEL = "qnn-htp-v75"` |
| Packages | `packagegroup-edge-accel-qnn-htp-v75`: `fastrpc` (libcdsprpc, DSP daemons), `qairt-sdk` 2.50.0.260828 (host runtime, `qnn-*` tools), `qairt-sdk-hexagon-v75` (DSP skels), `edge-qnn-htp-quadlet`; all from meta-qcom except the Quadlet |
| Device policy | `/dev/fastrpc-cdsp` is `root:fastrpc 0640` (libcdsprpc opens it read-only); `/dev/dma_heap/system` is `root:dmaheap 0660` with a `group:fastrpc:rw` ACL (meta-qcom udev rules) |
| Identity | `edge-ctr` (uid 608) joins `fastrpc` (`EDGE_ACCEL_SUPPLEMENTARY_GROUPS`); that one group opens both nodes |
| Rootless path | `qnn-htp-inference` Quadlet: both nodes passed in with `keep-groups`, `/sys/firmware` unmasked, no network, runtime from the host's `/usr` |
| Licence | QAIRT is under Qualcomm's `qcom-ai-stack` licence; the image gets a `NOT-REDISTRIBUTABLE` marker beside it (bundles built from it inherit the restriction) |

## Architecture

`kas/machines/ventuno-q.yml` includes `kas/accel/qnn-htp-v75.yml`, which sets
`EDGE_ACCEL=qnn-htp-v75`, `EDGE_ACCEL_PROPRIETARY=1` and
`EDGE_ACCEL_SUPPLEMENTARY_GROUPS=fastrpc:edge-ctr`. `edge-image.bbclass` then
installs `packagegroup-edge-accel-qnn-htp-v75`:

| Package | Source | Carries |
|---|---|---|
| `fastrpc` | meta-qcom | `libcdsprpc.so.1`, `cdsprpcd`, udev rules |
| `qairt-sdk` | meta-qcom | `libQnnHtp.so`, `libQnnHtpV75Stub.so`, `qnn-net-run` and the other `qnn-*` tools |
| `qairt-sdk-hexagon-v75` | meta-qcom | `libQnnHtpV75Skel.so` and the other DSP-side libraries under `/usr/share/qcom` |
| `edge-qnn-htp-quadlet` | meta-edge-bsp | `/etc/containers/systemd/users/608/qnn-htp-inference.container` |

At run time `libQnnHtp.so` loads the v75 stub, the stub opens
`/dev/fastrpc-cdsp`, and libcdsprpc serves the skel files to the DSP from the
path its `/usr/share/qcom/conf.d` entry names for the board's device-tree
model. `cdsprpcd` is not on this path: inference runs with it stopped.

`qairt-sdk` recommends the skels of every Hexagon generation; the accelerator
fragment drops all but v75 through `BAD_RECOMMENDATIONS`.

## The rootless Quadlet

`/etc/containers/systemd/users/608/qnn-htp-inference.container` runs once per
boot when the payload is present:

- The container image (`debian:trixie-slim`) supplies only the namespaces. The
  host's glibc is newer than the image's, and the FastRPC stub must match the
  DSP skels, so `qnn-net-run` runs from the host's `/usr` (mounted read-only at
  `/host/usr`) through the host's loader:
  `/host/usr/lib/ld-linux-aarch64.so.1 --library-path /host/usr/lib`.
- `AddDevice=` passes `/dev/fastrpc-cdsp` and `/dev/dma_heap/system`;
  `GroupAdd=keep-groups` carries `edge-ctr`'s `fastrpc` membership in.
- `Unmask=/sys/firmware`: libcdsprpc reads
  `/sys/firmware/devicetree/base/model` to select its `conf.d` entry and fails
  device creation without it. Podman masks `/sys/firmware`, and a bind mount
  does not override the mask; `ADSP_LIBRARY_PATH` and `DSP_LIBRARY_PATH` do not
  replace the lookup. Inside the container `/sys` is read-only and `efivarfs`
  is not mounted.
- `Network=none`. `/usr/share/qcom` and `/data/qnn-htp` are mounted read-only;
  output tensors and the profiling log go to `edge-ctr`'s state directory,
  `/data/edge-ctr/.local/state/qnn-htp-inference/`.

### Payload contract

```
/data/qnn-htp/
├── model/model.bin     QNN context binary for HTP (Quadlet condition)
├── input_list.txt      one input per line, relative to /data/qnn-htp (Quadlet condition)
├── inputs/*.raw        float32 tensors in the converted model's layout (NHWC)
└── QAIRT_VERSION       QAIRT release the context binary was generated with
```

A context binary is tied to the QAIRT release that generated it; a `qairt-sdk`
change in the image needs the binary regenerated.

## Compiling a model

The reference model is `resnet18-v1-7.onnx` from the ONNX model zoo, the
model the DRP-AI path compiles. Host tooling is the QAIRT SDK of the same
release as the image (2.50.0.260828, the archive meta-qcom fetches), on a
host the SDK supports, with Python 3.12 in a virtual environment holding the
dependency versions the SDK's `bin/check-python-dependency` and
`docs/QAIRT-Docs/QNN/general/setup/linux_setup.html` list (including
`onnx` 1.19.1 and `onnxruntime` 1.23.2). The converter's Python extension
links `libc++.so.1` (LLVM libc++), and its ONNX frontend imports
`distutils`, which Python 3.12 provides only through `setuptools`.

1. Preprocess inputs: resize the short side to 256, centre-crop 224, RGB,
   scale to [0, 1], normalise with the ImageNet mean/std, write float32 in
   NHWC order. The same preprocessing produces the calibration set.
2. Convert and quantise (8-bit activations, per-channel weights; the ONNX
   model's batch dimension is dynamic and must be fixed):

   ```bash
   qnn-onnx-converter -i resnet18-v1-7.onnx -d data 1,3,224,224 \
       --input_list calib_list.txt --act_bitwidth 8 --use_per_channel_quantization \
       -o resnet18_int8.cpp
   ```
3. Build the model library for the board (`qnn-model-lib-generator -t
   aarch64-ubuntu-gcc9.4` with `QNN_AARCH64_UBUNTU_GCC_94=/` and the host's
   `aarch64-linux-gnu-g++`; the result needs glibc 2.34).
4. Prepare the context binary on the board, as `edge-ctr`, with the image's
   tools:

   ```bash
   qnn-context-binary-generator --backend libQnnHtp.so \
       --model libresnet18_int8.so --binary_file model --output_dir out
   ```

## Proof it is the NPU

VENTUNO Q, image `20261118154223` (`qairt-sdk` 2.50.0.260828;
hardware-validated 2026-11-18), ResNet18
int8 from the steps above, two 224×224 ImageNet-preprocessed images
(`dog.jpg` from pytorch/hub, `grace_hopper.jpg` from the TensorFlow example
images), run as `edge-ctr` with `--perf_profile burst`, 200 inferences:

| Backend | Model | NetRun avg | Accelerator execute | Throughput |
|---|---|---|---|---|
| HTP (NPU) | int8 context binary | 2.97 ms | 1.16 ms | 142 inf/s |
| QNN CPU | fp32 model library | 131 ms (20 runs) | — | 7.6 inf/s |

The HTP profile reports 4 HVX threads and an accelerator execute time per
graph; a CPU fallback reports neither. Top-1 equals ONNX Runtime fp32 on the
host for both images (258 Samoyed, 457 bow tie), with a logit correlation of
0.9985 against the fp32 reference.

The shipped Quadlet, image `20261118162920`, unattended at boot as `edge-ctr`
(hardware-validated 2026-11-18): the unit ends `Result=success` with the
same top-1 for both images; the two-input run at boot averages 3.99 ms per
inference (1.63 ms accelerator execute, 4 HVX threads), measured cold.

Failure behaviour, same images:

- a user outside `fastrpc` gets `Device Creation failure` (exit 11) — the
  login user `devel` included;
- a corrupted context binary gets `Create From Binary failure` (exit 16);
- the Quadlet without `keep-groups` fails with exit 11; without its payload
  it is skipped (`ConditionResult=no`).

## Limitations

- SELinux runs permissive on this image; the container's `ioctl` on
  `fastrpc_device_t` and `dma_device_t` is logged as an AVC denial and has no
  policy module.
- The calibration set for the reference model is crops of the two evaluation
  images; it shows the quantised graph matches fp32, not quantisation quality
  over a dataset.
- `qairt-sdk` is one package: the image carries its GPU, LPAI, SNPE and Genie
  libraries alongside the HTP runtime.
