# E3 inert-gateway probe (diagnostic)

Splits the governed-over-baseline round-time gap into a presence part and
an interaction part. Three interleaved triplets of a, g, b (fifty rounds
each, one sitting, quiet machine) via `scripts/run_e3_replication.sh` with
`CONFIGS="a g b"`. Config g deploys the full gateway container into every
job pod but its listener never binds (`GATEWAY_INERT`), so the MSs degrade
exactly as in config a: g−a prices the container's mere presence, b−g the
per-round checkpoint interaction. Log-derived prediction for b−g from the
counted replication sessions: ~22–25 ms/round (four stewards' serialize +
write RPC, all inside the training segment).

Build provenance: the two rebuilt images come from the frozen campaign
commit (22bf60eb, `main`) plus only the inert flag — branch
`e3-inert-probe`, commits 9155387 (gateway: skip listener bind) and
7afc6b1 (deploy_job env mirror); diff vs frozen is 2 files, +13/−3.
On the kind node for this session: `dynamos1/agent:main` = 897fc983c620e
and `tamjiyan/policy-checkpoint-gateway:latest` = 0c1aba1cd42f7 (both also
tagged `:e3-inert-probe`; the frozen originals are preserved as
`:frozen-campaign` and restored after the session). The VFL MS images are
the untouched frozen ones and must match `campaign-n50/env/`
(vfl-train-demo f5c6d1a94dead, vfl-train-model-demo f77074962ecc5).

This tree is diagnostic evidence for the discussion chapter. It is never
counted E3 data, and the env snapshot intentionally differs from the
campaign record on the two rebuilt images. Layout and the triplet-void
counting rule are as in `e3-replication/README.md`; config g artifacts add
a per-steward `crictl stats` snapshot of the inert gateways' cumulative
CPU as presence-cost mechanism evidence.
