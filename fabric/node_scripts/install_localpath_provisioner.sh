#!/bin/bash
set -e

{

# ---------------------------------------------------------------------------
# Installs the rancher local-path-provisioner (pinned v0.0.37) and configures
# it for DYNAMOS on FABRIC. Run on the control node AFTER the kubespray
# cluster is up and BEFORE the DYNAMOS install.
#
# Why: kubespray installs no storage provisioner, and the DYNAMOS charts have
# PVCs that name no storageClassName (etcd-pvc, rabbit-pvc, rabbitmq-data-pvc,
# rabbitmq-log-pvc, the etcd StatefulSet's etcd-data claims) — they ride the
# cluster default StorageClass, so local-path is marked default below.
#
# The gateway-state StorageClass is NOT created here: the namespaces chart
# ships it (charts/namespaces/templates/gateway-state-storageclass.yaml) with
# provisioner rancher.io/local-path — exactly this provisioner. This script
# only has to carry a matching "gateway-state" entry in storageClassConfigs.
#
# NVME_MOUNT must match the mount point the notebook passed to
# configure_nvme() (default /mnt/nvme). The per-node map below encodes the
# server-only NVMe scope; for per-steward NVMe, add one
# {"node": "<name>", "paths": ["${NVME_MOUNT}"]} line per steward node that
# got an NVMe component in the slice.
# ---------------------------------------------------------------------------

NVME_MOUNT="${NVME_MOUNT:-/mnt/nvme}"
export NVME_MOUNT

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s

# Replace only the config.json key of the local-path-config ConfigMap (the
# other keys — setup, teardown, helperPod.yaml — must survive). python3 is
# already on the node via node_setup.sh; it builds the strict-JSON patch.
PATCH="$(python3 - <<'PYEOF'
import json, os

nvme_mount = os.environ["NVME_MOUNT"]
config = {
    "nodePathMap": [],
    "storageClassConfigs": {
        "local-path": {
            "nodePathMap": [
                {
                    "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
                    "paths": ["/opt/local-path-provisioner"],
                }
            ]
        },
        "gateway-state": {
            "nodePathMap": [
                {"node": "server", "paths": [nvme_mount]},
                {
                    "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
                    "paths": ["/opt/gateway-state"],
                },
            ]
        },
    },
}
print(json.dumps({"data": {"config.json": json.dumps(config, indent=2)}}))
PYEOF
)"

kubectl -n local-path-storage patch configmap local-path-config --type merge -p "$PATCH"

# kubespray installs no provisioner; the chart PVCs without a storageClassName
# need a cluster default.
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite

# The provisioner reads its config at startup — restart to pick up the patch.
kubectl -n local-path-storage rollout restart deployment/local-path-provisioner
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s

kubectl get storageclass

echo "local-path-provisioner v0.0.37 installed and configured."

}
