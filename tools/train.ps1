param(
    [ValidateSet('baseline', 'train', 'compare', 'tournament')]
    [string]$Mode = 'baseline',
    [string]$Config = 'training/config.lua',
    [string]$OutputDirectory = '',
    [string]$WeightsPath = '',
    [string]$StartWeightsPath = '',
    [string[]]$PlayerLogs = @(),
    [string]$ResumeCheckpoint = '',
    [string]$ExperimentSeed = '',
    [int]$ExperimentCount = 1,
    [int]$MaxWorkers = 0,
    [string[]]$ChampionPaths = @(),
    [int]$PopulationSize = 0,
    [int]$Generations = 0,
    [string]$BalatroPath = 'G:\SteamLibrary\steamapps\common\Balatro'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Resolve-TrainingPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
function Resolve-PlayerLogs([string[]]$Paths) {
    $resolved = @()
    foreach ($path in $Paths) {
        if ($path -ieq 'latest') {
            $logsDirectory = Join-Path $root 'logs'
            $latest = Get-ChildItem -LiteralPath $logsDirectory -File -Filter 'multibots-*.log' |
                Where-Object { $_.Name -notlike '*.snapshots.log' } |
                Sort-Object LastWriteTimeUtc -Descending |
                Where-Object {
                    Select-String -LiteralPath $_.FullName `
                        -Pattern '\bPVP\b(?=.*\bante=)(?=.*\bplayer_score=)' -Quiet
                } |
                Select-Object -First 1
            if (-not $latest) {
                throw "No player PvP logs found in $logsDirectory"
            }
            $resolved += $latest.FullName
            Write-Host "Resolved -PlayerLogs latest to $($latest.FullName)"
        } else {
            $resolved += Resolve-TrainingPath $path
        }
    }
    return $resolved
}
function ConvertTo-NativeArgumentLine([string[]]$Arguments) {
    $quotedArguments = foreach ($argument in $Arguments) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            $argument
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                [void]$builder.Append(('\' * (2 * $backslashes + 1)))
                [void]$builder.Append('"')
            } else {
                [void]$builder.Append(('\' * $backslashes))
                [void]$builder.Append($character)
            }
            $backslashes = 0
        }
        [void]$builder.Append(('\' * (2 * $backslashes)))
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return $quotedArguments -join ' '
}
$PlayerLogs = Resolve-PlayerLogs $PlayerLogs
if ($ExperimentCount -gt 1) {
    if ($Mode -ne 'train') { throw 'ExperimentCount greater than 1 is only valid in train mode' }
    if (-not $OutputDirectory) {
        $stamp = Get-Date -Format 'yyyy.MM.dd-HH.mm.ss'
        $OutputDirectory = Join-Path $root "training/results/$stamp-multi"
    }
    $groupOutput = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($OutputDirectory)) {
        $OutputDirectory
    } else { Join-Path $root $OutputDirectory }))
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Python 3 is required for parallel experiments; install Python or add python.exe to PATH' }
    $powerShellExecutable = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') {
        'pwsh.exe'
    } else { 'powershell.exe' })
    $parallelArgs = @(
        (Join-Path $PSScriptRoot 'train_parallel.py'),
        '--powershell', $powerShellExecutable,
        '--script', $PSCommandPath,
        '--root', $root,
        '--config', $Config,
        '--output-dir', $groupOutput,
        '--experiment-count', "$ExperimentCount",
        '--max-workers', "$MaxWorkers",
        '--population-size', "$PopulationSize",
        '--generations', "$Generations",
        '--balatro-path', $BalatroPath
    )
    if ($ExperimentSeed) { $parallelArgs += @('--experiment-seed', $ExperimentSeed) }
    if ($StartWeightsPath) { $parallelArgs += @('--start-weights-path', (Resolve-TrainingPath $StartWeightsPath)) }
    if ($PlayerLogs.Count -gt 0) {
        $parallelArgs += '--player-logs'
        $parallelArgs += @($PlayerLogs | ForEach-Object { Resolve-TrainingPath $_ })
    }
    $argumentLine = ConvertTo-NativeArgumentLine $parallelArgs
    $process = Start-Process -FilePath $python.Source -ArgumentList $argumentLine `
        -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Parallel training failed with exit code $($process.ExitCode)"
    }
    return
}
if (-not $OutputDirectory) {
    $stamp = Get-Date -Format 'yyyy.MM.dd-HH.mm.ss'
    $OutputDirectory = Join-Path $root "training/results/$stamp-$Mode"
}
$outputInput = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $root $OutputDirectory }
$output = [IO.Path]::GetFullPath($outputInput)
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (-not $ExperimentSeed -and -not $ResumeCheckpoint) {
    $ExperimentSeed = [Guid]::NewGuid().ToString('N')
}

if (-not ('MultiBotsLua51' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MultiBotsLua51 {
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetDllDirectory(string path);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr luaL_newstate();
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void luaL_openlibs(IntPtr state);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] public static extern int luaL_loadfile(IntPtr state, string path);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)] public static extern int lua_pcall(IntPtr state, int nargs, int nresults, int errorFunction);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr lua_tolstring(IntPtr state, int index, out UIntPtr length);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] public static extern void lua_pushstring(IntPtr state, string value);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] public static extern void lua_setfield(IntPtr state, int index, string key);
    [DllImport("lua51.dll", CallingConvention = CallingConvention.Cdecl)] public static extern void lua_close(IntPtr state);
}
'@
}
if (-not [MultiBotsLua51]::SetDllDirectory($BalatroPath)) { throw "Could not use Balatro DLL directory: $BalatroPath" }

$env:MULTIBOTS_TRAIN_MODE = $Mode
$env:MULTIBOTS_TRAIN_CONFIG = $Config
$env:MULTIBOTS_TRAIN_OUTPUT = $output.Replace('\', '/')
$env:MULTIBOTS_TRAIN_WEIGHTS = $WeightsPath
$env:MULTIBOTS_TRAIN_START_WEIGHTS = if ($StartWeightsPath) { Resolve-TrainingPath $StartWeightsPath } else { '' }
$env:MULTIBOTS_TRAIN_PLAYER_LOGS = ($PlayerLogs | ForEach-Object { Resolve-TrainingPath $_ }) -join ';'
$env:MULTIBOTS_TRAIN_RESUME = $ResumeCheckpoint
$env:MULTIBOTS_TRAIN_POPULATION = if ($PopulationSize -gt 0) { "$PopulationSize" } else { '' }
$env:MULTIBOTS_TRAIN_GENERATIONS = if ($Generations -gt 0) { "$Generations" } else { '' }
$env:MULTIBOTS_TRAIN_EXPERIMENT_SEED = $ExperimentSeed
$env:MULTIBOTS_TRAIN_CHAMPIONS = $ChampionPaths -join ';'

Push-Location $root
$state = [MultiBotsLua51]::luaL_newstate()
if ($state -eq [IntPtr]::Zero) { throw 'luaL_newstate failed' }
try {
    [MultiBotsLua51]::luaL_openlibs($state)
    foreach ($name in @('MULTIBOTS_TRAIN_MODE', 'MULTIBOTS_TRAIN_CONFIG', 'MULTIBOTS_TRAIN_OUTPUT',
            'MULTIBOTS_TRAIN_WEIGHTS', 'MULTIBOTS_TRAIN_START_WEIGHTS',
            'MULTIBOTS_TRAIN_PLAYER_LOGS', 'MULTIBOTS_TRAIN_RESUME', 'MULTIBOTS_TRAIN_POPULATION',
            'MULTIBOTS_TRAIN_GENERATIONS', 'MULTIBOTS_TRAIN_EXPERIMENT_SEED',
            'MULTIBOTS_TRAIN_CHAMPIONS')) {
        [MultiBotsLua51]::lua_pushstring($state, [Environment]::GetEnvironmentVariable($name))
        [MultiBotsLua51]::lua_setfield($state, -10002, $name)
    }
    $status = [MultiBotsLua51]::luaL_loadfile($state, 'training/cli.lua')
    if ($status -eq 0) { $status = [MultiBotsLua51]::lua_pcall($state, 0, 0, 0) }
    if ($status -ne 0) {
        $length = [UIntPtr]::Zero
        $pointer = [MultiBotsLua51]::lua_tolstring($state, -1, [ref]$length)
        $message = if ($pointer -eq [IntPtr]::Zero) { 'unknown Lua error' } else {
            [Runtime.InteropServices.Marshal]::PtrToStringAnsi($pointer, [int]$length.ToUInt64())
        }
        throw $message
    }
}
finally {
    [MultiBotsLua51]::lua_close($state)
    Pop-Location
}
Write-Host "Results: $output"
