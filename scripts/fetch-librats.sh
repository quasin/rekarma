#!/usr/bin/env bash
# Build librats from source and vendor the result into vendor/librats/.
#
# Nothing from librats is committed: vendor/librats/ is generated, ignored by
# git, and (re)created here — install.sh calls this script. Run it once after a
# clone, before `zig build`; rerun it to bump the pin.
#
# The prebuilt release archives (librats-linux-x64-*.zip) are built with the
# CMake defaults, and RATS_SEARCH_FEATURES — the whole bittorrent stack, magnet
# links included — is OFF by default: their rats_bt_* entry points are stubs
# that return RATS_ERR_NOT_ENABLED. `--magnet` needs a library that really has
# that stack, so the archive is not enough and the source build below turns the
# option on. cmake/g++/make are therefore required.
set -euo pipefail

LIBRATS_VERSION="${LIBRATS_VERSION:-3.0.2}"
URL="https://github.com/librats/librats/archive/refs/tags/${LIBRATS_VERSION}.tar.gz"
SHA256="${LIBRATS_SHA256:-4454af32d2585be892c72307468633f7465f3e79eda0ff0b0bdfe5401dbc5c3d}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor_dir="$repo_root/vendor/librats"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for tool in cmake g++ make curl tar; do
    command -v "$tool" >/dev/null || {
        echo "$tool is required to build librats from source" >&2
        exit 1
    }
done

echo "Fetching $URL"
curl -fsSL -o "$tmp_dir/librats.tar.gz" "$URL"

actual_sha="$(sha256sum "$tmp_dir/librats.tar.gz" | awk '{print $1}')"
if [ "$actual_sha" != "$SHA256" ]; then
    echo "sha256 mismatch: expected $SHA256, got $actual_sha" >&2
    exit 1
fi

tar -xzf "$tmp_dir/librats.tar.gz" -C "$tmp_dir"
src_dir="$tmp_dir/librats-${LIBRATS_VERSION}"

# Search features ON is the point of building here (magnet/bittorrent). Tests,
# the reference client and the examples are not part of the library we vendor.
cmake -S "$src_dir" -B "$tmp_dir/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DRATS_SEARCH_FEATURES=ON \
    -DRATS_STORAGE=ON \
    -DRATS_BUILD_TESTS=OFF \
    -DRATS_BUILD_CLIENT=OFF \
    -DRATS_BUILD_EXAMPLES=OFF \
    -DRATS_STATIC_LIBRARY=ON \
    -DRATS_SHARED_LIBRARY=OFF >/dev/null

cmake --build "$tmp_dir/build" -j"$(nproc)" >/dev/null

# `cmake --install` is what generates librats/util/features.h and version.h
# beside the public headers; the release archive ships neither (the old fetch
# script had to supply a hand-written features.h). A source install needs no
# shim, and the generated header records the options above.
cmake --install "$tmp_dir/build" --prefix "$tmp_dir/prefix" >/dev/null

# Replace any earlier unpack rather than merging into it, so a version bump
# cannot leave stale headers behind.
rm -rf "$vendor_dir"
mkdir -p "$vendor_dir"
cp -r "$tmp_dir/prefix/include" "$vendor_dir/include"
cp "$tmp_dir/prefix/lib/librats.a" "$vendor_dir/librats.a"

echo "Vendored librats $LIBRATS_VERSION built from source (search features ON) into $vendor_dir"
