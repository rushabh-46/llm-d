#!/bin/bash

# Configuration
NAMESPACE="${NAMESPACE:-llm-d-pd}"
JOB_NAME="custom-load-generator"
NUM_REQUESTS="${NUM_REQUESTS:-10}"
CONCURRENCY="${CONCURRENCY:-5}"

echo "NUM_REQUESTS=$NUM_REQUESTS"
echo "CONCURRENCY=$CONCURRENCY"

echo "🔍 Discovering Gateway IP..."
GATEWAY_IP=$(kubectl get gateway infra-pd-inference-gateway -n $NAMESPACE -o jsonpath='{.status.addresses[0].value}')
TARGET_URL="http://$GATEWAY_IP/v1/completions"
echo "✅ Found Gateway at: $TARGET_URL"

echo "🗑️  Cleaning up old jobs..."
kubectl delete job $JOB_NAME -n $NAMESPACE --ignore-not-found=true

echo "🚀 Creating Custom Load Job..."
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  template:
    metadata:
      annotations:
        gke-gcsfuse/volumes: "true"
    spec:
      serviceAccountName: ms-pd-llm-d-modelservice
      containers:
      - name: load-generator
        image: vllm/vllm-openai:latest
        command: ["python3", "-c"]
        args:
        - |
          import random
          import time
          import concurrent.futures
          import requests
          import json

          URL = "$TARGET_URL"
          MODEL = "Qwen/Qwen3-32B"
          NUM_REQUESTS = $NUM_REQUESTS
          CONCURRENCY = $CONCURRENCY

          print("Loading dataset...")
          try:
              with open("/mnt/dataset/hf-dataset/ShareGPT_V3_unfiltered_cleaned_split.json", "r") as f:
                  dataset = json.load(f)
              
              prompts = []
              for item in dataset:
                  if "conversations" in item and len(item["conversations"]) > 0:
                      first_conv = item["conversations"][0]
                      if first_conv.get("from") == "human":
                          prompts.append(first_conv.get("value"))
              print(f"Loaded {len(prompts)} prompts.")
          except Exception as e:
              print(f"Error loading dataset: {e}")
              prompts = ["Hello, how are you?"] # Fallback

          def send_request(i):
              prompt = random.choice(prompts) if prompts else "Hello"
              # Add random salt at the beginning to avoid prefix cache hits
              prompt = f"Random salt {random.randint(0, 1000000)}: " + prompt
              
              payload = {
                  "model": MODEL,
                  "prompt": prompt,
                  "max_tokens": 50,
              }
              
              start = time.time()
              try:
                  resp = requests.post(URL, json=payload)
                  latency = time.time() - start
                  print(f"Req {i}: Status {resp.status_code}, Prompt Len {len(prompt)}, Latency {latency:.2f}s")
                  return latency
              except Exception as e:
                  print(f"Req {i}: Error {e}")
                  return None

          print(f"Starting {NUM_REQUESTS} requests with concurrency {CONCURRENCY}...")
          start_total = time.time()

          with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
              futures = [executor.submit(send_request, i) for i in range(NUM_REQUESTS)]
              latencies = [f.result() for f in concurrent.futures.as_completed(futures)]

          total_time = time.time() - start_total
          valid_latencies = [l for l in latencies if l is not None]

          if valid_latencies:
              print(f"==========================================")
              print(f"Total Time: {total_time:.2f}s")
              print(f"Avg Latency: {sum(valid_latencies)/len(valid_latencies):.2f}s")
              print(f"Successful: {len(valid_latencies)}/{NUM_REQUESTS}")
              print(f"==========================================")
          else:
              print("All requests failed.")
        volumeMounts:
        - name: dataset-volume
          mountPath: /mnt/dataset
      volumes:
      - name: dataset-volume
        csi:
          driver: gcsfuse.csi.storage.gke.io
          volumeAttributes:
            bucketName: rlalwani-vllm
            mountOptions: implicit-dirs
      restartPolicy: Never
EOF

echo "⏳ Job submitted. Follow logs with:"
echo "kubectl logs -f job/$JOB_NAME -n $NAMESPACE"
