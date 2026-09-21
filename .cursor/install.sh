#!/usr/bin/env bash
#
# Cloud Agent install script for Hexagon-MLIR.
#
# This prepares everything that can be built from open sources:
#   - system build tools
#   - clang+llvm 13.0.1 host toolchain (used as CC/CXX/lld)
#   - triton + triton_shared submodules with the Qualcomm patches applied
#   - a Python virtual environment with the build requirements
#   - LLVM/MLIR built at the commit pinned by triton
#
# The Qualcomm Hexagon SDK, Hexagon Tools, and HexKL are distributed only
# through Qualcomm Software Center (login + license required) and are NOT
# fetched here by default. When they are made available (see the guard near the
# bottom), this script also builds Triton with the Hexagon backend and runs the
# LIT tests.
#
# The script is idempotent: re-running it skips work that is already complete.
#
# Out-of-tree build artifacts live under $HEX_DEPS (default: $HOME/hexagon-mlir-deps).
# The repository's own scripts write to the repo's *parent* directory; that path
# is not writable in a Cloud Agent (the repo is checked out at /workspace), so we
# use a dedicated writable directory instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HEXAGON_MLIR_ROOT="${REPO_ROOT}"
HEX_DEPS="${HEX_DEPS:-$HOME/hexagon-mlir-deps}"
mkdir -p "${HEX_DEPS}"

echo "==> Hexagon-MLIR install"
echo "    REPO_ROOT=${REPO_ROOT}"
echo "    HEX_DEPS=${HEX_DEPS}"

########################################
# 1. System packages
########################################
echo "==> Installing system packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential cmake ninja-build ccache git wget curl unzip \
  python3-dev python3-venv python3-pip clang-format

########################################
# 2. libtinfo5 (required by the clang+llvm 13.0.1 host toolchain)
#    Ubuntu 24.04 ships libtinfo6; the prebuilt clang 13 needs the versioned
#    libtinfo.so.5, so we install it from the Ubuntu archive if missing.
########################################
if ! ldconfig -p | grep -q 'libtinfo.so.5'; then
  echo "==> Installing libtinfo5"
  tmp_deb="$(mktemp -d)"
  wget -q --timeout=30 --tries=3 \
    "https://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb" \
    -O "${tmp_deb}/libtinfo5.deb"
  dpkg-deb -x "${tmp_deb}/libtinfo5.deb" "${tmp_deb}/x"
  sudo cp -a "${tmp_deb}"/x/lib/x86_64-linux-gnu/libtinfo.so.5* /usr/lib/x86_64-linux-gnu/
  sudo ldconfig
  rm -rf "${tmp_deb}"
fi

########################################
# 3. clang+llvm 13.0.1 host toolchain
########################################
export HOST_TOOLCHAIN="${HEX_DEPS}/HOST_TOOLCHAIN"
# Keyed off a stamp written after `tar` returns, not bin/clang: an interrupted
# extraction can leave an executable clang behind while lib/, the headers, or lld
# are still missing, and re-extracting over that tree is what repairs it.
if [[ ! -f "${HOST_TOOLCHAIN}/.extracted" ]]; then
  echo "==> Downloading clang+llvm 13.0.1 host toolchain"
  mkdir -p "${HOST_TOOLCHAIN}"
  ( cd "${HOST_TOOLCHAIN}"
    wget -q --timeout=30 --tries=3 "https://github.com/llvm/llvm-project/releases/download/llvmorg-13.0.1/clang+llvm-13.0.1-x86_64-linux-gnu-ubuntu-18.04.tar.xz"
    tar -xf "clang+llvm-13.0.1-x86_64-linux-gnu-ubuntu-18.04.tar.xz" --strip-components=1
    rm -f "clang+llvm-13.0.1-x86_64-linux-gnu-ubuntu-18.04.tar.xz" )
  touch "${HOST_TOOLCHAIN}/.extracted"
fi
export PATH="${HOST_TOOLCHAIN}/bin:${PATH}"
export CC="${HOST_TOOLCHAIN}/bin/clang"
export CXX="${HOST_TOOLCHAIN}/bin/clang++"

# The prebuilt clang 13 auto-selects the highest-versioned GCC toolchain it
# finds, and needs that toolchain's libstdc++.so (the -dev symlink) to link.
# Install the matching libstdc++-<ver>-dev if it is missing.
GCC_SEL="$("${CXX}" -v -E - </dev/null 2>&1 | sed -n 's#^Selected GCC installation: .*/\([0-9][0-9]*\)$#\1#p' | tail -1)"
if [[ -n "${GCC_SEL}" && ! -e "/usr/lib/gcc/x86_64-linux-gnu/${GCC_SEL}/libstdc++.so" ]]; then
  echo "==> Installing libstdc++-${GCC_SEL}-dev for clang's selected GCC toolchain"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "libstdc++-${GCC_SEL}-dev"
fi

########################################
# 4. Triton + triton_shared submodules (+ Qualcomm patches)
#    Run unconditionally: setup_submodules.sh clones only what is missing and
#    always re-runs the idempotent patch step, so a previous run that cloned but
#    failed to patch is recovered here.
########################################
echo "==> Setting up triton and triton_shared submodules"
bash "${REPO_ROOT}/ci/setup_submodules.sh"

########################################
# 5. Python virtual environment + requirements
########################################
export CONDA_ENV="${HEX_DEPS}/mlir-env"
# Keyed off bin/activate, not the directory: `python3 -m venv` creates its target
# before it finishes, so a failed run leaves a directory that cannot be sourced.
# Re-running venv over it completes the missing pieces.
if [[ ! -f "${CONDA_ENV}/bin/activate" ]]; then
  echo "==> Creating Python virtual environment"
  python3 -m venv "${CONDA_ENV}"
fi
# shellcheck disable=SC1091
source "${CONDA_ENV}/bin/activate"
python -m pip install --upgrade pip setuptools wheel
python -m pip install -r "${REPO_ROOT}/ci/hexagon-mlir-requirements.txt"

########################################
# 6. Build LLVM/MLIR at the commit pinned by triton
########################################
LLVM_SRC_DIR="${HEX_DEPS}/LLVM_DIR/llvm-project"
export LLVM_PROJECT_BUILD_DIR="${LLVM_SRC_DIR}/build"
LLVM_SHA="$(tr -d '[:space:]' < "${REPO_ROOT}/triton/cmake/llvm-hash.txt")"
LLVM_STAMP="${LLVM_PROJECT_BUILD_DIR}/install/.llvm-hash"
LLVM_INSTALLED_SHA=""
if [[ -f "${LLVM_STAMP}" ]]; then
  LLVM_INSTALLED_SHA="$(tr -d '[:space:]' < "${LLVM_STAMP}")"
fi
# Keyed off a stamp written after `cmake --install`, not the build tree: the Triton
# build below consumes install/{include,lib}, so a run interrupted before the install
# must resume, and an install left from a superseded llvm-hash.txt must be redone so
# Triton never links a stale revision.
if [[ "${LLVM_INSTALLED_SHA}" != "${LLVM_SHA}" ]]; then
  echo "==> Building LLVM/MLIR (${LLVM_SHA})"
  # LLVM_APPEND_VC_REV=OFF: Cloud Agents rewrite github URLs to embed an access
  # token (url.<token>@github.com/.insteadOf), and LLVM refuses to embed a
  # remote URL containing a password into its version string. Disabling the VC
  # revision stamp avoids inspecting the remote entirely.
  mkdir -p "${HEX_DEPS}/LLVM_DIR"
  if [[ ! -d "${LLVM_SRC_DIR}/.git" ]]; then
    git clone --filter=blob:none https://github.com/llvm/llvm-project.git "${LLVM_SRC_DIR}"
  fi
  # Fetch first: an existing clone predating an llvm-hash.txt bump does not have
  # the pinned commit yet.
  ( cd "${LLVM_SRC_DIR}" && git fetch origin && git checkout "${LLVM_SHA}" )
  cmake -G Ninja \
    -S "${LLVM_SRC_DIR}/llvm" \
    -B "${LLVM_PROJECT_BUILD_DIR}" \
    -DLLVM_ENABLE_PROJECTS="llvm;mlir;lld" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_ASM_COMPILER="${CC}" \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_TARGETS_TO_BUILD="AMDGPU;NVPTX;X86;Hexagon" \
    -DCMAKE_BUILD_TYPE="RelWithDebInfo" \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_CCACHE_BUILD:BOOL=ON \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_BUILD_EXAMPLES:BOOL=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DLLVM_USE_LINKER=lld \
    -DLLVM_PARALLEL_LINK_JOBS=4 \
    -DLLVM_APPEND_VC_REV=OFF \
    -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-unknown-linux-gnu" \
    -DCMAKE_INSTALL_PREFIX="${LLVM_PROJECT_BUILD_DIR}/install"
  cmake --build "${LLVM_PROJECT_BUILD_DIR}" -j"$(nproc)"
  cmake --install "${LLVM_PROJECT_BUILD_DIR}"
  echo "${LLVM_SHA}" > "${LLVM_STAMP}"
else
  echo "==> LLVM already built and installed at ${LLVM_SHA}; skipping"
fi

########################################
# 7. Qualcomm Hexagon SDK / Tools / HexKL (gated) + Triton backend build
#
# These three artifacts come from Qualcomm Software Center (login + license) and
# are not fetched by default. Provide them by either:
#   (a) allowlisting softwarecenter.qualcomm.com so ci/setup_tools.sh can fetch
#       them (only if anonymous download is possible), or
#   (b) placing them yourself and exporting HEXAGON_SDK_ROOT / HEXAGON_TOOLS /
#       HEXKL_ROOT before running this script.
########################################
if [[ -d "${HEXAGON_SDK_ROOT:-}" && -d "${HEXAGON_TOOLS:-}" && -d "${HEXKL_ROOT:-}" ]]; then
  echo "==> Hexagon SDK/Tools/HexKL detected; building Triton with the Hexagon backend"
  export HEXAGON_ARCH_VERSION="${HEXAGON_ARCH_VERSION:-75}"
  export TRITON_ROOT="${REPO_ROOT}/triton"
  PYTHON_VERSION="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  export TRITON_SHARED_OPT_PATH="${TRITON_ROOT}/build/cmake.linux-x86_64-cpython-${PYTHON_VERSION}/third_party/triton_shared/tools/triton-shared-opt/triton-shared-opt"
  export TRITON_HOME="${REPO_ROOT}"
  export TRITON_PLUGIN_DIRS="${REPO_ROOT}/triton_shared;${REPO_ROOT}/qcom_hexagon_backend"
  ( cd "${TRITON_ROOT}"
    TRITON_BUILD_WITH_CLANG_LLD=1 \
    TRITON_BUILD_WITH_CCACHE=true \
    LLVM_INCLUDE_DIRS="${LLVM_PROJECT_BUILD_DIR}/install/include" \
    LLVM_LIBRARY_DIR="${LLVM_PROJECT_BUILD_DIR}/install/lib" \
    LLVM_SYSPATH="${LLVM_PROJECT_BUILD_DIR}/install" \
    pip install -e . --no-build-isolation --verbose )
  echo "==> Running qcom_hexagon_backend LIT tests"
  lit "${TRITON_ROOT}/build/cmake.linux-x86_64-cpython-${PYTHON_VERSION}/third_party/qcom_hexagon_backend/test/" --verbose
else
  echo "==> SKIPPING Triton/Hexagon backend build:"
  echo "    Hexagon SDK/Tools/HexKL not available."
  echo "    Point HEXAGON_SDK_ROOT, HEXAGON_TOOLS, and HEXKL_ROOT at the extracted"
  echo "    directories (see comments above) to enable the full build. Everything"
  echo "    else (LLVM/MLIR, host toolchain, submodules, Python env) is ready."
fi

echo "==> Hexagon-MLIR install complete"
