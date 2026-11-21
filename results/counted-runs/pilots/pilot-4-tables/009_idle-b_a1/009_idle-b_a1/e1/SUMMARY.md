# e1 idle-b, attempt 1

- outcome: pass

## What ran

- cases.csv: 16 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 19 rows
- expiry.csv: 4 rows
- idle.csv: 4 rows
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
- check cases.csv stay-up · (b) expiry · server: pass
- check cases.csv stay-up · (b) no job in the window · server: pass
- check cases.csv stay-up · (b) idle process ended · server: pass
- check cases.csv stay-up · (b) expiry · clientone: pass
- check cases.csv stay-up · (b) no job in the window · clientone: pass
- check cases.csv stay-up · (b) idle process ended · clientone: pass
- check cases.csv stay-up · (b) expiry · clienttwo: pass
- check cases.csv stay-up · (b) no job in the window · clienttwo: pass
- check cases.csv stay-up · (b) idle process ended · clienttwo: pass
- check cases.csv stay-up · (b) expiry · clientthree: pass
- check cases.csv stay-up · (b) no job in the window · clientthree: pass
- check cases.csv stay-up · (b) idle process ended · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check expiry.csv server: pass
- check expiry.csv clientone: pass
- check expiry.csv clienttwo: pass
- check expiry.csv clientthree: pass
- check clocks idle.csv: pass (4 intervals, each on one machine)
- check idle.csv run · idle up after the job · server: pass
- check idle.csv run · idle up after the job · clientone: pass
- check idle.csv run · idle up after the job · clienttwo: pass
- check idle.csv run · idle up after the job · clientthree: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 20 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 50 files)
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
- check verdict.csv digest · inspector: pass (2 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 163746.9 ms, median 163746.9 ms, maximum 163746.9 ms
- events.csv duration_us (seed: retention 120 s): n=4, minimum 3.4 ms, median 4.1 ms, maximum 6.0 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 126.2 ms, median 129.1 ms, maximum 161.5 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 2.6 ms, median 2.6 ms, maximum 2.6 ms
- events.csv duration_us (run done): n=1, minimum 28350.8 ms, median 28350.8 ms, maximum 28350.8 ms
- expiry.csv after_due_us (server): n=1, minimum 2018.6 ms, median 2018.6 ms, maximum 2018.6 ms
- expiry.csv after_due_us (clientone): n=1, minimum 2060.9 ms, median 2060.9 ms, maximum 2060.9 ms
- expiry.csv after_due_us (clienttwo): n=1, minimum 2153.6 ms, median 2153.6 ms, maximum 2153.6 ms
- expiry.csv after_due_us (clientthree): n=1, minimum 2632.2 ms, median 2632.2 ms, maximum 2632.2 ms
- expiry.csv after_write_us (server): n=1, minimum 122018.6 ms, median 122018.6 ms, maximum 122018.6 ms
- expiry.csv after_write_us (clientone): n=1, minimum 122060.9 ms, median 122060.9 ms, maximum 122060.9 ms
- expiry.csv after_write_us (clienttwo): n=1, minimum 122153.6 ms, median 122153.6 ms, maximum 122153.6 ms
- expiry.csv after_write_us (clientthree): n=1, minimum 122632.2 ms, median 122632.2 ms, maximum 122632.2 ms
- idle.csv value_us (run): n=4, minimum 30262.7 ms, median 30438.1 ms, maximum 30967.1 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| stay-up | run: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 30.3 s after the job's enforcement point ended (its container started 30 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-bt5q7 | pass |
| stay-up | run: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 30.4 s after the job's enforcement point ended (its container started 30 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-4hbr5 | pass |
| stay-up | run: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 30.5 s after the job's enforcement point ended (its container started 30 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-2pbfp | pass |
| stay-up | run: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 31.0 s after the job's enforcement point ended (its container started 30 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-mzz95 | pass |
| stay-up | (b) expiry | server | every state file has one DELETED record, either form, from retention 120 s to retention + 35 s after its last write ALLOW; DEFERRED and CANCELLED kept | vfl_server_model/latest: DELETED 122.0 s after its last write, idle form; 0 DEFERRED and 0 CANCELLED kept | pass |
| stay-up | (b) no job in the window | server | no record by a job after the run's shutdown record | 0 job records after it | pass |
| stay-up | (b) idle process ended | server | no state file left and the idle Job complete | 0 state files left, idle Job complete | pass |
| stay-up | (b) expiry | clientone | every state file has one DELETED record, either form, from retention 120 s to retention + 35 s after its last write ALLOW; DEFERRED and CANCELLED kept | vfl_client_model/latest: DELETED 122.1 s after its last write, idle form; 0 DEFERRED and 0 CANCELLED kept | pass |
| stay-up | (b) no job in the window | clientone | no record by a job after the run's shutdown record | 0 job records after it | pass |
| stay-up | (b) idle process ended | clientone | no state file left and the idle Job complete | 0 state files left, idle Job complete | pass |
| stay-up | (b) expiry | clienttwo | every state file has one DELETED record, either form, from retention 120 s to retention + 35 s after its last write ALLOW; DEFERRED and CANCELLED kept | vfl_client_model/latest: DELETED 122.2 s after its last write, idle form; 0 DEFERRED and 0 CANCELLED kept | pass |
| stay-up | (b) no job in the window | clienttwo | no record by a job after the run's shutdown record | 0 job records after it | pass |
| stay-up | (b) idle process ended | clienttwo | no state file left and the idle Job complete | 0 state files left, idle Job complete | pass |
| stay-up | (b) expiry | clientthree | every state file has one DELETED record, either form, from retention 120 s to retention + 35 s after its last write ALLOW; DEFERRED and CANCELLED kept | vfl_client_model/latest: DELETED 122.6 s after its last write, idle form; 0 DEFERRED and 0 CANCELLED kept | pass |
| stay-up | (b) no job in the window | clientthree | no record by a job after the run's shutdown record | 0 job records after it | pass |
| stay-up | (b) idle process ended | clientthree | no state file left and the idle Job complete | 0 state files left, idle Job complete | pass |
