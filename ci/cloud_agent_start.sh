#!/usr/bin/env bash
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# Cursor Cloud Agent `start` entry point. Runs on every boot.
#
# Heavy, cacheable work (LLVM/SDK/venv) is produced by ci/cloud_agent_setup.sh
# and captured in the environment snapshot. This script only performs cheap,
# per-boot reconciliation:
#   1. Wire the shared environment into interactive shells (~/.bashrc).
#   2. Rebuild only the Triton editable install if it is missing (e.g. if the
#      workspace checkout dropped the untracked build tree).
#   3. Print a readiness summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/cloud_agent_env.sh"

# 1. Make sure every interactive shell sources the environment.
BASHRC="${HOME}/.bashrc"
MARKER="# >>> hexagon-mlir cloud agent env >>>"
if ! grep -qF "${MARKER}" "${BASHRC}" 2>/dev/null; then
  {
    echo ""
    echo "${MARKER}"
    echo "[ -f \"${ENV_FILE}\" ] && source \"${ENV_FILE}\""
    echo "# <<< hexagon-mlir cloud agent env <<<"
  } >> "${BASHRC}"
fi

# shellcheck disable=SC1091
source "${ENV_FILE}"

# 2. Rebuild the Triton editable install if the snapshot's build tree did not
#    survive (guarded so this is normally a no-op fast path).
MLIR_OPT="${LLVM_PROJECT_BUILD_DIR}/install/bin/mlir-opt"
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo '')"
BACKEND_DIR="${TRITON_ROOT}/build/cmake.linux-x86_64-cpython-${PY_VER}/third_party/qcom_hexagon_backend"
if [ -x "${MLIR_OPT}" ] && [ -n "${PY_VER}" ] && [ ! -d "${BACKEND_DIR}" ]; then
  echo "Triton build tree missing; rebuilding (LLVM is cached, this is incremental)..."
  if [ ! -d "${TRITON_ROOT}" ] || [ ! -d "${HEXAGON_MLIR_ROOT}/triton_shared" ]; then
    # ci/setup_submodules.sh is not executable in-repo.
    bash "${SCRIPT_DIR}/setup_submodules.sh"
  fi
  "${SCRIPT_DIR}/cloud_agent_build_triton.sh"
fi

# 3. Readiness summary.
echo "hexagon-mlir environment ready."
echo "  artifacts : ${MLIR_ARTIFACTS_DIR}"
echo "  mlir-opt  : $([ -x "${MLIR_OPT}" ] && echo "${MLIR_OPT}" || echo 'not found')"
echo "  triton    : $(python3 -c 'import triton,sys; sys.stdout.write(getattr(triton,"__version__","unknown"))' 2>/dev/null || echo 'not importable')"
