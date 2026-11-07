#!/usr/bin/env bash
set -euo pipefail
# Run from anywhere; resolve the repository root from examples/Multi/.
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
git -C "$REPO_ROOT" submodule update --init examples/Multi/TestZhuJiangDocs
