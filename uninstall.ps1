#Requires -PSEdition Core
#Requires -Version 7

<#
.SYNOPSIS
    Claude Code Multi-Model Switcher - Uninstaller
.DESCRIPTION
    Removes the switcher from $PROFILE and optionally deletes
    script files and/or model configuration data.
.EXAMPLE
    pwsh -File .\uninstall.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\claude-model-switcher",
    [switch]$RemoveData,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# ---------- 颜色工具 ----------
function Write-Info    { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Error   { param([string]$Message) Write-Host "  $Message" -ForegroundColor Red }

$profileHelperPath = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "profile-loader.ps1"))) {
    Join-Path $PSScriptRoot "profile-loader.ps1"
} else {
    Join-Path $InstallDir "profile-loader.ps1"
}
if (-not (Test-Path -LiteralPath $profileHelperPath)) {
    throw "Missing profile helper: $profileHelperPath"
}
. $profileHelperPath

function Get-RegisteredModelDataPaths {
    $sharedRoot = "$env:USERPROFILE\.claude-shared"
    $registryPath = Join-Path $sharedRoot "models-registry.json"
    $paths = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath $sharedRoot) {
        $paths.Add($sharedRoot)
    }

    if (-not (Test-Path -LiteralPath $registryPath)) {
        Write-Warn "Registry not found; only shared data can be removed safely."
        return @($paths)
    }

    try {
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($prop in $registry.PSObject.Properties) {
            if ($prop.Name -match '^[a-z0-9_]+$') {
                $modelDir = Join-Path $env:USERPROFILE ".claude-$($prop.Name)"
                if (Test-Path -LiteralPath $modelDir) {
                    $paths.Add($modelDir)
                }
            }
        }
    }
    catch {
        Write-Warn "Registry JSON parse failed; model directories will not be removed automatically: $_"
    }

    return @($paths | Select-Object -Unique)
}

# ---------- 安全删除重解析点 ----------
function Remove-SafeReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [System.IO.Directory]::Delete($item.FullName, $false)
    } elseif ($item.PSIsContainer) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    } else {
        Remove-Item -LiteralPath $item.FullName -Force
    }
}

# ---------- 横幅 ----------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║     Claude Code Multi-Model Switcher Uninstaller             ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""

# ---------- 1. 从 $PROFILE 移除 ----------
Write-Info "Checking PowerShell profile..."
$profileResult = Remove-ClaudeSwitcherProfileLoader -ProfilePath $PROFILE
if (-not $profileResult.Exists) {
    Write-Warn "`$PROFILE does not exist"
}
elseif ($profileResult.Warning) {
    Write-Warn $profileResult.Warning
}
if ($profileResult.Changed) {
    Write-Success "Removed loader from `$PROFILE"
} else {
    Write-Warn "No claude-model-switcher loader found in `$PROFILE"
}

# ---------- 2. 删除脚本文件 ----------
$removeScript = $true
if (-not $Yes) {
    Write-Host ""
    $ans = Read-Host "Remove script files from $InstallDir ? [Y/n]"
    if ($ans.Trim().ToLower() -in @('n','no')) {
        $removeScript = $false
    }
}

if ($removeScript -and (Test-Path -LiteralPath $InstallDir)) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Success "Removed script directory: $InstallDir"
} elseif (-not (Test-Path -LiteralPath $InstallDir)) {
    Write-Warn "Script directory not found: $InstallDir"
}

# ---------- 3. 删除模型数据 ----------
$removeData = $RemoveData
if (-not $Yes -and -not $RemoveData) {
    Write-Host ""
    Write-Warn "WARNING: This can delete registered model configs and shared conversation history."
    $ans = Read-Host "Remove registered model data and ~/.claude-shared ? [y/N]"
    if ($ans.Trim().ToLower() -in @('y','yes')) {
        $removeData = $true
    }
}

if ($removeData) {
    $dataPaths = @(Get-RegisteredModelDataPaths)
    if ($dataPaths.Count -eq 0) {
        Write-Warn "No registered model data found."
    }
    else {
        Write-Host ""
        Write-Warn "The following registered data paths will be removed:"
        $dataPaths | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        if (-not $Yes) {
            $confirm = Read-Host "Type DELETE to confirm"
            if ($confirm -ne "DELETE") {
                Write-Warn "Model data removal cancelled."
                $dataPaths = @()
            }
        }
        foreach ($path in $dataPaths) {
            Remove-SafeReparsePoint $path
            Write-Success "Removed data: $path"
        }
    }
} else {
    Write-Info "Model data preserved."
}

# ---------- 4. 完成 ----------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✅ Uninstall Complete                                       ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Please restart your terminal for changes to take full effect." -ForegroundColor Gray
Write-Host ""
