# opencode-voxtral

Wrapper script that runs [OpenCode](https://opencode.ai) with Mistral's [Voxtral](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) speech-to-text model via vLLM, enabling voice input in OpenCode through the [opencode-stt](https://github.com/MyChaOS87/opencode-stt) plugin.

## Requirements

- NVIDIA GPU with 8GB+ VRAM (tested on RTX 4070 Laptop)
- CUDA 13.x driver
- `prime-run` (for NVIDIA Optimus laptops — detected automatically)
- `uv` (recommended) or `pip`
- `opencode` in PATH
- [opencode-stt](https://github.com/MyChaOS87/opencode-stt) plugin installed (branch: `add-voxtral-support`)

## Installation

```bash
cd ~/ai/voxtral
sudo make install
```

This installs `opencode-voxtral` and `opencode-voxtral-status` system-wide.

On first run the script will offer to install the Python venv and all dependencies automatically.

## Quick Start

```bash
# First run — installs venv, downloads model (~17GB), starts vLLM, launches OpenCode
opencode-voxtral

# Additional terminals share the same vLLM instance
opencode-voxtral

# Pass arguments to OpenCode
opencode-voxtral -c /path/to/project
```

vLLM shuts down automatically when the last OpenCode instance exits.

## How It Works

1. Creates/manages a Python venv at `~/.opencode-voxtral`
2. Installs vLLM nightly (cu130) + dependencies on first run
3. Starts a singleton vLLM server with reference counting (one server, many OpenCode instances)
4. Sets `STT_VLLM_URL=http://localhost:<port>` for the opencode-stt plugin
5. Launches OpenCode in the foreground
6. On exit, decrements ref count — last instance stops vLLM

## Technical Details

- **Model**: `mistralai/Voxtral-Mini-4B-Realtime-2602` (official, ~17GB bf16)
- **Quantization**: fp8 on-the-fly (Ada Lovelace / RTX 40xx required) — loads in ~6.4GB VRAM
- **vLLM**: nightly `0.20.1rc1.dev72+` (cu130) — required for Voxtral multimodal dispatch fix (PR #38410)
- **Context length**: 1024 tokens (sufficient for STT audio chunks)
- **Port**: random high port (50000–65535) per session
- **Startup time**: ~70s after first download (torch.compile runs once)
- **Download**: accelerated via `hf-transfer` if installed

## Options

```
opencode-voxtral [OPTIONS] [OPENCODE-ARGS...]

--install       Install/update the Python venv and packages
--update        Check for and install package updates
--status        Show vLLM server status
--stop          Stop the vLLM server
--clean-cache   Delete model cache (re-downloads model on next run)
--clean-all     Delete venv + model cache (full reset)
--force         Skip confirmation prompts
--version       Show version
--help          Show help
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `VOXTRAL_MODEL` | `mistralai/Voxtral-Mini-4B-Realtime-2602` | HuggingFace model ID |
| `VOXTRAL_MAX_LEN` | `1024` | Max context length (tokens) |
| `VOXTRAL_GPU_MEMORY` | `0.90` | GPU memory utilization (0.0–1.0) |
| `VOXTRAL_QUANTIZATION` | `fp8` | Quantization method (`fp8`, `none`, etc.) |
| `VENV_DIR` | `~/.opencode-voxtral` | Python venv location |
| `DEBUG` | `` | Set to `1` for debug output |

## Status / Logs

```bash
opencode-voxtral-status          # Show status, GPU usage, active instances
opencode-voxtral-status stop     # Force stop vLLM
opencode-voxtral-status logs     # Tail vLLM logs
opencode-voxtral-status wait     # Wait until vLLM is ready
```

## Troubleshooting

### Not enough free VRAM at startup

Other processes (e.g. Zed, browser) are occupying GPU memory.

```bash
nvidia-smi                             # Check what's using VRAM
VOXTRAL_GPU_MEMORY=0.85 opencode-voxtral
```

### KV cache OOM after model loads

```bash
VOXTRAL_MAX_LEN=512 opencode-voxtral
```

### Shape mismatch error

Model cache is corrupted:

```bash
opencode-voxtral --clean-cache
opencode-voxtral
```

### vLLM fails with "Transformers does not recognize this architecture"

You are not running the nightly vLLM build. Reinstall:

```bash
opencode-voxtral --install
```

### Install hangs / network timeout

uv uses `UV_REQUEST_TIMEOUT` — if it times out, simply retry. The vLLM nightly wheel is fetched separately from PyPI packages to avoid index conflicts.

## Files

- `opencode-voxtral.sh` — main wrapper script
- `opencode-voxtral-status.sh` — status/stop/logs helper
- `Makefile` — system-wide install/uninstall

## Links

- Our fork (opencode-stt with vLLM/Voxtral support): https://github.com/MyChaOS87/opencode-stt (branch: `add-voxtral-support`)
- This repo: https://github.com/MyChaOS87/opencode-voxtral
- Model: https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
- vLLM nightly wheels: https://wheels.vllm.ai/nightly/cu130/
