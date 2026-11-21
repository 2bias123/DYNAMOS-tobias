# Policy-driven governance of persistent intermediate state

Code and results of the MSc thesis *Policy-Driven Governance of Persistent Intermediate State in
Data-Exchange Systems* by Tobias Meyer Innleggen (2026). A fork of
[DYNAMOS-jiyan](https://github.com/DYNAMOS-UVA/DYNAMOS-jiyan) at commit `8177839`.

## What the extension adds

The agreement between a data steward and a data analyst now also governs the state a computation stores for
later executions, such as the checkpoints of multi-round training.

- **Four agreement fields** (`stateDirectives`) decide whether state may be kept, how long after its last
  write, whether a later run may reuse it, and what a revocation does to it.
- **A state enforcement point** (`policy-checkpoint-gateway` in the code) decides each write, read and
  deletion of that state against the agreement, also between executions.

## Where things are

| | |
|---|---|
| The enforcement point | `go/cmd/policy-checkpoint-gateway/` |
| The agent's part | `go/cmd/agent/` (`deploy_job.go`, `ensure_pvc.go`, `idle_gateway.go`) |
| The workload's client | `python/dynamos-python-lib/dynamos/gateway_client.py` |
| The harness that ran the experiments | `harness/` |
| Checks on a local kind cluster | `scripts/kind_gate.sh` |
| Cluster setup on FABRIC | `fabric/` |
| Results | `results/counted-runs/` |
| Results of earlier campaigns | `results/archive/` |

## Results

The thesis reports E1, E2, E5 and the denial measurement of E4 from counted-3, and E3 and the growth
measurement of E4 from counted-4, which measured them again after two faults in the harness. counted-1 and
counted-2 stopped early on faults in the harness.

The older scripts `scripts/capture_e*.sh` and `scripts/run_e3_*.sh` produced `results/archive/`. Their E6 is
the thesis's E5.

## Running it

```
# the enforcement point's unit tests
cd go && go test ./cmd/policy-checkpoint-gateway/

# build, deploy and check everything on a local kind cluster, about half an hour
# needs docker, kind, kubectl, helm, linkerd, jq, go and python3, and a branch not named main
git switch -c check && scripts/kind_gate.sh

# recompute a run's analysis from its tables
python3 harness/analysis/compute.py --tables results/counted-runs/counted-3-tables --out /tmp/counted-3
```

The experiments ran through `harness/run` on a six-machine cluster on FABRIC.

## About this history

The work was done in a private repository of about 580 commits, condensed here into 40. Commit ids named
inside files and results are that repository's and do not exist here. The tag `8a73060` marks the commit the
images were built from.

---

# PET enabled vertical federated learning in DYNAMOS

This fork of the original DYNAMOS project serves as a codebase for my bachelor thesis.
This thesis extends the original DYNAMOS VFL workflow by adding in two new privacy enhancing microservices, Anonymization and Differential Privacy.

The new microservices and datasets can be found in the following directories:

- [Anonymization Microservice](python/anonymize-test)
- [Differential Privacy Microservice](python/differential-p-test)

To run the VFL training with the new microservices enabled, follow the same installation steps for the [regular DYNAMOS setup](https://github.com/Jorrit05/DYNAMOS/tree/main).
To test the deployment, an example VFL training request can be made.

Using curl, it could look like this:
```
curl -H "Host: api-gateway.api-gateway.svc.cluster.local" \
     -H "Content-Type: application/json" \
     --data-raw '{
       "type": "vflTrainModelRequest",
       "user": {
         "id": "1234",
         "userName": "jake.jongejans@student.uva.nl"
       },
       "dataProviders": [
         "server",
         "clientone",
         "clienttwo",
         "clientthree"
       ],
       "data_request": {
         "type": "vflTrainModelRequest",
         "data": {
           "learning_rate": 0.1,
           "cycles": 180,
           "policy_removal": -1,
           "policy_reintroduction": -1,
           "training_backtrack": 0
         },
         "requestMetadata": {}
       }
     }' \
     "http://api-gateway.api-gateway.svc.cluster.local:80/api/v1/requestApproval"
```
