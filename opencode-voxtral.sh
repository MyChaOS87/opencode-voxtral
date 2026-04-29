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
# Official Mistral model - requires nightly vLLM + fp8 quantization for 8GB VRAM
DEFAULT_MODEL="mistralai/Voxtral-Mini-4B-Realtime-2602"
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
VLLM_MAX_LEN="${VOXTRAL_MAX_LEN:-1024}"
# Quantization: fp8 applied by default for full-precision models (fits 8GB VRAM on Ada Lovelace)
VLLM_QUANTIZATION="${VOXTRAL_QUANTIZATION:-}"
VLLM_GPU_MEMORY="${VOXTRAL_GPU_MEMORY:-0.90}"
PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/opencode-voxtral"
VLLM_PID_FILE="$PID_DIR/vllm.pid"
VLLM_LOG_FILE="$PID_DIR/vllm.log"
REF_COUNT_FILE="$PID_DIR/ref_count"
VERSION="1.0.0"
OPENCODE_PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"

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
        
        # Disable uv HTTP timeout so large wheels (vLLM ~230MB, torch ~500MB) never abort


        # Create venv with uv if it doesn't exist
        if [[ ! -d "$VENV_DIR" ]]; then
            log_info "Creating virtual environment with uv..."
            uv venv "$VENV_DIR"
        fi
        
        # Install/upgrade packages with uv
        log_info "Installing required packages with uv..."
        log_info "This may take a few minutes (downloading ML models)..."
        
        # Install non-vllm packages from PyPI first
        log_info "Installing base packages..."
        uv pip install --python "$VENV_DIR/bin/python" \
            "mistral-common[image]>=1.11.0" transformers sounddevice soundfile numpy requests hf-transfer

        # Install vLLM nightly (cu130) separately - required for Voxtral multimodal dispatch fix (PR #38410)
        # Nightly is ahead of v0.20.0 by 850+ commits and includes the Voxtral fix
        log_info "Installing vLLM nightly (cu130)..."
        uv pip install --python "$VENV_DIR/bin/python" \
            --torch-backend=cu130 \
            --extra-index-url https://wheels.vllm.ai/nightly/cu130 \
            vllm
        
    else
        log_info "Using pip (consider installing uv for faster installs: https://astral.sh/uv)"
        
        # Disable pip timeout so large wheels never abort


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
        
        # Install non-vllm packages from PyPI first
        "$pip" install \
            "mistral-common[image]>=1.11.0" transformers sounddevice soundfile numpy requests hf-transfer

        # Install vLLM nightly (cu130) separately
        "$pip" install \
            --extra-index-url https://wheels.vllm.ai/nightly/cu130 \
            vllm
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
    
    # Try to get latest version from PyPI
    local latest_version
    if latest_version=$(curl -s --max-time 5 "https://pypi.org/pypi/vllm/json" 2>/dev/null | "$python" -c "import sys, json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null); then
        log_info "Latest vLLM version: $latest_version"
        
        if [[ "$installed_version" != "$latest_version" ]]; then
            log_warn "Update available: $installed_version -> $latest_version"
            if ask_yes_no "Would you like to update vLLM?" "y"; then
                log_info "Updating packages..."
                
                # Use uv if available, otherwise pip
                if has_uv; then
                    uv pip install --python "$VENV_DIR/bin/python" \
                        --torch-backend=cu130 \
                        --extra-index-url https://wheels.vllm.ai/nightly/cu130 \
                        --upgrade vllm transformers
                else
                    "$VENV_DIR/bin/pip" install \
                        --extra-index-url https://wheels.vllm.ai/nightly/cu130 \
                        --upgrade vllm transformers
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

        # Enable hf-transfer for faster multi-connection downloads (if installed)
        export HF_HUB_ENABLE_HF_TRANSFER=1

        # Reduce CUDA memory fragmentation
        export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

        # Build vllm command with optional quantization
        local vllm_args=(
            "serve" "$VLLM_MODEL"
            --served-model-name "default"
            --port "$VLLM_PORT"
            --max-model-len "$VLLM_MAX_LEN"
            --dtype bfloat16
            --gpu-memory-utilization "$VLLM_GPU_MEMORY"
            --max-num-seqs 4
            --trust-remote-code
        )
        
        # Add Voxtral-specific compilation config (required for Voxtral models)
        if [[ "$VLLM_MODEL" == *"voxtral"* ]] || [[ "$VLLM_MODEL" == *"Voxtral"* ]]; then
            log_info "Configuring Voxtral-specific compilation mode (PIECEWISE)"
            vllm_args+=(--compilation-config '{"cudagraph_mode": "PIECEWISE"}')
        fi
        
        # Quantization: use fp8 by default for official mistralai model (needs quantization for 8GB VRAM)
        # bitsandbytes is broken with Voxtral in current nightly (shape mismatch in llama weight loader)
        # fp8 works on Ada Lovelace (RTX 40xx) and halves VRAM to ~4GB
        # Can be overridden with VOXTRAL_QUANTIZATION=none (needs 16GB+ VRAM) or any other method
        if [[ "${VLLM_QUANTIZATION:-}" == "none" ]]; then
            log_warn "Quantization disabled - needs 16GB+ VRAM"
        elif [[ -n "${VLLM_QUANTIZATION:-}" ]]; then
            vllm_args+=(--quantization "$VLLM_QUANTIZATION")
            log_info "Using quantization: $VLLM_QUANTIZATION"
        elif [[ "$VLLM_MODEL" != *"4bit"* ]] && [[ "$VLLM_MODEL" != *"GPTQ"* ]] && [[ "$VLLM_MODEL" != *"AWQ"* ]]; then
            # Full-precision model - apply fp8 by default to fit in 8GB VRAM
            vllm_args+=(--quantization fp8)
            log_info "Applying fp8 quantization (fits 8GB VRAM, requires Ada Lovelace / RTX 40xx)"
        else
            log_info "Pre-quantized model - no additional quantization needed"
        fi
        
        # Launch vLLM in a new process group (setsid) so terminal signals
        # (Ctrl+C, Ctrl+X) don't reach it directly — only our cleanup trap
        # controls its lifetime via ref-counting.
        setsid $runner vllm "${vllm_args[@]}" \
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
            if [[ "$VLLM_MODEL" == *"4bit"* ]] || [[ "$VLLM_MODEL" == *"GPTQ"* ]] || [[ "$VLLM_MODEL" == *"AWQ"* ]] || [[ "$VLLM_MODEL" == *"GGUF"* ]]; then
                log_info "ℹ️  First run - downloading pre-quantized model"
                log_info "   Expected time: 5-15 minutes depending on connection"
            else
                log_info "ℹ️  First run - downloading full model (~16GB bfloat16)"
                log_info "   fp8 quantization will be applied at load time (fits 8GB VRAM)"
                log_info "   First load may take a minute to quantize"
            fi
            log_info "   📊 Download progress bars enabled (HF_HUB_ENABLE_PROGRESS_BARS=1)"
        else
            initial_cache_size=$(get_model_cache_size)
            log_info "📦 Model cache found: $(format_bytes "$initial_cache_size")"
        fi

        local wait_time=0
        local last_log_size=0
        local stall_count=0
        local last_cache_size=$initial_cache_size
        local cache_stall_count=0
        local download_start_size=$initial_cache_size
        local download_start_time=$SECONDS

        while true; do
            if check_vllm_health; then
                echo ""
                log_info "vLLM is ready (PID: $vllm_pid)"
                log_info "Total startup time: ${wait_time}s"
                break
            fi

            if ! kill -0 "$vllm_pid" 2>/dev/null; then
                echo ""

                # Check for specific error patterns in the log
                if [[ -f "$VLLM_LOG_FILE" ]]; then
                    if grep -q "Free memory on device.*less than desired GPU memory" "$VLLM_LOG_FILE" 2>/dev/null; then
                        local free_mem
                        free_mem=$(grep "Free memory on device" "$VLLM_LOG_FILE" 2>/dev/null | tail -1 | grep -o '[0-9.]*\/[0-9.]* GiB' || echo "unknown")
                        log_error "❌ NOT ENOUGH FREE VRAM AT STARTUP"
                        log_error ""
                        log_error "Free VRAM ($free_mem) is less than requested gpu-memory-utilization."
                        log_error "Other processes (e.g. Zed, desktop) are using GPU memory."
                        log_error ""
                        log_error "💡 SOLUTIONS:"
                        log_error "  1. Close GPU-using apps (Zed, browser, etc.) and retry"
                        log_error "  2. Lower utilization: VOXTRAL_GPU_MEMORY=0.85 $0"
                        log_error ""
                        rm -f "$VLLM_PID_FILE"
                        exit 1
                    elif grep -q "larger than the available KV cache memory" "$VLLM_LOG_FILE" 2>/dev/null; then
                        local max_len
                        max_len=$(grep "estimated maximum model length" "$VLLM_LOG_FILE" 2>/dev/null | tail -1 | grep -o 'is [0-9]*' | grep -o '[0-9]*' || echo "unknown")
                        log_error "❌ NOT ENOUGH VRAM FOR KV CACHE"
                        log_error ""
                        log_error "Model loaded OK but KV cache won't fit."
                        log_error "Max supported context length with current VRAM: ${max_len} tokens"
                        log_error ""
                        log_error "💡 SOLUTION: VOXTRAL_MAX_LEN=${max_len} $0"
                        log_error ""
                        rm -f "$VLLM_PID_FILE"
                        exit 1
                    elif grep -q "param_data.shape == loaded_weight.shape" "$VLLM_LOG_FILE" 2>/dev/null; then
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
                    elif grep -q "Transformers does not recognize this architecture" "$VLLM_LOG_FILE" 2>/dev/null; then
                        log_error "❌ VOXTRAL NOT SUPPORTED BY TRANSFORMERS 4.x"
                        log_error ""
                        log_error "Voxtral requires Transformers 5.x, but 5.x has a config validation bug."
                        log_error "This is a known issue: https://github.com/vllm-project/vllm/pull/38410"
                        log_error ""
                        log_error "💡 SOLUTION: Use Moonshine (CPU) or wait for vLLM update"
                        log_error "   Run: $0 --clean-all"
                        log_error "   Then use opencode-stt with Moonshine backend"
                        log_error ""
                        rm -f "$VLLM_PID_FILE"
                        exit 1
                    elif grep -q "Multiple valid text configs were found" "$VLLM_LOG_FILE" 2>/dev/null; then
                        log_error "❌ TRANSFORMERS 5.x CONFIG VALIDATION BUG"
                        log_error ""
                        log_error "This is a known incompatibility between Voxtral and Transformers 5.x."
                        log_error "vLLM PR #38410 fixes this but has not been released yet."
                        log_error ""
                        log_error "💡 SOLUTION: Use Moonshine (CPU) or wait for vLLM update"
                        log_error "   Run: $0 --clean-all"
                        log_error "   Then use opencode-stt with Moonshine backend"
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

            sleep 5
            wait_time=$((wait_time + 5))

            # Show progress every 30 seconds
            if [[ $((wait_time % 30)) -eq 0 ]]; then
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
                     else
                         # Model downloaded, now loading/quantizing on GPU
                         current_state="starting"
                    fi
                fi

                log_info "⏱️  $mins_elapsed min elapsed (no timeout - waiting for model to load)"
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
                            log_info "   🚀 Loading model into GPU (fp8 quantization)..."
                            ;;
                        starting)
                            log_info "   ✅ Model downloaded: $cache_human"
                            log_info "   🚀 Starting vLLM server..."
                            if [[ $stall_count -gt 60 ]]; then
                                log_info "   ⏳ Taking longer than expected, but may still be starting..."
                            fi
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
                        log_info "   🎮 GPU: ${gpu_util}% util, ${gpu_mem}MiB VRAM"
                    fi
                fi

                # Show last log line so user can see what vLLM is doing
                if [[ -f "$VLLM_LOG_FILE" ]]; then
                    local last_line
                    last_line=$(grep -v "^$" "$VLLM_LOG_FILE" 2>/dev/null | tail -1 || true)
                    if [[ -n "$last_line" ]]; then
                        log_info "   📋 Last log: ${last_line:0:120}"
                    fi
                fi
                echo ""
            fi
        done

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

    ) 200>"$PID_DIR/vllm-start.lock"
}

# Stop vLLM server
stop_vllm() {
    log_info "Stopping Voxtral vLLM server..."

    if [[ -f "$VLLM_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VLLM_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            # vLLM was launched with setsid so it is its own process group leader.
            # Kill the whole process group (pgid == pid) so all child workers die too.
            local pgid
            pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "$pid")

            # Graceful SIGTERM to the process group
            kill -- "-$pgid" 2>/dev/null || kill "$pid" 2>/dev/null || true

            # Wait up to 15 seconds for graceful exit
            local wait_count=0
            while kill -0 "$pid" 2>/dev/null && [[ $wait_count -lt 15 ]]; do
                sleep 1
                wait_count=$((wait_count + 1))
            done

            # Force-kill process group if still running
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "Force killing vLLM process group (pgid: $pgid)"
                kill -9 -- "-$pgid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$VLLM_PID_FILE"
    fi

    # Fallback: kill any vLLM workers still holding GPU memory
    local gpu_vllm_pids
    gpu_vllm_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null \
        | xargs -I{} ps -p {} -o pid=,comm= 2>/dev/null \
        | grep -i vllm | awk '{print $1}' || true)
    if [[ -n "$gpu_vllm_pids" ]]; then
        log_warn "Killing residual vLLM GPU processes: $gpu_vllm_pids"
        echo "$gpu_vllm_pids" | xargs kill -9 2>/dev/null || true
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
    
    # Block re-entrant signals during cleanup
    trap '' INT TERM
    
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
  VOXTRAL_MAX_LEN    Max model length (default: 1024)
  VOXTRAL_GPU_MEMORY GPU memory utilization (default: 0.90)
  VOXTRAL_QUANTIZATION Quantization method (default: fp8)
  STT_VLLM_URL       vLLM server URL for OpenCode plugin (auto-set by script)
  STT_PYTHON_PATH    Python interpreter for stt.py (auto-set to venv, override if needed)
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

# Check that the opencode-stt plugin is present in the plugins directory.
# The plugin must be placed there manually — either by symlinking the built
# dist/index.js or by installing the npm package.
check_opencode_plugin() {
    local plugins_dir="$OPENCODE_PLUGINS_DIR"
    # Look for any .js file in the plugins dir that looks like our plugin
    if compgen -G "$plugins_dir/*.js" &>/dev/null; then
        return 0
    fi
    log_warn "opencode-stt plugin not found in $plugins_dir"
    log_warn "Voice input will not be available until the plugin is installed."
    log_warn ""
    log_warn "To install, choose one of:"
    log_warn "  1. Symlink the built plugin:"
    log_warn "       mkdir -p $plugins_dir"
    log_warn "       ln -sf /path/to/opencode-stt/dist/index.js $plugins_dir/opencode-stt.js"
    log_warn "  2. Install from npm (once published):"
    log_warn "       # add 'opencode-stt' to your opencode.json plugin array"
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

    # Configure opencode-stt plugin (idempotent: silent if already set)
    check_opencode_plugin

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
    
    # Set environment variables for OpenCode STT plugin
    export STT_VLLM_URL="http://localhost:$VLLM_PORT"
    export STT_PYTHON_PATH="$VENV_DIR/bin/python"
    log_info "STT_VLLM_URL=$STT_VLLM_URL"
    log_info "STT_PYTHON_PATH=$STT_PYTHON_PATH"
    
    # Launch OpenCode
    log_info "Starting OpenCode..."
    log_info ""

    # Run OpenCode in the foreground so it owns the terminal (tty).
    # The trap is set to INT/TERM so cleanup still fires when the user
    # quits opencode normally (which sends SIGINT/SIGTERM to this shell).
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
