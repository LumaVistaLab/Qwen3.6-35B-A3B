param(
    [ValidateSet("server", "cli")]
    [string]$Mode = "server",

    [Nullable[int]]$Port,
    [Nullable[int]]$ContextSize,
    [Nullable[int]]$GpuLayers,
    [Nullable[int]]$Threads,
    [Nullable[int]]$ThreadsBatch,
    [Nullable[int]]$BatchSize,
    [Nullable[int]]$UBatchSize,
    [Nullable[int]]$ParallelSlots,
    [Nullable[int]]$ThreadsHttp,
    [Nullable[int]]$Priority,
    [string]$ModelPath,
    [string]$MmprojPath,
    [string]$ModelAlias,
    [string]$ModelTags,
    [Nullable[int]]$ImageMinTokens,
    [Nullable[int]]$ImageMaxTokens,

    [ValidateSet("auto", "on", "off")]
    [string]$FlashAttention,

    [ValidateSet("balanced", "quality", "speed", "vram")]
    [string]$OptimizeMode = "balanced",

    [switch]$NoAutoTune,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

Set-Location -LiteralPath $Root

$ModelsDir = Join-Path $Root "models"
$ArchivesDir = Join-Path $Root "archives"
$RuntimeDir = Join-Path $Root "runtime"
$LlamaBinDir = Join-Path $RuntimeDir "llama-bin"

function Resolve-IntSetting {
    param(
        [string]$Name,
        [int]$Default
    )

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) {
        return $parsed
    }

    Write-Warning "Ignoring invalid $Name=$raw; using $Default."
    return $Default
}

function Resolve-OptionalIntSetting {
    param([string]$Name)

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) {
        return $parsed
    }

    Write-Warning "Ignoring invalid $Name=$raw."
    return $null
}

function Resolve-OptionalStringSetting {
    param([string]$Name)

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw.Trim()
}

function Resolve-FileSetting {
    param(
        [string]$Value,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing $Description file path."
    }

    $candidatePaths = @()
    if ([System.IO.Path]::IsPathRooted($Value)) {
        $candidatePaths += $Value
    } else {
        $candidatePaths += (Join-Path $Root $Value)
        $candidatePaths += (Join-Path $ModelsDir $Value)
    }

    foreach ($candidatePath in ($candidatePaths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return Get-Item -LiteralPath $candidatePath
        }
    }

    throw "Cannot find $Description file: $Value"
}

function Get-DefaultModelAlias {
    param(
        [System.IO.FileInfo]$ModelFile,
        [bool]$VisionEnabled
    )

    $alias = [System.IO.Path]::GetFileNameWithoutExtension($ModelFile.Name)
    if ($alias -match "^(?<base>.+)-Q[0-9].*$") {
        $alias = $Matches["base"]
    }

    if ($VisionEnabled -and $alias -notmatch "(?i)(vision|vl|multimodal|image)") {
        $alias = "$alias-vision"
    }

    return $alias
}

function Normalize-OptimizeMode {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "balanced"
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "balanced" { return "balanced" }
        "quality" { return "quality" }
        "speed" { return "speed" }
        "vram" { return "vram" }
    }

    throw "Invalid optimize mode '$Value'. Use balanced, quality, speed, or vram."
}

function Get-DefaultContextSize {
    param([string]$OptimizeMode)

    switch ($OptimizeMode) {
        "quality" { return 16384 }
        "speed" { return 4096 }
        "vram" { return 4096 }
        default { return 8192 }
    }
}

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    return "{0:N0} bytes" -f $Bytes
}

function Format-GB {
    param($Value)

    if ($null -eq $Value) {
        return "unknown"
    }

    return "{0:N1} GB" -f [double]$Value
}

function Quote-CommandArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Select-File {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Title
    )

    Write-Host ""
    Write-Host $Title
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $file = $Files[$i]
        $size = Format-FileSize $file.Length
        Write-Host ("[{0}] {1} ({2})" -f ($i + 1), $file.Name, $size)
    }

    while ($true) {
        $answer = Read-Host "Enter number"
        $choice = 0
        if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $Files.Count) {
            return $Files[$choice - 1]
        }

        Write-Host "Invalid selection."
    }
}

function Select-OptimizeMode {
    $options = @(
        [pscustomobject]@{ Name = "balanced"; Description = "default balance of speed, quality, and VRAM use" },
        [pscustomobject]@{ Name = "quality"; Description = "larger context, more conservative performance settings" },
        [pscustomobject]@{ Name = "speed"; Description = "higher throughput, larger batch, higher priority" },
        [pscustomobject]@{ Name = "vram"; Description = "lower VRAM use, smaller batch, no mmproj GPU offload" }
    )

    Write-Host ""
    Write-Host "Optimization modes:"
    for ($i = 0; $i -lt $options.Count; $i++) {
        $option = $options[$i]
        Write-Host ("[{0}] {1} - {2}" -f ($i + 1), $option.Name, $option.Description)
    }

    while ($true) {
        $answer = Read-Host "Enter number (default 1)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return "balanced"
        }

        $choice = 0
        if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $options.Count) {
            return $options[$choice - 1].Name
        }

        Write-Host "Invalid selection."
    }
}

function Read-GgufString {
    param([System.IO.BinaryReader]$Reader)

    $length = [int64]$Reader.ReadUInt64()
    if ($length -lt 0) {
        throw "Invalid GGUF string length."
    }

    $bytes = $Reader.ReadBytes($length)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Skip-GgufValue {
    param(
        [System.IO.BinaryReader]$Reader,
        [int]$Type
    )

    switch ($Type) {
        0 { $Reader.ReadByte() | Out-Null }
        1 { $Reader.ReadSByte() | Out-Null }
        2 { $Reader.ReadUInt16() | Out-Null }
        3 { $Reader.ReadInt16() | Out-Null }
        4 { $Reader.ReadUInt32() | Out-Null }
        5 { $Reader.ReadInt32() | Out-Null }
        6 { $Reader.ReadSingle() | Out-Null }
        7 { $Reader.ReadBoolean() | Out-Null }
        8 {
            $length = [int64]$Reader.ReadUInt64()
            $Reader.BaseStream.Seek($length, [System.IO.SeekOrigin]::Current) | Out-Null
        }
        9 {
            $elementType = [int]$Reader.ReadUInt32()
            $count = [uint64]$Reader.ReadUInt64()
            for ([uint64]$i = 0; $i -lt $count; $i++) {
                Skip-GgufValue -Reader $Reader -Type $elementType
            }
        }
        10 { $Reader.ReadUInt64() | Out-Null }
        11 { $Reader.ReadInt64() | Out-Null }
        12 { $Reader.ReadDouble() | Out-Null }
        default { throw "Unsupported GGUF metadata type $Type." }
    }
}

function Get-GgufBlockCount {
    param([string]$Path)

    $stream = $null
    $reader = $null

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $reader = New-Object System.IO.BinaryReader($stream)

        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne "GGUF") {
            return $null
        }

        $reader.ReadUInt32() | Out-Null
        $reader.ReadUInt64() | Out-Null
        $metadataCount = [uint64]$reader.ReadUInt64()

        for ([uint64]$i = 0; $i -lt $metadataCount; $i++) {
            $key = Read-GgufString -Reader $reader
            $type = [int]$reader.ReadUInt32()

            if ($key -like "*.block_count") {
                switch ($type) {
                    4 { return [int]$reader.ReadUInt32() }
                    5 { return [int]$reader.ReadInt32() }
                    10 { return [int]$reader.ReadUInt64() }
                    11 { return [int]$reader.ReadInt64() }
                    default {
                        Skip-GgufValue -Reader $reader -Type $type
                    }
                }
            } else {
                Skip-GgufValue -Reader $reader -Type $type
            }
        }
    } catch {
        return $null
    } finally {
        if ($reader) {
            $reader.Close()
        } elseif ($stream) {
            $stream.Close()
        }
    }

    return $null
}

function Get-NvidiaProfile {
    $candidatePaths = @()
    $command = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if ($command) {
        $candidatePaths += $command.Source
    }

    if ($env:ProgramFiles) {
        $candidatePaths += (Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe")
    }

    foreach ($path in ($candidatePaths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $lines = & $path "--query-gpu=name,memory.total" "--format=csv,noheader,nounits" 2>$null
            $names = @()
            $totalMiB = 0

            foreach ($line in $lines) {
                $parts = $line -split ","
                if ($parts.Count -lt 2) {
                    continue
                }

                $names += $parts[0].Trim()
                $memoryMiB = 0
                if ([int]::TryParse($parts[1].Trim(), [ref]$memoryMiB)) {
                    $totalMiB += $memoryMiB
                }
            }

            if ($totalMiB -gt 0) {
                return [pscustomobject]@{
                    Present = $true
                    Name = ($names -join "; ")
                    MemoryGB = [Math]::Round($totalMiB / 1024, 1)
                    Source = "nvidia-smi"
                }
            }
        } catch {
        }
    }

    try {
        $controllers = @(
            Get-CimInstance Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.Name -match "NVIDIA" }
        )

        if ($controllers.Count -gt 0) {
            $totalBytes = [uint64]0
            foreach ($controller in $controllers) {
                if ($controller.AdapterRAM -gt 0) {
                    $totalBytes += [uint64]$controller.AdapterRAM
                }
            }

            $memoryGB = $null
            if ($totalBytes -gt 0) {
                $memoryGB = [Math]::Round($totalBytes / 1GB, 1)
            }

            return [pscustomobject]@{
                Present = $true
                Name = (($controllers | ForEach-Object { $_.Name }) -join "; ")
                MemoryGB = $memoryGB
                Source = "Win32_VideoController"
            }
        }
    } catch {
    }

    return [pscustomobject]@{
        Present = $false
        Name = "none"
        MemoryGB = $null
        Source = "none"
    }
}

function Get-SystemProfile {
    $logical = [Environment]::ProcessorCount
    $physical = $logical

    try {
        $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        $coreCount = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
        $threadCount = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

        if ($coreCount -gt 0) {
            $physical = [int]$coreCount
        }

        if ($threadCount -gt 0) {
            $logical = [int]$threadCount
        }
    } catch {
    }

    $totalMemoryGB = $null
    $freeMemoryGB = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalMemoryGB = [Math]::Round(([double]$os.TotalVisibleMemorySize * 1KB) / 1GB, 1)
        $freeMemoryGB = [Math]::Round(([double]$os.FreePhysicalMemory * 1KB) / 1GB, 1)
    } catch {
    }

    $nvidia = Get-NvidiaProfile

    return [pscustomobject]@{
        PhysicalCores = [Math]::Max(1, $physical)
        LogicalProcessors = [Math]::Max(1, $logical)
        TotalMemoryGB = $totalMemoryGB
        FreeMemoryGB = $freeMemoryGB
        NvidiaPresent = $nvidia.Present
        NvidiaName = $nvidia.Name
        NvidiaMemoryGB = $nvidia.MemoryGB
        NvidiaSource = $nvidia.Source
    }
}

function Get-AutoTuneSettings {
    param(
        [object]$Profile,
        [System.IO.FileInfo]$ModelFile,
        [int]$ContextSize,
        [string]$Mode,
        [string]$OptimizeMode
    )

    $physical = [Math]::Max(1, [int]$Profile.PhysicalCores)
    $logical = [Math]::Max(1, [int]$Profile.LogicalProcessors)
    $usingGpu = [bool]$Profile.NvidiaPresent

    switch ($OptimizeMode) {
        "quality" {
            $threadLimit = if ($usingGpu) { 10 } else { $physical }
            $threadsBatchLimit = if ($usingGpu) { 14 } else { [Math]::Max($physical, 16) }
            $batchScale = 0.75
            $gpuLayerSafety = 0.82
            $priority = 1
            $parallelSlots = 1
            $mmprojOffload = $true
        }
        "speed" {
            $threadLimit = if ($usingGpu) { [Math]::Min($logical, 20) } else { $logical }
            $threadsBatchLimit = $logical
            $batchScale = 1.50
            $gpuLayerSafety = 0.98
            $priority = 2
            $parallelSlots = 1
            $mmprojOffload = $true
        }
        "vram" {
            $threadLimit = if ($usingGpu) { [Math]::Min($physical, 8) } else { $physical }
            $threadsBatchLimit = if ($usingGpu) { [Math]::Min($logical, 12) } else { [Math]::Max($physical, 12) }
            $batchScale = 0.50
            $gpuLayerSafety = 0.65
            $priority = 0
            $parallelSlots = 1
            $mmprojOffload = $false
        }
        default {
            $threadLimit = if ($usingGpu) { 12 } else { $physical }
            $threadsBatchLimit = if ($usingGpu) { 16 } else { [Math]::Max($physical, 16) }
            $batchScale = 1.00
            $gpuLayerSafety = 0.90
            $priority = 1
            $parallelSlots = 1
            $mmprojOffload = $true
        }
    }

    $threads = [Math]::Min($physical, $threadLimit)
    if (-not $usingGpu -and $OptimizeMode -eq "speed") {
        $threads = [Math]::Min($logical, $threadLimit)
    }

    $threadsBatch = [Math]::Min($logical, $threadsBatchLimit)

    $threads = [Math]::Max(1, $threads)
    $threadsBatch = [Math]::Max($threads, $threadsBatch)

    $memoryForBatch = if ($usingGpu -and $null -ne $Profile.NvidiaMemoryGB) {
        [double]$Profile.NvidiaMemoryGB
    } elseif ($null -ne $Profile.FreeMemoryGB) {
        [double]$Profile.FreeMemoryGB
    } else {
        16.0
    }

    if ($memoryForBatch -ge 24) {
        $batchSize = 4096
        $ubatchSize = 1024
    } elseif ($memoryForBatch -ge 12) {
        $batchSize = 2048
        $ubatchSize = 512
    } elseif ($memoryForBatch -ge 8) {
        $batchSize = 1024
        $ubatchSize = 256
    } else {
        $batchSize = 512
        $ubatchSize = 128
    }

    $batchSize = [Math]::Max(256, [int]([Math]::Round($batchSize * $batchScale / 128) * 128))
    $ubatchSize = [Math]::Max(64, [int]([Math]::Round($ubatchSize * $batchScale / 64) * 64))
    $ubatchSize = [Math]::Min($ubatchSize, $batchSize)

    $modelGB = [double]$ModelFile.Length / 1GB
    $layerCount = Get-GgufBlockCount -Path $ModelFile.FullName
    $gpuLayers = 0

    if ($usingGpu) {
        if ($null -eq $Profile.NvidiaMemoryGB) {
            $gpuLayers = 999
        } else {
            $baseReserveGB = if ($ContextSize -ge 16384) {
                6.0
            } elseif ($ContextSize -ge 8192) {
                4.0
            } else {
                3.0
            }

            $reserveGB = switch ($OptimizeMode) {
                "quality" { $baseReserveGB + 1.0 }
                "speed" { [Math]::Max(1.5, $baseReserveGB - 1.0) }
                "vram" { $baseReserveGB + 2.0 }
                default { $baseReserveGB }
            }

            $usableGB = [Math]::Max(0.0, [double]$Profile.NvidiaMemoryGB - $reserveGB)
            if ($usableGB -ge ($modelGB * 1.05)) {
                $gpuLayers = 999
            } elseif ($layerCount -and $layerCount -gt 0 -and $modelGB -gt 0) {
                $estimatedLayers = [int][Math]::Floor(($usableGB / $modelGB) * [double]$layerCount * $gpuLayerSafety)
                $gpuLayers = [Math]::Max(0, [Math]::Min([int]$layerCount, $estimatedLayers))
            } else {
                $gpuLayers = 999
            }
        }
    }

    return [pscustomobject]@{
        Threads = $threads
        ThreadsBatch = $threadsBatch
        BatchSize = $batchSize
        UBatchSize = $ubatchSize
        GpuLayers = $gpuLayers
        ParallelSlots = $parallelSlots
        ThreadsHttp = [Math]::Min([Math]::Max(2, $logical), 8)
        Priority = $priority
        FlashAttention = "auto"
        MmprojOffload = $mmprojOffload
        OptimizeMode = $OptimizeMode
        LayerCount = $layerCount
        ModelGB = [Math]::Round($modelGB, 1)
    }
}

function Find-Executable {
    param(
        [string]$Name,
        [string[]]$SearchRoots
    )

    foreach ($searchRoot in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $searchRoot)) {
            continue
        }

        $directPath = Join-Path $searchRoot $Name
        if (Test-Path -LiteralPath $directPath) {
            return (Get-Item -LiteralPath $directPath).FullName
        }

        $match = Get-ChildItem -LiteralPath $searchRoot -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) {
            return $match.FullName
        }
    }

    return $null
}

function Find-Archive {
    param([string]$Pattern)

    $searchRoots = @($ArchivesDir, $Root)
    foreach ($searchRoot in $searchRoots) {
        if (-not (Test-Path -LiteralPath $searchRoot)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $searchRoot -Filter $Pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($match) {
            return $match
        }
    }

    return $null
}

function Ensure-LlamaBin {
    $legacyBinDir = Join-Path $Root "llama-bin"
    $existingServer = Find-Executable "llama-server.exe" @($LlamaBinDir, $legacyBinDir, $Root)
    if ($existingServer) {
        return (Split-Path -Parent $existingServer)
    }

    $llamaZip = Find-Archive "llama-*-bin-win-*.zip"

    if (-not $llamaZip) {
        throw "Cannot find llama-server.exe or a llama-*-bin-win-*.zip archive in $Root or $ArchivesDir."
    }

    Write-Host "Extracting $($llamaZip.Name) to runtime\llama-bin..."
    New-Item -ItemType Directory -Path $LlamaBinDir -Force | Out-Null
    Expand-Archive -LiteralPath $llamaZip.FullName -DestinationPath $LlamaBinDir -Force

    $cudaZip = Find-Archive "cudart-*.zip"

    if ($cudaZip) {
        Write-Host "Extracting $($cudaZip.Name) to runtime\llama-bin..."
        Expand-Archive -LiteralPath $cudaZip.FullName -DestinationPath $LlamaBinDir -Force
    }

    $server = Find-Executable "llama-server.exe" @($LlamaBinDir)
    if (-not $server) {
        throw "Extraction finished, but llama-server.exe was not found in $LlamaBinDir."
    }

    return (Split-Path -Parent $server)
}

if (-not $PSBoundParameters.ContainsKey("OptimizeMode")) {
    $envOptimizeMode = [Environment]::GetEnvironmentVariable("LLAMA_OPTIMIZE_MODE")
    if (-not [string]::IsNullOrWhiteSpace($envOptimizeMode)) {
        $OptimizeMode = $envOptimizeMode
    } else {
        $OptimizeMode = Select-OptimizeMode
    }
}

$OptimizeMode = Normalize-OptimizeMode $OptimizeMode

if ($null -eq $Port) {
    $Port = Resolve-IntSetting "LLAMA_PORT" 8080
}

if ($null -eq $ContextSize) {
    $ContextSize = Resolve-IntSetting "LLAMA_CTX_SIZE" (Get-DefaultContextSize $OptimizeMode)
}

$modelOverride = $ModelPath
if ([string]::IsNullOrWhiteSpace($modelOverride)) {
    $modelOverride = Resolve-OptionalStringSetting "LLAMA_MODEL"
}
if ([string]::IsNullOrWhiteSpace($modelOverride)) {
    $modelOverride = Resolve-OptionalStringSetting "LLAMA_ARG_MODEL"
}

if (-not [string]::IsNullOrWhiteSpace($modelOverride)) {
    $model = Resolve-FileSetting -Value $modelOverride -Description "model"
    if ($model.Extension -ne ".gguf") {
        throw "Model file must be a .gguf file: $($model.FullName)"
    }
    if ($model.Name -like "mmproj-*") {
        throw "Model file cannot be an mmproj file: $($model.FullName)"
    }
} else {
    $models = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "mmproj-*" } |
            Sort-Object DirectoryName, Name
    )

    if ($models.Count -eq 0) {
        throw "No model .gguf files found in $Root."
    }

    $model = Select-File -Files $models -Title "Available models:"
}

$autoTuneEnabled = -not $NoAutoTune
$systemProfile = $null
$autoTune = $null

if ($autoTuneEnabled) {
    $systemProfile = Get-SystemProfile
    $autoTune = Get-AutoTuneSettings -Profile $systemProfile -ModelFile $model -ContextSize $ContextSize -Mode $Mode -OptimizeMode $OptimizeMode
}

if ($null -eq $GpuLayers) {
    $envValue = Resolve-OptionalIntSetting "LLAMA_GPU_LAYERS"
    if ($null -ne $envValue) {
        $GpuLayers = $envValue
    } elseif ($autoTuneEnabled) {
        $GpuLayers = $autoTune.GpuLayers
    } else {
        $GpuLayers = 999
    }
}

if ($autoTuneEnabled) {
    if ($null -eq $Threads) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_THREADS"
        $Threads = if ($null -ne $envValue) { $envValue } else { $autoTune.Threads }
    }

    if ($null -eq $ThreadsBatch) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_THREADS_BATCH"
        $ThreadsBatch = if ($null -ne $envValue) { $envValue } else { $autoTune.ThreadsBatch }
    }

    if ($null -eq $BatchSize) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_BATCH_SIZE"
        $BatchSize = if ($null -ne $envValue) { $envValue } else { $autoTune.BatchSize }
    }

    if ($null -eq $UBatchSize) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_UBATCH_SIZE"
        $UBatchSize = if ($null -ne $envValue) { $envValue } else { $autoTune.UBatchSize }
    }

    if ($null -eq $ParallelSlots) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_PARALLEL"
        $ParallelSlots = if ($null -ne $envValue) { $envValue } else { $autoTune.ParallelSlots }
    }

    if ($null -eq $ThreadsHttp) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_THREADS_HTTP"
        $ThreadsHttp = if ($null -ne $envValue) { $envValue } else { $autoTune.ThreadsHttp }
    }

    if ($null -eq $Priority) {
        $envValue = Resolve-OptionalIntSetting "LLAMA_PRIORITY"
        $Priority = if ($null -ne $envValue) { $envValue } else { $autoTune.Priority }
    }

    if ([string]::IsNullOrWhiteSpace($FlashAttention)) {
        $envValue = [Environment]::GetEnvironmentVariable("LLAMA_FLASH_ATTN")
        if ($envValue -in @("auto", "on", "off")) {
            $FlashAttention = $envValue
        } elseif (-not [string]::IsNullOrWhiteSpace($envValue)) {
            Write-Warning "Ignoring invalid LLAMA_FLASH_ATTN=$envValue; using auto."
            $FlashAttention = $autoTune.FlashAttention
        } else {
            $FlashAttention = $autoTune.FlashAttention
        }
    }
}

$binDir = Ensure-LlamaBin
$exeName = if ($Mode -eq "cli") { "llama-cli.exe" } else { "llama-server.exe" }
$exePath = Find-Executable $exeName @($binDir)
if (-not $exePath) {
    throw "Cannot find $exeName in $binDir."
}

$arguments = @(
    "-m", $model.FullName,
    "-c", $ContextSize.ToString(),
    "-ngl", $GpuLayers.ToString()
)

if ($null -ne $Threads) {
    $arguments += @("-t", $Threads.ToString())
}

if ($null -ne $ThreadsBatch) {
    $arguments += @("-tb", $ThreadsBatch.ToString())
}

if ($null -ne $BatchSize) {
    $arguments += @("-b", $BatchSize.ToString())
}

if ($null -ne $UBatchSize) {
    $arguments += @("-ub", $UBatchSize.ToString())
}

if (-not [string]::IsNullOrWhiteSpace($FlashAttention)) {
    $arguments += @("-fa", $FlashAttention)
}

if ($null -ne $Priority) {
    $arguments += @("--prio", $Priority.ToString())
}

$disableMmproj = $false
if (-not [string]::IsNullOrWhiteSpace($env:LLAMA_NO_MMPROJ)) {
    $disableMmproj = $env:LLAMA_NO_MMPROJ -notin @("0", "false", "False", "FALSE")
}

$mmproj = $null
if (-not $disableMmproj) {
    $mmprojOverride = $MmprojPath
    if ([string]::IsNullOrWhiteSpace($mmprojOverride)) {
        $mmprojOverride = Resolve-OptionalStringSetting "LLAMA_MMPROJ"
    }
    if ([string]::IsNullOrWhiteSpace($mmprojOverride)) {
        $mmprojOverride = Resolve-OptionalStringSetting "LLAMA_ARG_MMPROJ"
    }

    if (-not [string]::IsNullOrWhiteSpace($mmprojOverride)) {
        $mmproj = Resolve-FileSetting -Value $mmprojOverride -Description "mmproj"
        if ($mmproj.Extension -ne ".gguf") {
            throw "mmproj file must be a .gguf file: $($mmproj.FullName)"
        }
        Write-Host "Using mmproj: $($mmproj.Name)"
        $arguments += @("--mmproj", $mmproj.FullName)
    } else {
        $mmprojFiles = @(
            Get-ChildItem -LiteralPath $Root -Recurse -Filter "mmproj*.gguf" -File -ErrorAction SilentlyContinue |
                Sort-Object DirectoryName, Name
        )

        if ($mmprojFiles.Count -eq 1) {
            $mmproj = $mmprojFiles[0]
            Write-Host "Using mmproj: $($mmproj.Name)"
            $arguments += @("--mmproj", $mmproj.FullName)
        } elseif ($mmprojFiles.Count -gt 1) {
            $mmproj = Select-File -Files $mmprojFiles -Title "Available mmproj files:"
            $arguments += @("--mmproj", $mmproj.FullName)
        }
    }

    if ($mmproj) {
        if ($autoTuneEnabled) {
            if ($autoTune.MmprojOffload) {
                $arguments += @("--mmproj-offload")
            } else {
                $arguments += @("--no-mmproj-offload")
            }
        }

        if ($null -eq $ImageMinTokens) {
            $ImageMinTokens = Resolve-OptionalIntSetting "LLAMA_IMAGE_MIN_TOKENS"
        }

        if ($null -eq $ImageMaxTokens) {
            $ImageMaxTokens = Resolve-OptionalIntSetting "LLAMA_IMAGE_MAX_TOKENS"
        }

        if ($null -ne $ImageMinTokens) {
            $arguments += @("--image-min-tokens", $ImageMinTokens.ToString())
        }

        if ($null -ne $ImageMaxTokens) {
            $arguments += @("--image-max-tokens", $ImageMaxTokens.ToString())
        }
    } else {
        Write-Warning "No mmproj file was loaded. Image requests will be rejected as non-vision-capable."
    }
} else {
    Write-Warning "LLAMA_NO_MMPROJ disables vision. Image requests will be rejected as non-vision-capable."
}

if ($Mode -eq "server") {
    $serverAlias = $ModelAlias
    if ([string]::IsNullOrWhiteSpace($serverAlias)) {
        $serverAlias = Resolve-OptionalStringSetting "LLAMA_MODEL_ALIAS"
    }
    if ([string]::IsNullOrWhiteSpace($serverAlias)) {
        $serverAlias = Resolve-OptionalStringSetting "LLAMA_ARG_ALIAS"
    }
    if ([string]::IsNullOrWhiteSpace($serverAlias) -and $mmproj) {
        $serverAlias = Get-DefaultModelAlias -ModelFile $model -VisionEnabled $true
    }

    if (-not [string]::IsNullOrWhiteSpace($serverAlias)) {
        $arguments += @("-a", $serverAlias)
    }

    $serverTags = $ModelTags
    if ([string]::IsNullOrWhiteSpace($serverTags)) {
        $serverTags = Resolve-OptionalStringSetting "LLAMA_MODEL_TAGS"
    }
    if ([string]::IsNullOrWhiteSpace($serverTags)) {
        $serverTags = Resolve-OptionalStringSetting "LLAMA_ARG_TAGS"
    }
    if ([string]::IsNullOrWhiteSpace($serverTags) -and $mmproj) {
        $serverTags = "vision,multimodal,image"
    }

    if (-not [string]::IsNullOrWhiteSpace($serverTags)) {
        $arguments += @("--tags", $serverTags)
    }

    if ($autoTuneEnabled) {
        $arguments += @("--cont-batching")
    }

    if ($null -ne $ParallelSlots) {
        $arguments += @("-np", $ParallelSlots.ToString())
    }

    if ($null -ne $ThreadsHttp) {
        $arguments += @("--threads-http", $ThreadsHttp.ToString())
    }

    $arguments += @("--host", "127.0.0.1", "--port", $Port.ToString())
    Write-Host ""
    Write-Host "Starting llama-server..."
    Write-Host "URL: http://127.0.0.1:$Port"
} else {
    $arguments += @("-cnv")
    Write-Host ""
    Write-Host "Starting llama-cli..."
}

Write-Host "Model: $($model.FullName)"
if ($mmproj) {
    Write-Host "Vision: enabled with mmproj $($mmproj.FullName)"
} else {
    Write-Host "Vision: disabled"
}

if ($Mode -eq "server" -and -not [string]::IsNullOrWhiteSpace($serverAlias)) {
    Write-Host "API model alias: $serverAlias"
}

if ($Mode -eq "server" -and -not [string]::IsNullOrWhiteSpace($serverTags)) {
    Write-Host "API model tags: $serverTags"
}

if ($autoTuneEnabled) {
    Write-Host ""
    Write-Host "Auto performance tuning: $OptimizeMode"
    Write-Host ("CPU: {0} physical cores / {1} logical processors" -f $systemProfile.PhysicalCores, $systemProfile.LogicalProcessors)
    Write-Host ("RAM: {0} total / {1} free" -f (Format-GB $systemProfile.TotalMemoryGB), (Format-GB $systemProfile.FreeMemoryGB))
    Write-Host ("GPU: {0} ({1}, VRAM {2})" -f $systemProfile.NvidiaName, $systemProfile.NvidiaSource, (Format-GB $systemProfile.NvidiaMemoryGB))
    if ($autoTune.LayerCount) {
        Write-Host ("GGUF layers: {0}; model size: {1}" -f $autoTune.LayerCount, (Format-GB $autoTune.ModelGB))
    }
    Write-Host ("Settings: -ngl {0}, -t {1}, -tb {2}, -b {3}, -ub {4}, -fa {5}, --prio {6}" -f $GpuLayers, $Threads, $ThreadsBatch, $BatchSize, $UBatchSize, $FlashAttention, $Priority)
    if ($Mode -eq "server") {
        Write-Host ("Server: -np {0}, --threads-http {1}, --cont-batching" -f $ParallelSlots, $ThreadsHttp)
    }
}

Write-Host ""

if ($DryRun) {
    $commandLine = @(
        Quote-CommandArgument $exePath
        $arguments | ForEach-Object { Quote-CommandArgument $_ }
    ) -join " "

    Write-Host "Dry run only. Command:"
    Write-Host $commandLine
    exit 0
}

& $exePath @arguments
exit $LASTEXITCODE
