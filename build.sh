#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build relocatable libkrun + libkrunfw artefacts for the host platform.
#
# Output: ./dist/libkrun-${LIBKRUN_VERSION}-${TARGET}.tar.gz
#
# The tarball layout:
#   lib/libkrun.${ext}              with @rpath / $ORIGIN install name
#   lib/libkrunfw.${ext}            with @rpath / $ORIGIN install name
#   include/libkrun.h
#   lib/pkgconfig/libkrun.pc        synthesised, prefix placeholder
#                                   rewritten by the consumer
#
# Versioning:
#   libkrun and libkrunfw use *independent* version schemes. The
#   pairing is authoritative via slp/krun's Homebrew formulas. We pin
#   both in this repo:
#     version.txt             libkrun release tag (e.g. 1.18.0)
#     libkrunfw-version.txt   libkrunfw release tag (e.g. 5.3.0)
#
# Build approach:
#   - libkrunfw: download upstream's prebuilt arch tarball + run its
#     bundled `make` + `make install`. Much faster than building the
#     custom Linux kernel from source.
#   - libkrun: clone the source tag and `make`, with PKG_CONFIG_PATH
#     pointing at the staged libkrunfw.
#
# Usage:
#   ./build.sh                    Build for the host's native triple.
#   TARGET=foo ./build.sh         Override the auto-detected target triple.
#
# Required tools:
#   - bash, make, gcc/clang
#   - cargo (Rust 1.75+)
#   - patchelf (Linux) or install_name_tool (macOS, ships with Xcode CLT)
#   - curl, tar, gzip, sha256sum / shasum
#   - pkg-config
#
# Exit codes:
#   0   Success, ./dist/libkrun-${LIBKRUN_VERSION}-${TARGET}.tar.gz exists.
#   1   Unknown / unsupported target triple.
#   2   Dependency missing.
#   3   Upstream download or build failed.
#   4   Relocation failed or relocation verification failed.
#   5   Smoke test failed (staged libkrun could not be dlopened).

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve versions + TARGET
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBKRUN_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/version.txt")"
LIBKRUNFW_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/libkrunfw-version.txt")"

if [[ -z "${TARGET:-}" ]]; then
  TARGET="$(rustc -vV | awk '/^host:/ {print $2}')"
fi

# Map host target → libkrunfw upstream arch + dylib extension.
# The libkrunfw kernel always runs inside a Linux microVM regardless
# of the host OS, so macOS arm64 uses the same kernel image as Linux
# arm64. Only the dylib loader format differs (Mach-O vs ELF), which
# the libkrunfw build handles via its host-aware Makefile.
case "${TARGET}" in
  aarch64-apple-darwin)
    DYLIB_EXT="dylib"
    LIBKRUNFW_ASSET="libkrunfw-prebuilt-aarch64.tgz"
    BACKEND="hvf"
    ;;
  x86_64-unknown-linux-gnu)
    DYLIB_EXT="so"
    LIBKRUNFW_ASSET="libkrunfw-x86_64.tgz"
    BACKEND="kvm"
    ;;
  aarch64-unknown-linux-gnu)
    DYLIB_EXT="so"
    LIBKRUNFW_ASSET="libkrunfw-aarch64.tgz"
    BACKEND="kvm"
    ;;
  *)
    echo "error: unsupported target triple '${TARGET}'" >&2
    echo "supported: aarch64-apple-darwin, x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu" >&2
    exit 1
    ;;
esac

echo "==> Building libkrun ${LIBKRUN_VERSION} (+ libkrunfw ${LIBKRUNFW_VERSION}) for ${TARGET}"
echo "==> Backend: ${BACKEND}, libkrunfw asset: ${LIBKRUNFW_ASSET}"

# ---------------------------------------------------------------------------
# Sanity-check tooling
# ---------------------------------------------------------------------------

need() {
  command -v "$1" > /dev/null 2>&1 || { echo "error: missing required tool '$1'" >&2; exit 2; }
}

need bash
need make
need cargo
need curl
need tar
need gzip
need pkg-config
command -v sha256sum > /dev/null 2>&1 || command -v shasum > /dev/null 2>&1 || { echo "error: missing sha256sum or shasum" >&2; exit 2; }

if [[ "${TARGET}" == *darwin* ]]; then
  need install_name_tool
else
  need patchelf
fi

# ---------------------------------------------------------------------------
# Upstream SHA verification helper.
#
# Reads upstream-checksums.txt at the repo root and verifies that a freshly
# downloaded file matches the pinned SHA-256. The manifest format is
# `<sha256>  <key>`, mirroring `sha256sum -c` output. Keys are URL-path-style
# triples like `libkrun/v1.18.1/source.tar.gz` so the same manifest can hold
# multiple versions side-by-side.
#
# Why this exists: GitHub release downloads aren't signed end-to-end. An
# upstream maintainer-account takeover or release-asset tamper would
# otherwise silently flow into the published vendor binaries. The watcher
# refreshes these pins whenever it bumps version.txt, so the verification
# window between cron-time fetch and build-time fetch is minutes, not days.
# ---------------------------------------------------------------------------

CHECKSUMS_FILE="${SCRIPT_DIR}/upstream-checksums.txt"

verify_sha() {
  local file="$1" key="$2" expected actual
  if [[ ! -f "${CHECKSUMS_FILE}" ]]; then
    echo "error: upstream-checksums.txt not found at ${CHECKSUMS_FILE}" >&2
    exit 3
  fi
  expected="$(awk -v k="${key}" '$2 == k {print $1; exit}' "${CHECKSUMS_FILE}")"
  if [[ -z "${expected}" ]]; then
    echo "error: no pinned SHA for '${key}' in upstream-checksums.txt" >&2
    echo "       bump the manifest before changing version.txt by hand." >&2
    exit 3
  fi
  if command -v sha256sum > /dev/null 2>&1; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  fi
  if [[ "${expected}" != "${actual}" ]]; then
    echo "error: upstream SHA mismatch for '${key}'" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    echo "  file:     ${file}" >&2
    exit 3
  fi
  echo "==> Verified upstream SHA for ${key}"
}

# ---------------------------------------------------------------------------
# Scratch directories
# ---------------------------------------------------------------------------

WORK="${SCRIPT_DIR}/build/${TARGET}"
DIST="${SCRIPT_DIR}/dist"
STAGE="${WORK}/stage"
PREFIX="${WORK}/prefix"

rm -rf "${WORK}"
mkdir -p "${WORK}" "${STAGE}/lib/pkgconfig" "${STAGE}/include" "${PREFIX}" "${DIST}"

# ---------------------------------------------------------------------------
# 1) libkrunfw: download prebuilt tarball, run its bundled make + install.
# ---------------------------------------------------------------------------

LIBKRUNFW_URL="https://github.com/containers/libkrunfw/releases/download/v${LIBKRUNFW_VERSION}/${LIBKRUNFW_ASSET}"
echo "==> Downloading libkrunfw v${LIBKRUNFW_VERSION} (${LIBKRUNFW_ASSET})"
curl --fail --silent --show-error --location \
  --output "${WORK}/${LIBKRUNFW_ASSET}" \
  "${LIBKRUNFW_URL}" \
  || { echo "error: failed to download libkrunfw from ${LIBKRUNFW_URL}" >&2; exit 3; }

verify_sha "${WORK}/${LIBKRUNFW_ASSET}" "libkrunfw/v${LIBKRUNFW_VERSION}/${LIBKRUNFW_ASSET}"

mkdir -p "${WORK}/libkrunfw"
tar -xzf "${WORK}/${LIBKRUNFW_ASSET}" -C "${WORK}/libkrunfw" --strip-components=1 \
  || { echo "error: failed to extract libkrunfw tarball" >&2; exit 3; }

# Upstream publishes two tarball shapes under different asset names:
#   - macOS `libkrunfw-prebuilt-<arch>.tgz`: source-ish tarball with a
#     Makefile that compiles kernel.c into a dylib. We run make.
#   - Linux `libkrunfw-<arch>.tgz`: fully prebuilt .so files. We just
#     install them.
# Detect by Makefile presence rather than asset name so this is robust
# to upstream renaming.
if [[ -f "${WORK}/libkrunfw/Makefile" ]]; then
  (
    cd "${WORK}/libkrunfw"
    echo "==> Building libkrunfw via its bundled Makefile"
    make -j"$(getconf _NPROCESSORS_ONLN || echo 4)" \
      || { echo "error: libkrunfw make failed" >&2; exit 3; }
    echo "==> Installing libkrunfw into ${PREFIX}"
    make PREFIX="${PREFIX}" install \
      || { echo "error: libkrunfw make install failed" >&2; exit 3; }
  )
else
  echo "==> Installing prebuilt libkrunfw binaries into ${PREFIX}"
  mkdir -p "${PREFIX}/lib64"
  shopt -s nullglob
  files=( "${WORK}/libkrunfw"/libkrunfw.* )
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    echo "error: tarball has no Makefile and no libkrunfw.* binaries" >&2
    ls -la "${WORK}/libkrunfw/" >&2
    exit 3
  fi
  cp -P "${files[@]}" "${PREFIX}/lib64/"
fi

# ---------------------------------------------------------------------------
# 2) libkrun: clone the source tag and build, pointing pkg-config at
#    the staged libkrunfw so the linker finds it.
# ---------------------------------------------------------------------------

echo "==> Cloning libkrun v${LIBKRUN_VERSION}"
curl --fail --silent --show-error --location \
  --output "${WORK}/libkrun.tar.gz" \
  "https://github.com/containers/libkrun/archive/refs/tags/v${LIBKRUN_VERSION}.tar.gz" \
  || { echo "error: failed to download libkrun source tarball" >&2; exit 3; }

verify_sha "${WORK}/libkrun.tar.gz" "libkrun/v${LIBKRUN_VERSION}/source.tar.gz"

mkdir -p "${WORK}/libkrun"
tar -xzf "${WORK}/libkrun.tar.gz" -C "${WORK}/libkrun" --strip-components=1 \
  || { echo "error: failed to extract libkrun source" >&2; exit 3; }

(
  cd "${WORK}/libkrun"
  echo "==> Building libkrun"
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64:${LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
  # NET=1 enables the `net` cargo feature, exposing krun_set_passt_fd
  # and krun_set_gvproxy_path (rootless networking; required by ward's
  # passt + gvproxy backends per igorjs/ward ADR-018).
  # BLK=1 enables the `blk` feature, exposing krun_add_virtio_block /
  # krun_add_disk for block-device-attached volumes (igorjs/ward#43).
  # Both gates are inert at runtime when the corresponding API is not
  # called; downstream consumers without these features keep working.
  make NET=1 BLK=1 -j"$(getconf _NPROCESSORS_ONLN || echo 4)" \
    || { echo "error: libkrun make failed" >&2; exit 3; }
  make NET=1 BLK=1 PREFIX="${PREFIX}" install \
    || { echo "error: libkrun make install failed" >&2; exit 3; }
)

# ---------------------------------------------------------------------------
# 3) Stage the artefacts we want in the final tarball.
# ---------------------------------------------------------------------------

# libkrunfw + libkrun .dylib/.so files. Both might be installed under
# lib/ or lib64/ depending on the upstream Makefile; copy whatever
# exists. The glob `lib*.dylib*` / `lib*.so*` covers both conventions:
#   Linux:  libkrunfw.so, libkrunfw.so.5, libkrunfw.so.5.3.0
#           (version SUFFIX after the extension)
#   macOS:  libkrun.dylib, libkrun.1.dylib, libkrun.1.18.0.dylib
#           (version INFIX between name and extension)
# A naive `libkrun.${DYLIB_EXT}*` glob only matches the Linux pattern
# and leaves the macOS versioned files behind, producing dangling
# symlinks. Anchoring with `lib*` keeps `libkrun.pc` and `libkrun.h`
# out of the result.
echo "==> Staging dylibs"
for libdir in "${PREFIX}/lib" "${PREFIX}/lib64"; do
  [[ -d "$libdir" ]] || continue
  find "$libdir" -maxdepth 1 \( -name "libkrun*.${DYLIB_EXT}*" -o -name "libkrunfw*.${DYLIB_EXT}*" \) \
    -exec cp -P {} "${STAGE}/lib/" \;
done

# Headers (only libkrun.h is what consumers need, libkrunfw is loaded
# at runtime, not directly compiled against).
cp "${PREFIX}/include/libkrun.h" "${STAGE}/include/" \
  || { echo "error: libkrun.h not found in ${PREFIX}/include" >&2; exit 3; }

# Verify we got the unversioned dylib symlinks (consumers link via -lkrun
# which resolves to libkrun.dylib / libkrun.so).
for lib in libkrun libkrunfw; do
  if ! ls "${STAGE}/lib/${lib}.${DYLIB_EXT}" > /dev/null 2>&1; then
    echo "error: missing ${STAGE}/lib/${lib}.${DYLIB_EXT} after staging" >&2
    ls -la "${STAGE}/lib/" >&2
    exit 3
  fi
done

# ---------------------------------------------------------------------------
# 4) Relocate install names so the dylibs are portable.
# ---------------------------------------------------------------------------

echo "==> Rewriting install names for relocatability"
echo "==> Stage layout before relocation:"
ls -la "${STAGE}/lib/" || true
if [[ "${TARGET}" == *darwin* ]]; then
  for lib in libkrun libkrunfw; do
    # Fully resolve the symlink chain to the actual versioned dylib.
    # Upstream libkrun lays out e.g.
    #   libkrun.dylib -> libkrun.1.dylib -> libkrun.1.18.0.dylib
    # `readlink` only follows one level; `realpath` chases the whole
    # chain. macOS's built-in realpath (BSD) is available on macOS 12+.
    sym="${STAGE}/lib/${lib}.${DYLIB_EXT}"
    if [[ ! -e "$sym" ]]; then
      echo "error: ${sym} not found after staging" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    target_file="$(realpath "$sym")"
    if [[ ! -f "$target_file" ]]; then
      echo "error: realpath of ${sym} -> ${target_file} is not a regular file" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    install_name_tool -id "@rpath/${lib}.${DYLIB_EXT}" "$target_file" || exit 4
  done
  # libkrun loads libkrunfw at runtime, rewrite its LC_LOAD_DYLIB
  # entry to @rpath too. Resolve the symlink chain to the real dylib:
  # macOS versioned names are infix (libkrun.1.dylib), so the previous
  # `libkrun.dylib.*` glob matched nothing and the rewrite silently
  # never ran (the `|| true` hid any failure as well). The verification
  # section below now asserts the result either way.
  libkrun_real="$(realpath "${STAGE}/lib/libkrun.${DYLIB_EXT}")"
  # Capture the references before rewriting: mutating the file while
  # otool's output is still being consumed is a race.
  fw_refs="$(otool -L "$libkrun_real" | awk 'NR>1 && /libkrunfw/ {print $1}')"
  while read -r ref; do
    [[ -z "$ref" || "$ref" == "@rpath/libkrunfw.${DYLIB_EXT}" ]] && continue
    install_name_tool -change "$ref" "@rpath/libkrunfw.${DYLIB_EXT}" "$libkrun_real" || exit 4
  done <<< "$fw_refs"
  # Add an @loader_path rpath to libkrun itself so its @rpath/libkrunfw
  # reference resolves next to it. Consumers still embed an rpath to
  # find libkrun, but libkrun finding libkrunfw no longer depends on
  # the consumer's rpath also covering the second hop. Guarded because
  # install_name_tool errors on a duplicate rpath entry.
  if ! otool -l "$libkrun_real" | grep -q 'path @loader_path '; then
    install_name_tool -add_rpath "@loader_path" "$libkrun_real" || exit 4
  fi
else
  # Linux: set RUNPATH = $ORIGIN so the loader looks next to the .so.
  for lib in libkrun libkrunfw; do
    # Resolve the full symlink chain to the real ELF. Upstream lays out
    # e.g. libkrun.so -> libkrun.so.1 -> libkrun.so.1.18.0 (two levels),
    # so a single-level `readlink` stops at an intermediate symlink and
    # patchelf would rewrite that instead of the actual binary. `realpath`
    # chases the whole chain (mirrors the install_name_tool step above).
    sym="${STAGE}/lib/${lib}.${DYLIB_EXT}"
    if [[ ! -e "$sym" ]]; then
      echo "error: ${sym} not found after staging" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    target_file="$(realpath "$sym")"
    if [[ ! -f "$target_file" ]]; then
      echo "error: realpath of ${sym} -> ${target_file} is not a regular file" >&2
      ls -la "${STAGE}/lib/" >&2
      exit 4
    fi
    patchelf --set-rpath '$ORIGIN' "$target_file" || exit 4
  done
fi

# ---------------------------------------------------------------------------
# 4.5) Verify relocation. A failed install_name_tool/patchelf run would
#      otherwise ship a signed, attested tarball that dlopen-fails on
#      the consumer's machine.
# ---------------------------------------------------------------------------

echo "==> Verifying relocated install names"
if [[ "${TARGET}" == *darwin* ]]; then
  for lib in libkrun libkrunfw; do
    real="$(realpath "${STAGE}/lib/${lib}.${DYLIB_EXT}")"
    id="$(otool -D "$real" | tail -1)"
    if [[ "$id" != "@rpath/${lib}.${DYLIB_EXT}" ]]; then
      echo "error: ${lib} install name is '${id}', expected '@rpath/${lib}.${DYLIB_EXT}'" >&2
      exit 4
    fi
  done
  libkrun_real="$(realpath "${STAGE}/lib/libkrun.${DYLIB_EXT}")"
  if otool -L "$libkrun_real" | awk 'NR>1 {print $1}' | grep -E '^/(Users|private|opt|home)/'; then
    echo "error: libkrun still references build-machine absolute paths (see above)" >&2
    exit 4
  fi
  if ! otool -L "$libkrun_real" | awk 'NR>1 {print $1}' | grep -q "^@rpath/libkrunfw\.${DYLIB_EXT}$"; then
    echo "error: libkrun does not reference @rpath/libkrunfw.${DYLIB_EXT}" >&2
    otool -L "$libkrun_real" >&2
    exit 4
  fi
else
  for lib in libkrun libkrunfw; do
    real="$(realpath "${STAGE}/lib/${lib}.${DYLIB_EXT}")"
    runpath="$(patchelf --print-rpath "$real")"
    if [[ "$runpath" != '$ORIGIN' ]]; then
      echo "error: ${lib} RUNPATH is '${runpath}', expected '\$ORIGIN'" >&2
      exit 4
    fi
  done
fi
echo "==> Relocation verified"

# ---------------------------------------------------------------------------
# 4.6) Smoke test: dlopen the staged libkrun and resolve a symbol.
#      Native builds only: TARGET may name a triple this host can't
#      load. libkrunfw resolves beside libkrun via @loader_path (macOS)
#      or $ORIGIN (Linux), so no loader env vars are needed, which also
#      makes this exercise the same path consumers use.
# ---------------------------------------------------------------------------

HOST_TRIPLE="$(rustc -vV | awk '/^host:/ {print $2}')"
if [[ "${TARGET}" != "${HOST_TRIPLE}" ]]; then
  echo "==> Skipping dlopen smoke test (cross-target ${TARGET} on ${HOST_TRIPLE})"
elif ! command -v python3 > /dev/null 2>&1; then
  echo "==> Skipping dlopen smoke test (python3 not available)"
else
  echo "==> dlopen smoke test"
  SMOKE_LIB="$(realpath "${STAGE}/lib/libkrun.${DYLIB_EXT}")" python3 - <<'PYEOF' || exit 5
import ctypes, os, sys
lib = ctypes.CDLL(os.environ["SMOKE_LIB"])
if not hasattr(lib, "krun_create_ctx"):
    print("error: krun_create_ctx not exported by staged libkrun", file=sys.stderr)
    sys.exit(1)
print("dlopen OK, krun_create_ctx resolved")
PYEOF
fi

# ---------------------------------------------------------------------------
# 5) Synthesise libkrun.pc, placeholder prefix rewritten by consumer.
# ---------------------------------------------------------------------------

cat > "${STAGE}/lib/pkgconfig/libkrun.pc" <<EOF
prefix=__VENDOR_PREFIX__
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libkrun
Description: Dynamic library for spawning microVMs
Version: ${LIBKRUN_VERSION}
Libs: -L\${libdir} -lkrun
Cflags: -I\${includedir}
EOF

# ---------------------------------------------------------------------------
# 6) Tar + checksum the result.
# ---------------------------------------------------------------------------

TARBALL="libkrun-${LIBKRUN_VERSION}-${TARGET}.tar.gz"
echo "==> Producing ${TARBALL}"
tar -C "${STAGE}" -czf "${DIST}/${TARBALL}" .

if command -v sha256sum > /dev/null 2>&1; then
  (cd "${DIST}" && sha256sum "${TARBALL}")
else
  (cd "${DIST}" && shasum -a 256 "${TARBALL}")
fi

echo "==> Done. Tarball at ${DIST}/${TARBALL}"
