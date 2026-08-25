#!/usr/bin/env bash
#
# Source this file to load the Hexagon-MLIR build/run environment in a shell:
#     source .cursor/activate_env.sh
#
# It mirrors scripts/set_local_env.sh but points at the writable out-of-tree
# dependency directory used by .cursor/install.sh ($HEX_DEPS) instead of the
# repository's parent directory (which is not writable in a Cloud Agent).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HEXAGON_MLIR_ROOT="${REPO_ROOT}"
HEX_DEPS="${HEX_DEPS:-$HOME/hexagon-mlir-deps}"

export HOST_TOOLCHAIN="${HEX_DEPS}/HOST_TOOLCHAIN"
export CC="${HOST_TOOLCHAIN}/bin/clang"
export CXX="${HOST_TOOLCHAIN}/bin/clang++"
export CONDA_ENV="${HEX_DEPS}/mlir-env"
export LLVM_PROJECT_BUILD_DIR="${HEX_DEPS}/LLVM_DIR/llvm-project/build"

export TRITON_ROOT="${REPO_ROOT}/triton"
export TRITON_HOME="${REPO_ROOT}"
export TRITON_PLUGIN_DIRS="${REPO_ROOT}/triton_shared;${REPO_ROOT}/qcom_hexagon_backend"
export HEXAGON_ARCH_VERSION="${HEXAGON_ARCH_VERSION:-75}"

# Qualcomm Hexagon SDK/Tools/HexKL (set these to your extracted locations).
# Only exported when actually provided: the backend CMake uses
# `DEFINED ENV{...}`, which is true for an exported empty value and would skip
# its "not set" fatal errors.
if [[ -n "${HEXAGON_SDK_ROOT:-}" ]]; then export HEXAGON_SDK_ROOT; fi
if [[ -n "${HEXAGON_TOOLS:-}" ]]; then export HEXAGON_TOOLS; fi
if [[ -n "${HEXKL_ROOT:-}" ]]; then export HEXKL_ROOT; fi

if [[ -d "${CONDA_ENV}" ]]; then
  # shellcheck disable=SC1091
  source "${CONDA_ENV}/bin/activate"
fi

PYTHON_VERSION="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo 3.12)"
TRITON_BUILD="${TRITON_ROOT}/build/cmake.linux-x86_64-cpython-${PYTHON_VERSION}"
export TRITON_SHARED_OPT_PATH="${TRITON_BUILD}/third_party/triton_shared/tools/triton-shared-opt/triton-shared-opt"
export PATH="${TRITON_BUILD}/third_party/qcom_hexagon_backend/bin/:${TRITON_BUILD}/third_party/triton_shared/tools/triton-shared-opt:${HOST_TOOLCHAIN}/bin:${PATH}"
export PYTHONPATH="${TRITON_ROOT}/python:${PYTHONPATH:-}"
