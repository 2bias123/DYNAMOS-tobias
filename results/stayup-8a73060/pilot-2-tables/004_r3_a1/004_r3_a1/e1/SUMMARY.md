# e1 r3, attempt 1

- outcome: pass

## What ran

- cases.csv: 16 rows
- claims.csv: 4 rows
- completeness.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 29 rows
- markers.csv: 4 rows
- pods.csv: 45 rows
- records.csv: 62 rows
- verdict.csv: 209 rows

## Checks

- check missing values: pass
- check cases.csv runs · two runs · server: pass
- check cases.csv outside · read of an absent object · server: pass
- check cases.csv R3 · read within retention · server: pass
- check cases.csv completeness · every state file has a write ALLOW record · server: pass
- check cases.csv runs · two runs · clientone: pass
- check cases.csv outside · read of an absent object · clientone: pass
- check cases.csv R3 · read within retention · clientone: pass
- check cases.csv completeness · every state file has a write ALLOW record · clientone: pass
- check cases.csv runs · two runs · clienttwo: pass
- check cases.csv outside · read of an absent object · clienttwo: pass
- check cases.csv R3 · read within retention · clienttwo: pass
- check cases.csv completeness · every state file has a write ALLOW record · clienttwo: pass
- check cases.csv runs · two runs · clientthree: pass
- check cases.csv outside · read of an absent object · clientthree: pass
- check cases.csv R3 · read within retention · clientthree: pass
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
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 28 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 9 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 9 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 69 files)
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
- check verdict.csv class · inspector: pass (3 rows, 0 failing)
- check verdict.csv node · inspector: pass (3 rows, 0 failing)
- check verdict.csv digest · inspector: pass (3 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 213171.8 ms, median 213171.8 ms, maximum 213171.8 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=8, minimum 167.6 ms, median 184.1 ms, maximum 31648.1 ms
- events.csv duration_us (deploy gap: held): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 2.6 ms, median 3.1 ms, maximum 3.5 ms
- events.csv duration_us (run done): n=2, minimum 28847.6 ms, median 37405.7 ms, maximum 45963.8 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| runs | two runs | server | 2 runs of job records | 2 | pass |
| outside | read of an absent object | server | run 1's read records DENY 'not found' on the seeded relation, at least one | read records: 1, 0 otherwise | pass |
| R3 | read within retention | server | run 2's first read ALLOW on the seeded relation, its written time that of run 1's last write of the same state | ALLOW ('vfl_server_model', 'latest') on GUID-state-aware, written 1794623902, run 1's last write 1794623902 | pass |
| completeness | every state file has a write ALLOW record | server | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| runs | two runs | clientone | 2 runs of job records | 2 | pass |
| outside | read of an absent object | clientone | run 1's read records DENY 'not found' on the seeded relation, at least one | read records: 1, 0 otherwise | pass |
| R3 | read within retention | clientone | run 2's first read ALLOW on the seeded relation, its written time that of run 1's last write of the same state | ALLOW ('vfl_client_model', 'latest') on GUID-state-aware, written 1794623902, run 1's last write 1794623902 | pass |
| completeness | every state file has a write ALLOW record | clientone | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| runs | two runs | clienttwo | 2 runs of job records | 2 | pass |
| outside | read of an absent object | clienttwo | run 1's read records DENY 'not found' on the seeded relation, at least one | read records: 1, 0 otherwise | pass |
| R3 | read within retention | clienttwo | run 2's first read ALLOW on the seeded relation, its written time that of run 1's last write of the same state | ALLOW ('vfl_client_model', 'latest') on GUID-state-aware, written 1794623902, run 1's last write 1794623902 | pass |
| completeness | every state file has a write ALLOW record | clienttwo | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| runs | two runs | clientthree | 2 runs of job records | 2 | pass |
| outside | read of an absent object | clientthree | run 1's read records DENY 'not found' on the seeded relation, at least one | read records: 1, 0 otherwise | pass |
| R3 | read within retention | clientthree | run 2's first read ALLOW on the seeded relation, its written time that of run 1's last write of the same state | ALLOW ('vfl_client_model', 'latest') on GUID-state-aware, written 1794623902, run 1's last write 1794623902 | pass |
| completeness | every state file has a write ALLOW record | clientthree | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
