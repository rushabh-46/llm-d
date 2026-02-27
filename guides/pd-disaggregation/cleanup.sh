#!/bin/bash

source v7x-aio-0-env.sh

# Config kubectl so kubectl context points to correct cluster and locaiton.
gcloud container clusters get-credentials $CLUSTER --location=$LOCATION

kubectl delete -f gaie-pd-epp-health-check-policy.yaml -n ${NAMESPACE}
kubectl delete -f httproute.gke.yaml -n ${NAMESPACE}
helmfile destroy -e gke_tpu -n ${NAMESPACE}

kubectl delete -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.2.0-rc.1/config/crd/bases/inference.networking.k8s.io_inferencepools.yaml
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/raw/v1.0.0/config/crd/bases/inference.networking.x-k8s.io_inferenceobjectives.yaml

# Delete node pool
gcloud container node-pools delete $NODE_POOL --cluster=${CLUSTER} --location=${LOCATION} --quiet

# Delete cluster
gcloud container clusters delete $CLUSTER --project=${PROJECT_ID} --location=${LOCATION} --quiet

# Delete firewall rule
gcloud compute firewall-rules delete ${NETWORK_FW_NAME} --project=${PROJECT_ID} --quiet

# Delete subnet
gcloud compute networks subnets delete ${SUBNET_NAME} --region=${LOCATION} --project=${PROJECT_ID} --quiet

# Delete network
gcloud compute networks delete ${VPC_NETWORK_NAME} --project=${PROJECT_ID} --quiet
