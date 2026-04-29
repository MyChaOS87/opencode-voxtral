# Voxtral + OpenCode Setup

Helper scripts for using Mistral's Voxtral speech-to-text model with OpenCode via the opencode-stt plugin.

## Installation

Install system-wide for easy access from anywhere:

```bash
cd ~/ai/voxtral
sudo make install
```

This creates the `opencode-voxtral` command available everywhere.

## Quick Start

```bash
# First run - installs venv and starts vLLM
opencode-voxtral

# Terminal 2 - shares the same vLLM
opencode-voxtral

# Terminal 3 - different project
opencode-voxtral -c /path/to/another/project
```

### Wrapper Script Features

- ✅ **Automatic venv management** - Creates/isolates Python environment at `~/.opencode-voxtral`
- ✅ **Auto-detects uv** - Uses [uv](https://astral.sh/uv) for 10-100x faster package installation (falls back to pip)
- ✅ **Auto-install prompt** - Asks to install if venv/packages missing
- ✅ **Update checking** - Checks for updates once per day, prompts to update
- ✅ **Singleton vLLM** - Only one server instance across all OpenCodes
- ✅ **Reference counting** - Tracks active OpenCode instances
- ✅ **Auto-cleanup** - Last instance stops vLLM
- ✅ **Health checks** - Waits for vLLM to be ready before launching OpenCode
- ✅ **prime-run support** - Automatically uses for NVIDIA Optimus laptops

## Scripts

### opencode-voxtral

Main wrapper script that manages venv, vLLM, and OpenCode lifecycle.

**Note:** You can also run directly from the repo without installing:
```bash
cd ~/ai/voxtral
./opencode-voxtral.sh
```

```bash
opencode-voxtral [OPTIONS] [OPENCODE-ARGS...]
```

Options:
- `--install` - Install/update the Python virtual environment
- `--update` - Check for and install updates
- `--status` - Show vLLM status and exit
- `--stop` - Stop vLLM server and exit
- `--version` - Show version and exit
- `--help` - Show help message

Environment variables:
- `VENV_DIR` - Python venv location (default: `~/.opencode-voxtral`)
- `VOXTRAL_PORT` - vLLM port (default: 8080)
- `VOXTRAL_MODEL` - Model to use (default: mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit)
  - Pre-quantized options (fastest, recommended for 8GB GPUs):
    - `mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit` (~4GB)
    - `freddm/Voxtral-Mini-4B-Realtime-2602-GGUF` (~3GB, use with `--quantization gguf`)
  - Full precision (requires 16GB VRAM or on-the-fly quantization):
    - `mistralai/Voxtral-Mini-4B-Realtime-2602` (~16GB)
- `VOXTRAL_MAX_LEN` - Max model length (default: 8192)
- `VOXTRAL_QUANTIZATION` - Quantization method (default: "" for pre-quantized models)
  - Only needed for non-pre-quantized models: `bitsandbytes` (very slow first run)
- `VOXTRAL_GPU_MEMORY` - GPU memory utilization 0.0-1.0 (default: 0.80, use lower if OOM)
- `DEBUG` - Enable debug output (set to 1)

**Examples:**

```bash
# First run - will prompt to install venv
opencode-voxtral

# Install/update manually
opencode-voxtral --install

# Check for updates
opencode-voxtral --update

# Check status
opencode-voxtral --status

# Stop vLLM server
opencode-voxtral --stop

# Clean model cache (fixes shape mismatch errors)
opencode-voxtral --clean-cache

# Nuclear option: clean everything including venv
opencode-voxtral --clean-all

# Launch with specific project
opencode-voxtral -c /path/to/project
```

### opencode-voxtral-status

Check status or manage the vLLM server.

```bash
opencode-voxtral-status [command]

Commands:
  status  - Show vLLM status, GPU usage, active instances (default)
  stop    - Force stop vLLM server
  logs    - Tail vLLM logs
  wait    - Wait for vLLM to be ready
```

### First Run / Model Download

**Default (pre-quantized): ~5-15 minutes**
The default model (`mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit`) is already quantized:
1. Download ~4GB model from HuggingFace
2. Load directly into GPU (no quantization needed)
3. Start vLLM server

**Full precision model: ~20-40 minutes**
If you use the full `mistralai/Voxtral-Mini-4B-Realtime-2602` model with `VOXTRAL_QUANTIZATION=bitsandbytes`:
1. Download ~16GB model
2. On-the-fly quantization to 4-bit (very slow CPU process)
3. Start vLLM server

The process may appear to "hang" during on-the-fly quantization - this is normal!

**To speed up subsequent runs:**
- Model is cached in `~/.cache/huggingface/`
- Don't delete the cache between runs
- Pre-quantized models start in ~10-30 seconds on subsequent runs

### start-voxtral-server.sh

Manual vLLM launcher (if you don't use the wrapper).

```bash
./start-voxtral-server.sh [port]
```

## UV Support (Recommended)

The script automatically detects and uses [uv](https://astral.sh/uv) if installed, providing:
- **10-100x faster** package installation
- **Better caching** for repeated installs
- **Significantly faster** venv creation

### Installing uv

```bash
# Via curl
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via pip
pip install uv

# Or via pacman (Arch)
sudo pacman -S uv
```

The script checks for `uv` in:
- `PATH` (standard location)
- `~/.cargo/bin/uv` (cargo install)
- `~/.local/bin/uv` (user install)

If uv is not found, the script automatically falls back to standard pip.

## Installation Flow

1. **First run** - Script detects no venv:
   ```
   [opencode-voxtral] Virtual environment not found at: ~/.opencode-voxtral
   [opencode-voxtral] Would you like to install it now? [Y/n] 
   ```

2. **Auto-install** with uv (if available):
   ```
   [opencode-voxtral] Using uv (fast Python package installer)
   [opencode-voxtral] Creating virtual environment with uv...
   [opencode-voxtral] Installing required packages with uv...
   # ~10-100x faster than pip!
   ```

   Or with pip (fallback):
   ```
   [opencode-voxtral] Using pip (consider installing uv for faster installs)
   [opencode-voxtral] Creating virtual environment...
   [opencode-voxtral] Installing required packages...
   ```

3. **Update checking** - Once per day, checks PyPI:
   ```
   [opencode-voxtral] Checking for updates...
   [opencode-voxtral] Update available: 0.19.0 -> 0.20.0
   [opencode-voxtral] Would you like to update vLLM? [Y/n]
   ```

4. **Launch** - Starts vLLM and OpenCode:
   ```
   [opencode-voxtral] Starting Voxtral vLLM server...
   [opencode-voxtral] vLLM is ready (PID: 12345)
   [opencode-voxtral] Starting OpenCode...
   ```

## Manual Setup (Without Wrapper)

If you prefer manual control:

### 1. Clone and Setup opencode-stt with Voxtral Support

```bash
cd ~/ai/opencode-stt

# Build the plugin
bun install
bun run build
```

### 2. Start the Voxtral vLLM Server

**Terminal 1:**
```bash
./start-voxtral-server.sh
```

Or manually:
```bash
# For NVIDIA Optimus laptops (8GB VRAM - use quantization)
prime-run vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 \
  --port 8080 \
  --max-model-len 8192 \
  --dtype bfloat16 \
  --quantization bitsandbytes \
  --gpu-memory-utilization 0.85 \
  --trust-remote-code

# For systems without Optimus
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 \
  --port 8080 \
  --max-model-len 8192 \
  --dtype bfloat16 \
  --quantization bitsandbytes \
  --gpu-memory-utilization 0.85 \
  --trust-remote-code
```

### 3. Configure OpenCode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["/home/kasch/ai/opencode-stt"]
}
```

Add to `~/.bashrc` (if not using the wrapper script):

```bash
export STT_VLLM_URL="http://localhost:8080"
```

### 4. Use Voice Input

**Terminal 2:**
```bash
opencode
```

In OpenCode, you can:
- Type: `Record my voice` - AI will use voice_input tool
- Type: `Check my voice setup` - Verify configuration

## Hardware Requirements

- **GPU**: NVIDIA RTX 4070 Laptop (8GB VRAM) ✅
- **Quantization**: 4-bit (fits in ~3-4GB VRAM)
- **Model**: mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit

## Backend Priority

When `backend: "auto"` (default), the plugin selects in this order:
1. **vllm** - GPU accelerated via vLLM server (e.g., Voxtral), ~150ms latency
2. **moonshine** - Fast CPU, tiny model
3. **faster-whisper** - Optimized Whisper
4. **whisper** - Original Whisper

## Troubleshooting

### "Cannot connect to vLLM server"
- Check status: `./opencode-voxtral-status.sh status`
- Wait for ready: `./opencode-voxtral-status.sh wait`
- View logs: `./opencode-voxtral-status.sh logs`
- Force restart: `./opencode-voxtral-status.sh stop` then retry
- Check if it's still loading (first run takes 20-40 min)

### "No STT backends detected"
- For Voxtral: Start the vLLM server or use wrapper script
- For CPU backends: Install dependencies (see plugin docs)

### Slow transcription
- Check GPU usage: `./opencode-voxtral-status.sh status`
- Ensure prime-run is active (for Optimus laptops)
- Check vLLM logs for errors

### Wrapper script issues
- Check PID directory: `ls -la /tmp/opencode-voxtral/`
- Kill stale processes: `./opencode-voxtral-status.sh stop`
- Check permissions: `chmod +x opencode-voxtral.sh`

### GPU Out of Memory (OOM) Errors
If you see `CUDA out of memory` errors:
```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 768.00 MiB...
```

**Solutions:**
1. **Use quantization** (enabled by default with `VOXTRAL_QUANTIZATION=bitsandbytes`)
2. **Lower GPU memory utilization**:
   ```bash
   VOXTRAL_GPU_MEMORY=0.70 opencode-voxtral
   ```
3. **Reduce max model length**:
   ```bash
   VOXTRAL_MAX_LEN=4096 opencode-voxtral
   ```
4. **Close other GPU applications** (browsers, other ML models, etc.)
5. **Check current GPU usage**:
   ```bash
   nvidia-smi
   ```

**For 8GB VRAM systems** (like RTX 4070 Laptop):
- Default settings should work with quantization enabled
- If still OOM, try `VOXTRAL_GPU_MEMORY=0.75` or lower
- Consider using CPU backends (Moonshine/Whisper) if GPU memory is consistently insufficient

### Very slow first startup (20-40 minutes)
This is **expected behavior** on first run! The process:
1. Downloads ~8GB model from HuggingFace
2. Performs bitsandbytes 4-bit quantization (very CPU-intensive)
3. Builds CUDA graphs for the model

**Symptoms:**
- Log file stops updating for 20+ minutes
- `nvidia-smi` shows Python using 100% CPU, low GPU usage
- Process appears "hung" but is actually working

**What to do:**
- Wait! First run is always slow
- Check it's still working: `nvidia-smi` should show Python process
- Check CPU activity: `top` or `htop` should show high CPU usage
- The timeout is 60 minutes for first run

**Speed up subsequent runs:**
- Don't delete `~/.cache/huggingface/`
- Quantized model is cached there
- Subsequent starts take ~10-30 seconds

### Shape Mismatch Error (AssertionError)
If you see an error like:
```
AssertionError: param_data.shape == loaded_weight.shape
```

**Cause:** The model cache is corrupted or partially downloaded.

**Solution:** Clean the cache and re-download:
```bash
opencode-voxtral --clean-cache
opencode-voxtral
```

This keeps your virtual environment intact but re-downloads the model.

### Installation/update issues
- Reinstall: `opencode-voxtral --install`
- Check venv: `ls -la ~/.opencode-voxtral/`
- Manual install: `python3 -m venv ~/.opencode-voxtral && source ~/.opencode-voxtral/bin/activate && pip install vllm transformers sounddevice soundfile numpy requests`

### Uninstalling

To completely remove everything:

```bash
# Uninstall the commands and delete all data
sudo make uninstall

# Or just clean the model cache
opencode-voxtral --clean-cache
```

## Development

Run directly from repo (without installing):
```bash
cd ~/ai/voxtral
./opencode-voxtral.sh
```

Makefile targets:
```bash
make install      # Install system-wide (requires sudo)
make uninstall    # Remove everything
make test         # Validate script syntax
make help         # Show all targets
```

## Files

- `opencode-voxtral.sh` - **Main wrapper script**
- `opencode-voxtral-status.sh` - Status checker and management
- `start-voxtral-server.sh` - Manual vLLM launcher (legacy)
- `Makefile` - Installation/uninstallation
- `../opencode-stt/` - The plugin with Voxtral support

## Links

- Upstream PR: https://github.com/harrytran998/opencode-stt/pulls
- Our fork: https://github.com/MyChaOS87/opencode-stt (add-voxtral-support branch)
- Voxtral model: https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit
