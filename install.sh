#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/WithAutonomi/ant-client/main/install.sh | bash

# The two C dependencies build.zig links, both vendored per target triple and
# neither committed: this script builds them into vendor/librats/ and
# vendor/fuse3/.
here="$(dirname "${BASH_SOURCE[0]}")"
bash "$here/scripts/fetch-librats.sh"
bash "$here/scripts/fetch-fuse3.sh"
