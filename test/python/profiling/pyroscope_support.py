# ===- pyroscope_support.py -------------------------------------------------===
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# ===------------------------------------------------------------------------===
"""Continuous-profiling support for the hexagon-mlir test suites.

Wires the Grafana Pyroscope Python SDK (``pyroscope-io``) into a pytest
session so that CPU profiles of the whole Triton -> MLIR -> Hexagon
compilation pipeline are pushed to a Pyroscope server (Grafana Cloud
Profiles or Pyroscope OSS) while the tests run.

Everything here is strictly opt-in and fail-safe:

* If ``PYROSCOPE_SERVER_ADDRESS`` is not set, profiling is silently disabled.
* If the ``pyroscope-io`` package is not installed, profiling is disabled
  with a warning (the test run itself is never affected).

Configuration is taken from environment variables so that the same code
works locally, in CI (via repository secrets), and in ad-hoc debug runs:

======================================  =========================================
Environment variable                    Meaning
======================================  =========================================
``PYROSCOPE_SERVER_ADDRESS``            Pyroscope ingest URL. For Grafana Cloud
                                        this looks like
                                        ``https://profiles-prod-XXX.grafana.net``.
``PYROSCOPE_BASIC_AUTH_USERNAME``       Grafana Cloud stack user id (numeric).
                                        Leave unset for an unauthenticated
                                        Pyroscope OSS server.
``PYROSCOPE_BASIC_AUTH_PASSWORD``       Grafana Cloud access-policy token with
                                        the ``profiles:write`` scope.
``PYROSCOPE_APPLICATION_NAME``          Overrides the application (service)
                                        name. Defaults to ``hexagon-mlir.tests``.
``PYROSCOPE_TENANT_ID``                 Only needed for self-hosted multi-tenant
                                        Pyroscope. Not needed for Grafana Cloud.
======================================  =========================================
"""

import contextlib
import os
import re
import socket
import subprocess

ENV_SERVER = "PYROSCOPE_SERVER_ADDRESS"
ENV_USERNAME = "PYROSCOPE_BASIC_AUTH_USERNAME"
ENV_PASSWORD = "PYROSCOPE_BASIC_AUTH_PASSWORD"
ENV_APP_NAME = "PYROSCOPE_APPLICATION_NAME"
ENV_TENANT_ID = "PYROSCOPE_TENANT_ID"

DEFAULT_APPLICATION_NAME = "hexagon-mlir.tests"

# Characters that interfere with Pyroscope's flameql tag-query syntax
# ({tag="value"}). Replaced rather than rejected so arbitrary pytest node ids
# can always be used as tag values.
_TAG_VALUE_UNSAFE = re.compile(r'[{}",]')


def sanitize_tag_value(value):
    """Make an arbitrary string safe to use as a Pyroscope tag value."""
    return _TAG_VALUE_UNSAFE.sub("_", str(value))


def _git_output(*args):
    try:
        result = subprocess.run(
            ["git", *args],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=os.path.dirname(os.path.abspath(__file__)),
        )
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def collect_session_tags():
    """Static tags attached to every profile of this test session.

    These are what make profiles comparable across time in Grafana:
    "did kernel X get slower to compile between commit A and commit B?"
    is answered by diffing flame graphs filtered on ``git_sha``.
    """
    tags = {
        "git_sha": _git_output("rev-parse", "--short", "HEAD") or "unknown",
        # GITHUB_HEAD_REF first: it is only set for pull_request events, where
        # GITHUB_REF_NAME is the merge ref ("42/merge") rather than the branch.
        "branch": (
            os.environ.get("GITHUB_HEAD_REF")
            or os.environ.get("GITHUB_REF_NAME")
            or _git_output("rev-parse", "--abbrev-ref", "HEAD")
            or "unknown"
        ),
        "hostname": socket.gethostname(),
    }
    github_run_id = os.environ.get("GITHUB_RUN_ID")
    if github_run_id:
        tags["ci_run_id"] = github_run_id
        tags["runner"] = "github-actions"
    else:
        tags["runner"] = "local"
    return {key: sanitize_tag_value(value) for key, value in tags.items()}


class PyroscopeSession:
    """Owns the lifecycle of the Pyroscope agent for one test session."""

    def __init__(self):
        self._pyroscope = None
        self.enabled = False
        self.disabled_reason = None
        self.application_name = None
        self.server_address = None

    def start(self, extra_tags=None):
        """Configure and start the Pyroscope agent.

        Returns True when profiling is active. Never raises: any failure
        records ``disabled_reason`` and leaves the test run untouched.
        """
        self.server_address = os.environ.get(ENV_SERVER)
        if not self.server_address:
            self.disabled_reason = f"{ENV_SERVER} is not set"
            return False

        try:
            import pyroscope
        except ImportError:
            self.disabled_reason = (
                "the 'pyroscope-io' package is not installed "
                "(pip install pyroscope-io)"
            )
            return False

        tags = collect_session_tags()
        if extra_tags:
            tags.update(
                {key: sanitize_tag_value(value) for key, value in extra_tags.items()}
            )

        self.application_name = os.environ.get(ENV_APP_NAME, DEFAULT_APPLICATION_NAME)
        configure_kwargs = {
            "application_name": self.application_name,
            "server_address": self.server_address,
            "sample_rate": 100,
            "tags": tags,
        }
        username = os.environ.get(ENV_USERNAME)
        if username:
            configure_kwargs["basic_auth_username"] = username
        password = os.environ.get(ENV_PASSWORD)
        if password:
            configure_kwargs["basic_auth_password"] = password
        tenant_id = os.environ.get(ENV_TENANT_ID)
        if tenant_id:
            configure_kwargs["tenant_id"] = tenant_id

        try:
            pyroscope.configure(**configure_kwargs)
        except Exception as exc:  # never break the test run
            self.disabled_reason = f"pyroscope.configure() failed: {exc}"
            return False

        self._pyroscope = pyroscope
        self.enabled = True
        return True

    def stop(self):
        """Flush and stop the agent (safe to call when disabled)."""
        if self._pyroscope is None:
            return
        try:
            self._pyroscope.shutdown()
        except Exception:
            pass
        self._pyroscope = None
        self.enabled = False

    def tag(self, tags):
        """Context manager that scopes extra tags to a block of work.

        Used by the pytest hooks to attach per-test tags so flame graphs can
        be sliced by test / kernel in Grafana's Tag Explorer. Returns a
        null context when profiling is disabled.
        """
        if not self.enabled:
            return contextlib.nullcontext()
        safe_tags = {
            key: sanitize_tag_value(value) for key, value in tags.items() if value
        }
        try:
            return self._pyroscope.tag_wrapper(safe_tags)
        except Exception:
            return contextlib.nullcontext()
