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
- pods.csv: 45 rows
- records.csv: 78 rows
- rounds-flip.csv: 6 rows
- storage.csv: 4 rows
- verdict.csv: 209 rows

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
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check expiry.csv server: pass
- check expiry.csv clientone: pass
- check expiry.csv clienttwo: pass
- check expiry.csv clientthree: pass
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 28 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 8 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 8 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 69 files)
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
- check verdict.csv class · inspector: pass (3 rows, 0 failing)
- check verdict.csv node · inspector: pass (3 rows, 0 failing)
- check verdict.csv digest · inspector: pass (3 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 200184.3 ms, median 200184.3 ms, maximum 200184.3 ms
- events.csv duration_us (seed: deny but retain): n=4, minimum 3.8 ms, median 4.1 ms, maximum 6.1 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=12, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=12, minimum 149.7 ms, median 180.6 ms, maximum 31477.0 ms
- events.csv duration_us (deploy gap: held): n=12, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=2, minimum 2.5 ms, median 3.5 ms, maximum 4.4 ms
- events.csv duration_us (flip: server allowed=false, round 2 closed and seen at 1794672505160465): n=1, minimum 6.1 ms, median 6.1 ms, maximum 6.1 ms
- events.csv duration_us (run done): n=2, minimum 13954.6 ms, median 28398.6 ms, maximum 42842.6 ms
- events.csv duration_us (seed: retention 120 s): n=4, minimum 0.0 ms, median 4.6 ms, maximum 6.7 ms
- events.csv duration_us (idle job seen): n=4, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (expiry wait): n=1, minimum 127595.2 ms, median 127595.2 ms, maximum 127595.2 ms
- expiry.csv after_due_us (server): n=1, minimum 18910.1 ms, median 18910.1 ms, maximum 18910.1 ms
- expiry.csv after_due_us (clientone): n=1, minimum 18526.8 ms, median 18526.8 ms, maximum 18526.8 ms
- expiry.csv after_due_us (clienttwo): n=1, minimum 18622.6 ms, median 18622.6 ms, maximum 18622.6 ms
- expiry.csv after_due_us (clientthree): n=1, minimum 18706.9 ms, median 18706.9 ms, maximum 18706.9 ms
- expiry.csv after_write_us (server): n=1, minimum 138910.1 ms, median 138910.1 ms, maximum 138910.1 ms
- expiry.csv after_write_us (clientone): n=1, minimum 138526.8 ms, median 138526.8 ms, maximum 138526.8 ms
- expiry.csv after_write_us (clienttwo): n=1, minimum 138622.6 ms, median 138622.6 ms, maximum 138622.6 ms
- expiry.csv after_write_us (clientthree): n=1, minimum 138706.9 ms, median 138706.9 ms, maximum 138706.9 ms
