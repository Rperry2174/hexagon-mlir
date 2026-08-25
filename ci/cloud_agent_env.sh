#!/usr/bin/env bash
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# Shared environment definition for the Cursor Cloud Agent development
# environment. Source this file to obtain a shell that can build and test
# hexagon-mlir. It is intentionally safe to source from an interactive shell:
# it does not enable `set -e` and guards every optional path.

# Resolve the repository root from this script's location.
_HEXAGON_MLIR_ENV_SELF="${BASH_SOURCE[0]:-$0}"
HEXAGON_MLIR_ROOT="$(cd "$(dirname "${_HEXAGON_MLIR_ENV_SELF}")/.." && pwd)"
export HEXAGON_MLIR_ROOT
export TRITON_ROOT="${HEXAGON_MLIR_ROOT}/triton"

# Persistent, repo-independent build artifacts. This directory is captured in
# the environment snapshot so the expensive LLVM/SDK downloads are reused.
# A home-dir default keeps it writable without root on the Cloud Agent VM;
# the CI scripts still fall back to /local/... when MLIR_ARTIFACTS_DIR is unset.
export MLIR_ARTIFACTS_DIR="${MLIR_ARTIFACTS_DIR:-${HOME}/mlir_build_artifacts}"

# Hexagon SDK / Tools / Kernel Library (downloaded by ci/setup_tools.sh).
export HEXAGON_SDK_VERSION="6.4.0.2"
export HEXAGON_SDK_ROOT="${MLIR_ARTIFACTS_DIR}/Hexagon_SDK/${HEXAGON_SDK_VERSION}"
export HEXAGON_TOOLS="${MLIR_ARTIFACTS_DIR}/Tools"
export HEXKL_ROOT="${MLIR_ARTIFACTS_DIR}/Hexagon_KL/1.0.0/hexkl_addon"
# The Kernel Library extracts to a nested path; locate hexkl_addon if the
# default guess is not present.
if [ ! -d "${HEXKL_ROOT}" ] && [ -d "${MLIR_ARTIFACTS_DIR}/Hexagon_KL" ]; then
  _hexkl_found="$(find "${MLIR_ARTIFACTS_DIR}/Hexagon_KL" -type d -name hexkl_addon 2>/dev/null | head -n 1)"
  [ -n "${_hexkl_found}" ] && export HEXKL_ROOT="${_hexkl_found}"
  unset _hexkl_found
fi

# Host toolchain (clang/LLVM 13) and the from-source LLVM/MLIR build tree.
export HOST_TOOLCHAIN="${MLIR_ARTIFACTS_DIR}/host_toolchain"
export LLVM_PROJECT_BUILD_DIR="${MLIR_ARTIFACTS_DIR}/llvm_triton/build"

# Python virtual environment holding the build/test dependencies and the
# editable triton install.
export MLIR_VENV="${MLIR_ARTIFACTS_DIR}/mlir-env"
if [ -f "${MLIR_VENV}/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "${MLIR_VENV}/bin/activate"
fi

# Triton / Hexagon backend runtime configuration (mirrors scripts/set_local_env.sh).
export HEXAGON_ARCH_VERSION="75"
export TRITON_HOME="${HEXAGON_MLIR_ROOT}"
export TRITON_PLUGIN_DIRS="${HEXAGON_MLIR_ROOT}/triton_shared;${HEXAGON_MLIR_ROOT}/qcom_hexagon_backend"

if command -v python3 >/dev/null 2>&1; then
  _py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
  if [ -n "${_py_ver}" ]; then
    _triton_build="${TRITON_ROOT}/build/cmake.linux-x86_64-cpython-${_py_ver}"
    export TRITON_SHARED_OPT_PATH="${_triton_build}/third_party/triton_shared/tools/triton-shared-opt/triton-shared-opt"
    export PATH="${_triton_build}/third_party/qcom_hexagon_backend/bin:${_triton_build}/third_party/triton_shared/tools/triton-shared-opt:${PATH}"
    unset _triton_build
  fi
  unset _py_ver
fi

export PYTHONPATH="${TRITON_ROOT}/python:${PYTHONPATH:-}"
export PATH="${HOST_TOOLCHAIN}/bin:${PATH}"

unset _HEXAGON_MLIR_ENV_SELF
