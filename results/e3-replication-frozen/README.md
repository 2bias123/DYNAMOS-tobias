# E3 replication session — frozen campaign build

Rerun of the replication session on the frozen campaign build. The first
session (`e3-replication/`, 2026-08-27) captured 9/9 but on
pvc-roundtrip-overhead branch images; before this session the four fork
images (`dynamos1/agent:main`, `tamjiyan/policy-checkpoint-gateway`,
`tamjiyan/vfl-train-demo`, `tamjiyan/vfl-train-model-demo`) were retagged
on the kind node back to the campaign-era images (branch builds preserved
as `:e7-branch-20260827`) and the steward agents rolled onto them.
Session date: 2026-08-27.

Same protocol as `e3-replication/`: three interleaved triplets — a, b, c
inside each triplet — of counted fifty-round overhead runs, one sitting,
quiet machine, captured by `scripts/run_e3_replication.sh` with
`E3_RESULTS_DIR` pointing here. Layout and the counting rule
are as in `e3-replication/README.md`. The env snapshot's dynamos image
digests must match `campaign-n50/env/` for the frozen-build claim to hold.
