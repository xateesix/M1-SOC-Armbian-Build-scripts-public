#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Since the 2026-09 repo restructure, this script lives alongside
# build-from-source-linux.sh in the same tools/ directory (no more nested
# armbian-project / deep config path to climb out of).
M1SOC_BUILD_SCRIPT="$SCRIPT_DIR/build-from-source-linux.sh"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ ! -f "$M1SOC_BUILD_SCRIPT" ]]; then
    echo "[ERROR] Missing build script: $M1SOC_BUILD_SCRIPT"
    exit 1
fi

release_tag="${RELEASE_TAG:-}"
if [[ -z "$release_tag" ]]; then
    echo "[ERROR] RELEASE_TAG env var is required -- no default is provided." >&2
    echo "        This used to silently fall back to a stale hardcoded 'v64-...'" >&2
    echo "        default, which caused real confusion after v92-v97 were built (see" >&2
    echo "        session history 2026-09-02). Invoke as:" >&2
    echo "          RELEASE_TAG=v98-my-fix-description bash tools/run-smart-build tools/run-emmc-pack.sh" >&2
    exit 1
fi

echo "[smart-build] Running eMMC pack build"
echo "[smart-build] Workspace root: $WORKSPACE_ROOT"
echo "[smart-build] Release tag: $release_tag"

KERNEL_BTF="${KERNEL_BTF:-no}" \
bash "$M1SOC_BUILD_SCRIPT" \
    --release-tag "$release_tag"
