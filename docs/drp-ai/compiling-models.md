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
   [the runtime layer](README.md#architecture--how-the-pieces-fit)) come straight from
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

`$DRPAI_BUILD` is the compile-env checkout — the build context that holds
`Dockerfile.v2l` and the staged Translator installer.

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

On the device, the runtime ([runtime layer](README.md#architecture--how-the-pieces-fit))
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

## The export step: getting an ONNX in the first place

The `compile_*` scripts take a model file as input, but many models are
not *distributed* as a ready ONNX. Classifiers from the ONNX model zoo
(ResNet-18, MobileNetV2) are — download the `.onnx` and compile it. Most
detection / segmentation / pose models are not: they ship as framework
checkpoints (`.pt`, torchvision weights, TFLite) and must be **exported**
to ONNX before the compile step.

Export is a *source-framework* operation, not a DRP-AI one, and it wants
the framework's own pinned environment. Two things make it awkward, and
both have a fixed answer:

- **Python version.** The upstream export recipes pin old framework
  versions (e.g. `torch==2.3.1`). These resolve cleanly on Python 3.10 and
  fight a modern host Python. The compiler image is already Ubuntu 22.04 /
  Python 3.10, so run the export **inside that same image** — a throwaway
  virtualenv, bind-mounting an output directory to keep the resulting ONNX
  on the host. The image is `--rm`; nothing about the export persists in it.
- **CUDA vs CPU wheels.** A model repo's `requirements.txt` frequently
  pulls a **CUDA** build of `torch` (e.g. `2.4.1+cu121`) over a CPU pin, so
  a plain `pip install torch==<ver>` followed by `-r requirements.txt`
  silently ends up on a GPU wheel. On a CPU build host that is heavier and
  off-recipe. Force the CPU build with an explicit index and re-assert it
  **after** `requirements.txt` so it wins:

  ```sh
  pip install torch==2.3.1 torchvision==0.18.1 \
      --index-url https://download.pytorch.org/whl/cpu
  # ... pip install -r requirements.txt ...
  pip install torch==2.3.1 torchvision==0.18.1 \
      --index-url https://download.pytorch.org/whl/cpu   # re-assert CPU wins
  ```

The per-model export procedure (which repo, which weights, which
`--imgsz`, which opset) is in the project's how-to pages under
`docs/model_list/how_to_convert/`, one file per family
(`How_to_convert_yolov5_onnx_models_V2L_V2M_V2MA.md`, etc.). Note the
input shape there can differ from the shape the V2L benchmark table uses —
e.g. the YOLOv5 how-to exports at 640, but the V2L-profiled configuration
is 320; export at the shape you intend to run. Confirm the exported model's
input node name and shape before compiling — that name is the `-i`
argument and the shape is `-s`:

```sh
python3 -c 'import onnx; m=onnx.load("model.onnx"); \
  print([(i.name,[d.dim_value for d in i.type.tensor_type.shape.dim]) \
  for i in m.graph.input])'
```

## Reading which operators ran on CPU

The flow's CPU-fallback is automatic and *silent* — the compile succeeds
whether the whole model mapped to the accelerator or half of it fell back
to CPU. The partition it chose is recorded in `deploy.json`, not printed.
Read it there.

Each accelerator subgraph is a `tvm_op` node whose `attrs.Compiler` is
`mera_drp`; everything else is CPU-side TVM (real CPU operators, or trivial
`__nop` reshapes). A clean, fully-offloaded model has **exactly one**
`mera_drp` subgraph and nothing but nops around it:

```sh
python3 -c '
import json, collections
d = json.load(open("deploy.json"))
ops = [n for n in d["nodes"] if n["op"] == "tvm_op"]
drp = [n for n in ops if (n.get("attrs") or {}).get("Compiler") == "mera_drp"]
cpu = [n for n in ops if (n.get("attrs") or {}).get("Compiler") != "mera_drp"]
print("mera_drp subgraphs:", len(drp))
print("CPU-side tvm ops   :", collections.Counter(
    (n.get("attrs") or {}).get("func_name","?") for n in cpu))'
```

- **One `mera_drp` subgraph, only `__nop` on CPU** → the accelerator ran
  the whole network end to end.
- **One `mera_drp` subgraph, a few real CPU ops** → the convolutional body
  ran on the accelerator; the CPU ops are the non-convolutional "glue" the
  backend leaves behind — input casts/slices at the head, and the
  detection-head decode (`reshape`/`transpose`/`strided_slice`/`concat` plus
  the box math) at the tail. Expected for detectors, not a gap.
- **Several `mera_drp` subgraphs** → the graph was *split*: the compiler hit
  an operator it can't place mid-graph, ran it on CPU, and resumed on the
  accelerator after. This is the failure mode to watch for — but see the
  observation below: it did **not** occur for any model tried on V2L.

### What V2L actually did (four models, measured)

Every model compiled so far — across classification, segmentation, and
detection — produced **exactly one** `mera_drp` subgraph. The backend maps
the entire convolutional feature-extraction graph to the accelerator in a
single piece; the only CPU work is head/tail glue. No model fragmented into
multiple subgraphs.

| Model | Task | `mera_drp` subgraphs | CPU-side ops |
|---|---|---|---|
| MobileNetV2 @224 | classification | 1 | none (`__nop` only) |
| DeepLabv3-r50 @224 | segmentation | 1 | none |
| YOLOv5s @320 | detection | 1 | head decode (sigmoid/anchor) |
| YOLOX-L @320 | detection (anchor-free) | 1 | input slice + head decode |

The segmentation result is the notable one: dilated convolutions, the ASPP
module, and bilinear upsampling all mapped to the accelerator with **zero**
CPU fallback.

The subgraph count is a useful *first* signal — it turns "does it run on the
accelerator?" into a countable fact before hardware. But it is **not**
sufficient, and the next section is why.

### Static partition is necessary, not sufficient — measure the weight

`deploy.json` shows *which* ops fall to CPU. It does **not** show how much
they *cost*. On hardware, that gap is decisive. The runtime's own per-op
profiler (`ProfileRun`, exposed by the `drpai-runner` benchmark) measured
this on the board (RZ/V2L, 6.12.43-cip7, `performance` governor); the split
of end-to-end `Run()` time:

| Model | NPU subgraph | CPU-side ops | Verdict |
|---|---|---|---|
| DeepLabv3-r50 @224 | **99.95 %** | ~0 | NPU-bound |
| YOLOX-L @320 | **98 %** | head decode + slice ≈ 2 % | NPU-bound |
| YOLOv5s @320 | **21 %** | **stem conv 58 %** + head decode 13 % + cast | **CPU-bound** |

The two detectors look *identical* in the static table above — each is "one
`mera_drp` subgraph plus CPU ops." At runtime they are opposites. YOLOX-L is
98 % accelerator. YOLOv5s spends **58 % of its inference in a single CPU
convolution** — its 6×6 stride-2 stem conv (the Focus-replacement) does not
place on gen-1 DRP-AI, so it runs on the A55 and dominates; the actual NPU
backbone is only ~21 % of the time. YOLOX-L's plain 3×3 stem places fine.

So the CPU fallback is **not** always lightweight "post-processing glue" — it
can be a heavyweight body convolution that determines the whole latency, and
which one it is depends on the model's stem/architecture, not on the task
type. The actionable rule for gen-1 V2L: a large-kernel, high-resolution stem
conv is a fallback risk; profile the compiled model on hardware before
trusting a latency estimate. Static analysis scopes the question; only the
runtime profile answers it.

## Status

This procedure is **proven** — it is how the validated on-device model was
produced. Two honest caveats:

- The compiler container is currently assembled from host-staged AI SDK
  inputs. A fully **pinned, reproducible-from-scratch** compile
  environment is tracked as roadmap (see the integration doc's
  [Status & roadmap](README.md#status--roadmap)).
- The **compile** side is exercised across classes — classification,
  segmentation, and detection all compile through this flow (see the
  four-model table above). On hardware, all three have been **profiled for
  latency and work-placement** (see
  [benchmarking-models.md](benchmarking-models.md)); **output correctness**
  is validated for classification only, and the detection models' CPU-side
  post-processing (detection-head decode) is not yet built into an
  application.

## References

- This compile environment: <https://github.com/umair-as/rzv2l-drpai-compile-env>
- DRP-AI TVM / RUHMI — repo: <https://github.com/renesas-rz/rzv_drp-ai_tvm>
- DRP-AI TVM / RUHMI — docs: <https://renesas-rz.github.io/rzv_drp-ai_tvm/>
- RZ/V AI SDK v7.00: <https://renesas-rz.github.io/rzv_ai_sdk/7.00/>
- RZ/V2L AI SDK getting started:
  <https://renesas-rz.github.io/rzv_ai_sdk/7.00/getting_started_v2l.html>
