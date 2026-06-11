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
.\start.ps1 -OptimizeMode speed
.\start.ps1 -OptimizeMode vram -ContextSize 4096
```

`-DryRun` prints the generated llama.cpp command without loading the model.

## Useful Overrides

Command-line parameters take priority over auto-tuning:

```powershell
.\start.ps1 -GpuLayers 12 -BatchSize 1024 -UBatchSize 256
```

Environment variables are also supported:

```powershell
set LLAMA_PORT=8080
set LLAMA_CTX_SIZE=8192
set LLAMA_GPU_LAYERS=12
set LLAMA_NO_MMPROJ=1
```

## Notes

- Model files are intentionally ignored by Git because they are large.
- `runtime/llama-bin/` is generated from archives and can be deleted safely.
- Keep llama.cpp zip files in `archives/` if you want the launcher to recreate the runtime folder automatically.
