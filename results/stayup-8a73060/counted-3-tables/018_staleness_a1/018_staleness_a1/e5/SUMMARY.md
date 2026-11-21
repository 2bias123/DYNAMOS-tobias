# e5 staleness, attempt 1

- outcome: pass

## What ran

- build.csv: 1 rows
- cases.csv: 5 rows
- claims.csv: 0 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- episodes-staleness.csv: 5 rows
- events.csv: 21 rows
- markers.csv: 4 rows
- pods.csv: 14 rows
- records.csv: 115 rows
- verdict.csv: 56 rows

## Checks

- check missing values: pass
- check cases.csv staleness · episode 1 · local: pass
- check cases.csv staleness · episode 2 · local: pass
- check cases.csv staleness · episode 3 · local: pass
- check cases.csv staleness · episode 4 · local: pass
- check cases.csv staleness · episode 5 · local: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check clocks episodes-staleness.csv: pass (5 intervals, each on one machine)
- check episodes-staleness.csv 1: pass
- check episodes-staleness.csv 2: pass
- check episodes-staleness.csv 3: pass
- check episodes-staleness.csv 4: pass
- check episodes-staleness.csv 5: pass
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

- episodes-staleness.csv value_us: n=5, minimum 13973.6 ms, median 14047.4 ms, maximum 18969.1 ms
- events.csv duration_us (clean start): n=1, minimum 70123.4 ms, median 70123.4 ms, maximum 70123.4 ms
- events.csv duration_us (outage: etcd forward stopped): n=5, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (flip sent during the outage): n=5, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (recovery: etcd forward relaunched): n=5, minimum 200.9 ms, median 201.1 ms, maximum 203.3 ms
- events.csv duration_us (re-enable sent): n=5, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
