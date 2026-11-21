# e1 adversarial, attempt 1

- outcome: fail: exit 1: e1 adversarial: Failed: kubectl exec -n server jake-jongejans-9ba65192server1-lm4cm -c policy-checkpoint-gateway -- rm /state/data/adversarial/rogue.bin: exit 1: error: Internal error occurred: unable to upgrade connection: container not found ("policy-checkpoint-gateway")

## What ran

- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 19 rows
- markers.csv: 4 rows
- pods.csv: 31 rows
- verdict.csv: 147 rows

## Checks

- check missing values: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 16 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 18 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 18 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 50 files)
- check verdict.csv class · request path: pass (6 rows, 0 failing)
- check verdict.csv node · request path: pass (6 rows, 0 failing)
- check verdict.csv digest · request path: pass (12 rows, 0 failing)
- check verdict.csv class · agent: pass (8 rows, 0 failing)
- check verdict.csv node · agent: pass (8 rows, 0 failing)
- check verdict.csv digest · agent: pass (16 rows, 0 failing)
- check verdict.csv class · idle: pass (8 rows, 0 failing)
- check verdict.csv node · idle: pass (8 rows, 0 failing)
- check verdict.csv digest · idle: pass (8 rows, 0 failing)
- check verdict.csv class · chain: pass (8 rows, 0 failing)
- check verdict.csv node · chain: pass (8 rows, 0 failing)
- check verdict.csv digest · chain: pass (48 rows, 0 failing)
- check verdict.csv class · inspector: pass (1 rows, 0 failing)
- check verdict.csv node · inspector: pass (1 rows, 0 failing)
- check verdict.csv digest · inspector: pass (1 rows, 0 failing)
- check verdict: fail

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 180955.7 ms, median 180955.7 ms, maximum 180955.7 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=4, minimum 133.8 ms, median 141.4 ms, maximum 144.8 ms
- events.csv duration_us (deploy gap: held): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=1, minimum 2.7 ms, median 2.7 ms, maximum 2.7 ms
- events.csv duration_us (adversarial: chain up): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (adversarial: tampered identity and concurrent writes sent): n=1, minimum 297.6 ms, median 297.6 ms, maximum 297.6 ms
- events.csv duration_us (adversarial: a file written past the enforcement point): n=1, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (adversarial: listing taken during a write, taken again): n=2, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
