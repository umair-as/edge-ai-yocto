# Cross-compilation — edge / aarch64

Notes on the cross-compile target this repo produces and how to use
the resulting SDK / sysroot.

## Target

- Architecture: `aarch64`
- Vendor: `-oe`, oe-core's default (`TARGET_VENDOR` in `conf/distro/edge-ai.conf`; matching it lets
  native and cross sstate be shared with other oe-core builds on the host)
- OS: `linux`
- Tuple: `aarch64-oe-linux`

## SDK

```bash
# Generate cross-SDK for the current image target
make shell
# inside kas shell:
bitbake edge-image-base -c populate_sdk
# or directly:
kas shell -c 'bitbake edge-image-base -c populate_sdk' \
  kas/base.yml:kas/machines/rzv2l.yml
```

SDK installer lands under `build/<BOARD>/tmp/deploy/sdk/`. Install with:

```bash
# Name: ${SDK_NAME}-toolchain-${SDK_VERSION}.sh, SDK_NAME = edge-<image>-x86_64-<tune>-<machine>
./edge-edge-image-base-x86_64-<tune>-<machine>-toolchain-<version>.sh
# Default install: /usr/local/edge-x86_64 (SDKPATHINSTALL)
source /usr/local/edge-x86_64/environment-setup-<tune>-oe-linux
```

After sourcing, the standard cross-compile variables are exported:
`CC`, `CXX`, `AR`, `LD`, `STRIP`, `PKG_CONFIG_PATH`, `CFLAGS`,
`LDFLAGS`, etc.

## Verifying you are cross-compiling correctly

```bash
${CC} --version            # should print aarch64-oe-linux-gcc
echo | ${CC} -E -dM - | grep '__aarch64__'   # confirms target arch
file $(which ${CC})         # the compiler binary is x86_64; output is aarch64
```

## CMake

```bash
cmake -B build \
  -DCMAKE_TOOLCHAIN_FILE=${OECORE_NATIVE_SYSROOT}/usr/share/cmake/OEToolchainConfig.cmake \
  .
```

The Yocto-supplied toolchain file handles the rest. Do not hand-write
`-DCMAKE_C_COMPILER` paths.

## Rust

```bash
# After sourcing the SDK environment:
export CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu
cargo build --release
```

The SDK puts the right linker on `PATH` automatically.

## Go

```bash
GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
  CC=${CC} go build -trimpath -o bin/myapp .
```

## Sysroot layout reminder

- `${SDKTARGETSYSROOT}` — target headers / libs (aarch64)
- `${OECORE_NATIVE_SYSROOT}` — host tools (x86_64)

If a build script ignores `${CC}` and reaches for `/usr/bin/gcc`,
fix the build script; do not work around it in the recipe.
