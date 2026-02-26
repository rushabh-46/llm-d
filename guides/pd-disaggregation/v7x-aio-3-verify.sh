#!/bin/bash

# ==============================================================================
# Configuration & Setup
# ==============================================================================
source v7x-aio-0-env.sh

NAMESPACE="${NAMESPACE:-llm-d-pd}"
# Colors for output
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "Starting verification in namespace: ${GREEN}${NAMESPACE}${NC}"

# Check for required tools
for tool in kubectl helm jq curl; do
    if ! command -v $tool &> /dev/null; then
        echo -e "${RED}Error: $tool is not installed.${NC}"
        exit 1
    fi
done

# ==============================================================================
# Step 1: Verify Helm Releases
# ==============================================================================
echo -e "\n--- Checking Helm Releases ---"
REQUIRED_CHARTS=("gaie-pd" "infra-pd" "ms-pd")

HELM_LIST=$(helm list -n "${NAMESPACE}")
ALL_CHARTS_FOUND=true

for chart in "${REQUIRED_CHARTS[@]}"; do
    if echo "$HELM_LIST" | grep -q "$chart"; then
        echo -e "Chart '$chart': ${GREEN}FOUND${NC}"
    else
        echo -e "Chart '$chart': ${RED}MISSING${NC}"
        ALL_CHARTS_FOUND=false
    fi
done

if [ "$ALL_CHARTS_FOUND" = false ]; then
    echo -e "${RED}One or more Helm charts are missing. Exiting.${NC}"
    exit 1
fi

# ==============================================================================
# Step 2: Verify K8s Resources (Deployments & Pods)
# ==============================================================================
echo -e "\n--- Checking Kubernetes Resources ---"

# We check deployments because Pod names (hashes) change.
# If Deployment is ready, the Pods are ready.
DEPLOYMENTS=(
    "gaie-pd-epp"
    "ms-pd-llm-d-modelservice-decode"
    "ms-pd-llm-d-modelservice-prefill"
)

for deploy in "${DEPLOYMENTS[@]}"; do
    # Check if deployment exists first to avoid confusing error messages
    if kubectl get deployment "$deploy" -n "${NAMESPACE}" > /dev/null 2>&1; then
        # Wait for rollout to complete
        if kubectl rollout status deployment/"$deploy" -n "${NAMESPACE}" --timeout=10s > /dev/null 2>&1; then
             echo -e "Deployment $deploy: ${GREEN}READY${NC}"
        else
             echo -e "Deployment $deploy: ${RED}NOT READY${NC}"
        fi
    else
        echo -e "Deployment $deploy: ${RED}NOT FOUND${NC}"
    fi
done

echo -e "\n--- verifying active Pods ---"
# List pods matching the broad app labels or names to confirm existence
kubectl get pods -n "${NAMESPACE}" | grep -E "gaie-pd|ms-pd"

# ==============================================================================
# Step 3: Verify Gateway & Network
# ==============================================================================
echo -e "\n--- Checking GKE Gateway ---"

GATEWAY_NAME="infra-pd-inference-gateway"
GATEWAY_IP=""
kubectl get gateway "$GATEWAY_NAME" -n "${NAMESPACE}"
# Wait/Check for Gateway IP
RAW_IP=$(kubectl get gateway "$GATEWAY_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)

if [ -z "$RAW_IP" ]; then
    echo -e "${RED}Gateway IP not assigned yet. It may take a few minutes.${NC}"
    exit 1
else
    echo -e "Gateway IP found: ${GREEN}${RAW_IP}${NC}"
    GATEWAY_IP="http://${RAW_IP}"
fi

# Check if Programmed
PROGRAMMED=$(kubectl get gateway "$GATEWAY_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
if [ "$PROGRAMMED" == "True" ]; then
    echo -e "Gateway Status: ${GREEN}PROGRAMMED${NC}"
else
    echo -e "Gateway Status: ${RED}NOT PROGRAMMED${NC} (Current status: $PROGRAMMED)"
    # We might want to warn but continue, or exit.
fi

# ==============================================================================
# Step 4: Functional Test (Curl)
# ==============================================================================
echo -e "\n--- Running Functional Tests ---"

ENDPOINT="${GATEWAY_IP}"
echo "Targeting Endpoint: $ENDPOINT"

# 4.1: Check /v1/models
echo -e "\n> Requesting /v1/models..."
MODELS_RESPONSE=$(curl -s "${ENDPOINT}/v1/models" -H "Content-Type: application/json")

# Validate valid JSON response
if ! echo "$MODELS_RESPONSE" | jq empty > /dev/null 2>&1; then
    echo -e "${RED}Failed to get valid JSON from /v1/models${NC}"
    echo "Raw Output: $MODELS_RESPONSE"
    exit 1
fi

# Extract the model ID dynamically
MODEL_ID=$(echo "$MODELS_RESPONSE" | jq -r '.data[0].id')

if [ "$MODEL_ID" != "null" ] && [ -n "$MODEL_ID" ]; then
    echo -e "Model detected: ${GREEN}${MODEL_ID}${NC}"
else
    echo -e "${RED}Could not detect model ID from response.${NC}"
    exit 1
fi

# 4.2: Check /v1/completions
echo -e "\n> Requesting /v1/completions (using model: ${MODEL_ID})..."

COMPLETION_PAYLOAD=$(jq -n \
                  --arg model "$MODEL_ID" \
                  --arg prompt "How are you today?" \
                  '{model: $model, max_tokens: 64, prompt: $prompt}')

COMPLETION_RESPONSE=$(curl -s -X POST "${ENDPOINT}/v1/completions" \
    -H 'Content-Type: application/json' \
    -d "$COMPLETION_PAYLOAD")

# Check for success in response
# We look for "choices" array which indicates a successful generation
if echo "$COMPLETION_RESPONSE" | jq -e '.choices' > /dev/null; then
    echo -e "Completion Test: ${GREEN}SUCCESS${NC}"
    echo "Response Snippet: $(echo "$COMPLETION_RESPONSE" | jq -r '.choices[0].text' | head -n 1)..."
else
    echo -e "Completion Test: ${RED}FAILED${NC}"
    echo "Raw Output: $COMPLETION_RESPONSE"
    exit 1
fi

echo -e "\n${GREEN}All verification steps passed successfully!${NC}"
