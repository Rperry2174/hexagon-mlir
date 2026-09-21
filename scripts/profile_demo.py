#!/usr/bin/env python3
# ===- profile_demo.py ------------------------------------------------------===
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# ===------------------------------------------------------------------------===
"""Run the Pyroscope profiling demo suite and push profiles to Grafana.

This exercises the full profiling pipeline (pytest conftest hooks ->
pyroscope-io agent -> Pyroscope server) using hardware-independent workloads,
so it works on any machine - no Hexagon SDK, device, or simulator needed.

Usage:

    export PYROSCOPE_SERVER_ADDRESS=https://profiles-prod-XXX.grafana.net
    export PYROSCOPE_BASIC_AUTH_USERNAME=<grafana-cloud-stack-user-id>
    export PYROSCOPE_BASIC_AUTH_PASSWORD=<token-with-profiles-write>
    python scripts/profile_demo.py

For a local Pyroscope OSS server (e.g. `docker run -p 4040:4040
grafana/pyroscope`), only PYROSCOPE_SERVER_ADDRESS=http://localhost:4040 is
needed.

See docs/profiling-pyroscope.md for the full profiling guide.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = REPO_ROOT / "test" / "python" / "profiling" / "demo"
DEFAULT_APP_NAME = "hexagon-mlir.tests"


def main():
    parser = argparse.ArgumentParser(
        description="Run the hexagon-mlir Pyroscope profiling demo suite."
    )
    parser.add_argument(
        "--server-address",
        default=None,
        help="Pyroscope server URL (overrides PYROSCOPE_SERVER_ADDRESS).",
    )
    parser.add_argument(
        "--application-name",
        default=None,
        help="Pyroscope application name (overrides PYROSCOPE_APPLICATION_NAME).",
    )
    parser.add_argument(
        "pytest_args",
        nargs="*",
        help="Extra arguments forwarded to pytest (e.g. -k large_trace).",
    )
    args = parser.parse_args()

    env = os.environ.copy()
    env["HEXAGON_MLIR_PROFILING_DEMO"] = "1"
    if args.server_address:
        env["PYROSCOPE_SERVER_ADDRESS"] = args.server_address
    if args.application_name:
        env["PYROSCOPE_APPLICATION_NAME"] = args.application_name

    server = env.get("PYROSCOPE_SERVER_ADDRESS")
    if not server:
        print(
            "error: PYROSCOPE_SERVER_ADDRESS is not set (and --server-address "
            "was not given).\nSet it to your Grafana Cloud Profiles URL, e.g.\n"
            "  export PYROSCOPE_SERVER_ADDRESS=https://profiles-prod-XXX.grafana.net\n"
            "  export PYROSCOPE_BASIC_AUTH_USERNAME=<stack-user-id>\n"
            "  export PYROSCOPE_BASIC_AUTH_PASSWORD=<token-with-profiles-write>",
            file=sys.stderr,
        )
        return 2

    app_name = env.get("PYROSCOPE_APPLICATION_NAME", DEFAULT_APP_NAME)
    print(f"==> Pushing profiles to {server} as application '{app_name}'")

    command = [sys.executable, "-m", "pytest", "-v", str(DEMO_DIR), *args.pytest_args]
    result = subprocess.run(command, env=env, cwd=REPO_ROOT)

    if result.returncode == 0:
        print(
            "\n==> Demo complete. Explore the profiles in Grafana:\n"
            "    Drilldown > Profiles (or the Pyroscope app), service "
            f"'{app_name}'.\n"
            "    Slice by the 'test' tag to compare workloads, e.g. the "
            "regex vs tokenizer\n"
            "    op-census implementations, or by 'git_sha' to compare "
            "commits."
        )
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
