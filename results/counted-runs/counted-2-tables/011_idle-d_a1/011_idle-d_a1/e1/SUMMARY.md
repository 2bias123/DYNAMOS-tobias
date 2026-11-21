# e1 idle-d, attempt 1

- outcome: pass

## What ran

- cases.csv: 12 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 16 rows
- idle.csv: 8 rows
- markers.csv: 4 rows
- pods.csv: 43 rows
- records.csv: 31 rows
- verdict.csv: 183 rows

## Checks

- check missing values: pass
- check cases.csv stay-up · run: idle up · server: pass
- check cases.csv stay-up · run: idle up · clientone: pass
- check cases.csv stay-up · run: idle up · clienttwo: pass
- check cases.csv stay-up · run: idle up · clientthree: pass
- check cases.csv stay-up · (d) nothing due · server: pass
- check cases.csv stay-up · (d) the same idle process · server: pass
- check cases.csv stay-up · (d) nothing due · clientone: pass
- check cases.csv stay-up · (d) the same idle process · clientone: pass
- check cases.csv stay-up · (d) nothing due · clienttwo: pass
- check cases.csv stay-up · (d) the same idle process · clienttwo: pass
- check cases.csv stay-up · (d) nothing due · clientthree: pass
- check cases.csv stay-up · (d) the same idle process · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check clocks idle.csv: pass (8 intervals, each on one machine)
- check idle.csv run · idle up after the job · server: pass
- check idle.csv run · idle up after the job · clientone: pass
- check idle.csv run · idle up after the job · clienttwo: pass
- check idle.csv run · idle up after the job · clientthree: pass
- check idle.csv (d) nothing due · window · server: pass
- check idle.csv (d) nothing due · window · clientone: pass
- check idle.csv (d) nothing due · window · clienttwo: pass
- check idle.csv (d) nothing due · window · clientthree: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 20 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 56 files)
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
- check verdict.csv class · inspector: pass (9 rows, 0 failing)
- check verdict.csv node · inspector: pass (9 rows, 0 failing)
- check verdict.csv digest · inspector: pass (9 rows, 0 failing; also not started)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 198112.8 ms, median 198112.8 ms, maximum 198112.8 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 160.5 ms, median 173.8 ms, maximum 184.7 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 2.7 ms, median 2.7 ms, maximum 2.7 ms
- events.csv duration_us (run done): n=1, minimum 30517.9 ms, median 30517.9 ms, maximum 30517.9 ms
- events.csv duration_us ((d) window): n=1, minimum 95000.0 ms, median 95000.0 ms, maximum 95000.0 ms
- idle.csv value_us (run): n=4, minimum 27475.4 ms, median 28003.0 ms, maximum 28473.9 ms
- idle.csv value_us ((d) nothing due): n=4, minimum 95000.1 ms, median 95000.1 ms, maximum 95000.1 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| stay-up | run: idle up | server | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 28.1 s after the job's enforcement point ended (its container started 28 s after), pod idle-state-server-ad751c18-vfltrainmodelrequest-kf6zd | pass |
| stay-up | run: idle up | clientone | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 27.5 s after the job's enforcement point ended (its container started 27 s after), pod idle-state-clientone-ad751c18-vfltrainmodelrequest-hc8gp | pass |
| stay-up | run: idle up | clienttwo | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 28.5 s after the job's enforcement point ended (its container started 28 s after), pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-jjvsc | pass |
| stay-up | run: idle up | clientthree | an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within 60 s of the job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM | idle up 27.9 s after the job's enforcement point ended (its container started 27 s after), pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-87qxt | pass |
| stay-up | (d) nothing due | server | over 3 polls of 30 s plus 5 s the audit log and every state file unchanged, at least one state file (the idle form logs no poll: that the polls took place is not shown) | audit log and 1 state files byte-identical over 95.000 s | pass |
| stay-up | (d) the same idle process | server | the idle pod from before the window still running with its agreement loaded, not restarted | pod idle-state-server-ad751c18-vfltrainmodelrequest-kf6zd running, 0 restarts | pass |
| stay-up | (d) nothing due | clientone | over 3 polls of 30 s plus 5 s the audit log and every state file unchanged, at least one state file (the idle form logs no poll: that the polls took place is not shown) | audit log and 1 state files byte-identical over 95.000 s | pass |
| stay-up | (d) the same idle process | clientone | the idle pod from before the window still running with its agreement loaded, not restarted | pod idle-state-clientone-ad751c18-vfltrainmodelrequest-hc8gp running, 0 restarts | pass |
| stay-up | (d) nothing due | clienttwo | over 3 polls of 30 s plus 5 s the audit log and every state file unchanged, at least one state file (the idle form logs no poll: that the polls took place is not shown) | audit log and 1 state files byte-identical over 95.000 s | pass |
| stay-up | (d) the same idle process | clienttwo | the idle pod from before the window still running with its agreement loaded, not restarted | pod idle-state-clienttwo-ad751c18-vfltrainmodelrequest-jjvsc running, 0 restarts | pass |
| stay-up | (d) nothing due | clientthree | over 3 polls of 30 s plus 5 s the audit log and every state file unchanged, at least one state file (the idle form logs no poll: that the polls took place is not shown) | audit log and 1 state files byte-identical over 95.000 s | pass |
| stay-up | (d) the same idle process | clientthree | the idle pod from before the window still running with its agreement loaded, not restarted | pod idle-state-clientthree-ad751c18-vfltrainmodelrequest-87qxt running, 0 restarts | pass |
