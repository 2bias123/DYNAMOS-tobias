# Evidence folder

Raw evaluation artifacts for the results chapter. The chapter is drafted *from*
this folder (coding plan, Evaluation chapter; evaluation freeze Tue 28 Jul 2026).
One subfolder per experiment that actually runs.

## Capture loop

Experiments run in the code repo, so capture happens there and gets ported here:

1. Run the experiment in `DYNAMOS-tobias`; raw output lands in
   `DYNAMOS-tobias/results/` (identical layout to this folder, committed in
   the code repo alongside the code that produced it). Evidence is tracked in
   both repos; the workbench copy is what the results chapter is drafted from.
2. Add the artifact's line to that experiment's `captures.md` at capture time,
   in `results/`.
3. Port with `scripts/sync-evidence.sh` (workbench). It copies new raw files
   only (an existing destination file is never overwritten), carries over
   `captures.md` and `README.md`, and reports any same-name but
   different-content drift, which should always be empty.

`results/` is the authoring point for `captures.md` and this README; edit them
there and sync forward, not here.

## Rules

1. **Raw output only.** Every file is the unedited product of a command or the
   system: tee'd stdout, `kubectl logs`, audit NDJSON, grpcurl responses,
   harness CSV/JSON, `go test` output, screenshots. Nothing is retyped,
   summarized, or prettified. Derived tables and plots belong in
   `thesis/drafts/`, citing files here by path.
2. **Append-only.** Never edit, overwrite, or delete a captured file. Failed or
   aborted runs stay; flag them in `captures.md`. This holds from the moment of
   capture, committed or not.
3. **Every artifact gets a line in its experiment's `captures.md`:** path,
   timestamp, exact command, DYNAMOS commit, one-line description. The
   description is metadata, never a substitute for the raw file.
4. **Filenames:** `YYYYMMDD-HHMMSS_<short-slug>.<ext>`, local time. Seconds
   granularity keeps repeated runs distinct.
5. **Environment snapshots go in `env/`** (git SHA, loaded images, kind/kubectl
   versions, chain config). Capture at least one per experiment day, as raw
   command output like everything else.

## Layout

- `campaign-n50/` — the counted re-run campaign (N=50 iterations, instrumented
  harness). Same per-experiment layout as below, with its own `env/` and its
  own `captures.md` per experiment. The capture scripts default here; the
  top-level experiment folders below hold the earlier captures and receive no
  new files.
- `env/` — cross-cutting environment snapshots.
- `e1-decision-correctness/` — HEADLINE. Oracle = plan §1.10 matrices.
  - `bufconn/` — table-driven unit-harness rows (write/read/purge).
  - `live-chain/` — the same rows against the live VFL chain (RPC responses +
    stdout audit lines), incl. the reissued-request resume rows and the
    revoke-then-regrant-without-purge row (scored compliant).
  - `adversarial/` — identity-mismatch, direct-FS-attempt (A7), lock-conflict (A1).
  - `audit-completeness/` — the invariant script's diff of `/state/data/**`
    against ALLOW write lines (runs after T-AUD lands the file leg).
- `e2-policy-latency/`
  - `watch-regime/` — about 10 flip-then-first-DENY trials, watch delivered.
  - `poll-spotcheck/` — the single watch-disabled confirming trial (regime is
    argued from the 30 s poll bound).
- `e3-overhead/` — ~10 rounds each; per-round latency, payload size, r².
  - `config-a-no-gateway/` — `requiresGateway:false`, no persistence (execution baseline).
  - `config-b-passthrough/` — gateway present, log-only.
  - `config-c-enforced/` — full enforcement, T6 write-through.
- `e4-storage-growth/` (v13: formerly E7)
  - `growth/` — audit-log and PVC size per round.
  - `flip-curve/` — the training-curve run with a mid-run policy flip, ALLOW
    then DENY (T5 flip demo). Raw capture lives here once; E1's headline claim
    references it, E4 plots it.
- `e5-genericity/` (v13: formerly E6) — by-construction artifacts: build/config
  output showing one unchanged gateway binary governs both `vfl_server_model`
  and `vfl_client_model`.
- `e6-purge-latency/` — revocation-to-purge latency.
  - `watch-regime/` — flip→purge-complete trials, watch delivered.
  - `induced-staleness/` — outage → no destruction on a non-fresh view →
    recovery → the deferred purge completes fresh.
- `e7-pvc-roundtrip/` — PVC round-trip overhead: the server MS rehydrates from
  the governed checkpoint every round and drops its in-memory model after the
  write (`capture_e3_overhead.sh d`, which defaults its artifacts here).
  Per-leg timings (serialize/RPC/gateway spans/deserialize) plus the
  fingerprint fidelity oracle. Post-v13 number (pre-v13 documents used E7 for
  storage growth); unrelated to the unscheduled "ungoverned direct write
  (E3-(d))" item below — the harness arm letter d is a coincidence.
  - `config-c-enforced/` — this experiment's own config (c) baseline runs.
  - `config-d-roundtrip/` — the server-only roundtrip variant arm.
  - `config-e-chain-roundtrip/` — the whole-chain arm: the three client MSs
    also rehydrate per round (`capture_e3_overhead.sh e`), holding state only
    across the train/gradient RPC pair; per-client governance ledgers,
    fidelity pairs, and leg timings on top of config d's server set.
  - `env/` — the session's environment snapshots.

## Not in this folder

- The supervisor-optional items (not scheduled, run only on request) have no
  folders, so nothing can be misfiled into an experiment that isn't running:
  **retention timeliness** (formerly E4; needs cut T7), **kill-resume
  demonstration** (formerly E5; cut stretch #1), **ungoverned direct write**
  (E3-(d)), **live second consumer** (E5's stretch #4). If one is requested,
  create its folder then, named descriptively, with no E-number.
- **Numbering:** plan v13 (24 Jul 2026) made the progress write-up's numbering
  canonical: E4 = storage growth (formerly E7), E5 = genericity (formerly E6).
  Documents and log entries older than v13 use the old numbers.
