# e1 adversarial, attempt 1

- outcome: pass

## What ran

- cases.csv: 8 rows
- claims.csv: 4 rows
- completeness.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 20 rows
- markers.csv: 4 rows
- operations.csv: 9 rows
- pods.csv: 38 rows
- records.csv: 188 rows
- verdict.csv: 168 rows

## Checks

- check missing values: pass
- check cases.csv adversarial · tampered identity · server: pass
- check cases.csv adversarial · 8 concurrent writes on one slot · server: pass
- check cases.csv adversarial · a file past the enforcement point · server: pass
- check cases.csv adversarial · one record per operation · server: pass
- check cases.csv completeness · every state file has a write ALLOW record · server: pass
- check cases.csv completeness · every state file has a write ALLOW record · clientone: pass
- check cases.csv completeness · every state file has a write ALLOW record · clienttwo: pass
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
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 20 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 16 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 16 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 52 files)
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
- check operations.csv server: pass
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
- check verdict.csv class · inspector: pass (4 rows, 0 failing)
- check verdict.csv node · inspector: pass (4 rows, 0 failing)
- check verdict.csv digest · inspector: pass (4 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 176381.8 ms, median 176381.8 ms, maximum 176381.8 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 159.3 ms, median 179.3 ms, maximum 187.1 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 3.1 ms, median 3.1 ms, maximum 3.1 ms
- events.csv duration_us (adversarial: chain up): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (adversarial: tampered identity and concurrent writes sent): n=1, minimum 320.5 ms, median 320.5 ms, maximum 320.5 ms
- events.csv duration_us (adversarial: a file written past the enforcement point): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (adversarial: listing taken during a write, taken again): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (adversarial: the planted file removed): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (run done): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| adversarial | tampered identity | server | the write refused PERMISSION_DENIED, one identity_mismatch record, no state file for it | PERMISSION_DENIED, 1 identity_mismatch records, no state file | pass |
| adversarial | 8 concurrent writes on one slot | server | 8 ALLOW answers, 8 write ALLOW records for the slot, one state file for it | answers ALLOW ALLOW ALLOW ALLOW ALLOW ALLOW ALLOW ALLOW, 8 records, 1 state files | pass |
| adversarial | a file past the enforcement point | server | completeness on the claim names data/adversarial/rogue.bin and nothing else | without a write ALLOW record: adversarial/rogue | pass |
| adversarial | one record per operation | server | every operation the battery sent has exactly one record of its expected op and decision, decided between its send and its return, both on the steward's VM | 9 operations, one record each | pass |
| completeness | every state file has a write ALLOW record | server | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 2 state files, each with a write ALLOW record | pass |
| completeness | every state file has a write ALLOW record | clientone | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| completeness | every state file has a write ALLOW record | clienttwo | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
| completeness | every state file has a write ALLOW record | clientthree | at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write ALLOW record of its class and key | 1 state files, each with a write ALLOW record | pass |
