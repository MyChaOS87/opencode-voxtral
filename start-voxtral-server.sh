#!/bin/bash
# Start Voxtral vLLM server for OpenCode STT plugin
# Usage: ./start-voxtral-server.sh [port]

set -e

# Configuration
PORT=${1:-8080}
MODEL="mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
MAX_MODEL_LEN=8192

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Voxtral vLLM server...${NC}"
echo "Model: $MODEL"
echo "Port: $PORT"
echo "Max model length: $MAX_MODEL_LEN"
echo ""

# Check if prime-run is available (for NVIDIA Optimus laptops)
if command -v prime-run &> /dev/null; then
    echo -e "${YELLOW}Using prime-run for NVIDIA GPU${NC}"
    RUNNER="prime-run"
else
    RUNNER=""
fi

# Check if vllm is installed
if ! command -v vllm &> /dev/null; then
    echo -e "${RED}Error: vllm not found. Install with: uv pip install vllm${NC}"
    exit 1
fi

# Start the server
echo -e "${GREEN}Launching server...${NC}"
echo "Press Ctrl+C to stop"
echo ""

$RUNNER vllm serve "$MODEL" \
    --port $PORT \
    --max-model-len $MAX_MODEL_LEN \
    --dtype bfloat16 \
    --load-format auto \
    --trust-remote-code

echo ""
echo -e "${RED}Server stopped${NC}"
