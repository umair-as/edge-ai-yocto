# Compiling models for DRP-AI — the host-side build

Companion to [the DRP-AI integration overview](README.md). That document
covers what runs *on the device*; this one covers the step *before* the
device — turning a trained model into a DRP-AI-runnable artifact on a
build host, reproducibly, in a container.

## The repo this all revolves around: `rzv_drp-ai_tvm`

If you work on models for this board, the one upstream to know is
**Renesas' DRP-AI TVM (RUHMI) project**:

- Repo: <https://github.com/renesas-rz/rzv_drp-ai_tvm>
- Docs: <https://renesas-rz.github.io/rzv_drp-ai_tvm/>

It is the centre of gravity for two reasons:

1. **It is the on-device runtime.** The libraries this platform ships
   (packaged by the `drpai-tvm-runtime` recipe, see
   [the runtime layer](README.md#4-the-runtime-layer)) come straight from
   this project. Nothing runs on the board without it.
2. **It is the model compiler.** The same project provides the MERA/TVM
   compiler and the `compile_*` tutorial scripts that turn an ONNX /
   PyTorch / TensorFlow model into the DRP-AI artifact you deploy.

It is an Apache-TVM-based, end-to-end flow (ONNX/PyTorch/TensorFlow in,
DRP-AI artifact out) with CPU fallback for operators the accelerator
doesn't support — so an arbitrary model compiles instead of failing on an
unsupported layer. Its docs carry the tutorials (sample and custom
models), the pre/post-processing reference, and sample applications
(ResNet50, YOLOX, DeepLabV3, pose, depth, camera→HDMI). This document is
the bridge between that project and this platform: how we wrap its
compiler in a container and where its outputs land on the board.

## What you need, and where it comes from

The compile uses three things on the build host:

- the **DRP-AI TVM compiler** (MERA/TVM) — from `rzv_drp-ai_tvm`, public;
- the **DRP-AI Translator** — the tool that adapts the model graph to the
  accelerator;
- a **cross toolchain (aarch64 poky SDK)** — to cross-compile the model's
  host-side graph for the target.

The Translator and the cross SDK ship inside the **RZ/V2L AI SDK**, which
you download from the Renesas portal. The AI SDK getting-started docs are
the obtain-and-set-up reference:

- AI SDK v7.00: <https://renesas-rz.github.io/rzv_ai_sdk/7.00/>
- RZ/V2L getting started:
  <https://renesas-rz.github.io/rzv_ai_sdk/7.00/getting_started_v2l.html>

These are Renesas build-host tools — they stay on the host that compiles
models; the artifact you produce is yours to deploy.

## Build the compiler container

We package the compiler stack into one pinned Docker image so every model
is built the same way. The image is deliberately **lean** — it carries the
compiler, the Translator, and the tutorial tooling, but **not** the cross
SDK (mounted at run time, see the next section).

A ready-made, pinned version of this environment — the Dockerfile, the
`build.sh` / `compile.sh` wrappers, and the setup notes — lives in a
dedicated repo,
[**rzv2l-drpai-compile-env**](https://github.com/umair-as/rzv2l-drpai-compile-env).
The rest of this section describes what it does and the one trap it handles.

In outline, the image is:

- a minimal Linux base + LLVM and build essentials;
- the **DRP-AI Translator**, installed from the AI SDK's installer;
- the **DRP-AI TVM / MERA compiler** wheels, taken from `rzv_drp-ai_tvm`
  at a **fixed release tag** — the *same* project and pin the on-device
  runtime comes from, so compiler and runtime are version-matched;
- the Python model-handling dependencies (ONNX, and the frameworks needed
  to load source models).

Build it once on the host (the Translator installer is staged into the
build context, never committed):

```sh
docker build -f Dockerfile.v2l -t drpai-tvm-v2l:<tag> "$DRPAI_BUILD"
```

## Mount the SDK at its install path (the one gotcha)

The cross SDK is relocatable, but the relocation is fixed at *install*
time: the SDK bakes its own install path into the ELF **interpreter** of
its `x86_64` cross-compilers. So:

> **Install the SDK to a host directory and bind-mount it into the
> container at that same path.** Mount it elsewhere and the cross-compiler
> looks present but fails to execute (`ENOENT` on its interpreter) partway
> through the compile — a confusing "compiler not found" for a file that
> is plainly there.

After installing, create the conventional sysroot alias the toolchain
expects (`aarch64-poky-linux` → `cortexa55-poky-linux`) once.

## Compile a model

With the image built and the SDK installed, a compile is one container
run. Placeholders: `$DRPAI_SDK` = the SDK install path, `$DRPAI_OUT` = an
output directory.

```sh
docker run --rm \
  -e SDK="$DRPAI_SDK" \
  -v "$DRPAI_SDK:$DRPAI_SDK" \
  -v "$DRPAI_OUT:/out" \
  drpai-tvm-v2l:<tag> bash -c '
    cd /drp-ai_tvm/tutorials
    # public ResNet-18 from the ONNX model zoo, as an example
    wget -q https://github.com/onnx/models/raw/main/validated/vision/classification/resnet/model/resnet18-v1-7.onnx
    python3 compile_onnx_model.py ./resnet18-v1-7.onnx \
        -o /out/resnet18_onnx -s 1,3,224,224 -i data
  '
```

- `-e SDK` is required (the lean image has no baked SDK path).
- `-s` is the model input shape; `-i` the input node name. The target SoC
  is fixed in the image environment.

The `compile_onnx_model.py`, `compile_pytorch_model.py`, and
`compile_tflite_model.py` scripts (and their options) are documented in
the project's tutorials:
<https://renesas-rz.github.io/rzv_drp-ai_tvm/>.

## What comes out, and how the board uses it

The output directory is the deployable model:

- a **shared object** — the cross-compiled host-side graph, weights baked
  in;
- small **graph-metadata** files;
- a **preprocess** set — the accelerator descriptors for the resize /
  normalise / format conversion that runs *on the accelerator* before
  inference.

On the device, the runtime ([runtime layer](README.md#4-the-runtime-layer))
loads this directory and drives the accelerator. The artifact has a low
glibc floor, so it isn't tied to the exact toolchain of the rootfs that
runs it. Deploying it is just placing the directory where the workload
expects it — on this platform, on the persistent `/data` partition, bind-
mounted into the rootless inference container.

## Compiling other models

The same container compiles any supported model: change the source model,
its input **shape** (`-s`), and its input **node name** (`-i`). Input
*formatting* — colour order, resize target, normalisation constants, and
whether a camera-style YUV→RGB conversion runs on the accelerator — is set
through the compile scripts' pre/post configuration. For model-specific
recipes (YOLOX, DeepLabV3, pose, …), camera-input variants, and the sample
applications, follow the project's how-to and tutorials at
<https://renesas-rz.github.io/rzv_drp-ai_tvm/>.

Classification is the simplest case (a single output vector); detection,
segmentation, and pose add CPU-side post-processing that lives in the
application, not the compile.

## Status

This procedure is **proven** — it is how the validated on-device model was
produced. Two honest caveats:

- The compiler container is currently assembled from host-staged AI SDK
  inputs. A fully **pinned, reproducible-from-scratch** compile
  environment is tracked as roadmap (see the integration doc's
  [Status and roadmap](README.md#status-and-roadmap)).
- Only classification has been taken end-to-end so far; detection /
  segmentation / pose compile through the same flow, but their on-device
  post-processing is not yet built.

## References

- This compile environment: <https://github.com/umair-as/rzv2l-drpai-compile-env>
- DRP-AI TVM / RUHMI — repo: <https://github.com/renesas-rz/rzv_drp-ai_tvm>
- DRP-AI TVM / RUHMI — docs: <https://renesas-rz.github.io/rzv_drp-ai_tvm/>
- RZ/V AI SDK v7.00: <https://renesas-rz.github.io/rzv_ai_sdk/7.00/>
- RZ/V2L AI SDK getting started:
  <https://renesas-rz.github.io/rzv_ai_sdk/7.00/getting_started_v2l.html>
