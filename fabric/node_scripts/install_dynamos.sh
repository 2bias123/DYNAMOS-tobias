#!/bin/bash
set -e

{

# ---------------------------------------------------------------------------
# Repo delivery route (checked first so a missing repo fails fast).
#   DYNAMOS_REPO_URL non-empty -> clone route: git clone that URL as ~/DYNAMOS.
#   DYNAMOS_REPO_URL empty     -> upload route (default): the notebook has
#                                 already uploaded the local checkout to
#                                 ~/DYNAMOS; assert it exists.
# The fork may be private, so the upload route needs no token.
# ---------------------------------------------------------------------------
DYNAMOS_REPO_URL="${DYNAMOS_REPO_URL:-}"

cd "$HOME"
if [ -n "$DYNAMOS_REPO_URL" ]; then
  echo "Repo route: clone ($DYNAMOS_REPO_URL)"
  if [ ! -d "$HOME/DYNAMOS" ]; then
    git clone "$DYNAMOS_REPO_URL" DYNAMOS
  else
    echo "~/DYNAMOS already exists; skipping clone"
  fi
else
  echo "Repo route: upload (expecting ~/DYNAMOS from the notebook)"
  if [ ! -d "$HOME/DYNAMOS" ]; then
    echo "ERROR: ~/DYNAMOS not found. Run the notebook's upload cell first," >&2
    echo "or set DYNAMOS_REPO_URL to use the clone route." >&2
    exit 1
  fi
fi

# Remove old helm repo if present
if [ -f /etc/apt/sources.list.d/helm-stable-debian.list ]; then
  sudo rm /etc/apt/sources.list.d/helm-stable-debian.list
fi

# Ensure apt supports HTTPS and curl
sudo apt-get update
sudo apt-get install -y curl gpg apt-transport-https

# Add Helm signing key
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null

# Add Helm apt repo
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | \
  sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

# Update and try installing via apt
sudo apt-get update

if sudo apt-get install -y helm; then
  echo "Helm installed via apt"
else
  echo "APT install failed — falling back to manual install"
  VERSION="v3.19.0"
  curl -fsSL "https://get.helm.sh/helm-${VERSION}-linux-amd64.tar.gz" -o helm-${VERSION}-linux-amd64.tar.gz
  tar -zxvf helm-${VERSION}-linux-amd64.tar.gz
  sudo mv linux-amd64/helm /usr/local/bin/helm
  rm -rf linux-amd64 helm-${VERSION}-linux-amd64.tar.gz
  echo "Helm manually installed, version:"
  helm version
fi

function addPathExport () {
  echo -e "export PATH=$1" >> $HOME/.bashrc
  echo "[inserted] export PATH=$1"
}

# Install CLI
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install-edge | LINKERD2_VERSION=edge-25.8.1 sh

# Add Linkerd to PATH
addPathExport "\$PATH:/home/ubuntu/.linkerd2/bin"
export PATH=$PATH:/home/ubuntu/.linkerd2/bin

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# Validate that Linkerd can be installed. On a cluster that already carries
# leftovers from a previous install, `linkerd check --pre` fails on
# "already exists" findings and `set -e` would abort the whole script here.
# Set LINKERD_PRECHECK=skip to bypass the pre-check after confirming that the
# failures are only such leftovers (or reset the cluster for a clean run).
if [ "${LINKERD_PRECHECK:-}" = "skip" ]; then
  echo "WARNING: skipping 'linkerd check --pre' (LINKERD_PRECHECK=skip)"
elif ! linkerd check --pre; then
  echo "" >&2
  echo "ERROR: 'linkerd check --pre' failed (output above)." >&2
  echo "If these are 'already exists' leftovers from a previous install," >&2
  echo "reset the cluster or re-run with LINKERD_PRECHECK=skip." >&2
  exit 1
fi

linkerd install --set nodeSelector."kubernetes\\.io/hostname"=dynamos --crds | kubectl apply -f - # install the Linkerd CRDs
linkerd install --set nodeSelector."kubernetes\\.io/hostname"=dynamos | kubectl apply -f - # install the control plane into the 'linkerd' namespace
linkerd check                               # validate everything worked!

# Install Jaeger onto the cluster for observability
linkerd jaeger install \
  --set collector.nodeSelector."kubernetes\\.io/hostname"=dynamos \
  --set nodeSelector."kubernetes\\.io/hostname"=dynamos \
  --set jaeger.nodeSelector."kubernetes\\.io/hostname"=dynamos \
  --set webhook.nodeSelector."kubernetes\\.io/hostname"=dynamos \
  | kubectl apply -f -

# etcd client, debugging convenience only — nothing in the install or run
# path needs a local etcdctl (the harness execs it inside the etcd pod, the
# seed script just copies files). The lineage's Homebrew route broke by 2026:
# `brew update` on a tarball install dies in the master->main migration
# ("not a git repository"), and set -e then killed the script here before
# the /etc/hosts line (21.09 sitting). Plain apt instead.
sudo apt-get install -y etcd-client

echo -e "127.0.0.1 api-gateway.api-gateway.svc.cluster.local" | sudo tee -a /etc/hosts

}
