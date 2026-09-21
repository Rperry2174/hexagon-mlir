#!/usr/bin/env bash 
# 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
set -euo pipefail
set -x
HEXAGON_MLIR_ROOT="$(git rev-parse --show-toplevel)"
export HEXAGON_MLIR_ROOT
export TRITON_ROOT=$HEXAGON_MLIR_ROOT/triton

# Set by the "Setup LLVM for Triton" workflow step, or by
# scripts/build_hexagon_mlir.sh for a local build. Without it the install
# prefix below silently resolves to /install.
: "${LLVM_PROJECT_BUILD_DIR:?set LLVM_PROJECT_BUILD_DIR to the LLVM build directory (see ci/setup_llvm.sh)}"
export LLVM_INSTALL_DIR=$LLVM_PROJECT_BUILD_DIR/install

source "${HEXAGON_MLIR_ROOT}/ci/setup_triton_env.sh"

pip install --upgrade pip setuptools wheel

# Build Triton using upstream LLVM
cd "$TRITON_ROOT"
echo Building triton

if ! TRITON_BUILD_WITH_CLANG_LLD=1 \
    TRITON_BUILD_WITH_CCACHE=true \
    LLVM_INCLUDE_DIRS=$LLVM_INSTALL_DIR/include \
    LLVM_LIBRARY_DIR=$LLVM_INSTALL_DIR/lib \
    LLVM_SYSPATH=$LLVM_INSTALL_DIR \
    pip install -e . --no-build-isolation --verbose; then
    echo Building hexagon-mlir failed
    exit 1
fi
echo hexagon-mlir successfully built

cd "$HEXAGON_MLIR_ROOT"

set +x
