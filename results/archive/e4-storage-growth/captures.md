# e4-storage-growth — captures

One line per artifact, newest last:
`<path> | YYYYMMDD-HHMMSS | <exact command> | <dynamos commit> | <what it shows / FAILED-run flag>`
`e4-storage-growth/growth/20260808-210909_growth-per-round.txt | 20260808-210909 | scripts/capture_e4_storage_growth.sh growth 20 | b3f6ad2 | E4 growth: per-round audit and PVC bytes over 20 enforced rounds (sampler + audit-record bytes), final listings on all four steward PVCs`
`e4-storage-growth/flip-curve/20260808-211104_allow-flip-deny-curve.txt | 20260808-211104 | scripts/capture_e4_storage_growth.sh flip 24 8 | b3f6ad2 | E4 flip curve: allowed=false after 8 of 24 rounds (onRevocation retain) -> training continues, persistence stops; aged checkpoint expires, no resume`
