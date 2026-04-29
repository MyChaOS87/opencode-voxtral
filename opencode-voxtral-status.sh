#!/bin/bash
# opencode-voxtral-status.sh - Check status of Voxtral vLLM server
# Usage: ./opencode-voxtral-status.sh [status|stop|logs|wait]

set -euo pipefail

PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/opencode-voxtral"
VLLM_PID_FILE="$PID_DIR/vllm.pid"
VLLM_LOG_FILE="$PID_DIR/vllm.log"
REF_COUNT_FILE="$PID_DIR/ref_count"
VLLM_PORT="${VOXTRAL_PORT:-8080}"

check_vllm_health() {
    curl -sf "http://localhost:$VLLM_PORT/health" >/dev/null 2>&1
}

check_vllm_process() {
    if [[ -f "$VLLM_PID_FILE" ]]; then
        local pid=$(cat "$VLLM_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_ref_count() {
    if [[ -f "$REF_COUNT_FILE" ]]; then
        cat "$REF_COUNT_FILE"
    else
        echo 0
    fi
}

show_status() {
    echo "=== OpenCode + Voxtral Status ==="
    echo ""
    
    if check_vllm_process; then
        local pid=$(cat "$VLLM_PID_FILE" 2>/dev/null)
        echo "vLLM Process: RUNNING (PID: $pid)"
        
        if check_vllm_health; then
            echo "vLLM Health:  HEALTHY"
            echo "vLLM URL:     http://localhost:$VLLM_PORT"
        else
            echo "vLLM Health:  NOT RESPONDING"
        fi
        
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null || echo "unknown")
        echo "vLLM Uptime:  $uptime"
    else
        echo "vLLM Process: NOT RUNNING"
    fi
    
    echo "Active OpenCode instances: $(get_ref_count)"
    
    if [[ -f "$VLLM_LOG_FILE" ]]; then
        echo ""
        echo "Recent vLLM Log:"
        tail -n 5 "$VLLM_LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (No log entries)"
    fi
}

force_stop() {
    echo "Force stopping vLLM..."
    
    if [[ -f "$VLLM_PID_FILE" ]]; then
        local pid=$(cat "$VLLM_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            echo "Killing PID: $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$VLLM_PID_FILE"
    fi
    
    local port_pid=$(lsof -ti:$VLLM_PORT 2>/dev/null || true)
    if [[ -n "$port_pid" ]]; then
        echo "Killing process on port $VLLM_PORT: $port_pid"
        kill -9 "$port_pid" 2>/dev/null || true
    fi
    
    rm -f "$REF_COUNT_FILE" "$PID_DIR/lock"
    rmdir "$PID_DIR" 2>/dev/null || true
    echo "vLLM stopped"
}

show_logs() {
    if [[ -f "$VLLM_LOG_FILE" ]]; then
        echo "=== vLLM Logs ==="
        tail -f "$VLLM_LOG_FILE"
    else
        echo "No log file found"
    fi
}

wait_for_vllm() {
    echo "Waiting for vLLM to be ready..."
    local retries=60
    while ((retries > 0)); do
        if check_vllm_health; then
            echo "vLLM is ready!"
            exit 0
        fi
        sleep 1
        ((retries--))
        echo -n "."
    done
    echo "Timeout waiting for vLLM"
    exit 1
}

# Main
case "${1:-status}" in
    status)
        show_status
        ;;
    stop)
        force_stop
        ;;
    logs)
        show_logs
        ;;
    wait)
        wait_for_vllm
        ;;
    *)
        echo "Usage: $0 [status|stop|logs|wait]"
        exit 1
        ;;
esac
