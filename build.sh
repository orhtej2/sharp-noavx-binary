#!/usr/bin/env bash
set -euo pipefail

## Repackages @img/sharp-libvips-linux-x64 (the prebuilt libvips used by
## sharp's Linux x64 binary) with libvips-noavx-binary's x86-64-v1 build,
## so it works as a drop-in replacement for CPUs without AVX/AVX2.
## Run with --help for usage details.

LIBVIPS_NOAVX_REPO="orhtej2/libvips-noavx-binary"
PACKAGE_NAME="@img/sharp-libvips-linux-x64"

WORK_DIR="${PWD}/build-work"
BUILD_DIR="${PWD}/build"
CURL="curl --silent --location --retry 3 --retry-max-time 30 --fail"

usage() {
  cat << EOF
Repackages ${PACKAGE_NAME} (the prebuilt libvips used by sharp's Linux x64
binary) with libvips-noavx-binary's x86-64-v1 build, so it works as a
drop-in replacement for CPUs without AVX/AVX2.

Usage: ./build.sh [SHARP_LIBVIPS_VERSION] [LIBVIPS_NOAVX_TAG]

Arguments:
    SHARP_LIBVIPS_VERSION   ${PACKAGE_NAME} npm version to base the package
                            on (default: latest on npm)
    LIBVIPS_NOAVX_TAG       ${LIBVIPS_NOAVX_REPO} release tag to source the
                            compiled libraries from (default: v<vips version>,
                            matching the vips version bundled in the target
                            sharp-libvips package)

Options:
    -h, --help              Show this help message and exit

Examples:
    ./build.sh                    # latest sharp-libvips + matching libvips-noavx-binary tag
    ./build.sh 1.3.4               # specific sharp-libvips package version, auto-matched libvips tag
    ./build.sh 1.3.4 v8.18.7        # fully explicit

Output:
    build/sharp-libvips-linux-x64-noavx-<version>.tar.gz

Requires: curl, jq, npm/node, tar (patchelf is downloaded automatically if
not already on PATH).
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { log_error "Required tool '$1' not found"; exit 1; }
}

for tool in curl jq tar npm node; do
  require_tool "$tool"
done

# patchelf is used to set an $ORIGIN RPATH on the repackaged libraries so
# libvips-cpp.so can find its sibling libvips.so at runtime. Fetch a static
# build if it isn't already on PATH.
PATCHELF_BIN="patchelf"
if ! command -v patchelf >/dev/null 2>&1; then
  log_warn "patchelf not found on PATH; downloading a static build"
  mkdir -p "$WORK_DIR/patchelf"
  $CURL -o "$WORK_DIR/patchelf.tar.gz" \
    "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz"
  tar xzf "$WORK_DIR/patchelf.tar.gz" -C "$WORK_DIR/patchelf"
  chmod +x "$WORK_DIR/patchelf/bin/patchelf"
  PATCHELF_BIN="$WORK_DIR/patchelf/bin/patchelf"
fi

SHARP_LIBVIPS_VERSION="${1:-}"
LIBVIPS_NOAVX_TAG="${2:-}"

rm -rf "$WORK_DIR/pkg"
mkdir -p "$WORK_DIR/pkg" "$BUILD_DIR"

if [ -z "$SHARP_LIBVIPS_VERSION" ]; then
  SHARP_LIBVIPS_VERSION="$(npm view "$PACKAGE_NAME" version)"
fi
log_info "Target package: ${PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}"

# Fetch the official package and use it as a template: only its compiled
# libvips-cpp.so binary is replaced, everything else (package.json, README,
# versions.json, headers) is kept as-is for maximum compatibility.
log_info "Fetching official ${PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}..."
npm pack "${PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}" --pack-destination "$WORK_DIR" >/dev/null
TARBALL="$(ls "$WORK_DIR"/img-sharp-libvips-linux-x64-*.tgz)"
tar xzf "$TARBALL" -C "$WORK_DIR/pkg" --strip-components=1

EXISTING_CPP_SO="$(basename "$(ls "$WORK_DIR"/pkg/lib/libvips-cpp.so.*)")"
VIPS_VERSION="$(jq -r .vips "$WORK_DIR/pkg/versions.json")"
log_info "Official package bundles libvips $VIPS_VERSION as lib/$EXISTING_CPP_SO"

if [ -z "$LIBVIPS_NOAVX_TAG" ]; then
  LIBVIPS_NOAVX_TAG="v${VIPS_VERSION}"
fi
log_info "Using libvips-noavx-binary release: $LIBVIPS_NOAVX_TAG"

log_info "Downloading libvips-noavx-binary $LIBVIPS_NOAVX_TAG..."
LIBVIPS_ASSET_URL="https://github.com/${LIBVIPS_NOAVX_REPO}/releases/download/${LIBVIPS_NOAVX_TAG}/libvips-${LIBVIPS_NOAVX_TAG}-linux-amd64.tar.gz"
mkdir -p "$WORK_DIR/noavx"
$CURL -o "$WORK_DIR/libvips-noavx.tar.gz" "$LIBVIPS_ASSET_URL"
tar xzf "$WORK_DIR/libvips-noavx.tar.gz" -C "$WORK_DIR/noavx" --strip-components=1

NOAVX_CPP_SO="$(readlink -f "$WORK_DIR/noavx/lib/libvips-cpp.so.42")"
NOAVX_VIPS_SO="$(readlink -f "$WORK_DIR/noavx/lib/libvips.so.42")"

# Sanity check: the C API ABI version embedded in the noavx build's own
# libvips.so.42.x.y is unrelated to the sharp-libvips project-version
# filename scheme, so we only compare the vips release actually built.
NOAVX_VIPS_VERSION="$(basename "$NOAVX_VIPS_SO" | sed -E 's/^libvips\.so\.42\.//')"
log_info "libvips-noavx-binary provides libvips ABI 42.$NOAVX_VIPS_VERSION"

log_info "Replacing lib/$EXISTING_CPP_SO and adding lib/libvips.so.42..."
rm -f "$WORK_DIR"/pkg/lib/libvips-cpp.so.*
cp "$NOAVX_CPP_SO" "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"
cp "$NOAVX_VIPS_SO" "$WORK_DIR/pkg/lib/libvips.so.42"
chmod 755 "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO" "$WORK_DIR/pkg/lib/libvips.so.42"

# libvips-cpp.so depends on libvips.so.42 (unlike the official build, which
# statically links everything into a single .so); give both an $ORIGIN rpath
# using the legacy DT_RPATH tag so the dependency resolves regardless of how
# the loading sharp.node binary was itself linked.
"$PATCHELF_BIN" --set-rpath '$ORIGIN' --force-rpath "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"
"$PATCHELF_BIN" --set-rpath '$ORIGIN' --force-rpath "$WORK_DIR/pkg/lib/libvips.so.42"

log_info "Verifying dynamic dependencies..."
if command -v ldd >/dev/null 2>&1; then
  ldd "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO" | grep -q "not found" && { log_error "Unresolved dependency detected"; ldd "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"; exit 1; }
fi

cat >> "$WORK_DIR/pkg/README.md" << EOF

## noavx rebuild

This package's \`lib/$EXISTING_CPP_SO\` (and the added \`lib/libvips.so.42\`) were
rebuilt for the x86-64-v1 CPU baseline (SSE2 only, no AVX/AVX2) from
[libvips-noavx-binary](https://github.com/${LIBVIPS_NOAVX_REPO}) tag
\`${LIBVIPS_NOAVX_TAG}\`, using [sharp-noavx-binary](https://github.com/orhtej2/sharp-noavx-binary).
All other files are unmodified from the official \`${PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}\` release.
EOF

OUTPUT_NAME="sharp-libvips-linux-x64-noavx-${SHARP_LIBVIPS_VERSION}"
rm -rf "$WORK_DIR/dist"
# Wrap the package in an extra top-level directory so the release tarball can
# be extracted straight into node_modules/@img with --strip-components=1,
# landing the package at node_modules/@img/sharp-libvips-linux-x64.
mkdir -p "$WORK_DIR/dist/$OUTPUT_NAME"
cp -r "$WORK_DIR/pkg" "$WORK_DIR/dist/$OUTPUT_NAME/sharp-libvips-linux-x64"

tar -czf "${BUILD_DIR}/${OUTPUT_NAME}.tar.gz" -C "$WORK_DIR/dist" "$OUTPUT_NAME"

log_info "Built ${BUILD_DIR}/${OUTPUT_NAME}.tar.gz"
log_info "Install with:"
log_info "  npm i sharp"
log_info "  tar xzf ${OUTPUT_NAME}.tar.gz -C node_modules/@img --strip-components=1"
