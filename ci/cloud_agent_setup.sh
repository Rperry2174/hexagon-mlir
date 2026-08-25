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
# The Cloud Agent base image ships a compiler toolchain (clang, gcc, cmake) but is
# missing several packages the from-source LLVM build, the Python venv, and Triton's
# C-extension build need. Install only the ones actually missing (idempotent):
#   * lld          - Triton is configured with TRITON_BUILD_WITH_CLANG_LLD=1, so the
#                    compiler is driven with `-fuse-ld=lld`; without a system ld.lld
#                    clang aborts with "invalid linker name in argument '-fuse-ld=lld'".
#   * python3-dev  - Triton's CMake runs find_package(Python3 Development.Module), which
#                    needs the Python headers (/usr/include/pythonX.Y/Python.h).
#   * python3-venv - `python3 -m venv` (step [2/5]) needs ensurepip, which Debian/Ubuntu
#                    ship separately in python3-venv (absent -> "ensurepip is not available").
#   * ninja-build  - cloud_agent_llvm.sh configures with `cmake -G Ninja` and Triton also
#                    builds with Ninja; without it CMake aborts (no CMAKE_MAKE_PROGRAM).
#   * ccache       - Triton builds with TRITON_BUILD_WITH_CCACHE=true and LLVM opts into
#                    ccache when present; installing it keeps rebuilds fast and consistent.
_prereq_pkgs=()
if ! [ -x /usr/bin/ld.lld ]; then
  _prereq_pkgs+=(lld)
fi
_py_header="$(python3 -c 'import os, sysconfig; print(os.path.join(sysconfig.get_path("include"), "Python.h"))' 2>/dev/null || true)"
if [ -z "${_py_header}" ] || [ ! -f "${_py_header}" ]; then
  _prereq_pkgs+=(python3-dev)
fi
# Probe the real venv capability (create a throwaway venv *with* pip) instead of
# testing a package name: Debian splits the ensurepip seed wheels into python3-venv,
# so `import ensurepip` succeeds even when `python3 -m venv` cannot.
_venv_probe="$(mktemp -d)"
if ! python3 -m venv "${_venv_probe}/probe" >/dev/null 2>&1; then
  _prereq_pkgs+=(python3-venv)
fi
rm -rf "${_venv_probe}"
if ! command -v ninja >/dev/null 2>&1; then
  _prereq_pkgs+=(ninja-build)
fi
if ! command -v ccache >/dev/null 2>&1; then
  _prereq_pkgs+=(ccache)
fi
if [ "${#_prereq_pkgs[@]}" -gt 0 ]; then
  echo "Installing system prerequisites: ${_prereq_pkgs[*]}"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${_prereq_pkgs[@]}"
else
  echo "System prerequisites already present (lld, python3-dev, python3-venv, ninja-build, ccache); skipping."
fi
unset _prereq_pkgs _py_header _venv_probe

# The pinned host toolchain (clang+llvm 13.0.1, an Ubuntu-18.04 build fetched by
# cloud_agent_llvm.sh) links against the ncurses ABI-5 library libtinfo.so.5 and
# needs its versioned symbol NCURSES_TINFO_5.0.19991023. Ubuntu 24.04 ships only
# libtinfo.so.6 (whose version node was renamed to NCURSES6_TINFO_*) and dropped
# the libtinfo5 package, so on a fresh pod clang-13 aborts at exec time -- exit
# 127, "libtinfo.so.5: cannot open shared object file" (or, with a naive .so.6
# symlink, "version `NCURSES_TINFO_5.0.19991023' not found"), which surfaces as
# CMake's "C compiler ... is broken" at the LLVM configure step. Provide the real
# ABI-5 library idempotently: prefer the distro package, else fetch the .deb from
# the Ubuntu pool (the usual path on noble) and register it with dpkg.
if ! [ -e /usr/lib/x86_64-linux-gnu/libtinfo.so.5 ] && ! [ -e /lib/x86_64-linux-gnu/libtinfo.so.5 ]; then
  echo "Providing libtinfo.so.5 (ncurses ABI 5) for the clang+llvm-13 host toolchain..."
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libtinfo5 2>/dev/null; then
    _ncurses_pool="http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/"
    _libtinfo5_deb="$(wget --no-verbose -O- "${_ncurses_pool}" 2>/dev/null \
      | grep -oE 'libtinfo5_[^"]+_amd64\.deb' | sort -uV | tail -n1)"
    if [ -z "${_libtinfo5_deb}" ]; then
      echo "ERROR: could not locate a libtinfo5 .deb under ${_ncurses_pool}" >&2
      exit 1
    fi
    echo "Fetching ${_libtinfo5_deb} from the Ubuntu pool..."
    wget --no-verbose --continue --tries=5 --timeout=60 --waitretry=10 \
      "${_ncurses_pool}${_libtinfo5_deb}" -O /tmp/libtinfo5.deb
    sudo dpkg -i /tmp/libtinfo5.deb || sudo DEBIAN_FRONTEND=noninteractive apt-get -y -f install
    rm -f /tmp/libtinfo5.deb
  fi
  sudo ldconfig
else
  echo "libtinfo.so.5 already present; skipping."
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
  # Re-source the shared env (which activates the new venv) rather than the
  # venv's `activate`: activation starts with `deactivate nondestructive`, so
  # activating a venv cloud_agent_env.sh already activated would restore the
  # pre-activation PATH and drop the host toolchain and LLVM install dirs.
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/cloud_agent_env.sh"
fi
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
