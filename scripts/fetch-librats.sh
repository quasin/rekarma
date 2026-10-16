#!/usr/bin/env bash
# Fetch and unpack the prebuilt librats release into vendor/librats/.
#
# Nothing from librats is committed: vendor/librats/ is generated, ignored by
# git, and (re)created here — install.sh calls this script. Run it once after a
# clone, before `zig build`.
set -euo pipefail

LIBRATS_VERSION="${LIBRATS_VERSION:-3.0.0}"
LIBRATS_ARCH="${LIBRATS_ARCH:-linux-x64}"
URL="https://github.com/librats/librats/releases/download/${LIBRATS_VERSION}/librats-${LIBRATS_ARCH}-${LIBRATS_VERSION}.zip"
SHA256="${LIBRATS_SHA256:-84fd5cb4017c557c72e8c5c087c94b31e9a8f75188c2448cafe3da505b444931}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor_dir="$repo_root/vendor/librats"
shim="$repo_root/scripts/librats/features.h"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Fetching $URL"
curl -fsSL -o "$tmp_dir/librats.zip" "$URL"

actual_sha="$(sha256sum "$tmp_dir/librats.zip" | awk '{print $1}')"
if [ "$actual_sha" != "$SHA256" ]; then
    echo "sha256 mismatch: expected $SHA256, got $actual_sha" >&2
    exit 1
fi

# unzip is not guaranteed to be installed; python3 is a Zig-free baseline.
python3 - "$tmp_dir/librats.zip" "$tmp_dir/extracted" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY

archive_root="$tmp_dir/extracted/${LIBRATS_ARCH%%-*}"

# Replace any earlier unpack rather than merging into it, so a version bump
# cannot leave stale headers behind.
rm -rf "$vendor_dir"
mkdir -p "$vendor_dir/include"
cp -r "$archive_root/include/." "$vendor_dir/include/"
cp "$archive_root/librats.a" "$vendor_dir/librats.a"

# The archive does not ship the generated librats/util/features.h that every
# public header includes (see the shim's own comment): install our replacement.
mkdir -p "$vendor_dir/include/librats/util"
cp "$shim" "$vendor_dir/include/librats/util/features.h"

echo "Vendored librats $LIBRATS_VERSION ($LIBRATS_ARCH) into $vendor_dir"
