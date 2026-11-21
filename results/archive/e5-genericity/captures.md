# e5-genericity — captures

One line per artifact, newest last:
`<path> | YYYYMMDD-HHMMSS | <exact command> | <dynamos commit> | <what it shows / FAILED-run flag>`
`e5-genericity/scenes/20260805-154409_miss-then-hit.txt | 20260805-154409 | scripts/capture_e5_genericity.sh miss-hit | 36004ea | E5 scenes 1+2: clean-slate miss -> governed write, then a new pod reuses via gateway read (writtenUnixSeconds matches), no recompute; records carry aggregate_result`
`e5-genericity/scenes/20260805-154530_denial-after-flip.txt | 20260805-154530 | scripts/capture_e5_genericity.sh denial | 36004ea | E5 scene 3: allowed=false (onRevocation retain) -> read+write DENY 'allowed = false', unpersisted answer, no destruction records`
`e5-genericity/scenes/20260805-154635_revocation-purge.txt | 20260805-154635 | scripts/capture_e5_genericity.sh revocation-purge | 36004ea | E5 scene 4: onRevocation=purge -> blob destroyed at the boot sweep under the confirmed-fresh gate (op=purge PURGED, policySource fresh), record per removal`
`e5-genericity/scenes/20260805-154746_retention-expiry.txt | 20260805-154746 | scripts/capture_e5_genericity.sh retention | 36004ea | E5 scene 5: the agreement's own 120s bound -> op=expired DELETED at the boot sweep (confirmed fresh), read DENY not-found, recompute`
