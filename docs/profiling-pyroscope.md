# Continuous profiling with Grafana Pyroscope

The Python test suites under `test/python` can push CPU profiles of the whole
Triton → MLIR → Hexagon compilation pipeline to [Grafana
Pyroscope](https://grafana.com/docs/pyroscope/latest/) (Grafana Cloud Profiles
or a self-hosted Pyroscope OSS server) while they run. Every pytest run
becomes a set of flame graphs in Grafana that can be sliced by test, kernel,
pipeline phase, and commit — so questions like *"which pass got slower for
kernel X between commit A and commit B?"* are answered by diffing two flame
graphs instead of adding ad-hoc timers.

Profiling is **opt-in and fail-safe**: when the environment variables below
are not set (or `pyroscope-io` is not installed), nothing changes about how
the tests run.

## Quick start

1. Install the SDK (already part of `ci/hexagon-mlir-requirements.txt`):

   ```bash
   pip install pyroscope-io
   ```

2. Export your Grafana Cloud Profiles credentials. In your Grafana Cloud
   stack, select **Details** next to the stack, then find the **Pyroscope**
   section for the URL and user; create an access-policy token with the
   `profiles:write` scope for the password.

   ```bash
   export PYROSCOPE_SERVER_ADDRESS=https://profiles-prod-XXX.grafana.net
   export PYROSCOPE_BASIC_AUTH_USERNAME=<numeric-stack-user-id>
   export PYROSCOPE_BASIC_AUTH_PASSWORD=<access-policy-token>
   ```

   For a local Pyroscope OSS server (`docker run -p 4040:4040
   grafana/pyroscope`), only `PYROSCOPE_SERVER_ADDRESS=http://localhost:4040`
   is needed.

3. Run any suite as usual:

   ```bash
   pytest -sv test/python/triton/test_vec_add.py
   ```

   The pytest report header confirms the state:

   ```text
   pyroscope profiling: enabled (application=hexagon-mlir.tests, server=...)
   ```

No Hexagon hardware handy? Validate the pipeline end to end with the
hardware-independent demo workloads:

```bash
python scripts/profile_demo.py
```

## Environment variables

| Variable | Meaning |
| --- | --- |
| `PYROSCOPE_SERVER_ADDRESS` | Pyroscope ingest URL. Profiling is disabled when unset. |
| `PYROSCOPE_BASIC_AUTH_USERNAME` | Grafana Cloud stack user id (numeric). Unset for unauthenticated OSS servers. |
| `PYROSCOPE_BASIC_AUTH_PASSWORD` | Grafana Cloud access-policy token with `profiles:write`. |
| `PYROSCOPE_APPLICATION_NAME` | Service name in Grafana. Defaults to `hexagon-mlir.tests`. |
| `PYROSCOPE_TENANT_ID` | Only for self-hosted multi-tenant Pyroscope. Not needed for Grafana Cloud. |

In CI, `.github/workflows/build.yml` maps the repository secrets of the same
names into the job environment, so any pytest step profiles automatically
once the secrets are configured.

## What gets tagged

Session-wide tags (attached to every profile of a run):

| Tag | Value |
| --- | --- |
| `git_sha` / `branch` | Commit and branch under test. |
| `ci_run_id` / `runner` | GitHub Actions run id; `runner` is `github-actions` or `local`. |
| `hostname` | Machine that ran the suite. |

Per-test tags (scoped by `test/python/conftest.py` around each test body):

| Tag | Value |
| --- | --- |
| `suite` | `triton`, `torch-mlir`, `mlir`, or `profiling` (demo). |
| `test_file` | Test module stem, e.g. `test_vec_add`. |
| `test` | Full pytest node id, e.g. `test_vec_add.py::test_vec_add`. |

Pipeline-phase tags (scoped inside the backend, see
`qcom_hexagon_backend/backend/pyroscope_phases.py`):

| `phase` value | Where |
| --- | --- |
| `compile.ttir` | Triton IR canonicalization (`make_ttir`). |
| `compile.ttsharedir` | `triton-shared-opt --triton-to-linalg-experimental`. |
| `compile.obj` / `compile.llir` / `compile.so` | Linalg → LLVM IR → Hexagon object/shared-object codegen. |
| `compile.torch_mlir_to_so` | Full torch-mlir compile-to-shared-object path. |
| `launch.wrapper_codegen` | C++ launcher wrapper generation. |
| `launch.link_shared_object` | Hexagon toolchain shared-object link. |
| `launch.execute` | Device/simulator execution (includes `adb`/simulator wait time). |

The `launch.*` phases also carry a `kernel` tag with the kernel function name.

## Example workflows in Grafana

Open **Drilldown → Profiles** (or Explore with the Pyroscope data source) and
select the `hexagon-mlir.tests` service.

- **Where does test time go for one kernel?** Filter
  `{test_file="test_matmul"}` and group by `phase`: compile vs link vs
  execute time per kernel, continuously, for every CI run.
- **Did a commit slow down compilation?** Comparison view with baseline
  `{git_sha="abc1234"}` vs comparison `{git_sha="def5678"}`, filtered to
  `{phase="compile.obj"}` — the diff flame graph shows exactly which pass got
  slower.
- **Which implementation is hotter?** The demo suite ships two competing
  implementations of the same MLIR op census; compare
  `{test="...op_census[regex]"}` against `{test="...op_census[tokenizer]"}`.

## Design notes

- `test/python/profiling/pyroscope_support.py` owns configuration and the
  agent lifecycle; `test/python/conftest.py` starts/stops it per pytest
  session and scopes the per-test tags with `pyroscope.tag_wrapper`.
- `qcom_hexagon_backend/backend/pyroscope_phases.py` is dependency-free and
  import-guarded: the backend never requires `pyroscope-io` at runtime, and
  all tagging errors are swallowed. Profiling can never break a build or a
  test run.
- The Python SDK samples the Python process (and, with
  `detect_subprocesses`, its children). Native frames inside pybind11 calls
  (MLIR pass manager, LLVM codegen) appear under the Python frame that
  invoked them — enough to attribute time to pipeline stages. For
  native-level C++ flame graphs of `linalg-hexagon-opt`/LLVM internals, the
  next step is host-level [eBPF profiling via Grafana
  Alloy](https://grafana.com/docs/pyroscope/latest/configure-client/grafana-alloy/ebpf/)
  on the CI runner, which requires no changes to this repository.
