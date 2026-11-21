# e2-policy-latency — captures

One line per artifact, newest last:
`<path> | YYYYMMDD-HHMMSS | <exact command> | <dynamos commit> | <what it shows / FAILED-run flag>`
`e2-policy-latency/poll-spotcheck/20260725-164418_poll-only-deny.txt | 20260725-164418 | scripts/capture_e2_pollcheck.sh | 968fd33 | E2 poll-only spot-check (watch disabled): flip to first enforced DENY within the 30s poll bound, one confirming trial`
`e2-policy-latency/watch-regime/20260725-164753_flip-to-first-deny.txt | 20260725-164753 | scripts/capture_e2_latency.sh 10 | dd297c1 | E2 watch-regime: flip via /policyEnforcer PUT to first enforced DENY on the aggregator's next write, 10 trials`
