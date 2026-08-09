# e6-purge-latency — captures

One line per artifact, newest last:
`<path> | YYYYMMDD-HHMMSS | <exact command> | <dynamos commit> | <what it shows / FAILED-run flag>`
`e6-purge-latency/watch-regime/20260806-162600_flip-to-purge-complete.txt | 20260806-162600 | scripts/capture_e6_purge_latency.sh latency 10 | f50c272 | E6 watch-regime: flip via /policyEnforcer PUT (stamped at initiation) to purge-complete on a standalone gateway pod, 10 trials`
`e6-purge-latency/induced-staleness/20260806-162618_outage-defer-recover-purge.txt | 20260806-162618 | scripts/capture_e6_purge_latency.sh staleness | f50c272 | E6 induced staleness: outage -> stale fail-closed writes, no destruction on non-fresh, flip unobserved; recovery -> confirmed-fresh purge within one poll bound`
`e6-purge-latency/watch-regime/20260806-163104_flip-to-purge-complete.txt | 20260806-163104 | scripts/capture_e6_purge_latency.sh latency 10 | e631457 | E6 watch-regime: flip via /policyEnforcer PUT (stamped at initiation) to purge-complete on a standalone gateway pod, 10 trials`
`e6-purge-latency/watch-regime/20260806-163121_flip-to-purge-complete.txt | 20260806-163121 | scripts/capture_e6_purge_latency.sh latency 10 | e631457 | E6 watch-regime: flip via /policyEnforcer PUT (stamped at initiation) to purge-complete on a standalone gateway pod, 10 trials`
`e6-purge-latency/induced-staleness/20260806-163211_outage-defer-recover-purge.txt | 20260806-163211 | scripts/capture_e6_purge_latency.sh staleness | e631457 | E6 induced staleness: outage -> stale fail-closed writes, no destruction on non-fresh, flip unobserved; recovery -> confirmed-fresh purge within one poll bound`
`e6-purge-latency/induced-staleness/20260806-163304_outage-defer-recover-purge.txt | 20260806-163304 | scripts/capture_e6_purge_latency.sh staleness | e631457 | E6 induced staleness: outage -> stale fail-closed writes, no destruction on non-fresh, flip unobserved; recovery -> confirmed-fresh purge within one poll bound`
