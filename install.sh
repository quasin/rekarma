#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/WithAutonomi/ant-client/main/install.sh | bash

# Prebuilt librats release that build.zig links. Not committed: this script
# downloads it into vendor/librats/.
bash "$(dirname "${BASH_SOURCE[0]}")/scripts/fetch-librats.sh"
