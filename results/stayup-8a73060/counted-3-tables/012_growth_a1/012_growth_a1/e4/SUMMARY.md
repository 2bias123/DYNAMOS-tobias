# e4 growth, attempt 1

- outcome: fail: exit 1: e4 growth: Failed: E4 growth failed: sampler covers the run server: samples 1794719176693627 to 1794719211705940, writes 1794719192734755 to 1794719211818736, 36 samples

## What ran

- cases.csv: 11 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 16 rows
- markers.csv: 4 rows
- pods.csv: 37 rows
- records.csv: 219 rows
- rounds-growth.csv: 50 rows
- storage.csv: 4 rows
- verdict.csv: 165 rows

## Checks

- check missing values: fail (missing value rounds-growth.csv:sample_us:50, 4 in all)
- check cases.csv persisted every round · persisted every round · server: pass
- check cases.csv no destruction · no destruction · server: pass
- check cases.csv persisted every round · persisted every round · clientone: pass
- check cases.csv no destruction · no destruction · clientone: pass
- check cases.csv persisted every round · persisted every round · clienttwo: pass
- check cases.csv no destruction · no destruction · clienttwo: pass
- check cases.csv persisted every round · persisted every round · clientthree: pass
- check cases.csv no destruction · no destruction · clientthree: pass
- check cases.csv clean-slate read · clean-slate read · server: pass
- check cases.csv sampler covers the run · sampler covers the run · server: fail
- check cases.csv state persisted · state persisted · server: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 20 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 20 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 20 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 51 files)
- check verdict.csv class · request path: pass (6 rows, 0 failing)
- check verdict.csv node · request path: pass (6 rows, 0 failing)
- check verdict.csv digest · request path: pass (12 rows, 0 failing)
- check verdict.csv class · agent: pass (8 rows, 0 failing)
- check verdict.csv node · agent: pass (8 rows, 0 failing)
- check verdict.csv digest · agent: pass (16 rows, 0 failing)
- check verdict.csv class · idle: pass (12 rows, 0 failing)
- check verdict.csv node · idle: pass (12 rows, 0 failing)
- check verdict.csv digest · idle: pass (12 rows, 0 failing)
- check verdict.csv class · chain: pass (8 rows, 0 failing)
- check verdict.csv node · chain: pass (8 rows, 0 failing)
- check verdict.csv digest · chain: pass (48 rows, 0 failing)
- check verdict.csv class · sampler: pass (1 rows, 0 failing)
- check verdict.csv node · sampler: pass (1 rows, 0 failing)
- check verdict.csv digest · sampler: pass (1 rows, 0 failing)
- check verdict.csv class · inspector: pass (2 rows, 0 failing)
- check verdict.csv node · inspector: pass (2 rows, 0 failing)
- check verdict.csv digest · inspector: pass (2 rows, 0 failing)
- check verdict: fail

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 170807.5 ms, median 170807.5 ms, maximum 170807.5 ms
- events.csv duration_us (sampler created, waits for the server claim): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 138.7 ms, median 145.2 ms, maximum 158.4 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 2.3 ms, median 2.3 ms, maximum 2.3 ms
- events.csv duration_us (run done): n=1, minimum 44200.5 ms, median 44200.5 ms, maximum 44200.5 ms
