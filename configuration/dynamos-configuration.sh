#!/bin/bash

set -e

# Change this to the path of the DYNAMOS repository on your disk
echo "Setting up paths..."
DYNAMOS_ROOT="${HOME}/Thesis/DYNAMOS"

# Charts
charts_path="${DYNAMOS_ROOT}/charts"
core_chart="${charts_path}/core"
namespace_chart="${charts_path}/namespaces"
orchestrator_chart="${charts_path}/orchestrator"
agents_chart="${charts_path}/agents"
ttp_chart="${charts_path}/thirdparty"
api_gw_chart="${charts_path}/api-gateway"

# Config
config_path="${DYNAMOS_ROOT}/configuration"
k8s_service_files="${config_path}/k8s_service_files"
etcd_launch_files="${config_path}/etcd_launch_files"

# Image overrides for registry-pulling environments (FABRIC): when
# DYNAMOS_IMG_ACCOUNT / DYNAMOS_IMG_TAG are set, the fork charts pull
# from that Hub account/tag instead of the values.yaml defaults, and the
# agents' job-deploy env (MICROSERVICE_REPOSITORY_NAME /
# SIDECAR_REPOSITORY_NAME) follows the same account. Unset, the
# variables expand to nothing and every helm command below is identical
# to the plain kind install.
img_overrides=""
agents_img_overrides=""
if [ -n "${DYNAMOS_IMG_ACCOUNT:-}" ]; then
    img_overrides="--set dockerArtifactAccount=${DYNAMOS_IMG_ACCOUNT}"
    agents_img_overrides="--set microserviceRepositoryName=${DYNAMOS_IMG_ACCOUNT} --set sidecarRepositoryName=${DYNAMOS_IMG_ACCOUNT}"
fi
if [ -n "${DYNAMOS_IMG_TAG:-}" ]; then
    img_overrides="${img_overrides} --set branchNameTag=${DYNAMOS_IMG_TAG}"
fi

rabbit_definitions_file="${k8s_service_files}/definitions.json"
example_definitions_file="${k8s_service_files}/definitions_example.json"

cp "$example_definitions_file" "$rabbit_definitions_file"
echo "definitions_example.json copied over definitions.json to ensure a clean file"

echo "Generating RabbitMQ password..."
# Create a password for a rabbit user
rabbit_pw=$(openssl rand -hex 16)

# Use the RabbitCtl to make a special hash of that password. On hosts
# without docker (kubespray nodes carry only containerd) compute the same
# rabbit_password_hashing_sha256 hash locally: 4-byte salt +
# SHA256(salt||pw), base64(salt||digest).
if command -v docker >/dev/null 2>&1; then
    hashed_pw=$($SUDO docker run --rm rabbitmq:3-management rabbitmqctl hash_password $rabbit_pw)
    actual_hash=$(echo "$hashed_pw" | cut -d $'\n' -f2)
else
    actual_hash=$(python3 -c 'import base64,hashlib,os,sys; pw=sys.argv[1].encode(); salt=os.urandom(4); print(base64.b64encode(salt+hashlib.sha256(salt+pw).digest()).decode())' "$rabbit_pw")
fi

echo "Replacing tokens..."
cp ${k8s_service_files}/definitions_example.json ${rabbit_definitions_file}


# The Rabbit Hashed password needs to be in definitions.json file, that is the configuration for RabbitMQ
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS sed
    sed -i '' "s|%PASSWORD%|${actual_hash}|g" ${rabbit_definitions_file}
else
    # GNU sed
    sed -i "s|%PASSWORD%|${actual_hash}|g" ${rabbit_definitions_file}
fi

echo "Installing namespaces..."

# Install namespaces
helm upgrade -i -f ${namespace_chart}/values.yaml namespaces ${namespace_chart} --set secret.password=${rabbit_pw}

echo "Preparing PVC"

{
    cd ${DYNAMOS_ROOT}/configuration
    ./fill-rabbit-pvc.sh
}

#Install prometheus
echo "Installing Prometheus..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade -i -f "${core_chart}/prometheus-values.yaml" prometheus prometheus-community/prometheus

echo "Installing NGINX..."
helm install -f "${core_chart}/ingress-values.yaml" nginx oci://ghcr.io/nginxinc/charts/nginx-ingress -n ingress --version 0.18.0

echo "Installing DYNAMOS core..."
helm upgrade -i -f ${core_chart}/values.yaml core ${core_chart} --set hostPath=${HOME}

sleep 3
# Install orchestrator layer
helm upgrade -i -f "${orchestrator_chart}/values.yaml" orchestrator ${orchestrator_chart} ${img_overrides}

sleep 1

echo "Installing agents layer"
helm upgrade -i -f "${agents_chart}/values.yaml" agents ${agents_chart} ${img_overrides} ${agents_img_overrides}

sleep 1

echo "Installing thirdparty layer..."
helm upgrade -i -f "${ttp_chart}/values.yaml" surf ${ttp_chart} ${img_overrides}

sleep 1

echo "Installing api gateway"
helm upgrade -i -f "${api_gw_chart}/values.yaml" api-gateway ${api_gw_chart} ${img_overrides}

echo "Finished setting up DYNAMOS"

exit 0