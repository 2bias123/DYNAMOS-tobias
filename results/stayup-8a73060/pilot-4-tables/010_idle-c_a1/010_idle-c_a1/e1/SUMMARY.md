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
- pods.csv: 46 rows
- records.csv: 62 rows
- verdict.csv: 212 rows

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
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
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
- check verdict.csv class · inspector: pass (4 rows, 0 failing)
- check verdict.csv node · inspector: pass (4 rows, 0 failing)
- check verdict.csv digest · inspector: pass (4 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 166258.4 ms, median 166258.4 ms, maximum 166258.4 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=8, minimum 139.5 ms, median 170.5 ms, maximum 31597.2 ms
- events.csv duration_us (deploy gap: held): n=8, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 2.4 ms, median 2.5 ms, maximum 2.5 ms
- events.csv duration_us (run done): n=2, minimum 28393.7 ms, median 39819.9 ms, maximum 51246.1 ms
- idle.csv value_us (run 1): n=4, minimum 3139.0 ms, median 3510.7 ms, maximum 3961.1 ms
- idle.csv value_us (run 2): n=4, minimum 18141.6 ms, median 18505.4 ms, maximum 18964.4 ms
- idle.csv value_us ((c) hand-over): n=8, minimum 1037.5 ms, median 2394.7 ms, maximum 3494.0 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| stay-up | run 1: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 3.1 s after the job's enforcement point ended (its container started 3 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-wxpmz | pass |
| stay-up | run 1: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 3.5 s after the job's enforcement point ended (its container started 3 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-grhdz | pass |
| stay-up | run 1: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 3.6 s after the job's enforcement point ended (its container started 3 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-xp4hj | pass |
| stay-up | run 1: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 4.0 s after the job's enforcement point ended (its container started 3 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-nb87j | pass |
| stay-up | run 2: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 18.1 s after the job's enforcement point ended (its container started 18 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-cs9t8 | pass |
| stay-up | run 2: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 18.4 s after the job's enforcement point ended (its container started 18 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-n6l2q | pass |
| stay-up | run 2: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 18.6 s after the job's enforcement point ended (its container started 18 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-7f2lr | pass |
| stay-up | run 2: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 19.0 s after the job's enforcement point ended (its container started 18 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-rcf5h | pass |
| stay-up | (c) hand-over | server | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1101 ms, logged 3.494 s before the job's first record | pass |
| stay-up | (c) every round persists | server | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) state read back | server | run 2's first read ALLOW, its written time that of run 1's last write of the same state | ALLOW ('vfl_server_model', 'latest'), written 1794671386, run 1's last write 1794671386 | pass |
| stay-up | (c) hand-over | clientone | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1097 ms, logged 3.252 s before the job's first record | pass |
| stay-up | (c) every round persists | clientone | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) hand-over | clienttwo | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1559 ms, logged 3.230 s before the job's first record | pass |
| stay-up | (c) every round persists | clienttwo | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
| stay-up | (c) hand-over | clientthree | one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job decides, the job's enforcement point started and decided first after that line | hand-over 1038 ms, logged 3.322 s before the job's first record | pass |
| stay-up | (c) every round persists | clientthree | 3 write ALLOW records by run 2's job, nothing else | 3 write records, 3 ALLOW | pass |
