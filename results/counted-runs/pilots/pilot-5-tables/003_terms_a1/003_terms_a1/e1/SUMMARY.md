# e1 terms, attempt 1

- outcome: pass

## What ran

- cases.csv: 72 rows
- claims.csv: 4 rows
- env/clocks.csv: 14 rows
- env/gates.csv: 68 rows
- events.csv: 91 rows
- markers.csv: 4 rows
- pods.csv: 65 rows
- records.csv: 163 rows
- verdict.csv: 329 rows

## Checks

- check missing values: pass
- check cases.csv runs · one run per set of terms · server: pass
- check cases.csv W1 · write, allowed false · server: pass
- check cases.csv R1 · read, allowed false · server: pass
- check cases.csv W1 · nothing destroyed, allowed false · server: pass
- check cases.csv W1 · write, no state directives · server: pass
- check cases.csv R1 · read, no state directives · server: pass
- check cases.csv W1 · nothing destroyed, no state directives · server: pass
- check cases.csv W1 · write, unknown onRevocation · server: pass
- check cases.csv R1 · read, unknown onRevocation · server: pass
- check cases.csv W1 · invalid directives recorded, unknown onRevocation · server: pass
- check cases.csv W1 · nothing destroyed, unknown onRevocation · server: pass
- check cases.csv W1 · write, negative retention · server: pass
- check cases.csv R1 · read, negative retention · server: pass
- check cases.csv W1 · invalid directives recorded, negative retention · server: pass
- check cases.csv W1 · nothing destroyed, negative retention · server: pass
- check cases.csv W4 · write, resume disabled · server: pass
- check cases.csv R2 · read, resume disabled · server: pass
- check cases.csv W4 · nothing destroyed, resume disabled · server: pass
- check cases.csv runs · one run per set of terms · clientone: pass
- check cases.csv W1 · write, allowed false · clientone: pass
- check cases.csv R1 · read, allowed false · clientone: pass
- check cases.csv W1 · nothing destroyed, allowed false · clientone: pass
- check cases.csv W1 · write, no state directives · clientone: pass
- check cases.csv R1 · read, no state directives · clientone: pass
- check cases.csv W1 · nothing destroyed, no state directives · clientone: pass
- check cases.csv W1 · write, unknown onRevocation · clientone: pass
- check cases.csv R1 · read, unknown onRevocation · clientone: pass
- check cases.csv W1 · invalid directives recorded, unknown onRevocation · clientone: pass
- check cases.csv W1 · nothing destroyed, unknown onRevocation · clientone: pass
- check cases.csv W1 · write, negative retention · clientone: pass
- check cases.csv R1 · read, negative retention · clientone: pass
- check cases.csv W1 · invalid directives recorded, negative retention · clientone: pass
- check cases.csv W1 · nothing destroyed, negative retention · clientone: pass
- check cases.csv W4 · write, resume disabled · clientone: pass
- check cases.csv R2 · read, resume disabled · clientone: pass
- check cases.csv W4 · nothing destroyed, resume disabled · clientone: pass
- check cases.csv runs · one run per set of terms · clienttwo: pass
- check cases.csv W1 · write, allowed false · clienttwo: pass
- check cases.csv R1 · read, allowed false · clienttwo: pass
- check cases.csv W1 · nothing destroyed, allowed false · clienttwo: pass
- check cases.csv W1 · write, no state directives · clienttwo: pass
- check cases.csv R1 · read, no state directives · clienttwo: pass
- check cases.csv W1 · nothing destroyed, no state directives · clienttwo: pass
- check cases.csv W1 · write, unknown onRevocation · clienttwo: pass
- check cases.csv R1 · read, unknown onRevocation · clienttwo: pass
- check cases.csv W1 · invalid directives recorded, unknown onRevocation · clienttwo: pass
- check cases.csv W1 · nothing destroyed, unknown onRevocation · clienttwo: pass
- check cases.csv W1 · write, negative retention · clienttwo: pass
- check cases.csv R1 · read, negative retention · clienttwo: pass
- check cases.csv W1 · invalid directives recorded, negative retention · clienttwo: pass
- check cases.csv W1 · nothing destroyed, negative retention · clienttwo: pass
- check cases.csv W4 · write, resume disabled · clienttwo: pass
- check cases.csv R2 · read, resume disabled · clienttwo: pass
- check cases.csv W4 · nothing destroyed, resume disabled · clienttwo: pass
- check cases.csv runs · one run per set of terms · clientthree: pass
- check cases.csv W1 · write, allowed false · clientthree: pass
- check cases.csv R1 · read, allowed false · clientthree: pass
- check cases.csv W1 · nothing destroyed, allowed false · clientthree: pass
- check cases.csv W1 · write, no state directives · clientthree: pass
- check cases.csv R1 · read, no state directives · clientthree: pass
- check cases.csv W1 · nothing destroyed, no state directives · clientthree: pass
- check cases.csv W1 · write, unknown onRevocation · clientthree: pass
- check cases.csv R1 · read, unknown onRevocation · clientthree: pass
- check cases.csv W1 · invalid directives recorded, unknown onRevocation · clientthree: pass
- check cases.csv W1 · nothing destroyed, unknown onRevocation · clientthree: pass
- check cases.csv W1 · write, negative retention · clientthree: pass
- check cases.csv R1 · read, negative retention · clientthree: pass
- check cases.csv W1 · invalid directives recorded, negative retention · clientthree: pass
- check cases.csv W1 · nothing destroyed, negative retention · clientthree: pass
- check cases.csv W4 · write, resume disabled · clientthree: pass
- check cases.csv R2 · read, resume disabled · clientthree: pass
- check cases.csv W4 · nothing destroyed, resume disabled · clientthree: pass
- check env/gates.csv node Ready · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free on / · after the clean start: pass (6 rows, 0 failing)
- check env/gates.csv disk free for archives · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv disk free for state claims · after the clean start: pass (4 rows, 0 failing)
- check env/gates.csv lease · after the clean start: pass (1 rows, 0 failing)
- check env/gates.csv stop date · after the clean start: pass (1 rows, 0 failing; also not a counted unit)
- check env/gates.csv chain images on the node · after the clean start: pass (24 rows, 0 failing)
- check env/gates.csv digest · after the clean start: pass (20 rows, 0 failing)
- check env/gates.csv digest at the registry · after the clean start: pass (5 rows, 0 failing)
- check marker M1 (STATE_LOCK_NOT_ACQUIRED, gateway): pass (0 hits in 52 files)
- check marker M2 (IDLE_GATEWAY_NOT_STOPPED, agent): pass (0 hits in 10 files)
- check marker M3 (IDLE_GATEWAY_NOT_RUNNING, agent): pass (0 hits in 10 files)
- check marker M4 (No policy gateway reachable, service): pass (0 hits in 130 files)
- check verdict.csv class · request path: pass (6 rows, 0 failing)
- check verdict.csv node · request path: pass (6 rows, 0 failing)
- check verdict.csv digest · request path: pass (12 rows, 0 failing)
- check verdict.csv class · agent: pass (8 rows, 0 failing)
- check verdict.csv node · agent: pass (8 rows, 0 failing)
- check verdict.csv digest · agent: pass (16 rows, 0 failing)
- check verdict.csv class · idle: pass (25 rows, 0 failing)
- check verdict.csv node · idle: pass (25 rows, 0 failing)
- check verdict.csv digest · idle: pass (25 rows, 0 failing; also not started)
- check verdict.csv class · chain: pass (24 rows, 0 failing)
- check verdict.csv node · chain: pass (24 rows, 0 failing)
- check verdict.csv digest · chain: pass (144 rows, 0 failing)
- check verdict.csv class · inspector: pass (2 rows, 0 failing)
- check verdict.csv node · inspector: pass (2 rows, 0 failing)
- check verdict.csv digest · inspector: pass (2 rows, 0 failing)
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- events.csv duration_us (clean start): n=1, minimum 200727.6 ms, median 200727.6 ms, maximum 200727.6 ms
- events.csv duration_us (terms: allowed false): n=4, minimum 4.0 ms, median 4.4 ms, maximum 6.0 ms
- events.csv duration_us (deploy gap: chain jobs deleted): n=20, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (deploy gap: chain pods gone): n=20, minimum 146.2 ms, median 182.9 ms, maximum 31793.5 ms
- events.csv duration_us (deploy gap: held): n=20, minimum 0.0 ms, median 0.0 ms, maximum 0.0 ms
- events.csv duration_us (trigger): n=5, minimum 2.1 ms, median 2.5 ms, maximum 4.7 ms
- events.csv duration_us (run done): n=5, minimum 34574.1 ms, median 46795.6 ms, maximum 47449.5 ms
- events.csv duration_us (terms: no state directives): n=4, minimum 3.4 ms, median 3.8 ms, maximum 5.7 ms
- events.csv duration_us (terms: unknown onRevocation): n=4, minimum 4.1 ms, median 4.6 ms, maximum 5.7 ms
- events.csv duration_us (terms: negative retention): n=4, minimum 4.3 ms, median 4.9 ms, maximum 5.1 ms
- events.csv duration_us (terms: resume disabled): n=4, minimum 3.6 ms, median 4.2 ms, maximum 5.1 ms

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| runs | one run per set of terms | server | 5 runs of job records | 5 | pass |
| W1 | write, allowed false | server | every write record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, allowed false | server | every read record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, allowed false | server | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, no state directives | server | every write record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, no state directives | server | every read record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, no state directives | server | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, unknown onRevocation | server | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, unknown onRevocation | server | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, unknown onRevocation | server | at least one invalid_directives record by the job's enforcement point | 1: unknown onRevocation "shred" | pass |
| W1 | nothing destroyed, unknown onRevocation | server | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, negative retention | server | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, negative retention | server | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, negative retention | server | at least one invalid_directives record by the job's enforcement point | 1: negative retentionSeconds -1 | pass |
| W1 | nothing destroyed, negative retention | server | no PURGED or DELETED record in the run | 0 | pass |
| W4 | write, resume disabled | server | every write record ALLOW on allowed terms on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R2 | read, resume disabled | server | every read record DENY with reason 'resume disabled' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W4 | nothing destroyed, resume disabled | server | no PURGED or DELETED record in the run | 0 | pass |
| runs | one run per set of terms | clientone | 5 runs of job records | 5 | pass |
| W1 | write, allowed false | clientone | every write record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, allowed false | clientone | every read record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, allowed false | clientone | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, no state directives | clientone | every write record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, no state directives | clientone | every read record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, no state directives | clientone | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, unknown onRevocation | clientone | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, unknown onRevocation | clientone | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, unknown onRevocation | clientone | at least one invalid_directives record by the job's enforcement point | 1: unknown onRevocation "shred" | pass |
| W1 | nothing destroyed, unknown onRevocation | clientone | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, negative retention | clientone | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, negative retention | clientone | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, negative retention | clientone | at least one invalid_directives record by the job's enforcement point | 1: negative retentionSeconds -1 | pass |
| W1 | nothing destroyed, negative retention | clientone | no PURGED or DELETED record in the run | 0 | pass |
| W4 | write, resume disabled | clientone | every write record ALLOW on allowed terms on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R2 | read, resume disabled | clientone | every read record DENY with reason 'resume disabled' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W4 | nothing destroyed, resume disabled | clientone | no PURGED or DELETED record in the run | 0 | pass |
| runs | one run per set of terms | clienttwo | 5 runs of job records | 5 | pass |
| W1 | write, allowed false | clienttwo | every write record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, allowed false | clienttwo | every read record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, allowed false | clienttwo | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, no state directives | clienttwo | every write record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, no state directives | clienttwo | every read record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, no state directives | clienttwo | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, unknown onRevocation | clienttwo | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, unknown onRevocation | clienttwo | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, unknown onRevocation | clienttwo | at least one invalid_directives record by the job's enforcement point | 1: unknown onRevocation "shred" | pass |
| W1 | nothing destroyed, unknown onRevocation | clienttwo | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, negative retention | clienttwo | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, negative retention | clienttwo | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, negative retention | clienttwo | at least one invalid_directives record by the job's enforcement point | 1: negative retentionSeconds -1 | pass |
| W1 | nothing destroyed, negative retention | clienttwo | no PURGED or DELETED record in the run | 0 | pass |
| W4 | write, resume disabled | clienttwo | every write record ALLOW on allowed terms on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R2 | read, resume disabled | clienttwo | every read record DENY with reason 'resume disabled' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W4 | nothing destroyed, resume disabled | clienttwo | no PURGED or DELETED record in the run | 0 | pass |
| runs | one run per set of terms | clientthree | 5 runs of job records | 5 | pass |
| W1 | write, allowed false | clientthree | every write record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, allowed false | clientthree | every read record DENY with reason 'allowed = false' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, allowed false | clientthree | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, no state directives | clientthree | every write record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, no state directives | clientthree | every read record DENY with reason 'stateDirectives absent' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | nothing destroyed, no state directives | clientthree | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, unknown onRevocation | clientthree | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, unknown onRevocation | clientthree | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, unknown onRevocation | clientthree | at least one invalid_directives record by the job's enforcement point | 1: unknown onRevocation "shred" | pass |
| W1 | nothing destroyed, unknown onRevocation | clientthree | no PURGED or DELETED record in the run | 0 | pass |
| W1 | write, negative retention | clientthree | every write record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R1 | read, negative retention | clientthree | every read record DENY with reason 'invalid stateDirectives; fail closed' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W1 | invalid directives recorded, negative retention | clientthree | at least one invalid_directives record by the job's enforcement point | 1: negative retentionSeconds -1 | pass |
| W1 | nothing destroyed, negative retention | clientthree | no PURGED or DELETED record in the run | 0 | pass |
| W4 | write, resume disabled | clientthree | every write record ALLOW on allowed terms on relation GUID-state-aware, at least one | write records: 3, 0 otherwise | pass |
| R2 | read, resume disabled | clientthree | every read record DENY with reason 'resume disabled' on relation GUID-state-aware, at least one | read records: 1, 0 otherwise | pass |
| W4 | nothing destroyed, resume disabled | clientthree | no PURGED or DELETED record in the run | 0 | pass |
