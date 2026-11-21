# e1 d1-job, attempt 1

- outcome: pass

## What ran

- cases.csv: 12 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 20 rows
- markers.csv: 4 rows
- pods.csv: 37 rows
- records.csv: 144 rows
- verdict.csv: 165 rows

## Checks

- check missing values: pass
- check cases.csv D1 · job form: one PURGED per state file · server: pass
- check cases.csv D1 · no write allowed after the purge · server: pass
- check cases.csv D1 · no state left · server: pass
- check cases.csv D1 · job form: one PURGED per state file · clientone: pass
- check cases.csv D1 · no write allowed after the purge · clientone: pass
- check cases.csv D1 · no state left · clientone: pass
- check cases.csv D1 · job form: one PURGED per state file · clienttwo: pass
- check cases.csv D1 · no write allowed after the purge · clienttwo: pass
- check cases.csv D1 · no state left · clienttwo: pass
- check cases.csv D1 · job form: one PURGED per state file · clientthree: pass
- check cases.csv D1 · no write allowed after the purge · clientthree: pass
- check cases.csv D1 · no state left · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 20 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 10 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 10 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 52 files)
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
- check verdict.csv class · inspector: pass (3 rows, 0 failing)
- check verdict.csv node · inspector: pass (3 rows, 0 failing)
- check verdict.csv digest · inspector: pass (3 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 211329.8 ms, median 211329.8 ms, maximum 211329.8 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 150.9 ms, median 174.8 ms, maximum 199.2 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 2.8 ms, median 2.8 ms, maximum 2.8 ms
- events.csv duration_us (d1: every steward's job has written): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (d1: revocation with purge during the job): n=4, minimum 4.4 ms, median 8.8 ms, maximum 12.4 ms
- events.csv duration_us (run done): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| D1 | job form: one PURGED per state file | server | one purge PURGED record per state file the job wrote, each with job fields and on fresh terms, while the job's enforcement point was still serving | 1 PURGED for 1 state files written | pass |
| D1 | no write allowed after the purge | server | no write ALLOW record after the first PURGED | 0 | pass |
| D1 | no state left | server | no state file on the claim at the unit's end | 0 state files | pass |
| D1 | job form: one PURGED per state file | clientone | one purge PURGED record per state file the job wrote, each with job fields and on fresh terms, while the job's enforcement point was still serving | 1 PURGED for 1 state files written | pass |
| D1 | no write allowed after the purge | clientone | no write ALLOW record after the first PURGED | 0 | pass |
| D1 | no state left | clientone | no state file on the claim at the unit's end | 0 state files | pass |
| D1 | job form: one PURGED per state file | clienttwo | one purge PURGED record per state file the job wrote, each with job fields and on fresh terms, while the job's enforcement point was still serving | 1 PURGED for 1 state files written | pass |
| D1 | no write allowed after the purge | clienttwo | no write ALLOW record after the first PURGED | 0 | pass |
| D1 | no state left | clienttwo | no state file on the claim at the unit's end | 0 state files | pass |
| D1 | job form: one PURGED per state file | clientthree | one purge PURGED record per state file the job wrote, each with job fields and on fresh terms, while the job's enforcement point was still serving | 1 PURGED for 1 state files written | pass |
| D1 | no write allowed after the purge | clientthree | no write ALLOW record after the first PURGED | 0 | pass |
| D1 | no state left | clientthree | no state file on the claim at the unit's end | 0 state files | pass |
