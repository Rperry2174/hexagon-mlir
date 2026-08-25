#!/usr/bin/env bash
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# Cursor Cloud Agent `install` entry point.
#
# Reproduces the hexagon-mlir CI build (.github/workflows/build.yml) on the
# Cloud Agent VM by orchestrating the existing ci/*.sh scripts. It is
# idempotent: expensive, repo-independent artifacts (Hexagon SDK/Tools/KL,
# host toolchain, from-source LLVM/MLIR, the Python venv) live under
# MLIR_ARTIFACTS_DIR and are reused when already present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEXAGON_MLIR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${HEXAGON_MLIR_ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cloud_agent_env.sh"

echo "======================================================================"
echo " hexagon-mlir Cloud Agent setup"
echo "   repo root : ${HEXAGON_MLIR_ROOT}"
echo "   artifacts : ${MLIR_ARTIFACTS_DIR}"
echo "======================================================================"

mkdir -p "${MLIR_ARTIFACTS_DIR}"

echo ""
echo "=== [0/5] System prerequisites ==="
# Triton is built with TRITON_BUILD_WITH_CLANG_LLD=1, which drives the C/C++
# compiler with `-fuse-ld=lld`. If that compiler ever resolves to the distro
# clang (/usr/bin/clang++) it needs a matching /usr/bin/ld.lld, otherwise it
# aborts with "invalid linker name in argument '-fuse-ld=lld'". The base image
# ships clang but not lld, so install it (idempotent; only runs when missing).
if ! [ -x /usr/bin/ld.lld ]; then
  echo "Installing lld (provides /usr/bin/ld.lld)..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lld
else
  echo "lld already present (/usr/bin/ld.lld); skipping."
fi

echo ""
echo "=== [1/5] Hexagon SDK, Tools, and Kernel Library ==="
if [ ! -d "${HEXAGON_SDK_ROOT}" ] || [ ! -d "${HEXAGON_TOOLS}" ] || [ ! -d "${HEXKL_ROOT}" ]; then
  # setup_tools.sh installs into /local/mnt/workspace/MLIR_build_artifacts,
  # which matches the default MLIR_ARTIFACTS_DIR.
  chmod +x "${SCRIPT_DIR}/setup_tools.sh"
  "${SCRIPT_DIR}/setup_tools.sh"
  # Drop the downloaded archives once extracted to save disk / snapshot size.
  echo "Removing downloaded SDK/Tools/KL archives to reclaim disk..."
  rm -f "${MLIR_ARTIFACTS_DIR}"/Hexagon_SDK_lnx.zip \
        "${MLIR_ARTIFACTS_DIR}"/Hexagon_open_access.Core.*.tar.gz \
        "${MLIR_ARTIFACTS_DIR}"/Hexagon_KL/*.zip \
        "${MLIR_ARTIFACTS_DIR}"/Hexagon_KL/*.Linux-Any.zip 2>/dev/null || true
  # Re-resolve HEXKL_ROOT now that the Kernel Library has been extracted.
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/cloud_agent_env.sh"
else
  echo "Hexagon SDK/Tools/KL already present; skipping download."
fi

echo ""
echo "=== [2/5] Python virtual environment ==="
if [ ! -f "${MLIR_VENV}/bin/activate" ]; then
  echo "Creating virtual environment at ${MLIR_VENV}"
  python3 -m venv "${MLIR_VENV}"
fi
# shellcheck disable=SC1091
source "${MLIR_VENV}/bin/activate"
python3 -m pip install --upgrade pip setuptools wheel

echo ""
echo "=== [3/5] Submodules (triton, triton_shared) + patches ==="
chmod +x "${SCRIPT_DIR}/setup_submodules.sh"
"${SCRIPT_DIR}/setup_submodules.sh"

echo ""
echo "=== [3b/5] Python build/test requirements ==="
python3 -m pip install -r "${HEXAGON_MLIR_ROOT}/ci/requirements.txt"

echo ""
echo "=== [4/5] LLVM/MLIR (from source) ==="
"${SCRIPT_DIR}/cloud_agent_llvm.sh"

echo ""
echo "=== [5/5] Build Triton + Hexagon backend ==="
"${SCRIPT_DIR}/cloud_agent_build_triton.sh"

echo ""
echo "======================================================================"
echo " hexagon-mlir Cloud Agent setup complete."
echo "======================================================================"
