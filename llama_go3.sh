#!/bin/bash

CONTAINER_NAME="llama_server"
IMAGE_NAME="llama_cpp_cuda"
MODEL_DIR="/mnt/models/llm"
HOST_PORT="8080"

# ---- INPUT FROM FLASK ----
MODEL_NAME="$1"
CONTEXT_SIZE="$2"

# ---- Defaults if not passed ----
if [ -z "$MODEL_NAME" ]; then
    echo "No model passed, defaulting to first model..."
    MODEL_NAME=$(ls $MODEL_DIR/*.gguf | head -n 1 | xargs -n1 basename)
fi

MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

if [ -z "$CONTEXT_SIZE" ]; then
    CONTEXT_SIZE=65536
fi

echo "Model: $MODEL_PATH"
echo "Context: $CONTEXT_SIZE"

# ---- Detect VRAM ----
echo "Detecting GPU memory..."
GPU_MEM=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits)

TOTAL_VRAM=0
while read -r line; do
    TOTAL_VRAM=$((TOTAL_VRAM + line))
done <<< "$GPU_MEM"

echo "Total free VRAM: ${TOTAL_VRAM} MiB"

# ---- Tensor split auto ----
echo "Calculating tensor split..."

readarray -t VRAMS <<< "$GPU_MEM"

TOTAL=0
for v in "${VRAMS[@]}"; do
    TOTAL=$((TOTAL + v))
done

SPLIT=""
for v in "${VRAMS[@]}"; do
    PERCENT=$((v * 100 / TOTAL))
    SPLIT+="$PERCENT,"
done

TENSOR_SPLIT=${SPLIT%,}

echo "Tensor split: $TENSOR_SPLIT"

# ---- Stop old container ----
if [ "$(sudo docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
    echo "Stopping old container..."
    sudo docker stop $CONTAINER_NAME
    sudo docker rm $CONTAINER_NAME
fi

# ---- Validate model exists ----
if [ ! -f "$MODEL_PATH" ]; then
    echo "❌ Model not found: $MODEL_PATH"
    exit 1
fi

# ---- Launch ----
echo "Launching llama-server..."

sudo docker run -d \
--name $CONTAINER_NAME \
--gpus '"device=0,1,2"' \
--restart unless-stopped \
-p $HOST_PORT:$HOST_PORT \
-v /mnt/models:/mnt/models \
--env PYTHONUNBUFFERED=1 \
--log-opt mode=non-blocking \
--log-opt max-buffer-size=4m \
$IMAGE_NAME \
./build/bin/llama-server \
--model $MODEL_PATH \
--n-gpu-layers -1 \
--ctx-size $CONTEXT_SIZE \
--tensor-split $TENSOR_SPLIT \
--host 0.0.0.0 \
--port $HOST_PORT \
--embeddings

echo ""
echo "✅ Server running:"
echo "Model: $MODEL_PATH"
echo "Context: $CONTEXT_SIZE"
echo "URL: http://localhost:$HOST_PORT"
