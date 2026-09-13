# FABRIC deployment kit — DYNAMOS-tobias

Deploys this fork on a six-node FABRIC slice (CIEN, host `cien-w1`):
kubespray Kubernetes cluster, local-path storage, Linkerd, and the full
DYNAMOS install. Adapted from the Scattered-Directive working pipeline
(`fabric/kubernetes.ipynb`, successful run 2025-11-20).

## Contents

- `e3-fabric-slice.ipynb` — the consolidated notebook; run it top to bottom
  on the FABRIC JupyterHub (or a local fablib environment).
- `node_scripts/` — scripts the notebook uploads to the slice nodes.
  `install_dynamos.sh` (repo delivery + Helm/Linkerd) and
  `install_localpath_provisioner.sh` (storage) are adapted/new; the rest are
  verbatim from Scattered-Directive.
- `kubespray/ansible.cfg` — ansible config uploaded to the control node.
  The notebook writes `kubespray/inventory.ini` next to it at runtime.

## Execution order

The notebook's phases, in order:

1. **Pre-flight** — image/site/host go/no-go checks (nothing created yet)
2. **Slice** — 6 nodes + FABNetv4 network, explicit 2-week lease
3. **NVMe** — format + mount `/mnt/nvme` on the NVMe node(s), first use only
4. **Node prep** — base packages on every node
5. **Kubespray** — cluster install from the control node (~10-27 min)
6. **Provisioner** — local-path-provisioner v0.0.37; default StorageClass
   plus the `gateway-state` backing paths (NVMe on `server`)
7. **DYNAMOS** — repo delivery, etcd seed, `install_dynamos.sh`,
   `dynamos-configuration.sh`
8. **Teardown** — helm uninstall / namespace + PVC cleanup / slice delete

## Operator inputs

Two decisions live in the notebook:

- **`DYNAMOS_REPO_URL`** (Phase 7). Empty (default) = upload route: the
  notebook pushes the local checkout's `charts/`, `configuration/` and
  `scripts/add_*.sh` to `control:~/DYNAMOS` — works for a private fork, no
  token needed, but requires the notebook to run from `fabric/` inside a
  full checkout. Non-empty = `install_dynamos.sh` clones that URL.
- **NVMe scope** (`nvme` flag in the node config, Phase 2). Default is
  server-only; per-steward NVMe is the alternative. Keep the flag in sync
  with the `gateway-state` nodePathMap in
  `node_scripts/install_localpath_provisioner.sh`.

Step-by-step ownership runbook: thesis-workbench
`notes/plan-september/fabric-port-runbook.md`.
