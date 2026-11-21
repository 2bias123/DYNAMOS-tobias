# e2 poll, attempt 1

- outcome: pass

## What ran

- cases.csv: 4 rows
- claims.csv: 0 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 7 rows
- markers.csv: 4 rows
- pods.csv: 19 rows
- records.csv: 91 rows
- trials-poll.csv: 2 rows
- verdict.csv: 72 rows

## Checks

- check missing values: pass
- check cases.csv poll · trial 1 · server: pass
- check cases.csv poll · trial 2 · server: pass
- check cases.csv complete log · trial 1 · server: pass
- check cases.csv complete log · trial 2 · server: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 5 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 9 files)
- check clocks trials-poll.csv: pass (2 intervals, each on one machine)
- check trials-poll.csv 1: pass
- check trials-poll.csv 2: pass
- check verdict.csv class · request path: pass (6 rows, 0 failing)
- check verdict.csv node · request path: pass (6 rows, 0 failing)
- check verdict.csv digest · request path: pass (12 rows, 0 failing)
- check verdict.csv class · agent: pass (8 rows, 0 failing)
- check verdict.csv node · agent: pass (8 rows, 0 failing)
- check verdict.csv digest · agent: pass (16 rows, 0 failing)
- check verdict.csv class · idle: pass (4 rows, 0 failing)
- check verdict.csv node · idle: pass (4 rows, 0 failing)
- check verdict.csv digest · idle: pass (4 rows, 0 failing)
- check verdict.csv class · standalone: pass (1 rows, 0 failing)
- check verdict.csv node · standalone: pass (1 rows, 0 failing)
- check verdict.csv digest · standalone: pass (2 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 64679.7 ms, median 64679.7 ms, maximum 64679.7 ms
- events.csv duration_us (standalone gateway up): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (re-enable sent): n=3, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (flip sent): n=2, minimum 32.0 ms, median 32.5 ms, maximum 33.0 ms
- trials-poll.csv value_us: n=2, minimum 25600.2 ms, median 27040.0 ms, maximum 28479.7 ms
- trials-poll.csv rtt_us: n=2, minimum 32.0 ms, median 32.5 ms, maximum 33.0 ms
