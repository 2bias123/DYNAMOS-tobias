# e1 idle-c, attempt 1

- outcome: pass

## What ran

- cases.csv: 17 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 29 rows
- idle.csv: 16 rows
- markers.csv: 4 rows
- pods.csv: 48 rows
- records.csv: 62 rows
- verdict.csv: 218 rows

## Checks

- check missing values: pass
- check cases.csv stay-up · run 1: idle up · server: pass
- check cases.csv stay-up · run 1: idle up · clientone: pass
- check cases.csv stay-up · run 1: idle up · clienttwo: pass
- check cases.csv stay-up · run 1: idle up · clientthree: pass
- check cases.csv stay-up · run 2: idle up · server: pass
- check cases.csv stay-up · run 2: idle up · clientone: pass
- check cases.csv stay-up · run 2: idle up · clienttwo: pass
- check cases.csv stay-up · run 2: idle up · clientthree: pass
- check cases.csv stay-up · (c) hand-over · server: pass
- check cases.csv stay-up · (c) every round persists · server: pass
- check cases.csv stay-up · (c) state read back · server: pass
- check cases.csv stay-up · (c) hand-over · clientone: pass
- check cases.csv stay-up · (c) every round persists · clientone: pass
- check cases.csv stay-up · (c) hand-over · clienttwo: pass
- check cases.csv stay-up · (c) every round persists · clienttwo: pass
- check cases.csv stay-up · (c) hand-over · clientthree: pass
- check cases.csv stay-up · (c) every round persists · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check clocks idle.csv: pass (16 intervals, each on one machine)
- check idle.csv run 1 · idle up after the job · server: pass
- check idle.csv run 1 · idle up after the job · clientone: pass
- check idle.csv run 1 · idle up after the job · clienttwo: pass
- check idle.csv run 1 · idle up after the job · clientthree: pass
- check idle.csv run 2 · idle up after the job · server: pass
- check idle.csv run 2 · idle up after the job · clientone: pass
- check idle.csv run 2 · idle up after the job · clienttwo: pass
- check idle.csv run 2 · idle up after the job · clientthree: pass
- check idle.csv (c) hand-over · duration logged by the agent · server: pass
- check idle.csv (c) hand-over · hand-over line to the job's first record · server: pass
- check idle.csv (c) hand-over · duration logged by the agent · clientone: pass
- check idle.csv (c) hand-over · hand-over line to the job's first record · clientone: pass
- check idle.csv (c) hand-over · duration logged by the agent · clienttwo: pass
- check idle.csv (c) hand-over · hand-over line to the job's first record · clienttwo: pass
- check idle.csv (c) hand-over · duration logged by the agent · clientthree: pass
- check idle.csv (c) hand-over · hand-over line to the job's first record · clientthree: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 28 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
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
- check verdict.csv class · inspector: pass (6 rows, 0 failing)
- check verdict.csv node · inspector: pass (6 rows, 0 failing)
- check verdict.csv digest · inspector: pass (6 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 130815.7 ms, median 130815.7 ms, maximum 130815.7 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=8, minimum 152.7 ms, median 165.7 ms, maximum 31633.9 ms
- events.csv duration_us (deploy gap: held): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 2.8 ms, median 3.0 ms, maximum 3.3 ms
- events.csv duration_us (run done): n=2, minimum 30318.7 ms, median 38277.6 ms, maximum 46236.5 ms
- idle.csv value_us (run 1): n=4, minimum 4577.3 ms, median 4833.4 ms, maximum 5326.9 ms
- idle.csv value_us (run 2): n=4, minimum 19575.6 ms, median 19834.4 ms, maximum 20309.0 ms
- idle.csv value_us ((c) hand-over): n=8, minimum 529.6 ms, median 2367.6 ms, maximum 4026.1 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| stay-up | run 1: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 4.9 s after the job's enforcement point ended (its container started 4 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-ndlps | pass |
| stay-up | run 1: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 4.6 s after the job's enforcement point ended (its container started 4 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-dzfdj | pass |
| stay-up | run 1: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 5.3 s after the job's enforcement point ended (its container started 5 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-mdlnw | pass |
| stay-up | run 1: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 4.8 s after the job's enforcement point ended (its container started 4 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-v29m8 | pass |
| stay-up | run 2: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 19.9 s after the job's enforcement point ended (its container started 19 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-r9dnd | pass |
| stay-up | run 2: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 19.6 s after the job's enforcement point ended (its container started 19 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-wgq47 | pass |
| stay-up | run 2: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 20.3 s after the job's enforcement point ended (its container started 20 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-rzg67 | pass |
| stay-up | run 2: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 19.8 s after the job's enforcement point ended (its container started 19 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-kdqkx | pass |
| stay-up | (c) hand-over | server | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 530 ms, logged 3.885 s before the job's first record | pass |
| stay-up | (c) every round persists | server | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) state read back | server | run 2's first read ALLOW, its written time that of run 1's last write of the same state | ALLOW ('vfl_server_model', 'latest'), written 1794718404, run 1's last write 1794718404 | pass |
| stay-up | (c) hand-over | clientone | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1057 ms, logged 3.805 s before the job's first record | pass |
| stay-up | (c) every round persists | clientone | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) hand-over | clienttwo | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1047 ms, logged 3.678 s before the job's first record | pass |
| stay-up | (c) every round persists | clienttwo | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) hand-over | clientthree | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 530 ms, logged 4.026 s before the job's first record | pass |
| stay-up | (c) every round persists | clientthree | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
