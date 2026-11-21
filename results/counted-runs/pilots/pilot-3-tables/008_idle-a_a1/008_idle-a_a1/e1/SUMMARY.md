# e1 idle-a, attempt 1

- outcome: pass

## What ran

- cases.csv: 12 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 19 rows
- idle.csv: 8 rows
- markers.csv: 4 rows
- pods.csv: 36 rows
- records.csv: 35 rows
- verdict.csv: 162 rows

## Checks

- check missing values: pass
- check cases.csv stay-up · run: idle up · server: pass
- check cases.csv stay-up · run: idle up · clientone: pass
- check cases.csv stay-up · run: idle up · clienttwo: pass
- check cases.csv stay-up · run: idle up · clientthree: pass
- check cases.csv stay-up · (a) revocation · server: pass
- check cases.csv stay-up · (a) idle process ended · server: pass
- check cases.csv stay-up · (a) revocation · clientone: pass
- check cases.csv stay-up · (a) idle process ended · clientone: pass
- check cases.csv stay-up · (a) revocation · clienttwo: pass
- check cases.csv stay-up · (a) idle process ended · clienttwo: pass
- check cases.csv stay-up · (a) revocation · clientthree: pass
- check cases.csv stay-up · (a) idle process ended · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check clocks idle.csv: pass (8 intervals, each on one machine)
- check idle.csv run · idle up after the job · server: pass
- check idle.csv run · idle up after the job · clientone: pass
- check idle.csv run · idle up after the job · clienttwo: pass
- check idle.csv run · idle up after the job · clientthree: pass
- check idle.csv (a) revocation · PURGED vfl_server_model/latest · server: pass
- check idle.csv (a) revocation · PURGED vfl_client_model/latest · clientone: pass
- check idle.csv (a) revocation · PURGED vfl_client_model/latest · clienttwo: pass
- check idle.csv (a) revocation · PURGED vfl_client_model/latest · clientthree: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 20 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 12 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 12 files)
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
- check verdict.csv class · inspector: pass (2 rows, 0 failing)
- check verdict.csv node · inspector: pass (2 rows, 0 failing)
- check verdict.csv digest · inspector: pass (2 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 224323.1 ms, median 224323.1 ms, maximum 224323.1 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 192.7 ms, median 233.6 ms, maximum 245.6 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 3.2 ms, median 3.2 ms, maximum 3.2 ms
- events.csv duration_us (run done): n=1, minimum 28960.0 ms, median 28960.0 ms, maximum 28960.0 ms
- events.csv duration_us ((a) revocation sent): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- idle.csv value_us (run): n=4, minimum 27060.9 ms, median 27726.0 ms, maximum 28234.1 ms
- idle.csv value_us ((a) revocation): n=4, minimum 33.1 ms, median 36.7 ms, maximum 44.4 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| stay-up | run: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 27.1 s after the job's enforcement point ended (its container started 27 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-qnpmj | pass |
| stay-up | run: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 27.8 s after the job's enforcement point ended (its container started 27 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-8vxlw | pass |
| stay-up | run: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 28.2 s after the job's enforcement point ended (its container started 28 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-nxnlr | pass |
| stay-up | run: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 27.7 s after the job's enforcement point ended (its container started 27 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-k78qx | pass |
| stay-up | (a) revocation | server | one PURGED record per state file the run wrote, idle form (no job fields) on fresh terms, decided 0 to 5 s after the revocation's send from the steward's own VM, no state file left | 1 PURGED for 1 state files written, 0.044 to 0.044 s after the send; 0 state files left; clocks one: server | pass |
| stay-up | (a) idle process ended | server | the idle Job complete after the purge (exit 0) | complete | pass |
| stay-up | (a) revocation | clientone | one PURGED record per state file the run wrote, idle form (no job fields) on fresh terms, decided 0 to 5 s after the revocation's send from the steward's own VM, no state file left | 1 PURGED for 1 state files written, 0.037 to 0.037 s after the send; 0 state files left; clocks one: clientone | pass |
| stay-up | (a) idle process ended | clientone | the idle Job complete after the purge (exit 0) | complete | pass |
| stay-up | (a) revocation | clienttwo | one PURGED record per state file the run wrote, idle form (no job fields) on fresh terms, decided 0 to 5 s after the revocation's send from the steward's own VM, no state file left | 1 PURGED for 1 state files written, 0.033 to 0.033 s after the send; 0 state files left; clocks one: clienttwo | pass |
| stay-up | (a) idle process ended | clienttwo | the idle Job complete after the purge (exit 0) | complete | pass |
| stay-up | (a) revocation | clientthree | one PURGED record per state file the run wrote, idle form (no job fields) on fresh terms, decided 0 to 5 s after the revocation's send from the steward's own VM, no state file left | 1 PURGED for 1 state files written, 0.037 to 0.037 s after the send; 0 state files left; clocks one: clientthree | pass |
| stay-up | (a) idle process ended | clientthree | the idle Job complete after the purge (exit 0) | complete | pass |
