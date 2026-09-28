# sharp-noavx-binary

Drop-in replacement for `node_modules/@img/sharp-libvips-linux-x64` (the
prebuilt [libvips](https://github.com/libvips/libvips) binary that
[sharp](https://github.com/lovell/sharp) downloads on Linux x64), rebuilt for
the **x86-64-v1** CPU baseline (SSE2 only, no AVX/AVX2). Useful for running
`sharp` on older/low-end CPUs or restrictive hypervisors that don't expose
AVX2 to the guest.

It repackages the official `@img/sharp-libvips-linux-x64` npm package,
swapping in the `libvips-cpp.so` (and `libvips.so`) built by
[libvips-noavx-binary](https://github.com/orhtej2/libvips-noavx-binary).
Everything else (package.json, headers, README, versions.json) is kept
untouched from the official release, so it stays compatible with whatever
version of `sharp` expects it.

## Usage

```bash
npm i sharp
curl -L -o sharp-libvips-noavx.tar.gz \
  https://github.com/orhtej2/sharp-noavx-binary/releases/latest/download/sharp-libvips-linux-x64-noavx-<version>.tar.gz
tar xzf sharp-libvips-noavx.tar.gz -C node_modules/@img --strip-components=1
```

Replace `<version>` with the `@img/sharp-libvips-linux-x64` version matching
your installed `sharp` (check `node_modules/@img/sharp-libvips-linux-x64/package.json`,
or see the [releases page](https://github.com/orhtej2/sharp-noavx-binary/releases)).

Run this after every `npm install`/`npm ci` that (re)installs `sharp`, since
npm will otherwise restore the AVX2 build.

Verify it worked:

```bash
node -e "console.log(require('sharp').versions)"
```

## Building locally

```bash
./build.sh [SHARP_LIBVIPS_VERSION] [LIBVIPS_NOAVX_TAG]
```

- `SHARP_LIBVIPS_VERSION`: the `@img/sharp-libvips-linux-x64` npm version to
  base the package on (defaults to latest on npm).
- `LIBVIPS_NOAVX_TAG`: the [libvips-noavx-binary](https://github.com/orhtej2/libvips-noavx-binary)
  release tag to source the compiled libraries from (defaults to `v<vips version>`,
  matching the libvips version bundled in the target sharp-libvips package).

Output: `build/sharp-libvips-linux-x64-noavx-<version>.tar.gz`.

Requires `curl`, `jq`, `npm`/`node`, and `tar`. `patchelf` is downloaded
automatically if not already on `PATH`.

## How it works

`sharp.node` on Linux dynamically links against a specifically-named file,
`libvips-cpp.so.<vips-version>`, found via an rpath relative to
`node_modules/@img/sharp-libvips-linux-x64/lib`. The official package
statically links every dependency (including libvips.so itself) into that
one file. `libvips-noavx-binary` builds `libvips-cpp.so` and `libvips.so` as
separate shared objects, so this repo also copies over `libvips.so.42` and
patches an `$ORIGIN` rpath onto both files (via `patchelf`) so the dynamic
linker can find it at runtime.

Only `linux-x64` (glibc) is supported, matching what `libvips-noavx-binary`
currently builds.

## Related repos

- [libvips-noavx-binary](https://github.com/orhtej2/libvips-noavx-binary) — builds the underlying libvips binary.
- [sharp](https://github.com/lovell/sharp) / [sharp-libvips](https://github.com/lovell/sharp-libvips) — upstream projects this repackages.

Disclaimer: This repo is almost purely vibecoded with copilot.
