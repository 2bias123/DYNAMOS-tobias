# E3 replication session

Three interleaved triplets — a, b, c inside each triplet — of counted
fifty-round overhead runs, captured in one sitting by
`scripts/run_e3_replication.sh`. Same capture script and instrument as the
campaign block (`capture_e3_overhead.sh`, api-gateway round markers); only
`E3_RESULTS_DIR` differs, so the frozen campaign tree is never written.

Why a separate session: the campaign block (`campaign-n50/e3-overhead/`)
holds one counted run per configuration, which confounds configuration with
session — its b-below-a median ordering (~5 ms) is the size of session
drift, not a measured gateway saving. Three runs per configuration,
interleaved so drift hits every configuration alike, put between-run
variance next to between-config variance, and the comparison can then be
reported over run medians.

Layout: `config-{a-no-gateway,b-passthrough,c-enforced}/` with one
timestamped artifact and CSV per run, one `captures.md` line per artifact,
and `env/` for the session snapshot. The snapshot's dynamos image digests
must match `campaign-n50/env/` for the frozen-build claim to carry over.

Counting rule: a failed run voids its whole triplet. Its
earlier runs are not counted (annotated in `captures.md`), and the triplet
reruns in full from config a. Failed captures stay recorded.
