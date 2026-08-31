#!/usr/bin/env bash
set -u

# E3 replication session driver: three interleaved triplets of counted
# fifty-round overhead runs — a, b, c inside each triplet — in one sitting.
# Artifacts land in the fresh tree results/e3-replication/ via the
# E3_RESULTS_DIR override; the frozen campaign tree is never written.
#
# Why: the campaign E3 block holds one counted run per configuration, so
# configuration is confounded with session. Three runs per configuration,
# interleaved so drift hits every configuration alike, put between-run
# variance next to between-config variance.
#
# Session protocol:
# - Quiet machine: plugged in, no builds or heavy apps, hands off for the
#   roughly 1.5 h. The instrument is wall-clock kubectl log timestamps.
# - The env snapshot runs first and its fork-image provenance gate must
#   pass. Before drafting from the session, compare its dynamos image
#   digests against results/campaign-n50/env/ — same digests, same frozen
#   build.
# - Config order inside a triplet stays a, b, c: config a needs the gateway
#   absent and its etcd flip is ephemeral (see capture_e3_overhead.sh).
# - Counting rule: a failed run voids its whole triplet. The
#   driver stops, annotates captures.md, and the triplet reruns in full.
#   Never resume mid-triplet — a partial triplet breaks the time-slot
#   pairing the interleaving exists for.
#
# Usage: run_e3_replication.sh [start_triplet]
#   start_triplet resumes a stopped session at that triplet (default 1).
#   CONFIGS overrides the per-triplet config order (default "a b c"; the
#   inert probe session runs CONFIGS="a g b").
#
# Dry run (uncounted, throwaway tree — never the default tree):
#   E3_RESULTS_DIR=/tmp/e3-dryrun TRIPLETS=2 CYCLES=5 run_e3_replication.sh
# Two triplets exercise the one untested step: a second config-a invocation
# after intervening resets.

root="$(cd "$(dirname "$0")/.." && pwd)"
TRIPLETS="${TRIPLETS:-3}"
CYCLES="${CYCLES:-50}"
CONFIGS="${CONFIGS:-a b c}"
START="${1:-1}"
case "$START" in ''|*[!0-9]*) echo "usage: $0 [start_triplet]" >&2; exit 2 ;; esac
{ [ "$START" -ge 1 ] && [ "$START" -le "$TRIPLETS" ]; } \
	|| { echo "usage: $0 [start_triplet]  (1..$TRIPLETS)" >&2; exit 2; }

E3_RESULTS_DIR="${E3_RESULTS_DIR:-$root/results/e3-replication}"
export E3_RESULTS_DIR

echo "=== E3 replication: triplets ${START}..${TRIPLETS} of [${CONFIGS}], ${CYCLES} rounds each, tree: $E3_RESULTS_DIR"

echo
echo "=== env snapshot (fork-image provenance gate)"
if ! ENV_RESULTS_DIR="$E3_RESULTS_DIR/env" "$root/scripts/capture_env_snapshot.sh"; then
	echo "env snapshot failed its provenance gate; reload the fork images (kind load + reset) before any counted run" >&2
	exit 1
fi

for t in $(seq "$START" "$TRIPLETS"); do
	done_cfgs=""
	for cfg in $CONFIGS; do
		echo
		echo "=== triplet $t/$TRIPLETS, config $cfg ($(date +%H:%M:%S))"
		if ! "$root/scripts/capture_e3_overhead.sh" "$cfg" "$CYCLES"; then
			if [ -n "$done_cfgs" ]; then
				note="its earlier runs (${done_cfgs# }) are not counted"
			else
				note="no earlier runs in this triplet"
			fi
			echo "(triplet $t aborted at config $cfg — $note; the triplet reruns in full)" \
				>> "$E3_RESULTS_DIR/captures.md"
			echo
			echo "TRIPLET $t FAILED at config $cfg; noted in $E3_RESULTS_DIR/captures.md." >&2
			echo "Diagnose, then rerun the whole triplet: $0 $t" >&2
			exit 1
		fi
		done_cfgs="$done_cfgs $cfg"
	done
done

echo
echo "=== session complete: triplets ${START}..${TRIPLETS} captured under $E3_RESULTS_DIR"
echo "next: port to the workbench evidence tree and log the session narrative"
