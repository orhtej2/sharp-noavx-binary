#!/usr/bin/env bash
set -euo pipefail

## Builds drop-in replacements for node_modules/@img/sharp-libvips-linux-x64
## and node_modules/@img/sharp-linux-x64, both rebuilt for the x86-64-v1 CPU
## baseline (no AVX/AVX2, no SSE4.2/"x86-64-v2") using libvips-noavx-binary.
## Run with --help for usage details.

LIBVIPS_NOAVX_REPO="orhtej2/libvips-noavx-binary"
SHARP_REPO="https://github.com/lovell/sharp.git"
LIBVIPS_PACKAGE_NAME="@img/sharp-libvips-linux-x64"

WORK_DIR="${PWD}/build-work"
BUILD_DIR="${PWD}/build"
CURL="curl --silent --location --retry 3 --retry-max-time 30 --fail"

usage() {
  cat << EOF
Builds drop-in replacements for node_modules/@img/sharp-libvips-linux-x64 and
node_modules/@img/sharp-linux-x64, both rebuilt for the x86-64-v1 CPU baseline
(no AVX/AVX2, no SSE4.2/"x86-64-v2") using libvips-noavx-binary.

Usage: ./build.sh [SHARP_VERSION] [LIBVIPS_NOAVX_TAG]

Arguments:
    SHARP_VERSION           sharp npm version to build against (default:
                            latest on npm). Determines the matching
                            @img/sharp-libvips-linux-x64 version automatically.
    LIBVIPS_NOAVX_TAG       ${LIBVIPS_NOAVX_REPO} release tag to source the
                            compiled libvips libraries from (default:
                            v<vips version>, matching the vips version
                            bundled with the target sharp release)

Options:
    -h, --help              Show this help message and exit

Environment:
    CFLAGS, CXXFLAGS         Extra flags appended after the CPU baseline flags
                            when compiling the sharp native addon.

Examples:
    ./build.sh                    # latest sharp + matching sharp-libvips/libvips-noavx-binary tags
    ./build.sh 0.35.5              # specific sharp version, auto-matched libvips
    ./build.sh 0.35.5 v8.18.7        # fully explicit

Output:
    build/sharp-noavx-linux-x64-<sharp version>.tar.gz, containing both
    sharp-libvips-linux-x64/ and sharp-linux-x64/ packages.

Requires: curl, jq, git, npm/node, a C/C++ toolchain (gcc/g++, make, python3),
and tar. patchelf is downloaded automatically if not already on PATH.
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

for tool in curl jq tar npm node git g++ make python3; do
  require_tool "$tool"
done

# patchelf is used to fix up SONAMEs and set an $ORIGIN RPATH on the
# repackaged libraries. Fetch a static build if it isn't already on PATH.
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

# The compiler's -march choices vary by GCC version ("x86-64-v1" isn't
# recognized by older GCCs, even though it's the effective baseline of plain
# "x86-64"). Probe for the most specific flag actually supported, matching
# libvips-noavx-binary's own approach, and always force generic tuning so no
# AVX/AVX2/SSE4.2 instructions are emitted regardless of the host CPU.
compiler_supports_flag() {
  printf 'int main(void){return 0;}\n' | "${CXX:-g++}" "$1" -x c++ -c -o /dev/null - >/dev/null 2>&1
}

if compiler_supports_flag "-march=x86-64-v1"; then
  BASELINE_ARCH_FLAGS="-march=x86-64-v1 -mtune=generic"
else
  BASELINE_ARCH_FLAGS="-march=x86-64 -mtune=generic"
fi
log_info "Using CPU baseline compiler flags: $BASELINE_ARCH_FLAGS"

SHARP_VERSION="${1:-}"
LIBVIPS_NOAVX_TAG="${2:-}"

rm -rf "$WORK_DIR/pkg" "$WORK_DIR/sharp-src" "$WORK_DIR/dist"
mkdir -p "$WORK_DIR/pkg" "$BUILD_DIR"

if [ -z "$SHARP_VERSION" ]; then
  SHARP_VERSION="$(npm view sharp version)"
fi
log_info "Target sharp version: $SHARP_VERSION"

SHARP_LIBVIPS_VERSION="$(npm view "sharp@${SHARP_VERSION}" "optionalDependencies.${LIBVIPS_PACKAGE_NAME}")"
log_info "Matching ${LIBVIPS_PACKAGE_NAME} version: $SHARP_LIBVIPS_VERSION"

##
## Step 1: repackage @img/sharp-libvips-linux-x64
##

# Fetch the official package and use it as a template: only its compiled
# libvips-cpp.so binary is replaced, everything else (package.json, README,
# versions.json, headers) is kept as-is for maximum compatibility.
log_info "Fetching official ${LIBVIPS_PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}..."
npm pack "${LIBVIPS_PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}" --pack-destination "$WORK_DIR" >/dev/null
TARBALL="$(ls "$WORK_DIR"/img-sharp-libvips-linux-x64-*.tgz)"
tar xzf "$TARBALL" -C "$WORK_DIR/pkg" --strip-components=1
rm -f "$TARBALL"

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

log_info "Replacing lib/$EXISTING_CPP_SO and adding lib/libvips.so.42..."
rm -f "$WORK_DIR"/pkg/lib/libvips-cpp.so.*
cp "$NOAVX_CPP_SO" "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"
cp "$NOAVX_VIPS_SO" "$WORK_DIR/pkg/lib/libvips.so.42"
chmod 755 "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO" "$WORK_DIR/pkg/lib/libvips.so.42"

# libvips-noavx-binary keeps libvips-cpp.so and libvips.so as separate
# objects (unlike the official build, which statically links everything into
# a single .so). Fix each file's own embedded SONAME to match its filename in
# this package (renaming loses the original "libvips-cpp.so.42" SONAME,
# which would otherwise end up as the DT_NEEDED string of anything linking
# against it, rather than the "libvips-cpp.so.<vips_version>" filename sharp
# actually ships), and give both an $ORIGIN rpath (legacy DT_RPATH tag) so
# libvips-cpp.so can find its sibling libvips.so.42 at runtime.
"$PATCHELF_BIN" --set-soname "$EXISTING_CPP_SO" "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"
"$PATCHELF_BIN" --set-soname "libvips.so.42" "$WORK_DIR/pkg/lib/libvips.so.42"
"$PATCHELF_BIN" --set-rpath '$ORIGIN' --force-rpath "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"
"$PATCHELF_BIN" --set-rpath '$ORIGIN' --force-rpath "$WORK_DIR/pkg/lib/libvips.so.42"

log_info "Verifying dynamic dependencies..."
if ldd "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO" | grep -q "not found"; then
  log_error "Unresolved dependency detected"
  ldd "$WORK_DIR/pkg/lib/$EXISTING_CPP_SO"
  exit 1
fi

cat >> "$WORK_DIR/pkg/README.md" << EOF

## noavx rebuild

This package's \`lib/$EXISTING_CPP_SO\` (and the added \`lib/libvips.so.42\`) were
rebuilt for the x86-64-v1 CPU baseline (SSE2 only, no AVX/AVX2) from
[libvips-noavx-binary](https://github.com/${LIBVIPS_NOAVX_REPO}) tag
\`${LIBVIPS_NOAVX_TAG}\`, using [sharp-noavx-binary](https://github.com/orhtej2/sharp-noavx-binary).
All other files are unmodified from the official \`${LIBVIPS_PACKAGE_NAME}@${SHARP_LIBVIPS_VERSION}\` release.
EOF

##
## Step 2: build @img/sharp-linux-x64 from source against the noavx libvips
##
## The official sharp.node also refuses to run below the "x86-64-v2" baseline
## (see sharp.mjs's `_isUsingX64V2()` gate, which checks the CPUID SSE4.2 bit
## at runtime independently of libvips) so it must be rebuilt too, not just
## libvips.

log_info "Cloning sharp v${SHARP_VERSION}..."
git clone --quiet --depth 1 --branch "v${SHARP_VERSION}" "$SHARP_REPO" "$WORK_DIR/sharp-src"

log_info "Patching CPU baseline gate (this build never requires SSE4.2)..."
python3 - "$WORK_DIR/sharp-src/src/utilities.cc" << 'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
pattern = re.compile(
    r'#if defined\(__GNUC__\) && defined\(__x86_64__\)\n'
    r'// Are SSE 4\.2 intrinsics available at runtime\?\n'
    r'Napi::Value _isUsingX64V2.*?\n#endif\n',
    re.DOTALL
)
replacement = (
    '// This noavx build targets the x86-64-v1 baseline, so it never requires\n'
    '// SSE4.2; report v2 as satisfied unconditionally to skip sharp.mjs\'s gate.\n'
    'Napi::Value _isUsingX64V2(const Napi::CallbackInfo& info) {\n'
    '  Napi::Env env = info.Env();\n'
    '  return Napi::Boolean::New(env, true);\n'
    '}\n'
)
new_src, count = pattern.subn(replacement, src)
if count != 1:
    raise SystemExit(f"expected exactly 1 match for _isUsingX64V2 patch, got {count}")
open(path, 'w').write(new_src)
PYEOF

pushd "$WORK_DIR/sharp-src" >/dev/null

log_info "Installing sharp build dependencies..."
npm install >/dev/null

# Build against our noavx libvips instead of the official AVX2 prebuilt.
rm -rf node_modules/@img/sharp-libvips-linux-x64
cp -r "$WORK_DIR/pkg" node_modules/@img/sharp-libvips-linux-x64

export CFLAGS="${BASELINE_ARCH_FLAGS} ${CFLAGS:-}"
export CXXFLAGS="${BASELINE_ARCH_FLAGS} ${CXXFLAGS:-}"
log_info "Building sharp.node with CFLAGS='$CFLAGS' CXXFLAGS='$CXXFLAGS'..."
npm run build:dist
npm run build
npm run package-from-local-build

popd >/dev/null

SHARP_NODE_BIN="$WORK_DIR/sharp-src/npm/linux-x64/lib/sharp-linux-x64-${SHARP_VERSION}.node"
log_info "Verifying sharp.node dynamic dependencies..."
if ldd "$SHARP_NODE_BIN" | grep -q "not found"; then
  log_error "Unresolved dependency detected"
  ldd "$SHARP_NODE_BIN"
  exit 1
fi

##
## Step 3: package both into a single release tarball
##

OUTPUT_NAME="sharp-noavx-linux-x64-${SHARP_VERSION}"
mkdir -p "$WORK_DIR/dist/$OUTPUT_NAME"
# Wrap both packages in an extra top-level directory so the release tarball
# can be extracted straight into node_modules/@img with --strip-components=1,
# landing each package at node_modules/@img/<name>.
cp -r "$WORK_DIR/pkg" "$WORK_DIR/dist/$OUTPUT_NAME/sharp-libvips-linux-x64"
cp -r "$WORK_DIR/sharp-src/npm/linux-x64" "$WORK_DIR/dist/$OUTPUT_NAME/sharp-linux-x64"

tar -czf "${BUILD_DIR}/${OUTPUT_NAME}.tar.gz" -C "$WORK_DIR/dist" "$OUTPUT_NAME"

log_info "Built ${BUILD_DIR}/${OUTPUT_NAME}.tar.gz"
log_info "Install with:"
log_info "  npm i sharp@${SHARP_VERSION}"
log_info "  tar xzf ${OUTPUT_NAME}.tar.gz -C node_modules/@img --strip-components=1"
