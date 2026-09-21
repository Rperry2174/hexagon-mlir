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
_PYROSCOPE_PHASES_PATH = (
    _REPO_ROOT / "qcom_hexagon_backend" / "backend" / "pyroscope_phases.py"
)


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_process_lwp():
    return _load_module("hexagon_mlir_process_lwp", _PROCESS_LWP_PATH)


# The same phase-tagging helper the Hexagon backend uses; loaded by file path
# because the backend package is only importable inside a Triton install.
_phases = _load_module("hexagon_mlir_pyroscope_phases", _PYROSCOPE_PHASES_PATH)


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
    [(20_000, 60), (100_000, 45)],
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
    for _ in range(800):
        dialect_counts, op_counts = census(texts)

    # Both implementations must at least agree on the corpus fundamentals.
    assert dialect_counts["func"] > 0
    assert dialect_counts["linalg"] > 0
    assert len(op_counts) > 50


# -----------------------------------------------------------------------------
# Workload 3: miniature compiler pipeline with pipeline-phase tags.
#
# A text-level parse -> analyze -> transform -> emit pipeline over the real
# MLIR corpus, with each stage wrapped in the same profile_phase() helper the
# Hexagon backend uses (pyroscope_phases.py). This exercises phase tagging
# inside a pytest session and makes flame graphs sliceable by pipeline stage,
# exactly like compile.* / launch.* on a real kernel run.
#
# The transform stage (SSA value renumbering) is parametrized with a fast and
# a deliberately naive implementation. In Grafana, diffing
#   {test=".../test_mini_pipeline[fast]"}  vs  {test=".../test_mini_pipeline[naive]"}
# in the "Diff flame graph" view pinpoints _rename_ssa_naive as the
# regression - the workflow used to catch a real slowdown between commits.
# -----------------------------------------------------------------------------

_SSA_TOKEN = re.compile(r"%[A-Za-z0-9_]+")


def _parse_module(text):
    """Parse a module's text into a flat list of op records."""
    ops = []
    for line_no, raw_line in enumerate(text.splitlines()):
        line = raw_line.split("//", 1)[0].strip()
        if not line:
            continue
        match = _OP_PATTERN.search(line)
        if match is None:
            continue
        values = _SSA_TOKEN.findall(line)
        equals = line.find("=")
        results = [v for v in values if equals != -1 and line.find(v) < equals]
        operands = [v for v in values if v not in results]
        ops.append(
            {
                "op": match.group(0),
                "dialect": match.group(1),
                "results": results,
                "operands": operands,
                "line_no": line_no,
            }
        )
    return ops


def _analyze_fusable_pairs(ops):
    """Count producer/consumer pairs of linalg ops (naive fusion candidates)."""
    producer_by_value = {}
    for index, op in enumerate(ops):
        for value in op["results"]:
            producer_by_value[value] = index
    fusable = 0
    for op in ops:
        if not op["op"].startswith("linalg."):
            continue
        for value in op["operands"]:
            producer = producer_by_value.get(value)
            if producer is not None and ops[producer]["op"].startswith("linalg."):
                fusable += 1
    return fusable


def _ssa_rename_map(text):
    """Map every SSA value to %ssa<N> in first-occurrence order."""
    rename = {}
    for match in _SSA_TOKEN.finditer(text):
        token = match.group(0)
        if token not in rename:
            rename[token] = f"%ssa{len(rename)}"
    return rename


def _rename_ssa_fast(text, rename):
    """Single-pass regex substitution through a dict lookup."""
    return _SSA_TOKEN.sub(lambda match: rename[match.group(0)], text)


def _rename_ssa_naive(text, rename):
    """Deliberately quadratic: two full-text str.replace passes per SSA value.

    Longest-first ordering avoids prefix clobbering and the delimited
    placeholders keep replacement outputs from being re-matched, so this
    produces output identical to the fast version - at far greater cost.
    """
    ordered = sorted(rename, key=len, reverse=True)
    for index, token in enumerate(ordered):
        text = text.replace(token, f"\x00{index}\x00")
    for index, token in enumerate(ordered):
        text = text.replace(f"\x00{index}\x00", rename[token])
    return text


@pytest.mark.parametrize(
    "rename_ssa,transform_repeats",
    [(_rename_ssa_fast, 2500), (_rename_ssa_naive, 750)],
    ids=["fast", "naive"],
)
def test_mini_pipeline(rename_ssa, transform_repeats):
    # Repeat counts are calibrated so each phase runs for a few seconds,
    # giving the 100Hz sampler solid per-phase coverage.
    texts = [path.read_text(errors="replace") for path in _corpus_files()]

    with _phases.profile_phase("demo.parse"):
        modules = None
        for _ in range(500):
            modules = [_parse_module(text) for text in texts]

    with _phases.profile_phase("demo.analyze"):
        total_fusable = 0
        for _ in range(6000):
            total_fusable = sum(_analyze_fusable_pairs(ops) for ops in modules)

    with _phases.profile_phase("demo.transform"):
        renamed = None
        for _ in range(transform_repeats):
            renamed = [rename_ssa(text, _ssa_rename_map(text)) for text in texts]

    with _phases.profile_phase("demo.emit"):
        emitted = None
        for _ in range(600):
            emitted = "\n".join(
                "\n".join(line for line in text.splitlines() if line.strip())
                for text in renamed
            )

    assert sum(len(ops) for ops in modules) > 1000
    assert total_fusable > 0
    # Most corpus files carry SSA values, so most renamed texts must contain
    # the renumbered form.
    assert sum("%ssa0" in text for text in renamed) > len(renamed) // 2
    assert len(emitted) > 0
    # fast and naive must be interchangeable: spot-check equivalence.
    sample = texts[0]
    mapping = _ssa_rename_map(sample)
    assert _rename_ssa_fast(sample, mapping) == _rename_ssa_naive(sample, mapping)
