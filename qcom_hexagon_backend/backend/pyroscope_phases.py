# ===- pyroscope_phases.py --------------------------------------------------===
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# ===------------------------------------------------------------------------===
"""Optional Grafana Pyroscope phase tags for the Hexagon backend.

When the hosting process (typically a pytest session, see
``test/python/conftest.py``) runs with the Pyroscope Python agent active,
:func:`profile_phase` scopes a ``phase`` tag around the major stages of the
Triton -> MLIR -> Hexagon pipeline. Flame graphs in Grafana can then be
sliced by phase (e.g. ``compile.obj`` vs ``launch.execute``) instead of
showing one undifferentiated blob per test.

This module is deliberately dependency-free and fail-safe:

* If ``PYROSCOPE_SERVER_ADDRESS`` is not set, or ``pyroscope-io`` is not
  installed, :func:`profile_phase` is a zero-cost no-op.
* Tagging errors are swallowed; profiling must never affect compilation.
"""

import contextlib
import os
import re

_TAG_VALUE_UNSAFE = re.compile(r'[{}",]')


def _sanitize(value):
    return _TAG_VALUE_UNSAFE.sub("_", str(value))


def _get_pyroscope():
    """Return the pyroscope module when profiling is plausibly active."""
    if not os.environ.get("PYROSCOPE_SERVER_ADDRESS"):
        return None
    try:
        import pyroscope
    except ImportError:
        return None
    return pyroscope


@contextlib.contextmanager
def profile_phase(phase, **tags):
    """Scope a Pyroscope ``phase`` tag (plus optional extra tags) to a block.

    Usage::

        with profile_phase("compile.obj", kernel=func_name):
            ...
    """
    pyroscope = _get_pyroscope()
    tag_context = None
    if pyroscope is not None:
        tag_values = {"phase": _sanitize(phase)}
        tag_values.update(
            {key: _sanitize(value) for key, value in tags.items() if value}
        )
        try:
            tag_context = pyroscope.tag_wrapper(tag_values)
            tag_context.__enter__()
        except Exception:
            tag_context = None
    try:
        yield
    finally:
        if tag_context is not None:
            try:
                tag_context.__exit__(None, None, None)
            except Exception:
                pass
