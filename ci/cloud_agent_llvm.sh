#!/usr/bin/env bash
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# Build + install LLVM/MLIR for the Cursor Cloud Agent environment.
#
# This mirrors ci/setup_llvm.sh but adapts it to the Cloud Agent VM, which has
# a fixed, comparatively small disk. Two deliberate differences from CI:
#   * CMAKE_BUILD_TYPE=Release (assertions still ON). A RelWithDebInfo build of
#     llvm;mlir;lld for four targets produces ~50 GB of debug-info binaries,
#     which does not fit. Release is functionally identical for building/testing
#     Triton and the Hexagon backend (the repo's debug workflow uses runtime
#     IR-dump env vars, not gdb symbols inside LLVM).
#   * The build tree is deleted after `ninja install`, keeping only the install
#     prefix, so the snapshot stays small and Triton links against install/.
# It also sets LLVM_APPEND_VC_REV=OFF: the Cloud Agent rewrites github.com
# remotes to embed an access token, and stamping that URL breaks the build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEXAGON_MLIR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cloud_agent_env.sh"

LLVM_TOP="${MLIR_ARTIFACTS_DIR}/llvm_triton"
LLVM_SRC="${LLVM_TOP}/llvm-project"
BUILD_DIR="${LLVM_PROJECT_BUILD_DIR}"          # ${LLVM_TOP}/build
INSTALL_DIR="${BUILD_DIR}/install"
LLVM_BUILD_TYPE="${LLVM_CMAKE_BUILD_TYPE:-Release}"
# LLVM's CMake aborts when LLVM_CCACHE_BUILD is ON but ccache is not on PATH, and
# the Cloud Agent image does not ship it; opt in only when it is available.
if command -v ccache >/dev/null 2>&1; then
  LLVM_CCACHE_BUILD="ON"
else
  LLVM_CCACHE_BUILD="OFF"
fi

# The install prefix is all that survives a build, so it is stamped with the
# commit it was produced from. Without that check a re-run after the Triton pin
# moves would keep the previous LLVM and build Triton against the wrong headers.
EXPECTED_LLVM_HASH="$(tr -d '[:space:]' < "${HEXAGON_MLIR_ROOT}/triton/cmake/llvm-hash.txt")"
INSTALLED_HASH_FILE="${INSTALL_DIR}/.llvm-hash"
echo "Expected LLVM commit hash for Triton: ${EXPECTED_LLVM_HASH}"

if [ -x "${INSTALL_DIR}/bin/mlir-opt" ]; then
  if [ "$(cat "${INSTALLED_HASH_FILE}" 2>/dev/null)" = "${EXPECTED_LLVM_HASH}" ]; then
    echo "LLVM/MLIR already installed at ${INSTALL_DIR}; skipping."
    exit 0
  fi
  echo "LLVM install at ${INSTALL_DIR} was not built from ${EXPECTED_LLVM_HASH}; rebuilding."
  rm -rf "${INSTALL_DIR}"
fi

# --- Host toolchain (clang/LLVM 13) ------------------------------------------
if [ ! -x "${HOST_TOOLCHAIN}/bin/clang" ]; then
  echo "Downloading host toolchain (clang+llvm 13.0.1)..."
  mkdir -p "${HOST_TOOLCHAIN}"
  _tc_tar="/tmp/host_toolchain.tar.xz"
  wget -q "https://github.com/llvm/llvm-project/releases/download/llvmorg-13.0.1/clang+llvm-13.0.1-x86_64-linux-gnu-ubuntu-18.04.tar.xz" -O "${_tc_tar}"
  tar -xf "${_tc_tar}" -C "${HOST_TOOLCHAIN}" --strip-components=1
  rm -f "${_tc_tar}"
fi
export CC="${HOST_TOOLCHAIN}/bin/clang"
export CXX="${HOST_TOOLCHAIN}/bin/clang++"

# --- LLVM source at the triton-pinned commit --------------------------------
if [ -d "${LLVM_SRC}/.git" ]; then
  echo "Updating existing LLVM checkout to ${EXPECTED_LLVM_HASH}"
  git -C "${LLVM_SRC}" fetch --depth 1 origin "${EXPECTED_LLVM_HASH}"
  git -C "${LLVM_SRC}" checkout --detach FETCH_HEAD
elif [ -f "${LLVM_SRC}/llvm/CMakeLists.txt" ]; then
  echo "Using existing LLVM source tree at ${LLVM_SRC} (assumed at ${EXPECTED_LLVM_HASH})."
else
  echo "Shallow-cloning LLVM at ${EXPECTED_LLVM_HASH}..."
  mkdir -p "${LLVM_SRC}"
  git -C "${LLVM_SRC}" init -q
  git -C "${LLVM_SRC}" remote add origin https://github.com/llvm/llvm-project.git
  git -C "${LLVM_SRC}" fetch --depth 1 origin "${EXPECTED_LLVM_HASH}"
  git -C "${LLVM_SRC}" checkout --detach FETCH_HEAD
fi

# --- Configure + build + install --------------------------------------------
mkdir -p "${BUILD_DIR}"
echo "Configuring LLVM (${LLVM_BUILD_TYPE}) with CMake..."
cmake -G Ninja -S "${LLVM_SRC}/llvm" -B "${BUILD_DIR}" \
    -DLLVM_ENABLE_PROJECTS="llvm;mlir;lld" \
    -DLLVM_APPEND_VC_REV=OFF \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_ASM_COMPILER="${CC}" \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_TARGETS_TO_BUILD="AMDGPU;NVPTX;X86;Hexagon" \
    -DCMAKE_BUILD_TYPE="${LLVM_BUILD_TYPE}" \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_CCACHE_BUILD="${LLVM_CCACHE_BUILD}" \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-unknown-linux-gnu \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"

echo "Building LLVM..."
ninja -C "${BUILD_DIR}" -j"$(nproc)"

echo "Installing LLVM to ${INSTALL_DIR}..."
ninja -C "${BUILD_DIR}" install
printf '%s\n' "${EXPECTED_LLVM_HASH}" > "${INSTALLED_HASH_FILE}"

# Reclaim disk: keep only the install prefix, drop the build tree + source.
echo "Pruning LLVM build tree (keeping install prefix)..."
find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 ! -name install -exec rm -rf {} +
rm -rf "${LLVM_SRC}"

echo "LLVM installed at ${INSTALL_DIR}"
"${INSTALL_DIR}/bin/mlir-opt" --version | head -3 || true
