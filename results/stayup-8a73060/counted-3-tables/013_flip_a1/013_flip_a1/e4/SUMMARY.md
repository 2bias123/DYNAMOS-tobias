# e4 flip, attempt 1

- outcome: pass

## What ran

- cases.csv: 14 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 55 rows
- expiry.csv: 4 rows
- markers.csv: 4 rows
- pods.csv: 44 rows
- records.csv: 254 rows
- rounds-flip.csv: 50 rows
- storage.csv: 4 rows
- verdict.csv: 206 rows

## Checks

- check missing values: pass
- check cases.csv allow then deny · allow then deny · server: pass
- check cases.csv run 1 destroys nothing · run 1 destroys nothing · server: pass
- check cases.csv put on the claim's VM · put on the claim's VM · server: pass
- check cases.csv expiry window · expiry window · server: pass
- check cases.csv nothing to resume · nothing to resume · server: pass
- check cases.csv persisted every round · persisted every round · clientone: pass
- check cases.csv run 1 destroys nothing · run 1 destroys nothing · clientone: pass
- check cases.csv expiry window · expiry window · clientone: pass
- check cases.csv persisted every round · persisted every round · clienttwo: pass
- check cases.csv run 1 destroys nothing · run 1 destroys nothing · clienttwo: pass
- check cases.csv expiry window · expiry window · clienttwo: pass
- check cases.csv persisted every round · persisted every round · clientthree: pass
- check cases.csv run 1 destroys nothing · run 1 destroys nothing · clientthree: pass
- check cases.csv expiry window · expiry window · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check expiry.csv server: pass
- check expiry.csv clientone: pass
- check expiry.csv clienttwo: pass
- check expiry.csv clientthree: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 28 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 23 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 23 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 71 files)
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
- check verdict.csv class · inspector: pass (2 rows, 0 failing)
- check verdict.csv node · inspector: pass (2 rows, 0 failing)
- check verdict.csv digest · inspector: pass (2 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 213399.4 ms, median 213399.4 ms, maximum 213399.4 ms
- events.csv duration_us (seed: deny but retain): n=4, minimum 3.8 ms, median 4.4 ms, maximum 6.5 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=12, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=12, minimum 165.5 ms, median 189.9 ms, maximum 29554.9 ms
- events.csv duration_us (deploy gap: held): n=12, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 2.3 ms, median 2.7 ms, maximum 3.2 ms
- events.csv duration_us (flip: server allowed=false, round 9 closed and seen at 1794719511612717): n=1, minimum 6.2 ms, median 6.2 ms, maximum 6.2 ms
- events.csv duration_us (run done): n=2, minimum 20086.3 ms, median 33937.1 ms, maximum 47787.9 ms
- events.csv duration_us (seed: retention 120 s): n=4, minimum 0.0 ms, median 3.7 ms, maximum 6.2 ms
- events.csv duration_us (idle job seen): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (expiry wait): n=1, minimum 126118.5 ms, median 126118.5 ms, maximum 126118.5 ms
- expiry.csv after_due_us (server): n=1, minimum 127.1 ms, median 127.1 ms, maximum 127.1 ms
- expiry.csv after_due_us (clientone): n=1, minimum 14538.3 ms, median 14538.3 ms, maximum 14538.3 ms
- expiry.csv after_due_us (clienttwo): n=1, minimum 15228.8 ms, median 15228.8 ms, maximum 15228.8 ms
- expiry.csv after_due_us (clientthree): n=1, minimum 15380.0 ms, median 15380.0 ms, maximum 15380.0 ms
- expiry.csv after_write_us (server): n=1, minimum 120127.1 ms, median 120127.1 ms, maximum 120127.1 ms
- expiry.csv after_write_us (clientone): n=1, minimum 134538.3 ms, median 134538.3 ms, maximum 134538.3 ms
- expiry.csv after_write_us (clienttwo): n=1, minimum 135228.8 ms, median 135228.8 ms, maximum 135228.8 ms
- expiry.csv after_write_us (clientthree): n=1, minimum 135380.0 ms, median 135380.0 ms, maximum 135380.0 ms
