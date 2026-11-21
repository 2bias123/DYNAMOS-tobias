# e1 w4, attempt 1

- outcome: pass

## What ran

- cases.csv: 8 rows
- claims.csv: 4 rows
- completeness.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 15 rows
- markers.csv: 4 rows
- pods.csv: 37 rows
- records.csv: 31 rows
- verdict.csv: 165 rows

## Checks

- check missing values: pass
- check cases.csv W4 · write allowed · server: pass
- check cases.csv completeness · every state file has a write ALLOW record · server: pass
- check cases.csv W4 · write allowed · clientone: pass
- check cases.csv completeness · every state file has a write ALLOW record · clientone: pass
- check cases.csv W4 · write allowed · clienttwo: pass
- check cases.csv completeness · every state file has a write ALLOW record · clienttwo: pass
- check cases.csv W4 · write allowed · clientthree: pass
- check cases.csv completeness · every state file has a write ALLOW record · clientthree: pass
- check completeness.csv server · state-server-ad751c18-vfltrainmodelrequest: pass
- check completeness.csv clientone · state-clientone-ad751c18-vfltrainmodelrequest: pass
- check completeness.csv clienttwo · state-clienttwo-ad751c18-vfltrainmodelrequest: pass
- check completeness.csv clientthree · state-clientthree-ad751c18-vfltrainmodelrequest: pass
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
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 49 files)
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

- events.csv duration_us (clean start): n=1, minimum 200663.1 ms, median 200663.1 ms, maximum 200663.1 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 149.8 ms, median 169.1 ms, maximum 194.3 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 2.1 ms, median 2.1 ms, maximum 2.1 ms
- events.csv duration_us (run done): n=1, minimum 28659.2 ms, median 28659.2 ms, maximum 28659.2 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| W4 | write allowed | server | write records only ALLOW, at least one, each by the job's enforcement point on relation GUID-state-aware with a fresh or cached view and allowed terms | 3 write records, 3 of them ALLOW as expected | pass |
| completeness | every state file has a write ALLOW record | server | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| W4 | write allowed | clientone | write records only ALLOW, at least one, each by the job's enforcement point on relation GUID-state-aware with a fresh or cached view and allowed terms | 3 write records, 3 of them ALLOW as expected | pass |
| completeness | every state file has a write ALLOW record | clientone | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| W4 | write allowed | clienttwo | write records only ALLOW, at least one, each by the job's enforcement point on relation GUID-state-aware with a fresh or cached view and allowed terms | 3 write records, 3 of them ALLOW as expected | pass |
| completeness | every state file has a write ALLOW record | clienttwo | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| W4 | write allowed | clientthree | write records only ALLOW, at least one, each by the job's enforcement point on relation GUID-state-aware with a fresh or cached view and allowed terms | 3 write records, 3 of them ALLOW as expected | pass |
| completeness | every state file has a write ALLOW record | clientthree | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
