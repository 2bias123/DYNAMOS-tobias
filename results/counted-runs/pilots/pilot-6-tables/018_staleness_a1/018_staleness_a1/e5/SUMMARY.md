# e5 staleness, attempt 1

- outcome: pass

## What ran

- build.csv: 1 rows
- cases.csv: 1 rows
- claims.csv: 0 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- episodes-staleness.csv: 1 rows
- events.csv: 5 rows
- markers.csv: 4 rows
- pods.csv: 14 rows
- records.csv: 23 rows
- verdict.csv: 56 rows

## Checks

- check missing values: pass
- check cases.csv staleness · episode 1 · local: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check clocks episodes-staleness.csv: pass (1 intervals, each on one machine)
- check episodes-staleness.csv 1: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 0 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 8 files)
- check verdict.csv class · request path: pass (6 rows, 0 failing)
- check verdict.csv node · request path: pass (6 rows, 0 failing)
- check verdict.csv digest · request path: pass (12 rows, 0 failing)
- check verdict.csv class · agent: pass (8 rows, 0 failing)
- check verdict.csv node · agent: pass (8 rows, 0 failing)
- check verdict.csv digest · agent: pass (16 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- episodes-staleness.csv value_us: n=1, minimum 9008.9 ms, median 9008.9 ms, maximum 9008.9 ms
- events.csv duration_us (clean start): n=1, minimum 70156.9 ms, median 70156.9 ms, maximum 70156.9 ms
- events.csv duration_us (outage: etcd forward stopped): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (flip sent during the outage): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (recovery: etcd forward relaunched): n=1, minimum 201.6 ms, median 201.6 ms, maximum 201.6 ms
- events.csv duration_us (re-enable sent): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
