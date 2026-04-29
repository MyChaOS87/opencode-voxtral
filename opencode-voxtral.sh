#!/bin/bash
# opencode-voxtral.sh - Launch OpenCode with shared Voxtral vLLM server
# 
# Features:
# - Automatic venv management at ~/.opencode-voxtral
# - Auto-install prompt if venv/packages missing
# - Update checking
# - Singleton vLLM server with reference counting
#
# Usage: ./opencode-voxtral.sh [opencode-args...]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$HOME/.opencode-voxtral}"
# Persist user model choice across restarts
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode-voxtral"
MODEL_CONFIG_FILE="$CONFIG_DIR/last-model"
# Default to pre-quantized model (much faster, skips on-the-fly quantization)
DEFAULT_MODEL="mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
# Load persisted model unless explicitly overridden by env var
if [[ -n "${VOXTRAL_MODEL:-}" ]]; then
    VLLM_MODEL="$VOXTRAL_MODEL"
elif [[ -f "$MODEL_CONFIG_FILE" ]]; then
    VLLM_MODEL="$(cat "$MODEL_CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$VLLM_MODEL" ]]; then
        :  # model loaded from config
    else
        VLLM_MODEL="$DEFAULT_MODEL"
    fi
else
    VLLM_MODEL="$DEFAULT_MODEL"
fi
# Generate random high port (50000-65535) if not specified
if [[ -n "${VOXTRAL_PORT:-}" ]]; then
    VLLM_PORT="$VOXTRAL_PORT"
else
    # Generate random port between 50000-65535
    VLLM_PORT=$((50000 + RANDOM % 15536))
fi
VLLM_MAX_LEN="${VOXTRAL_MAX_LEN:-8192}"
# Quantization: only needed for non-pre-quantized models
VLLM_QUANTIZATION="${VOXTRAL_QUANTIZATION:-}"
VLLM_GPU_MEMORY="${VOXTRAL_GPU_MEMORY:-0.80}"
PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/opencode-voxtral"
VLLM_PID_FILE="$PID_DIR/vllm.pid"
VLLM_LOG_FILE="$PID_DIR/vllm.log"
REF_COUNT_FILE="$PID_DIR/ref_count"
VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Ensure PID directory exists
mkdir -p "$PID_DIR"

# Logging functions
log_info() { echo -e "${GREEN}[opencode-voxtral]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[opencode-voxtral]${NC} $1" >&2; }
log_error() { echo -e "${RED}[opencode-voxtral]${NC} $1" >&2; }
log_debug() { echo -e "${BLUE}[opencode-voxtral]${NC} $1" >&2; }
log_prompt() { echo -e "${CYAN}[opencode-voxtral]${NC} $1" >&2; }

# Check if running in interactive terminal
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Check if uv is available (prefer uv over pip for speed)
has_uv() {
    # Check common uv locations
    if command -v uv &>/dev/null; then
        return 0
    elif [[ -x "$HOME/.cargo/bin/uv" ]]; then
        return 0
    elif [[ -x "$HOME/.local/bin/uv" ]]; then
        return 0
    fi
    return 1
}

# Get the appropriate Python executable
get_python_cmd() {
    if has_uv; then
        echo "uv run --python python3"
    else
        echo "python3"
    fi
}

# Ask user for confirmation (y/n)
ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    
    if ! is_interactive; then
        # Non-interactive, return default
        log_debug "Non-interactive mode detected, using default: $default"
        [[ "$default" == "y" ]]
        return
    fi
    
    log_debug "Interactive mode confirmed, prompting user"
    
    while true; do
        if [[ "$default" == "y" ]]; then
            log_prompt "$prompt [Y/n] "
        else
            log_prompt "$prompt [y/N] "
        fi
        read -r response
        
        # Default if empty
        if [[ -z "$response" ]]; then
            response="$default"
        fi
        
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) log_warn "Please answer yes or no.";;
        esac
    done
}

# Check if venv exists and is valid
check_venv() {
    if [[ ! -d "$VENV_DIR" ]]; then
        return 1
    fi
    
    # Check if python exists in venv
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        return 1
    fi
    
    return 0
}

# Check if required packages are installed
check_packages() {
    local python="$VENV_DIR/bin/python"
    
    # Check vllm
    if ! "$python" -c "import vllm" 2>/dev/null; then
        return 1
    fi
    
    # Check other required packages
    if ! "$python" -c "import sounddevice, soundfile, numpy, requests" 2>/dev/null; then
        return 1
    fi
    
    return 0
}

# Install/update the venv and packages
install_venv() {
    log_info "Setting up Python virtual environment..."
    log_info "Location: $VENV_DIR"
    
    # Check if uv is available and preferred
    if has_uv; then
        log_info "Using uv (fast Python package installer)"
        
        # Create venv with uv if it doesn't exist
        if [[ ! -d "$VENV_DIR" ]]; then
            log_info "Creating virtual environment with uv..."
            uv venv "$VENV_DIR"
        fi
        
        # Install/upgrade packages with uv
        log_info "Installing required packages with uv..."
        log_info "This may take a few minutes (downloading ML models)..."
        
        uv pip install --python "$VENV_DIR/bin/python" \
            vllm transformers sounddevice soundfile numpy requests bitsandbytes
        
    else
        log_info "Using pip (consider installing uv for faster installs: https://astral.sh/uv)"
        
        # Create venv with standard python if it doesn't exist
        if [[ ! -d "$VENV_DIR" ]]; then
            log_info "Creating virtual environment..."
            python3 -m venv "$VENV_DIR"
        fi
        
        local python="$VENV_DIR/bin/python"
        local pip="$VENV_DIR/bin/pip"
        
        # Upgrade pip
        log_info "Upgrading pip..."
        "$pip" install --upgrade pip
        
        # Install/upgrade packages
        log_info "Installing required packages..."
        log_info "This may take a few minutes (downloading ML models)..."
        
        "$pip" install vllm transformers sounddevice soundfile numpy requests bitsandbytes
    fi
    
    log_info "Installation complete!"
}

# Check for updates (compare installed vllm version with latest)
check_for_updates() {
    local python="$VENV_DIR/bin/python"
    
    log_info "Checking for updates..."
    
    # Get installed vllm version
    local installed_version
    installed_version=$("$python" -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "unknown")
    
    log_info "Installed vLLM version: $installed_version"
    
    # Try to get latest version from PyPI (with timeout)
    local latest_version
    if latest_version=$(curl -s --max-time 5 "https://pypi.org/pypi/vllm/json" 2>/dev/null | "$python" -c "import sys, json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null); then
        log_info "Latest vLLM version: $latest_version"
        
        if [[ "$installed_version" != "$latest_version" ]]; then
            log_warn "Update available: $installed_version -> $latest_version"
            if ask_yes_no "Would you like to update vLLM?" "y"; then
                log_info "Updating packages..."
                
                # Use uv if available, otherwise pip
                if has_uv; then
                    uv pip install --python "$VENV_DIR/bin/python" --upgrade vllm transformers
                else
                    "$VENV_DIR/bin/pip" install --upgrade vllm transformers
                fi
                
                log_info "Update complete!"
            fi
        else
            log_info "vLLM is up to date."
        fi
    else
        log_warn "Could not check for updates (network unavailable)"
    fi
}

# Get the Python executable (either from venv or system)
get_python() {
    if check_venv; then
        echo "$VENV_DIR/bin/python"
    else
        echo "python3"
    fi
}

# Check if vLLM is healthy
check_vllm_health() {
    local url="http://localhost:$VLLM_PORT/health"
    curl -sf "$url" >/dev/null 2>&1
}

# Get HuggingFace cache size for the current model
get_model_cache_size() {
    local cache_dir="${HF_HOME:-$HOME/.cache/huggingface}"
    local model_dir=""

    # Try to find the model directory
    if [[ -d "$cache_dir/hub/models--${VLLM_MODEL//\//--}" ]]; then
        model_dir="$cache_dir/hub/models--${VLLM_MODEL//\//--}"
    elif [[ -d "$cache_dir/hub/models--mistralai--Voxtral-Mini-4B-Realtime-2602" ]]; then
        model_dir="$cache_dir/hub/models--mistralai--Voxtral-Mini-4B-Realtime-2602"
    fi

    if [[ -n "$model_dir" ]] && [[ -d "$model_dir" ]]; then
        du -sb "$model_dir" 2>/dev/null | cut -f1 || echo "0"
    else
        echo "0"
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        if [[ $bytes -gt 1073741824 ]]; then
            echo "$(echo "scale=1; $bytes/1073741824" | bc 2>/dev/null || echo "$((bytes/1073741824))")GiB"
        elif [[ $bytes -gt 1048576 ]]; then
            echo "$(echo "scale=1; $bytes/1048576" | bc 2>/dev/null || echo "$((bytes/1048576))")MiB"
        elif [[ $bytes -gt 1024 ]]; then
            echo "$(echo "scale=1; $bytes/1024" | bc 2>/dev/null || echo "$((bytes/1024))")KiB"
        else
            echo "${bytes}B"
        fi
    fi
}

# Get vLLM process CPU usage
get_vllm_cpu_usage() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0"
    else
        echo "0"
    fi
}

# Estimate progress based on cache size
estimate_progress() {
    local current_size=$1
    local expected_size

    # Determine expected download size based on model
    if [[ "$VLLM_MODEL" == *"4bit"* ]] || [[ "$VLLM_MODEL" == *"int4"* ]]; then
        expected_size=4294967296  # ~4GB for pre-quantized models
    elif [[ "$VLLM_MODEL" == *"GGUF"* ]]; then
        expected_size=3221225472  # ~3GB for GGUF Q4_K_M
    elif [[ -n "$VLLM_QUANTIZATION" ]]; then
        # With on-the-fly quantization: download ~16GB, then quantize
        # Total cache may peak higher during process
        expected_size=21474836480  # 20GB peak
    else
        expected_size=17179869184  # 16GB for unquantized bfloat16
    fi

    local percent=$((current_size * 100 / expected_size))
    if [[ $percent -gt 100 ]]; then
        percent=100
    fi
    echo "$percent"
}

# Get reference count
get_ref_count() {
    if [[ -f "$REF_COUNT_FILE" ]]; then
        cat "$REF_COUNT_FILE"
    else
        echo 0
    fi
}

# Set reference count (with atomic file write)
set_ref_count() {
    local count="$1"
    local tmp_file="$REF_COUNT_FILE.tmp.$$"
    echo "$count" > "$tmp_file"
    mv "$tmp_file" "$REF_COUNT_FILE"
}

# Increment reference count
increment_ref() {
    local count
    count=$(get_ref_count)
    count=$((count + 1))
    set_ref_count "$count"
    log_debug "Reference count incremented to: $count"
}

# Decrement reference count
decrement_ref() {
    local count
    count=$(get_ref_count)
    if [[ $count -gt 0 ]]; then
        count=$((count - 1))
        set_ref_count "$count"
    fi
    log_debug "Reference count decremented to: $count"
    echo "$count"
}

# Check if vLLM process is actually running
check_vllm_process() {
    if [[ -f "$VLLM_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VLLM_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Start vLLM server
start_vllm() {
    log_info "Starting Voxtral vLLM server..."
    log_info "Model: $VLLM_MODEL"
    log_info "Port: $VLLM_PORT"
    
    # Check if already running
    if check_vllm_process && check_vllm_health; then
        log_info "vLLM server already running (PID: $(cat "$VLLM_PID_FILE"))"
        return 0
    fi
    
    # Check for stale vLLM processes using GPU memory
    local vllm_pids
    vllm_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -I{} ps -p {} -o comm=,pid= 2>/dev/null | grep -i vllm | awk '{print $2}' || true)
    if [[ -n "$vllm_pids" ]]; then
        log_warn "Found stale vLLM processes using GPU: $vllm_pids"
        if ask_yes_no "Kill these processes to free up GPU memory?" "y"; then
            echo "$vllm_pids" | xargs kill -9 2>/dev/null || true
            sleep 2
        else
            log_warn "Proceeding without killing - this may cause out-of-memory errors"
        fi
    fi
    
    # Kill any stale processes on our port
    local stale_pid
    stale_pid=$(lsof -ti:$VLLM_PORT 2>/dev/null || true)
    if [[ -n "$stale_pid" ]]; then
        log_warn "Killing stale process on port $VLLM_PORT (PID: $stale_pid)"
        kill -9 "$stale_pid" 2>/dev/null || true
        sleep 1
    fi
    
    # Determine runner (prime-run for Optimus laptops)
    local runner=""
    if command -v prime-run &>/dev/null; then
        log_info "Using prime-run for NVIDIA GPU"
        runner="prime-run"
    fi
    
    # Check vllm is available
    local python
    python=$(get_python)
    if ! "$python" -c "import vllm" 2>/dev/null; then
        log_error "vllm not found in $python"
        log_info "Please run: $0 --install"
        exit 1
    fi
    
    # Start vLLM in background
    log_info "Launching vLLM (log: $VLLM_LOG_FILE)"
    
    # Use flock on the log file to prevent concurrent starts
    (
        flock -n 200 || { log_info "Another instance is starting vLLM, waiting..."; flock 200; }
        
        # Double-check after acquiring lock
        if check_vllm_process && check_vllm_health; then
            log_info "vLLM started by another instance (PID: $(cat "$VLLM_PID_FILE"))"
            exit 0
        fi
        
        # Use venv python if available
        if check_venv; then
            export PATH="$VENV_DIR/bin:$PATH"
        fi

        # Enable HuggingFace download progress bars
        export HF_HUB_ENABLE_PROGRESS_BARS=1
        export HF_HUB_DOWNLOAD_TIMEOUT=300

        # Build vllm command with optional quantization
        local vllm_args=(
            "serve" "$VLLM_MODEL"
            --port "$VLLM_PORT"
            --max-model-len "$VLLM_MAX_LEN"
            --dtype bfloat16
            --load-format auto
            --trust-remote-code
            --gpu-memory-utilization "$VLLM_GPU_MEMORY"
        )
        
        # Add Voxtral-specific compilation config (required for Voxtral models)
        if [[ "$VLLM_MODEL" == *"voxtral"* ]] || [[ "$VLLM_MODEL" == *"Voxtral"* ]]; then
            log_info "Configuring Voxtral-specific compilation mode (PIECEWISE)"
            vllm_args+=(--compilation-config '{"cudagraph_mode": "PIECEWISE"}')
        fi
        
        # Add quantization if explicitly specified (not needed for pre-quantized models)
        if [[ -n "$VLLM_QUANTIZATION" ]]; then
            vllm_args+=(--quantization "$VLLM_QUANTIZATION")
            log_info "Using on-the-fly quantization: $VLLM_QUANTIZATION"
            log_info "   ⚠️  This will be VERY SLOW on first run (20-40 min)"
        fi
        
        $runner vllm "${vllm_args[@]}" \
            > "$VLLM_LOG_FILE" 2>&1 &
        
        local vllm_pid=$!
        echo "$vllm_pid" > "$VLLM_PID_FILE"
        
        # Wait for vLLM to be ready
        log_info "Waiting for vLLM to be ready..."

        # Check if this is likely first run (no cached model)
        local cache_dir="${HF_HOME:-$HOME/.cache/huggingface}"
        local is_first_run=false
        local initial_cache_size=0
        local model_cache_name="${VLLM_MODEL//\//--}"
        if [[ ! -d "$cache_dir/hub/models--$model_cache_name" ]]; then
            is_first_run=true
            if [[ "$VLLM_MODEL" == *"4bit"* ]] || [[ "$VLLM_MODEL" == *"GGUF"* ]]; then
                log_info "ℹ️  First run - downloading pre-quantized model (~4GB)"
                log_info "   This is much faster than on-the-fly quantization"
                log_info "   Expected time: 5-15 minutes depending on connection"
            else
                log_info "ℹ️  First run - downloading full model (~16GB)"
                if [[ -n "$VLLM_QUANTIZATION" ]]; then
                    log_info "   ⚠️  On-the-fly quantization will be VERY SLOW (20-40 min)"
                else
                    log_info "   ⚠️  Large model without quantization - needs 16GB+ VRAM"
                fi
            fi
            log_info "   📊 Download progress bars enabled (HF_HUB_ENABLE_PROGRESS_BARS=1)"
        else
            initial_cache_size=$(get_model_cache_size)
            log_info "📦 Model cache found: $(format_bytes "$initial_cache_size")"
        fi

        log_info "Showing live log output (press Ctrl+C to stop watching, vLLM will keep running):"
        echo ""

        # Start a background tail process to show log output
        local tail_pid
        tail -f "$VLLM_LOG_FILE" 2>/dev/null &
        tail_pid=$!

        # Longer timeout for first run with quantization (45 minutes)
        local max_wait=2700  # 45 minutes in seconds
        if [[ "$is_first_run" == "true" ]] && [[ -n "$VLLM_QUANTIZATION" ]]; then
            max_wait=3600  # 60 minutes for first run with quantization
            log_info "Extended timeout enabled: 60 minutes for first-run quantization"
        fi

        local retries=$max_wait
        local wait_time=0
        local last_log_size=0
        local stall_count=0
        local last_cache_size=$initial_cache_size
        local cache_stall_count=0
        local download_start_size=$initial_cache_size
        local download_start_time=$SECONDS

        while [[ $retries -gt 0 ]]; do
            if check_vllm_health; then
                # Kill the tail process
                kill $tail_pid 2>/dev/null || true
                wait $tail_pid 2>/dev/null || true
                echo ""
                log_info "vLLM is ready (PID: $vllm_pid)"
                log_info "Total startup time: ${wait_time}s"
                # Persist model choice for future runs
                if [[ -n "$VLLM_MODEL" ]]; then
                    mkdir -p "$CONFIG_DIR"
                    echo "$VLLM_MODEL" > "$MODEL_CONFIG_FILE"
                    log_debug "Model preference saved: $VLLM_MODEL"
                fi
                exit 0
            fi

            # Check if process died
            if ! kill -0 "$vllm_pid" 2>/dev/null; then
                # Kill the tail process
                kill $tail_pid 2>/dev/null || true
                wait $tail_pid 2>/dev/null || true
                echo ""

                # Check for specific error patterns in the log
                if [[ -f "$VLLM_LOG_FILE" ]]; then
                    if grep -q "param_data.shape == loaded_weight.shape" "$VLLM_LOG_FILE" 2>/dev/null; then
                        log_error "❌ SHAPE MISMATCH ERROR DETECTED"
                        log_error ""
                        log_error "This error means the model cache is corrupted."
                        log_error "The cache shows $(format_bytes "$(get_model_cache_size)") but should be ~4-8GB."
                        log_error ""
                        log_error "💡 SOLUTION: Clean the cache and re-download"
                        log_error "   Run: $0 --clean-cache"
                        log_error ""
                        rm -f "$VLLM_PID_FILE"
                        exit 1
                    elif grep -q "CUDA out of memory" "$VLLM_LOG_FILE" 2>/dev/null; then
                        log_error "❌ GPU OUT OF MEMORY ERROR"
                        log_error ""
                        log_error "Solutions:"
                        log_error "  1. Lower GPU memory: VOXTRAL_GPU_MEMORY=0.70 $0"
                        log_error "  2. Reduce max length: VOXTRAL_MAX_LEN=4096 $0"
                        log_error ""
                        rm -f "$VLLM_PID_FILE"
                        exit 1
                    fi
                fi

                log_error "vLLM process died. Check full logs: $VLLM_LOG_FILE"
                tail -50 "$VLLM_LOG_FILE" >&2 || true
                rm -f "$VLLM_PID_FILE"
                exit 1
            fi

            # Check if log file is still growing (detect stalled quantization)
            local current_log_size=0
            if [[ -f "$VLLM_LOG_FILE" ]]; then
                current_log_size=$(stat -c%s "$VLLM_LOG_FILE" 2>/dev/null || echo 0)
            fi

            if [[ $current_log_size -eq $last_log_size ]]; then
                stall_count=$((stall_count + 1))
            else
                stall_count=0
                last_log_size=$current_log_size
            fi

            sleep 1
            retries=$((retries - 1))
            wait_time=$((wait_time + 1))

            # Show progress every 30 seconds
            if [[ $((wait_time % 30)) -eq 0 ]]; then
                local mins_remaining=$((retries / 60))
                local mins_elapsed=$((wait_time / 60))

                # Get current cache size
                local current_cache_size=$(get_model_cache_size)
                local cache_diff=$((current_cache_size - last_cache_size))
                local cache_human=$(format_bytes "$current_cache_size")
                local cpu_usage=$(get_vllm_cpu_usage "$vllm_pid")

                # State machine for progress tracking
                local current_state="unknown"
                if [[ $current_cache_size -eq $last_cache_size ]]; then
                    cache_stall_count=$((cache_stall_count + 1))
                else
                    cache_stall_count=0
                    last_cache_size=$current_cache_size
                fi

                # Determine expected size based on model
                local expected_download_size=17179869184  # 16GB default
                if [[ "$VLLM_MODEL" == *"4bit"* ]] || [[ "$VLLM_MODEL" == *"int4"* ]]; then
                    expected_download_size=4294967296  # 4GB
                elif [[ "$VLLM_MODEL" == *"GGUF"* ]]; then
                    expected_download_size=3221225472  # 3GB
                fi

                # Determine phase
                if [[ $cache_diff -gt 10485760 ]]; then  # >10MB growth = downloading
                    current_state="downloading"
                elif [[ $current_cache_size -lt $expected_download_size ]]; then
                    if [[ $cache_stall_count -lt 3 ]]; then
                        current_state="downloading"
                    else
                        current_state="download_stalled"
                    fi
                else
                    # Downloaded expected size, now check if still growing
                    if [[ $cache_diff -gt 0 ]]; then
                        current_state="downloading"
                    elif [[ $cache_stall_count -lt 3 ]]; then
                        current_state="downloaded"
                    elif [[ -n "$VLLM_QUANTIZATION" ]]; then
                        # Only show quantizing state if on-the-fly quantization is enabled
                        local cpu_int="${cpu_usage%.*}"
                        if [[ -z "$cpu_int" ]] || [[ "$cpu_int" == "0" ]]; then
                            cpu_int=0
                        fi
                        if [[ $cpu_int -gt 30 ]]; then
                            current_state="quantizing"
                        elif [[ $cpu_int -gt 5 ]]; then
                            current_state="quantizing_slow"
                        else
                            current_state="stalled"
                        fi
                    else
                        # Pre-quantized model: should start soon after download
                        current_state="starting"
                    fi
                fi

                echo ""
                log_info "⏱️  $mins_elapsed min elapsed, ~$mins_remaining min timeout left"

                if [[ "$is_first_run" == "true" ]]; then
                    # Determine model size description
                    local model_size_desc="~16GB"
                    if [[ "$VLLM_MODEL" == *"4bit"* ]] || [[ "$VLLM_MODEL" == *"int4"* ]]; then
                        model_size_desc="~4GB (pre-quantized)"
                    elif [[ "$VLLM_MODEL" == *"GGUF"* ]]; then
                        model_size_desc="~3GB (GGUF)"
                    fi

                    case "$current_state" in
                        downloading)
                            # Calculate average rate since download started (smoother than last 30s)
                            local download_elapsed=$((SECONDS - download_start_time))
                            local download_growth=$((current_cache_size - download_start_size))
                            local avg_rate=0
                            if [[ $download_elapsed -gt 0 ]] && [[ $download_growth -gt 0 ]]; then
                                avg_rate=$((download_growth / download_elapsed))
                            fi
                            log_info "   📥 Downloading model: $cache_human"
                            if [[ $avg_rate -gt 0 ]]; then
                                log_info "   ⬇️  Avg rate: $(format_bytes "$avg_rate")/s (${download_elapsed}s elapsed)"
                            fi
                            log_info "   ⏳ Model is $model_size_desc, please wait..."
                            ;;
                        download_stalled)
                            local stalled_elapsed=$((SECONDS - download_start_time))
                            local stalled_growth=$((current_cache_size - download_start_size))
                            local stalled_avg_rate=0
                            if [[ $stalled_elapsed -gt 0 ]] && [[ $stalled_growth -gt 0 ]]; then
                                stalled_avg_rate=$((stalled_growth / stalled_elapsed))
                            fi
                            log_info "   📥 Downloading model: $cache_human"
                            log_info "   ⚠️  Download appears paused (no growth for ${cache_stall_count}s)"
                            if [[ $stalled_avg_rate -gt 0 ]]; then
                                log_info "   ⬇️  Avg so far: $(format_bytes "$stalled_avg_rate")/s (${stalled_elapsed}s elapsed)"
                            fi
                            log_info "   ⏳ This may be due to network or HuggingFace rate limits"
                            ;;
                        downloaded)
                            log_info "   ✅ Model downloaded: $cache_human"
                            # Reset download tracking for any future downloads
                            download_start_size=$current_cache_size
                            download_start_time=$SECONDS
                            if [[ -n "$VLLM_QUANTIZATION" ]]; then
                                log_info "   🔧 Starting on-the-fly quantization (this is slow)..."
                            else
                                log_info "   🚀 Loading model into GPU..."
                            fi
                            ;;
                        starting)
                            log_info "   ✅ Model downloaded: $cache_human"
                            log_info "   🚀 Starting vLLM server..."
                            if [[ $stall_count -gt 60 ]]; then
                                log_info "   ⏳ Taking longer than expected, but may still be starting..."
                            fi
                            ;;
                        quantizing)
                            log_info "   🔧 Quantizing model (CPU: ${cpu_usage}%)"
                            log_info "   ⏳ This is the slow part - converting to 4-bit weights"
                            log_info "   ✅ Process is actively working!"
                            ;;
                        quantizing_slow)
                            log_info "   🔧 Quantizing model (CPU: ${cpu_usage}%)"
                            log_info "   ⏳ Processing slowly but steadily..."
                            ;;
                        stalled)
                            log_info "   ⚠️  Process appears stalled (CPU: ${cpu_usage}%)"
                            log_info "   📝 Log not growing for ${stall_count}s"
                            if [[ $stall_count -gt 120 ]]; then
                                log_warn "   ⚠️  WARNING: Process may be stuck!"
                                log_info "   💡 Try: $0 --clean-cache --force && $0"
                            else
                                log_info "   ⏳ May just be slow - will warn if stuck for 2+ min"
                            fi
                            ;;
                    esac
                fi

                # Show GPU status
                if command -v nvidia-smi &>/dev/null; then
                    local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
                    local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
                    if [[ -n "$gpu_util" ]] && [[ -n "$gpu_mem" ]]; then
                        if [[ "$current_state" == "quantizing" ]] || [[ "$current_state" == "quantizing_slow" ]]; then
                            log_info "   🎮 GPU: ${gpu_util}% util, ${gpu_mem}MiB VRAM (quantization may use CPU more than GPU)"
                        else
                            log_info "   🎮 GPU: ${gpu_util}% util, ${gpu_mem}MiB VRAM"
                        fi
                    fi
                fi

                echo ""
            fi
        done

        # Kill the tail process
        kill $tail_pid 2>/dev/null || true
        wait $tail_pid 2>/dev/null || true
        echo ""

        # Check for specific error patterns
        if [[ -f "$VLLM_LOG_FILE" ]]; then
            if grep -q "param_data.shape == loaded_weight.shape" "$VLLM_LOG_FILE" 2>/dev/null; then
                log_error "❌ SHAPE MISMATCH ERROR DETECTED"
                log_error ""
                log_error "This error usually means:"
                log_error "  • The model cache is corrupted or partially downloaded"
                log_error "  • There's a version mismatch between cached files"
                log_error ""
                log_error "💡 SOLUTION: Clean the cache and start fresh"
                log_error "   Run: $0 --clean-cache"
                log_error ""
                log_error "Then try again: $0"
                log_error ""
                log_error "Full error log: $VLLM_LOG_FILE"
                kill "$vllm_pid" 2>/dev/null || true
                rm -f "$VLLM_PID_FILE"
                exit 1
            elif grep -q "CUDA out of memory" "$VLLM_LOG_FILE" 2>/dev/null; then
                log_error "❌ GPU OUT OF MEMORY ERROR"
                log_error ""
                log_error "Solutions:"
                log_error "  1. Lower GPU memory: VOXTRAL_GPU_MEMORY=0.70 $0"
                log_error "  2. Reduce max length: VOXTRAL_MAX_LEN=4096 $0"
                log_error "  3. Close other GPU apps and try again"
                log_error ""
                log_error "Full error log: $VLLM_LOG_FILE"
                kill "$vllm_pid" 2>/dev/null || true
                rm -f "$VLLM_PID_FILE"
                exit 1
            fi
        fi

        log_error "vLLM failed to start within $((max_wait / 60)) minutes"
        log_error "This may indicate:"
        log_error "  1. Slow download/quantization (bitsandbytes can take 30+ min on first run)"
        log_error "  2. GPU out of memory - try reducing VOXTRAL_GPU_MEMORY"
        log_error "  3. Model cache corrupted - try: $0 --clean-cache"
        log_error ""
        log_error "Check full logs: $VLLM_LOG_FILE"
        tail -100 "$VLLM_LOG_FILE" >&2 || true
        kill "$vllm_pid" 2>/dev/null || true
        rm -f "$VLLM_PID_FILE"
        exit 1
        
    ) 200>"$PID_DIR/vllm-start.lock"
}

# Stop vLLM server
stop_vllm() {
    log_info "Stopping Voxtral vLLM server..."

    if [[ -f "$VLLM_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VLLM_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            # Try graceful shutdown first
            kill "$pid" 2>/dev/null || true

            # Wait up to 10 seconds for graceful exit
            local wait_count=0
            while kill -0 "$pid" 2>/dev/null && [[ $wait_count -lt 10 ]]; do
                sleep 1
                wait_count=$((wait_count + 1))
            done

            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "Force killing vLLM (PID: $pid)"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$VLLM_PID_FILE"
    fi

    # Clean up PID directory
    rm -f "$REF_COUNT_FILE" "$PID_DIR"/*.lock "$PID_DIR"/*.tmp.* 2>/dev/null || true
    rmdir "$PID_DIR" 2>/dev/null || true

    log_info "vLLM stopped"
}

# Clean only model cache (keep venv)
clean_model_cache() {
    local force="${1:-false}"
    
    log_warn "⚠️  This will DELETE the model cache:"
    echo "   - HuggingFace cache: ~/.cache/huggingface/hub/models--mistralai--Voxtral*"
    echo "   - vLLM logs and PID files: $PID_DIR"
    echo "   (Virtual environment will be preserved)"
    echo ""

    if [[ "$force" != "true" ]]; then
        if ! ask_yes_no "Delete model cache and start fresh download?" "n"; then
            log_info "Clean cancelled"
            exit 0
        fi
    fi

    log_info "Stopping any running vLLM processes..."
    stop_vllm 2>/dev/null || true

    # Kill any remaining vLLM processes using GPU
    local vllm_pids
    vllm_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -I{} ps -p {} -o comm=,pid= 2>/dev/null | grep -i vllm | awk '{print $2}' || true)
    if [[ -n "$vllm_pids" ]]; then
        log_info "Killing remaining vLLM processes: $vllm_pids"
        echo "$vllm_pids" | xargs kill -9 2>/dev/null || true
    fi

    log_info "Deleting HuggingFace model cache..."
    local cache_dir="${HF_HOME:-$HOME/.cache/huggingface}"
    local cache_size=$(du -sh "$cache_dir/hub/models--"*Voxtral* 2>/dev/null | cut -f1 || echo "0B")
    rm -rf "$cache_dir/hub/models--mistralai--Voxtral"*
    rm -rf "$cache_dir/hub/models--mlx-community--Voxtral"*

    log_info "Clearing model preference..."
    rm -f "$MODEL_CONFIG_FILE"

    log_info "Cleaning up temporary files..."
    rm -rf "$PID_DIR"

    log_info "✅ Model cache cleaned! Freed approximately $cache_size"
    log_info "   Next run will use default model: $DEFAULT_MODEL"
}

# Clean all caches and venv (nuclear option)
clean_everything() {
    local force="${1:-false}"
    
    log_warn "☢️  NUCLEAR OPTION - This will DELETE EVERYTHING:"
    echo "   - Virtual environment: $VENV_DIR"
    echo "   - HuggingFace cache: ~/.cache/huggingface/hub/models--mistralai--Voxtral*"
    echo "   - vLLM logs and PID files: $PID_DIR"
    echo ""
    log_error "This requires complete reinstallation (~5-10 min)"
    echo ""

    if [[ "$force" != "true" ]]; then
        if ! ask_yes_no "Are you sure you want to delete EVERYTHING and start from scratch?" "n"; then
            log_info "Clean cancelled"
            exit 0
        fi
    fi

    log_info "Stopping any running vLLM processes..."
    stop_vllm 2>/dev/null || true

    # Kill any remaining vLLM processes using GPU
    local vllm_pids
    vllm_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | xargs -I{} ps -p {} -o comm=,pid= 2>/dev/null | grep -i vllm | awk '{print $2}' || true)
    if [[ -n "$vllm_pids" ]]; then
        log_info "Killing remaining vLLM processes: $vllm_pids"
        echo "$vllm_pids" | xargs kill -9 2>/dev/null || true
    fi

    log_info "Deleting virtual environment: $VENV_DIR"
    rm -rf "$VENV_DIR"

    log_info "Deleting HuggingFace model cache..."
    local cache_dir="${HF_HOME:-$HOME/.cache/huggingface}"
    rm -rf "$cache_dir/hub/models--mistralai--Voxtral"*
    rm -rf "$cache_dir/hub/models--mlx-community--Voxtral"*

    log_info "Clearing model preference and config..."
    rm -rf "$CONFIG_DIR"

    log_info "Cleaning up temporary files..."
    rm -rf "$PID_DIR"

    log_info "✅ Nuclear clean complete! Everything has been deleted."
    log_info "   Run '$0 --install' to set up completely fresh."
}

# Cleanup function - called on exit
cleanup() {
    local exit_code=$?
    
    log_debug "Cleanup triggered (exit code: $exit_code)"
    
    # Decrement reference count
    local ref_count
    ref_count=$(decrement_ref)
    
    if [[ $ref_count -eq 0 ]]; then
        log_info "Last OpenCode instance exiting, stopping vLLM..."
        stop_vllm
    else
        log_info "OpenCode exited (vLLM still running, $ref_count instances remaining)"
    fi
    
    exit $exit_code
}

# Trap signals to ensure cleanup
trap cleanup EXIT INT TERM

# Show help
show_help() {
    cat << EOF
OpenCode + Voxtral Launcher v$VERSION

Usage: $0 [OPTIONS] [OPENCODE-ARGS...]

Options:
  --install          Install/update the Python virtual environment
  --update           Check for and install updates
  --status           Show vLLM status and exit
  --stop             Stop vLLM server and exit
  --clean-cache      Delete only model cache (keep venv, fixes shape mismatch)
  --clean-all        Nuclear option: delete venv AND cache (start completely fresh)
  -f, --force        Skip confirmation prompts (use with --clean-cache or --clean-all)
  --reset-model      Reset to default model ($DEFAULT_MODEL)
  --version          Show version and exit
  --help             Show this help message

Environment Variables:
  VENV_DIR           Python venv location (default: ~/.opencode-voxtral)
  VOXTRAL_PORT       vLLM port (random 50000-65535, or set fixed)
  VOXTRAL_MODEL      Model to use (default: mistralai/Voxtral-Mini-4B-Realtime-2602)
  VOXTRAL_MAX_LEN    Max model length (default: 8192)
  VOXTRAL_GPU_MEMORY GPU memory utilization (default: 0.80)
  VOXTRAL_QUANTIZATION Quantization method (default: bitsandbytes)
  STT_VLLM_URL       vLLM server URL for OpenCode plugin (auto-set by script)
  DEBUG              Enable debug output (set to 1)

Examples:
  $0                           # Launch OpenCode with Voxtral
  $0 -c /path/to/project       # Launch with specific project
  $0 --install                 # Install/update dependencies
  $0 --status                  # Check vLLM status
EOF
}

# Show version
show_version() {
    echo "opencode-voxtral v$VERSION"
}

# Handle command-line arguments
# Sets global variables: ACTION, FORCE_CLEAN, OPENCODE_ARGS
default_action="run"
parse_args() {
    ACTION="$default_action"
    FORCE_CLEAN=false
    OPENCODE_ARGS=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)
                ACTION="install"
                shift
                ;;
            --update)
                ACTION="update"
                shift
                ;;
            --status)
                ACTION="status"
                shift
                ;;
            --stop)
                ACTION="stop"
                shift
                ;;
            --clean-cache)
                ACTION="clean-cache"
                shift
                ;;
            --clean-all)
                ACTION="clean-all"
                shift
                ;;
            -f|--force)
                FORCE_CLEAN=true
                shift
                ;;
            --reset-model)
                ACTION="reset-model"
                shift
                ;;
            --version)
                ACTION="version"
                shift
                ;;
            --help|-h)
                ACTION="help"
                shift
                ;;
            *)
                # Collect remaining args for opencode
                OPENCODE_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# Setup and check environment
setup_environment() {
    # Check if venv exists
    if ! check_venv; then
        log_warn "Virtual environment not found at: $VENV_DIR"
        if ask_yes_no "Would you like to install it now?" "y"; then
            install_venv
        else
            log_error "Cannot continue without virtual environment."
            log_info "Run manually with: $0 --install"
            exit 1
        fi
    fi
    
    # Check if packages are installed
    if ! check_packages; then
        log_warn "Required packages not found in virtual environment"
        if ask_yes_no "Would you like to install/update them now?" "y"; then
            install_venv
        else
            log_error "Cannot continue without required packages."
            exit 1
        fi
    fi
    
    # Check for updates (once per day)
    local last_check_file="$VENV_DIR/.last_update_check"
    local check_updates=false
    
    if [[ ! -f "$last_check_file" ]]; then
        check_updates=true
    else
        local last_check
        last_check=$(stat -c %Y "$last_check_file" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local day_seconds=86400
        
        if [[ $((now - last_check)) -gt $day_seconds ]]; then
            check_updates=true
        fi
    fi
    
    if $check_updates; then
        touch "$last_check_file"
        # Run update check in background so it doesn't block startup
        (check_for_updates &) 2>/dev/null
    fi
}

# Main
main() {
    # Parse arguments
    parse_args "$@"
    
    # Handle actions that don't require full setup
    case "$ACTION" in
        help)
            show_help
            exit 0
            ;;
        version)
            show_version
            exit 0
            ;;
        install)
            install_venv
            exit 0
            ;;
        update)
            if ! check_venv; then
                log_error "Virtual environment not found. Run: $0 --install"
                exit 1
            fi
            check_for_updates
            exit 0
            ;;
        status)
            exec "$SCRIPT_DIR/opencode-voxtral-status.sh" status
            ;;
        stop)
            exec "$SCRIPT_DIR/opencode-voxtral-status.sh" stop
            ;;
        clean-cache)
            clean_model_cache "$FORCE_CLEAN"
            exit 0
            ;;
        clean-all)
            clean_everything "$FORCE_CLEAN"
            exit 0
            ;;
        reset-model)
            if [[ -f "$MODEL_CONFIG_FILE" ]]; then
                local old_model="$(cat "$MODEL_CONFIG_FILE" 2>/dev/null || true)"
                rm -f "$MODEL_CONFIG_FILE"
                log_info "✅ Model preference reset"
                log_info "   Previous: $old_model"
                log_info "   Now using default: $DEFAULT_MODEL"
            else
                log_info "No model preference set, already using default: $DEFAULT_MODEL"
            fi
            exit 0
            ;;
        run)
            # Continue to main flow
            ;;
    esac
    
    log_info "OpenCode + Voxtral Launcher v$VERSION"
    log_info "PID: $$"
    
    # Show model info
    if [[ -f "$MODEL_CONFIG_FILE" ]]; then
        log_info "Using persisted model: $VLLM_MODEL"
        log_info "   (from $MODEL_CONFIG_FILE)"
    elif [[ -n "${VOXTRAL_MODEL:-}" ]]; then
        log_info "Using model from env: $VLLM_MODEL"
    else
        log_info "Using default model: $VLLM_MODEL"
    fi
    
    # Setup environment (checks venv, packages, updates)
    setup_environment
    
    # Debug mode
    if [[ "${DEBUG:-}" == "1" ]]; then
        log_debug "Debug mode enabled"
        log_debug "VENV_DIR: $VENV_DIR"
        log_debug "PID_DIR: $PID_DIR"
        log_debug "VLLM_PID_FILE: $VLLM_PID_FILE"
        log_debug "REF_COUNT_FILE: $REF_COUNT_FILE"
        log_debug "Initial ref count: $(get_ref_count)"
        set -x  # Enable bash trace
    fi
    
    # Increment reference count
    increment_ref
    
    # Start vLLM if needed
    start_vllm
    
    # Set environment variable for OpenCode STT plugin
    export STT_VLLM_URL="http://localhost:$VLLM_PORT"
    log_info "STT_VLLM_URL=$STT_VLLM_URL"
    
    # Launch OpenCode
    log_info "Starting OpenCode..."
    log_info ""
    
    # Run OpenCode with all passed arguments
    if command -v opencode &>/dev/null; then
        if [[ ${#OPENCODE_ARGS[@]} -gt 0 ]]; then
            opencode "${OPENCODE_ARGS[@]}"
        else
            opencode
        fi
    else
        log_error "opencode not found in PATH"
        exit 1
    fi
}

# Run main
main "$@"
