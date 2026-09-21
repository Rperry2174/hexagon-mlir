#!/usr/bin/env bash 
# 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# Sourced by ci/build_triton.sh and scripts/build_triton.sh. It deliberately
# does not touch shell options: the trailing `set +x` it used to carry turned
# off the caller's tracing for the rest of the build.

HEXAGON_MLIR_ROOT="$(git rev-parse --show-toplevel)"
export HEXAGON_MLIR_ROOT
export TRITON_ROOT=$HEXAGON_MLIR_ROOT/triton

# Get the Python version
PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

# Triton shared path
export TRITON_SHARED_OPT_PATH=$TRITON_ROOT/build/cmake.linux-x86_64-cpython-${PYTHON_VERSION}/third_party/triton_shared/tools/triton-shared-opt/triton-shared-opt

# Provided by the caller (the "Install Tools and Dependencies" workflow step,
# or scripts/build_hexagon_mlir.sh locally). Re-exporting them unchecked used to
# turn an unset value into an empty path and fail deep inside the build.
: "${HEXAGON_SDK_ROOT:?set HEXAGON_SDK_ROOT to the Hexagon SDK (see ci/setup_tools.sh)}"
: "${HEXAGON_TOOLS:?set HEXAGON_TOOLS to the Hexagon tools directory (see ci/setup_tools.sh)}"
: "${HEXKL_ROOT:?set HEXKL_ROOT to the Hexagon KL addon (see ci/setup_tools.sh)}"
export HEXAGON_SDK_ROOT HEXAGON_TOOLS HEXKL_ROOT
export HEXAGON_ARCH_VERSION=75
export TRITON_HOME=$HEXAGON_MLIR_ROOT
export TRITON_PLUGIN_DIRS="$HEXAGON_MLIR_ROOT/triton_shared;$HEXAGON_MLIR_ROOT/qcom_hexagon_backend"
export PATH=$TRITON_ROOT/build/cmake.linux-x86_64-cpython-${PYTHON_VERSION}/third_party/qcom_hexagon_backend/bin/:$TRITON_ROOT/build/cmake.linux-x86_64-cpython-${PYTHON_VERSION}/third_party/triton_shared/tools/triton-shared-opt:$PATH
# Guard the expansion: with PYTHONPATH unset this produced a trailing ':',
# which python reads as "also import from the current directory".
export PYTHONPATH=$TRITON_ROOT/python${PYTHONPATH:+:$PYTHONPATH}

# Add host toolchain to PATH
export PATH="${HOST_TOOLCHAIN:+${HOST_TOOLCHAIN}/bin:}${PATH}"

