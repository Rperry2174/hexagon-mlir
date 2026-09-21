#!/usr/bin/env bash
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# Build Triton together with the qcom_hexagon_backend plugin against the
# from-source LLVM/MLIR install. Unlike ci/build_triton.sh this wrapper
# propagates build failures and verifies the produced backend, so it is safe
# to use as an idempotent (re)build step.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cloud_agent_env.sh"
# cloud_agent_env.sh already activates the venv. Do not re-activate it here: that
# restores the pre-activation PATH, dropping the host toolchain and LLVM install
# directories that clang/lld are found through.

LLVM_INSTALL_DIR="${LLVM_PROJECT_BUILD_DIR}/install"
if [ ! -x "${LLVM_INSTALL_DIR}/bin/mlir-opt" ]; then
  echo "ERROR: LLVM/MLIR install not found at ${LLVM_INSTALL_DIR}" >&2
  exit 1
fi

python3 -m pip install --upgrade pip setuptools wheel

echo "Building Triton (+ qcom_hexagon_backend) against ${LLVM_INSTALL_DIR}"
cd "${TRITON_ROOT}"
TRITON_BUILD_WITH_CLANG_LLD=1 \
  TRITON_BUILD_WITH_CCACHE=true \
  LLVM_INCLUDE_DIRS="${LLVM_INSTALL_DIR}/include" \
  LLVM_LIBRARY_DIR="${LLVM_INSTALL_DIR}/lib" \
  LLVM_SYSPATH="${LLVM_INSTALL_DIR}" \
  python3 -m pip install -e . --no-build-isolation --verbose

PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
BACKEND_DIR="${TRITON_ROOT}/build/cmake.linux-x86_64-cpython-${PY_VER}/third_party/qcom_hexagon_backend"
if [ ! -d "${BACKEND_DIR}" ]; then
  echo "ERROR: qcom_hexagon_backend build output missing at ${BACKEND_DIR}" >&2
  exit 1
fi

python3 -c "import triton; print('triton', getattr(triton, '__version__', 'unknown'), 'imported OK')"
echo "Triton + Hexagon backend build verified."
