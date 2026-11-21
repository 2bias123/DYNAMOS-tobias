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

- events.csv duration_us (clean start): n=1, minimum 186518.3 ms, median 186518.3 ms, maximum 186518.3 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=8, minimum 134.7 ms, median 158.9 ms, maximum 31640.0 ms
- events.csv duration_us (deploy gap: held): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 3.1 ms, median 3.2 ms, maximum 3.3 ms
- events.csv duration_us (run done): n=2, minimum 29680.3 ms, median 38480.5 ms, maximum 47280.6 ms
- idle.csv value_us (run 1): n=4, minimum 5243.4 ms, median 5495.7 ms, maximum 6026.7 ms
- idle.csv value_us (run 2): n=4, minimum 16259.8 ms, median 16512.2 ms, maximum 17032.9 ms
- idle.csv value_us ((c) hand-over): n=8, minimum 523.4 ms, median 2157.6 ms, maximum 3778.7 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| stay-up | run 1: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 5.2 s after the job's enforcement point ended (its container started 5 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-xq9ml | pass |
| stay-up | run 1: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 5.5 s after the job's enforcement point ended (its container started 5 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-76zq2 | pass |
| stay-up | run 1: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 5.4 s after the job's enforcement point ended (its container started 5 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-bctnf | pass |
| stay-up | run 1: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 6.0 s after the job's enforcement point ended (its container started 6 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-8skfv | pass |
| stay-up | run 2: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 16.3 s after the job's enforcement point ended (its container started 16 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-t6kdg | pass |
| stay-up | run 2: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 16.6 s after the job's enforcement point ended (its container started 16 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-rkp9q | pass |
| stay-up | run 2: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 16.5 s after the job's enforcement point ended (its container started 16 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-5krcs | pass |
| stay-up | run 2: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 17.0 s after the job's enforcement point ended (its container started 17 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-4c2cw | pass |
| stay-up | (c) hand-over | server | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 866 ms, logged 3.248 s before the job's first record | pass |
| stay-up | (c) every round persists | server | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) state read back | server | run 2's first read ALLOW, its written time that of run 1's last write of the same state | ALLOW ('vfl_server_model', 'latest'), written 1794681452, run 1's last write 1794681452 | pass |
| stay-up | (c) hand-over | clientone | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1067 ms, logged 3.779 s before the job's first record | pass |
| stay-up | (c) every round persists | clientone | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) hand-over | clienttwo | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1022 ms, logged 3.431 s before the job's first record | pass |
| stay-up | (c) every round persists | clienttwo | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) hand-over | clientthree | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 523 ms, logged 3.277 s before the job's first record | pass |
| stay-up | (c) every round persists | clientthree | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
