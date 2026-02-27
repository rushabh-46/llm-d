#!/bin/bash

# Source the env vars
source v7x-aio-0-env.sh

# Config kubectl
gcloud container clusters get-credentials $CLUSTER --location=$LOCATION

YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Install the Inference Extension CRDs.
# Although GKE already installed it: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploy-gke-inference-gateway#compatibility, EPP will crash if not explicitly install it.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.0.0/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.2.0-rc.1/config/crd/bases/inference.networking.k8s.io_inferencepools.yaml

# Create namespace
kubectl create namespace ${NAMESPACE}

# Create HF token secret
kubectl create secret generic llm-d-hf-token \
  --namespace "${NAMESPACE}" \
  --from-literal="HF_TOKEN=${HF_TOKEN}"

# Install the p/d stack, make sure you are under dir guides/pd-disaggregation
helmfile apply -e gke_tpu -n ${NAMESPACE}

# Install HTTP route
kubectl apply -f httproute.gke.yaml -n ${NAMESPACE}

# Overwrite the default gaie-pd-epp health check policy to set
# gaie-pd-epp health check port from default one to an allowlisted one
kubectl apply -f gaie-pd-epp-health-check-policy.yaml

# Replace the default gaie-pd-epp deployment to update gaie-pd-epp
# to listen to the allowlisted grpc-health-check port
kubectl replace -f gaie-pd-epp-deployment.yaml
