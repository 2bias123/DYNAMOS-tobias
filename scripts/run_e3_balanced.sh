#!/usr/bin/env bash
set -u

# E3 balanced-order redo driver: quadruplets of counted fifty-round overhead
# runs — a, b, c, h per quadruplet — in one sitting, with the config order
# rotating through a Williams Latin square so position drift and first-order
# carryover are balanced. Sibling to run_e3_replication.sh (the three-arm
# fixed-order frozen driver, left intact as that session's record); this one
# is never the default tree. Artifacts land in results/e3-balanced/ via the
# E3_RESULTS_DIR override.
#
# Arms: a no-gateway, b pass-through, c write-through,
# h store-only write-through (c minus governance). Unit = quadruplet.
#
# Why the rotation: run_e3_replication.sh runs a fixed a,b,c every triplet, so
# steady session drift adds a constant to every paired difference instead of
# cancelling. The Williams square below is Latin (each config once per
# position) AND row-complete (its 12 consecutive ordered pairs are the 12
# distinct ordered pairs of {a,b,c,h}, each once), so across the four orders
# both position and immediate-predecessor are balanced. The four orders cycle
# 1->2->3->4->1... across the quadruplets; at QUADS=32 each order runs 8 times.
#
#   Q-order 1:  a  b  h  c
#   Q-order 2:  b  c  a  h
#   Q-order 3:  c  h  b  a
#   Q-order 4:  h  a  c  b
#
# Session protocol:
# - Quiet machine: plugged in, no builds or heavy apps, hands off for the
#   roughly 4 h 45 m. The instrument is wall-clock kubectl log timestamps.
# - The env snapshot runs first and its fork-image provenance gate must pass.
#   Counted runs go through run_e3_balanced_32quads.sh, which adds the
#   digest-EQUALITY gate against the e3-frozen build before this driver runs.
# - Each config block resets and seeds first, so config order within a
#   quadruplet is a measurement-drift concern only, never a correctness one
#   (config a resets THEN flips requiresGateway off; b/c/h reset restores it).
# - Counting rule: a failed run voids its whole quadruplet. The
#   driver stops, annotates captures.md, and the quadruplet reruns in full.
#   Never resume mid-quadruplet — a partial quadruplet breaks the time-slot
#   pairing the interleaving exists for.
# - The realized order is recorded per quadruplet in captures.md (the rotation
#   is the plan; the record is the evidence).
#
# Usage: run_e3_balanced.sh [start_quad]
#   start_quad resumes a stopped session at that quadruplet (default 1). The
#   rotation is keyed to the quadruplet number, so a resume keeps the same
#   order a given quadruplet would have had in an uninterrupted run.
#
# Dry run (uncounted, throwaway tree — never the default tree):
#   E3_RESULTS_DIR=/tmp/e3-dryrun QUADS=2 CYCLES=5 run_e3_balanced.sh
# Two quadruplets exercise two orders and the one otherwise-untested step: a
# second config-a invocation after intervening resets.

root="$(cd "$(dirname "$0")/.." && pwd)"
QUADS="${QUADS:-32}"
CYCLES="${CYCLES:-50}"
START="${1:-1}"
case "$START" in ''|*[!0-9]*) echo "usage: $0 [start_quad]" >&2; exit 2 ;; esac
{ [ "$START" -ge 1 ] && [ "$START" -le "$QUADS" ]; } \
	|| { echo "usage: $0 [start_quad]  (1..$QUADS)" >&2; exit 2; }

# The Williams square, one row per order. Indexed 0..3; quadruplet q uses
# row (q-1) mod 4.
ORDERS=(
	"a b h c"
	"b c a h"
	"c h b a"
	"h a c b"
)

E3_RESULTS_DIR="${E3_RESULTS_DIR:-$root/results/e3-balanced}"
export E3_RESULTS_DIR

echo "=== E3 balanced: quadruplets ${START}..${QUADS} [a b c h, Williams-rotated], ${CYCLES} rounds each, tree: $E3_RESULTS_DIR"

echo
echo "=== env snapshot (fork-image provenance gate)"
if ! ENV_RESULTS_DIR="$E3_RESULTS_DIR/env" "$root/scripts/capture_env_snapshot.sh"; then
	echo "env snapshot failed its provenance gate; reload the fork images (kind load + reset) before any counted run" >&2
	exit 1
fi

for q in $(seq "$START" "$QUADS"); do
	order="${ORDERS[$(( (q - 1) % 4 ))]}"
	echo
	echo "=== quadruplet $q/$QUADS, order [$order] ($(date +%H:%M:%S))"
	echo "\`(quadruplet $q: Williams order [$order])\`" >> "$E3_RESULTS_DIR/captures.md"
	done_cfgs=""
	for cfg in $order; do
		echo
		echo "=== quadruplet $q/$QUADS, config $cfg ($(date +%H:%M:%S))"
		if ! "$root/scripts/capture_e3_overhead.sh" "$cfg" "$CYCLES"; then
			if [ -n "$done_cfgs" ]; then
				note="its earlier runs (${done_cfgs# }) are not counted"
			else
				note="no earlier runs in this quadruplet"
			fi
			echo "(quadruplet $q aborted at config $cfg — $note; the quadruplet reruns in full)" \
				>> "$E3_RESULTS_DIR/captures.md"
			echo
			echo "QUADRUPLET $q FAILED at config $cfg; noted in $E3_RESULTS_DIR/captures.md." >&2
			echo "Diagnose, then rerun the whole quadruplet: $0 $q" >&2
			exit 1
		fi
		done_cfgs="$done_cfgs $cfg"
	done
done

echo
echo "=== session complete: quadruplets ${START}..${QUADS} captured under $E3_RESULTS_DIR"
echo "next: port to the workbench evidence tree and log the session narrative"
