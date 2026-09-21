#!/usr/bin/env bash
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "Configuring git submodules"
cd "${REPO_ROOT}"

# Ensure existing submodules are initialized
git submodule update --init

add_and_checkout() {
  local name="$1"
  local url="$2"
  local commit="$3"

  # The previous call left us inside the submodule it checked out.
  cd "${REPO_ROOT}"

  # Probe for a real checkout rather than asking `git submodule status`, which
  # answers about the .gitmodules entry and so reports success for a path that
  # was never cloned. Self-hosted runners also keep empty leftover directories
  # between builds, which a bare -d test would mistake for a checkout.
  # --force is needed because the path is already declared in .gitmodules.
  if [ ! -e "${REPO_ROOT}/${name}/.git" ]; then
    # `git submodule add` refuses to clone into an existing directory, so drop
    # an empty leftover first. rmdir keeps a populated directory untouched.
    rmdir "${REPO_ROOT}/${name}" 2>/dev/null || true
    echo "Adding submodule ${name}"
    git submodule add --force "${url}" "${name}"
  fi

  echo "Checking out ${name} at ${commit}"
  cd "${REPO_ROOT}/${name}"
  git fetch origin
  git checkout "${commit}"
}

add_and_checkout \
  triton \
  https://github.com/triton-lang/triton.git \
  df38505e451a1541555379bcf378be9e8c00545c

add_and_checkout \
  triton_shared \
  https://github.com/facebookincubator/triton-shared.git \
  0614763d270ec0eacba9d5d8283cdff6bedb03c8

cd "${REPO_ROOT}"
echo "Applying qcom specific patches to triton_shared"
bash "${REPO_ROOT}/ci/apply_patches.sh" || {
  echo "ERROR: Failed while applying patches"
  exit 1
}

echo "Submodules triton and triton_shared initialized and patched successfully."
