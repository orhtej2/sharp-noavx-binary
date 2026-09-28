# sharp-noavx-binary

Drop-in replacement for `node_modules/@img/sharp-linux-x64` and
`node_modules/@img/sharp-libvips-linux-x64` (the prebuilt
[sharp](https://github.com/lovell/sharp) native addon and its
[libvips](https://github.com/libvips/libvips) dependency), rebuilt for the
**x86-64-v1** CPU baseline (no AVX/AVX2, no SSE4.2/"x86-64-v2"). Useful for
running `sharp` on older/low-end CPUs or restrictive hypervisors that don't
expose these instruction sets to the guest.

Both the official prebuilt `libvips-cpp.so` *and* the official
`sharp-linux-x64.node` addon itself require the x86-64-v2 baseline (SSE4.2) —
sharp's JS wrapper actively refuses to load the addon on CPUs lacking it,
via a `cpuid`-based runtime check, independent of whichever libvips is
loaded. So this repo rebuilds **both**:

- `@img/sharp-libvips-linux-x64`: repackages the official npm package,
  swapping in the `libvips-cpp.so`/`libvips.so` built by
  [libvips-noavx-binary](https://github.com/orhtej2/libvips-noavx-binary).
  Everything else (package.json, headers, README, versions.json) is kept
  untouched from the official release.
- `@img/sharp-linux-x64`: sharp's native addon (`sharp.node`), recompiled
  from source against the rebuilt libvips above, targeting the x86-64-v1
  baseline, with the SSE4.2 CPU gate (`_isUsingX64V2`) patched to always
  report satisfied (since this build never requires SSE4.2 to begin with).

## Usage

```bash
npm i sharp
curl -L -o sharp-noavx.tar.gz \
  https://github.com/orhtej2/sharp-noavx-binary/releases/latest/download/sharp-noavx-linux-x64-<version>.tar.gz
tar xzf sharp-noavx.tar.gz -C node_modules/@img --strip-components=1
```

Replace `<version>` with the installed `sharp` version (check
`node_modules/sharp/package.json`, or see the
[releases page](https://github.com/orhtej2/sharp-noavx-binary/releases)).

Run this after every `npm install`/`npm ci` that (re)installs `sharp`, since
npm will otherwise restore the AVX2/SSE4.2 build.

Verify it worked:

```bash
node -e "console.log(require('sharp').versions)"
```

If it still fails, check that the CPU your process actually runs on (not
just the build/CI machine) supports at least SSE2 — that's the true floor;
anything below that isn't supported by libvips/Node.js at all.

## Building locally

```bash
./build.sh [SHARP_VERSION] [LIBVIPS_NOAVX_TAG]
```

- `SHARP_VERSION`: the `sharp` npm version to build against (defaults to
  latest). The matching `@img/sharp-libvips-linux-x64` version is resolved
  automatically from `sharp`'s own `optionalDependencies`.
- `LIBVIPS_NOAVX_TAG`: the [libvips-noavx-binary](https://github.com/orhtej2/libvips-noavx-binary)
  release tag to source the compiled libraries from (defaults to `v<vips version>`,
  matching the libvips version bundled with the target sharp release).

Output: `build/sharp-noavx-linux-x64-<sharp version>.tar.gz`, containing both
`sharp-libvips-linux-x64/` and `sharp-linux-x64/` packages.

Requires `curl`, `jq`, `git`, `npm`/`node`, a C/C++ toolchain (gcc/g++, make,
python3), and `tar`. `patchelf` is downloaded automatically if not already on
`PATH`. Extra `CFLAGS`/`CXXFLAGS` set in the environment are appended after
the CPU baseline flags when compiling the sharp native addon.

## How it works

### libvips-cpp.so

`sharp.node` on Linux dynamically links against a specifically-named file,
`libvips-cpp.so.<vips-version>`, found via an rpath relative to
`node_modules/@img/sharp-libvips-linux-x64/lib`. The official package
statically links every dependency (including libvips.so itself) into that
one file. `libvips-noavx-binary` builds `libvips-cpp.so` and `libvips.so` as
separate shared objects, so this repo also copies over `libvips.so.42`, and
uses `patchelf` to fix up each file's own SONAME (so it matches its on-disk
filename in the package, keeping `DT_NEEDED` entries of anything linking
against it consistent) and add an `$ORIGIN` rpath so the dynamic linker can
find `libvips.so.42` alongside it at runtime.

### sharp.node

sharp's own prebuilt native addon is compiled requiring the x86-64-v2
baseline, and additionally gates itself at runtime with a `cpuid` check
(`_isUsingX64V2` in `src/utilities.cc`) that's consulted unconditionally by
sharp's JS wrapper (`lib/sharp.mjs`) whenever the `linux-x64`/`linuxmusl-x64`
runtime is used — regardless of which libvips ends up loaded. `build.sh`
clones the matching `sharp` tag, patches that check to always report success
(valid here since this build itself targets x86-64-v1), and recompiles
`sharp.node` from source with `-march=x86-64-v1` (falling back to plain
`x86-64` on older GCC versions that don't recognize the microarchitecture
level name — both are equivalent baselines), linked against the repackaged
libvips from the step above.

Only `linux-x64` (glibc) is supported, matching what `libvips-noavx-binary`
currently builds.

## Related repos

- [libvips-noavx-binary](https://github.com/orhtej2/libvips-noavx-binary) — builds the underlying libvips binary.
- [sharp](https://github.com/lovell/sharp) / [sharp-libvips](https://github.com/lovell/sharp-libvips) — upstream projects this repackages.

Disclaimer: This repo is almost purely vibecoded with copilot.
