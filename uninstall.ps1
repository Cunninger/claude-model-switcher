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

# ---------- 安全删除重解析点 ----------
function Remove-SafeReparsePoint {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [System.IO.Directory]::Delete($Path, $false)
    } elseif ($item.PSIsContainer) {
        Remove-Item -Recurse -Force $Path
    } else {
        Remove-Item -Force $Path
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
if (Test-Path $PROFILE) {
    $content = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains("claude-model-switcher.ps1")) {
        $lines = Get-Content $PROFILE
        $newLines = $lines | Where-Object {
            -not ($_ -match "claude-model-switcher")
        }
        # 同时移除空行块（如果留下连续空行）
        $cleaned = @()
        $prevEmpty = $false
        foreach ($line in $newLines) {
            $isEmpty = [string]::IsNullOrWhiteSpace($line)
            if ($isEmpty -and $prevEmpty) { continue }
            $cleaned += $line
            $prevEmpty = $isEmpty
        }
        Set-Content -Path $PROFILE -Value ($cleaned -join "`n") -NoNewline
        Write-Success "Removed loader from `$PROFILE"
    } else {
        Write-Warn "No claude-model-switcher loader found in `$PROFILE"
    }
} else {
    Write-Warn "`$PROFILE does not exist"
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

if ($removeScript -and (Test-Path $InstallDir)) {
    Remove-Item -Recurse -Force $InstallDir
    Write-Success "Removed script directory: $InstallDir"
} elseif (-not (Test-Path $InstallDir)) {
    Write-Warn "Script directory not found: $InstallDir"
}

# ---------- 3. 删除模型数据 ----------
$removeData = $RemoveData
if (-not $Yes -and -not $RemoveData) {
    Write-Host ""
    Write-Warn "WARNING: This will delete ALL model configs and conversation history!"
    $ans = Read-Host "Remove all model data (~/.claude-* and ~/.claude-shared) ? [y/N]"
    if ($ans.Trim().ToLower() -in @('y','yes')) {
        $removeData = $true
    }
}

if ($removeData) {
    $sharedRoot = "$env:USERPROFILE\.claude-shared"
    if (Test-Path $sharedRoot) {
        Remove-SafeReparsePoint $sharedRoot
        Write-Success "Removed shared data: $sharedRoot"
    }

    $modelDirs = Get-ChildItem -Path "$env:USERPROFILE" -Directory -Filter ".claude-*" -ErrorAction SilentlyContinue
    foreach ($dir in $modelDirs) {
        Remove-SafeReparsePoint $dir.FullName
        Write-Success "Removed model data: $($dir.FullName)"
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
