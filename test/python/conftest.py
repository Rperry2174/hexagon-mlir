# ===- conftest.py ----------------------------------------------------------===
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# ===------------------------------------------------------------------------===
"""Session-wide pytest hooks for the hexagon-mlir Python test suites.

Currently this wires Grafana Pyroscope continuous profiling into every
pytest run under ``test/python`` (triton, torch-mlir, mlir, profiling demo).

Profiling is opt-in via environment variables (see
``profiling/pyroscope_support.py`` and ``docs/profiling-pyroscope.md``); when
they are absent this conftest is a no-op and the suites behave exactly as
before.
"""

import importlib.util
import warnings
from pathlib import Path

import pytest

_TEST_PYTHON_DIR = Path(__file__).resolve().parent


def _load_pyroscope_support():
    # Loaded by file path rather than package import so the hooks work no
    # matter how pytest resolves the test/python package layout.
    support_path = _TEST_PYTHON_DIR / "profiling" / "pyroscope_support.py"
    spec = importlib.util.spec_from_file_location(
        "hexagon_mlir_pyroscope_support", support_path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_pyroscope_support = _load_pyroscope_support()
_profiling_session = _pyroscope_support.PyroscopeSession()


def _suite_for(item):
    """Suite tag: first path component under test/python (triton, mlir, ...)."""
    try:
        relative = Path(str(item.fspath)).resolve().relative_to(_TEST_PYTHON_DIR)
        return relative.parts[0] if len(relative.parts) > 1 else "python"
    except ValueError:
        return "external"


def pytest_configure(config):
    started = _profiling_session.start()
    if not started and _profiling_session.disabled_reason:
        # Only warn when someone clearly intended to profile but the setup
        # is incomplete; stay silent when profiling was never requested.
        if not _profiling_session.disabled_reason.endswith("is not set"):
            warnings.warn(
                "Pyroscope profiling disabled: "
                f"{_profiling_session.disabled_reason}",
                stacklevel=1,
            )


def pytest_report_header(config):
    if _profiling_session.enabled:
        return (
            "pyroscope profiling: enabled "
            f"(application={_profiling_session.application_name}, "
            f"server={_profiling_session.server_address})"
        )
    return f"pyroscope profiling: disabled ({_profiling_session.disabled_reason})"


def pytest_unconfigure(config):
    _profiling_session.stop()


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_call(item):
    # Scope per-test tags around the test body so flame graphs can be sliced
    # by individual test / kernel in Grafana's Tag Explorer.
    tags = {
        "suite": _suite_for(item),
        "test_file": Path(str(item.fspath)).stem,
        "test": item.nodeid,
    }
    with _profiling_session.tag(tags):
        yield
