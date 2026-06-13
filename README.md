# Qwen3.6 GGUF Launcher

Windows launcher scripts for running local GGUF models with llama.cpp CUDA builds.

## llama.cpp Version

- llama.cpp build: `b9590`
- Commit: `d2462f8f7`
- Runtime archive: `llama-b9590-bin-win-cuda-12.4-x64.zip`
- CUDA runtime archive: `cudart-llama-bin-win-cuda-12.4-x64.zip`
- Platform: Windows x86_64, CUDA 12.4
- Compiler reported by `llama-server.exe --version`: Clang 20.1.8

## Directory Layout

```text
.
|-- start.bat              # Double-click entry point
|-- start.ps1              # Main launcher and auto-tuning logic
|-- README.md
|-- .gitignore
|-- models/                # GGUF model files and mmproj files
|-- archives/              # Downloaded llama.cpp / CUDA runtime zip files
`-- runtime/llama-bin/     # Extracted llama.cpp binaries, recreated if needed
```

## Quick Start

Double-click `start.bat`.

The launcher asks for:

1. Optimization mode
2. Model file

Press Enter at the optimization prompt to use `balanced`.
After the server is ready, the launcher opens the WebUI in your default browser.

## Optimization Modes

| Mode | Purpose |
| --- | --- |
| `balanced` | Default balance of speed, quality, and VRAM use. |
| `quality` | Larger default context and conservative throughput settings. |
| `speed` | Higher GPU offload, larger batch size, and higher process priority. |
| `vram` | Lower VRAM use, smaller batch size, and no mmproj GPU offload. |

## PowerShell Usage

```powershell
.\start.ps1
.\start.ps1 -Mode cli
.\start.ps1 -DryRun
.\start.ps1 -NoOpenWebUI
.\start.ps1 -OptimizeMode speed
.\start.ps1 -OptimizeMode vram -ContextSize 4096
.\start.ps1 -ModelPath .\models\Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf -MmprojPath .\models\mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf
```

`-DryRun` prints the generated llama.cpp command without loading the model.
`-NoOpenWebUI` starts the server without opening a browser.

## Vision / Image Requests

Image requests require both the language model and its matching `mmproj` file. The launcher now:

- Loads a single `mmproj*.gguf` automatically, or accepts `-MmprojPath`.
- Adds a stable vision alias by default, for example `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-vision`.
- Adds API tags `vision,multimodal,image` when an mmproj is loaded.
- Prints `Vision: enabled` or `Vision: disabled` before starting.

If a client says `Images require a vision-capable model`, restart the server and select the printed API model alias in that client. If the launcher prints `Vision: disabled`, make sure the matching `mmproj-*.gguf` file is present and `LLAMA_NO_MMPROJ` is not set.

## Useful Overrides

Command-line parameters take priority over auto-tuning:

```powershell
.\start.ps1 -GpuLayers 12 -BatchSize 1024 -UBatchSize 256
.\start.ps1 -ModelAlias qwen3-vision -ModelTags vision,multimodal,image
```

Environment variables are also supported:

```powershell
set LLAMA_PORT=8080
set LLAMA_CTX_SIZE=8192
set LLAMA_GPU_LAYERS=12
set LLAMA_MODEL=models\Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf
set LLAMA_MMPROJ=models\mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf
set LLAMA_MODEL_ALIAS=qwen3-vision
set LLAMA_MODEL_TAGS=vision,multimodal,image
set LLAMA_NO_MMPROJ=1
```

## Notes

- Model files are intentionally ignored by Git because they are large.
- `runtime/llama-bin/` is generated from archives and can be deleted safely.
- Keep llama.cpp zip files in `archives/` if you want the launcher to recreate the runtime folder automatically.
