# e1 d6, attempt 1

- outcome: pass

## What ran

- cases.csv: 20 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 34 rows
- markers.csv: 4 rows
- pods.csv: 46 rows
- records.csv: 62 rows
- verdict.csv: 212 rows

## Checks

- check missing values: pass
- check cases.csv runs · two runs · server: pass
- check cases.csv D6 · write denied · server: pass
- check cases.csv D6 · read denied · server: pass
- check cases.csv D6 · nothing destroyed · server: pass
- check cases.csv D6 · state kept · server: pass
- check cases.csv runs · two runs · clientone: pass
- check cases.csv D6 · write denied · clientone: pass
- check cases.csv D6 · read denied · clientone: pass
- check cases.csv D6 · nothing destroyed · clientone: pass
- check cases.csv D6 · state kept · clientone: pass
- check cases.csv runs · two runs · clienttwo: pass
- check cases.csv D6 · write denied · clienttwo: pass
- check cases.csv D6 · read denied · clienttwo: pass
- check cases.csv D6 · nothing destroyed · clienttwo: pass
- check cases.csv D6 · state kept · clienttwo: pass
- check cases.csv runs · two runs · clientthree: pass
- check cases.csv D6 · write denied · clientthree: pass
- check cases.csv D6 · read denied · clientthree: pass
- check cases.csv D6 · nothing destroyed · clientthree: pass
- check cases.csv D6 · state kept · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 28 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 9 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 9 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 73 files)
- check verdict.csv class · request path: pass (6 rows, 0 failing)
- check verdict.csv node · request path: pass (6 rows, 0 failing)
- check verdict.csv digest · request path: pass (12 rows, 0 failing)
- check verdict.csv class · agent: pass (8 rows, 0 failing)
- check verdict.csv node · agent: pass (8 rows, 0 failing)
- check verdict.csv digest · agent: pass (16 rows, 0 failing)
- check verdict.csv class · idle: pass (16 rows, 0 failing)
- check verdict.csv node · idle: pass (16 rows, 0 failing)
- check verdict.csv digest · idle: pass (16 rows, 0 failing)
- check verdict.csv class · chain: pass (12 rows, 0 failing)
- check verdict.csv node · chain: pass (12 rows, 0 failing)
- check verdict.csv digest · chain: pass (72 rows, 0 failing)
- check verdict.csv class · inspector: pass (4 rows, 0 failing)
- check verdict.csv node · inspector: pass (4 rows, 0 failing)
- check verdict.csv digest · inspector: pass (4 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 154210.5 ms, median 154210.5 ms, maximum 154210.5 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=8, minimum 147.7 ms, median 160.8 ms, maximum 31729.5 ms
- events.csv duration_us (deploy gap: held): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 2.3 ms, median 2.7 ms, maximum 3.1 ms
- events.csv duration_us (run done): n=2, minimum 28718.6 ms, median 37514.3 ms, maximum 46310.1 ms
- events.csv duration_us (d6: revocation without purge): n=4, minimum 4.5 ms, median 5.3 ms, maximum 5.7 ms
- events.csv duration_us (d6: settle): n=1, minimum 35000.0 ms, median 35000.0 ms, maximum 35000.0 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| runs | two runs | server | 2 runs of job records | 2 | pass |
| D6 | write denied | server | every write record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| D6 | read denied | server | every read record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| D6 | nothing destroyed | server | no PURGED or DELETED record in the unit | 0 | pass |
| D6 | state kept | server | the state files after the revocation, at least one, byte-identical at the unit's end | 1 state files after the revocation, 1 at the end, identical | pass |
| runs | two runs | clientone | 2 runs of job records | 2 | pass |
| D6 | write denied | clientone | every write record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| D6 | read denied | clientone | every read record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| D6 | nothing destroyed | clientone | no PURGED or DELETED record in the unit | 0 | pass |
| D6 | state kept | clientone | the state files after the revocation, at least one, byte-identical at the unit's end | 1 state files after the revocation, 1 at the end, identical | pass |
| runs | two runs | clienttwo | 2 runs of job records | 2 | pass |
| D6 | write denied | clienttwo | every write record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| D6 | read denied | clienttwo | every read record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| D6 | nothing destroyed | clienttwo | no PURGED or DELETED record in the unit | 0 | pass |
| D6 | state kept | clienttwo | the state files after the revocation, at least one, byte-identical at the unit's end | 1 state files after the revocation, 1 at the end, identical | pass |
| runs | two runs | clientthree | 2 runs of job records | 2 | pass |
| D6 | write denied | clientthree | every write record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| D6 | read denied | clientthree | every read record of run 2 DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| D6 | nothing destroyed | clientthree | no PURGED or DELETED record in the unit | 0 | pass |
| D6 | state kept | clientthree | the state files after the revocation, at least one, byte-identical at the unit's end | 1 state files after the revocation, 1 at the end, identical | pass |
