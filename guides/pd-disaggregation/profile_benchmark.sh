#!/bin/bash
# Script to profile disaggregated vLLM serving
# It starts profiling on all vLLM pods, runs the benchmark, waits for completion, and then stops profiling.

export NAMESPACE="llm-d-pd"
JOB_NAME="custom-load-generator"

# Get pod names
PREFILL_POD=$(kubectl get pods -l llm-d.ai/role=prefill -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
DECODE_POD=$(kubectl get pods -l llm-d.ai/role=decode -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')

echo "Found Prefill Pod: $PREFILL_POD"
echo "Found Decode Pod: $DECODE_POD"

if [ -z "$PREFILL_POD" ] || [ -z "$DECODE_POD" ]; then
  echo "Could not find both prefill and decode pods! Are they running?"
  exit 1
fi

echo "⏳ Waiting for pods to be fully ready (model loading)..."
kubectl wait --for=condition=ready pod -l llm-d.ai/inference-serving=true -n $NAMESPACE --timeout=600s

# Start profiling in parallel
echo "Starting profile on Prefill and Decode pod..."
kubectl exec $PREFILL_POD -c vllm -n $NAMESPACE -- curl -s -X POST http://localhost:8000/start_profile &
kubectl exec $DECODE_POD -c vllm -n $NAMESPACE -- curl -s -X POST http://localhost:8200/start_profile &
wait
echo "Profiler started on both pods."

echo "Running benchmark..."
export NUM_REQUESTS=4
export CONCURRENCY=4
./guides/pd-disaggregation/run_custom_load.sh

echo "⏳ Waiting for benchmark job to finish..."
kubectl wait --for=condition=complete job/$JOB_NAME -n $NAMESPACE --timeout=600s


# Stop profiling in parallel
echo "Stopping profile on Prefill and Decode pod..."
kubectl exec $PREFILL_POD -c vllm -n $NAMESPACE -- curl -s -X POST http://localhost:8000/stop_profile &
kubectl exec $DECODE_POD -c vllm -n $NAMESPACE -- curl -s -X POST http://localhost:8200/stop_profile &
wait
echo "Profiler stopped on both pods."

echo "Profiling complete! Traces should be in /mnt/traces in the pods."
echo "Use 'kubectl cp' to extract them."
