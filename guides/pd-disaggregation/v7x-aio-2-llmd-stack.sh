#!/bin/bash

# Source the env vars
source v7x-aio-0-env.sh

# Config kubectl
gcloud container clusters get-credentials $CLUSTER --location=$LOCATION

YELLOW='\033[0;33m'
NC='\033[0m' # No Color

if ! gcloud resource-manager org-policies describe \
  compute.restrictLoadBalancerCreationForTypes \
  --project=${PROJECT_ID} \
  --format="value(listPolicy.allowedValues)" | \
  grep -q "EXTERNAL_MANAGED_HTTP_HTTPS";then
  gateway_config="../prereq/gateway-provider/common-configurations/gke.yaml"
  echo -e "${YELLOW}Warning: Project ${PROJECT_ID}'s policy does not support" \
    "EXTERNAL_MANAGED_HTTP_HTTPS. Fall gatewayClassName in ${gateway_config}" \
    "from 'gke-l7-regional-external-managed' to 'gke-l7-rilb'." \
    "Note ${gateway_config} will be modified.${NC}"
  sed -i 's/gke-l7-regional-external-managed/gke-l7-rilb/' ${gateway_config}
fi

# Install the Inference Extension CRDs.
# Although GKE already installed it: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploy-gke-inference-gateway#compatibility, EPP will crash if not explicitly install it.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.0.0/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.2.0-rc.1/config/crd/bases/inference.networking.k8s.io_inferencepools.yaml

# create namespace
kubectl create namespace ${NAMESPACE}

# create HF token secret
kubectl create secret generic llm-d-hf-token \
  --namespace "${NAMESPACE}" \
  --from-literal="HF_TOKEN=${HF_TOKEN}"

# install the p/d stack, make sure you are unde dir guides/pd-disaggregation
helmfile apply -e gke_tpu -n ${NAMESPACE}

# install HTTP route
kubectl apply -f httproute.gke.yaml -n ${NAMESPACE}
