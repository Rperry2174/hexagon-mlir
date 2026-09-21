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
export HEXAGON_MLIR_ROOT=$HEXAGON_MLIR_ROOT

echo "=== Upgrading pip tooling ==="
pip install --upgrade pip setuptools wheel

echo "=== Installing triton and torch-mlir build requirements ==="
pip install -r ${HEXAGON_MLIR_ROOT}/ci/requirements.txt

# Same environment the CI build uses, so the two cannot drift apart.
source "${HEXAGON_MLIR_ROOT}/ci/setup_triton_env.sh"

# Set by scripts/build_hexagon_mlir.sh, or by the workflow's LLVM step.
: "${LLVM_PROJECT_BUILD_DIR:?set LLVM_PROJECT_BUILD_DIR to the LLVM build directory (see ci/setup_llvm.sh)}"
# ci/setup_llvm.sh and build_hexagon_mlir.sh both install LLVM into
# <build>/install; point Triton at the install tree, not the raw build tree.
export LLVM_INSTALL_DIR="$LLVM_PROJECT_BUILD_DIR/install"

echo "=== Building triton ==="
cd "$TRITON_ROOT"

if ! TRITON_BUILD_WITH_CLANG_LLD=1 \
    TRITON_BUILD_WITH_CCACHE=true \
    LLVM_INCLUDE_DIRS="$LLVM_INSTALL_DIR/include" \
    LLVM_LIBRARY_DIR="$LLVM_INSTALL_DIR/lib" \
    LLVM_SYSPATH="$LLVM_INSTALL_DIR" \
    pip install -e . --no-build-isolation --verbose; then
    echo "Triton build failed"
    exit 1
fi

echo "Triton build completed successfully."
cd "$HEXAGON_MLIR_ROOT"

set +x
