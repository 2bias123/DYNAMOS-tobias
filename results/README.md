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
   only — existing destination files are never overwritten — carries over
   `captures.md`/`README.md`, and reports any same-name/different-content
   drift, which should always be empty.

`results/` is the authoring point for `captures.md` and this README; edit them
there and sync forward, not here.

## Rules

1. **Raw output only.** Every file is the unedited product of a command or the
   system: tee'd stdout, `kubectl logs`, audit NDJSON, grpcurl responses,
   harness CSV/JSON, `go test` output, screenshots. Nothing retyped, nothing
   summarized, nothing prettified. Derived tables and plots belong in
   `thesis/drafts/`, citing files here by path.
2. **Append-only.** Never edit, overwrite, or delete a captured file. Failed or
   aborted runs stay; flag them in `captures.md`.
3. **Every artifact gets a line in its experiment's `captures.md`:** path,
   timestamp, exact command, DYNAMOS commit, one-line description. The
   description is metadata, never a substitute for the raw file.
4. **Filenames:** `YYYYMMDD-HHMMSS_<short-slug>.<ext>`, local time. Seconds
   granularity keeps repeated runs distinct.
5. **Environment snapshots go in `env/`** (git SHA, loaded images, kind/kubectl
   versions, chain config) — at minimum one per experiment day, captured as raw
   command output like everything else.

## Layout

- `env/` — cross-cutting environment snapshots.
- `e1-decision-correctness/` — HEADLINE. Oracle = plan §1.10 matrices.
  - `bufconn/` — table-driven unit-harness rows (write/read/purge).
  - `live-chain/` — the same rows against the live VFL chain (RPC responses +
    stdout audit lines), incl. the reissued-request resume rows and the
    revoke→re-grant-no-purge row (scored compliant).
  - `adversarial/` — identity-mismatch, direct-FS-attempt (A7), lock-conflict (A1).
  - `audit-completeness/` — the invariant script's diff of `/state/data/**`
    against ALLOW write lines (runs after T-AUD lands the file leg).
- `e2-policy-latency/`
  - `watch-regime/` — ~10 flip→first-DENY trials, watch delivered.
  - `poll-spotcheck/` — the single watch-disabled confirming trial (regime is
    argued from the 30 s poll bound).
- `e3-overhead/` — ~10 rounds each; per-round latency, payload size, r².
  - `config-a-no-gateway/` — `requiresGateway:false`, no persistence (execution baseline).
  - `config-b-passthrough/` — gateway present, log-only.
  - `config-c-enforced/` — full enforcement, T6 write-through.
- `e4-storage-growth/` (v13: formerly E7)
  - `growth/` — audit-log and PVC size per round.
  - `flip-curve/` — the ALLOW→flip→DENY training-curve run (T5 flip demo). Raw
    capture lives here once; E1's headline claim references it, E4 plots it.
- `e5-genericity/` (v13: formerly E6) — by-construction artifacts: build/config
  output showing one unchanged gateway binary governs both `vfl_server_model`
  and `vfl_client_model`.

## Not in this folder

- The supervisor-optional items (not scheduled, run only on request) have no
  folders, so nothing can be misfiled into an experiment that isn't running:
  **retention timeliness** (formerly E4; needs cut T7), **kill-resume
  demonstration** (formerly E5; cut stretch #1), **ungoverned direct write**
  (E3-(d)), **live second consumer** (E5's stretch #4). If one is requested,
  create its folder then, named descriptively — no E-number.
- **Numbering:** plan v13 (24 Jul 2026) made the progress write-up's numbering
  canonical: E4 = storage growth (formerly E7), E5 = genericity (formerly E6).
  Documents and log entries older than v13 use the old numbers.
