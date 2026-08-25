# ===- test_profiling_demo.py -----------------------------------------------===
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause.
# For more license information:
#   https://github.com/qualcomm/hexagon-mlir/LICENSE.txt
#
# ===------------------------------------------------------------------------===
"""Pyroscope profiling demo workloads.

These tests exercise real, hardware-independent Python code paths of the
repository (LWP profile post-processing and an op census over the MLIR
regression corpus) with enough CPU work for the Pyroscope sampler to build
meaningful flame graphs. They validate the profiling pipeline end to end
without requiring the Hexagon SDK, a device, or the simulator.

They are excluded from normal test runs; enable them with::

    HEXAGON_MLIR_PROFILING_DEMO=1 pytest -v test/python/profiling/demo

or via the convenience runner ``scripts/profile_demo.py``, which also prints
where to find the resulting profiles in Grafana.
"""

import importlib.util
import json
import os
import random
import re
from collections import Counter
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("HEXAGON_MLIR_PROFILING_DEMO") != "1",
    reason="profiling demo workloads (set HEXAGON_MLIR_PROFILING_DEMO=1 to run)",
)

_REPO_ROOT = Path(__file__).resolve().parents[4]
_PROCESS_LWP_PATH = _REPO_ROOT / "test" / "python" / "process_lwp.py"
_MLIR_CORPUS_DIR = _REPO_ROOT / "qcom_hexagon_backend" / "test"


def _load_process_lwp():
    spec = importlib.util.spec_from_file_location(
        "hexagon_mlir_process_lwp", _PROCESS_LWP_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# -----------------------------------------------------------------------------
# Workload 1: LWP (Loop Watch Point) post-processing at scale.
#
# Reuses the real post-processing code from test/python/process_lwp.py on a
# synthetic-but-well-formed trace: a triple-nested loop structure like the
# ones emitted by --hexagon-lwp-instrumentation on device.
# -----------------------------------------------------------------------------

_LWP_OPS_BY_LOOP = {
    1: ["scf.for"],
    2: ["linalg.matmul", "linalg.generic"],
    3: ["linalg.elemwise_binary", "arith.addf"],
    4: ["vector.transfer_read", "vector.transfer_write"],
}


def _generate_lwp_trace(tmp_path, outer_iterations):
    """Emit an LWP JSON trace + infodump file mimicking device output."""
    rng = random.Random(20260825)
    entries = []
    cyc = 0
    for _ in range(outer_iterations):
        entries.append({"id": 1, "cyc": cyc})
        for inner_id in (2, 3, 4):
            cyc += rng.randint(10, 50)
            entries.append({"id": inner_id, "cyc": cyc})
            cyc += rng.randint(100, 2000)
            entries.append({"id": inner_id, "cyc": cyc})
        cyc += rng.randint(10, 50)
        entries.append({"id": 1, "cyc": cyc})
        cyc += rng.randint(10, 50)

    json_path = tmp_path / "lwp.json"
    json_path.write_text(json.dumps({"entries": entries}))

    dump_lines = [
        f"Location {loop_id * 10}, {loop_id * 10 + 2} corresponds to ID {loop_id}"
        f" | Collected ops: {', '.join(ops)}"
        for loop_id, ops in _LWP_OPS_BY_LOOP.items()
    ]
    dump_path = tmp_path / "lwp_infodump.txt"
    dump_path.write_text("\n".join(dump_lines) + "\n")
    return json_path, dump_path


@pytest.mark.parametrize(
    "outer_iterations,repeats",
    [(20_000, 4), (100_000, 8)],
    ids=["small_trace", "large_trace"],
)
def test_lwp_postprocessing(tmp_path, outer_iterations, repeats):
    process_lwp = _load_process_lwp()
    json_path, dump_path = _generate_lwp_trace(tmp_path, outer_iterations)

    summary = None
    # Repeat the parse/aggregate cycle so the profiler has a sustained,
    # realistic workload (each pass re-reads and re-aggregates the trace,
    # exactly what happens across many kernel runs).
    for _ in range(repeats):
        summary = process_lwp.process_json(str(json_path))
    id_to_location, id_to_ops = process_lwp.process_dump_file(str(dump_path))
    process_lwp.write_to_csv(summary, id_to_location, id_to_ops)

    assert summary[1]["iter_count"] == outer_iterations
    assert summary[2]["parent_id"] == 1
    assert id_to_ops[2] == ["linalg.matmul", "linalg.generic"]
    assert Path("/tmp/lwp_output.csv").exists()


# -----------------------------------------------------------------------------
# Workload 2: op census over the MLIR regression corpus.
#
# Scans every .mlir file under qcom_hexagon_backend/test and counts operation
# occurrences per dialect, with two competing implementations (regex vs
# character tokenizer). In Grafana's Tag Explorer the two tests appear as
# separate `test` tags, so their flame graphs can be diffed directly - the
# canonical "which implementation is hotter, and why" workflow.
# -----------------------------------------------------------------------------

_OP_PATTERN = re.compile(r"\b([a-z_][a-z0-9_]*)\.([a-z0-9_.]+)")


def _corpus_files():
    files = sorted(_MLIR_CORPUS_DIR.rglob("*.mlir"))
    assert len(files) > 50, f"unexpectedly small MLIR corpus under {_MLIR_CORPUS_DIR}"
    return files


def _census_with_regex(texts):
    dialect_counts = Counter()
    op_counts = Counter()
    for text in texts:
        for match in _OP_PATTERN.finditer(text):
            dialect_counts[match.group(1)] += 1
            op_counts[match.group(0)] += 1
    return dialect_counts, op_counts


def _census_with_tokenizer(texts):
    dialect_counts = Counter()
    op_counts = Counter()
    for text in texts:
        for raw_line in text.splitlines():
            line = raw_line.split("//", 1)[0]
            for token in line.replace("(", " ").replace("<", " ").split():
                head, dot, tail = token.partition(".")
                if not dot or not tail:
                    continue
                if not head or not (head[0].isalpha() or head[0] == "_"):
                    continue
                if not all(c.isalnum() or c in "._" for c in head + tail):
                    continue
                dialect_counts[head] += 1
                op_counts[f"{head}.{tail}"] += 1
    return dialect_counts, op_counts


@pytest.mark.parametrize(
    "census",
    [_census_with_regex, _census_with_tokenizer],
    ids=["regex", "tokenizer"],
)
def test_mlir_corpus_op_census(census):
    texts = [path.read_text(errors="replace") for path in _corpus_files()]

    dialect_counts, op_counts = None, None
    for _ in range(40):
        dialect_counts, op_counts = census(texts)

    # Both implementations must at least agree on the corpus fundamentals.
    assert dialect_counts["func"] > 0
    assert dialect_counts["linalg"] > 0
    assert len(op_counts) > 50
