#Requires -PSEdition Core
#Requires -Version 7

<#
.SYNOPSIS
    Claude Code Multi-Model Switcher - One-line Installer
.DESCRIPTION
    Installs the switcher to $env:LOCALAPPDATA\claude-model-switcher,
    appends the loader to $PROFILE, and reloads the profile.
    After installation, run Add-ClaudeModel to configure your first model.
.EXAMPLE
    iwr https://raw.githubusercontent.com/cunninger/claude-model-switcher/master/install.ps1 -OutFile install.ps1
    pwsh -File .\install.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\claude-model-switcher",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProfileMarkerBegin = "# >>> Claude Code Multi-Model Switcher >>>"
$ProfileMarkerEnd   = "# <<< Claude Code Multi-Model Switcher <<<"

# ---------- 颜色工具 ----------
function Write-Info    { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Error   { param([string]$Message) Write-Host "  $Message" -ForegroundColor Red }

function New-UniqueTempDir {
    param([string]$Prefix = "claude-model-switcher")

    $path = Join-Path $env:TEMP "$Prefix-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function New-BackupPath {
    param([Parameter(Mandatory)][string]$Path)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$Path.backup-$timestamp"
    $i = 1
    while (Test-Path -LiteralPath $backupPath) {
        $backupPath = "$Path.backup-$timestamp-$i"
        $i++
    }
    return $backupPath
}

function Install-StagedDirectory {
    param(
        [Parameter(Mandatory)][string]$StagingDir,
        [Parameter(Mandatory)][string]$DestinationDir
    )

    $scriptPath = Join-Path $StagingDir "claude-model-switcher.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Staged directory is invalid: missing claude-model-switcher.ps1"
    }

    $parent = Split-Path -Parent $DestinationDir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $currentDir = (Get-Location).ProviderPath
    if ($currentDir -and $currentDir.StartsWith($DestinationDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Location $env:TEMP
    }

    $backupDir = $null
    if (Test-Path -LiteralPath $DestinationDir) {
        $backupDir = New-BackupPath -Path $DestinationDir
        Move-Item -LiteralPath $DestinationDir -Destination $backupDir -Force
    }

    try {
        Move-Item -LiteralPath $StagingDir -Destination $DestinationDir -Force
        if ($backupDir -and (Test-Path -LiteralPath $backupDir)) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force
        }
    }
    catch {
        if ($backupDir -and (Test-Path -LiteralPath $backupDir) -and -not (Test-Path -LiteralPath $DestinationDir)) {
            Move-Item -LiteralPath $backupDir -Destination $DestinationDir -Force
        }
        throw
    }
}

function Set-ProfileLoaderBlock {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    $block = @"
$ProfileMarkerBegin
`$env:CLAUDE_SWITCHER_QUIET = "1"
. "$ScriptPath"
$ProfileMarkerEnd
"@

    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        New-Item -Path $ProfilePath -ItemType File -Force | Out-Null
        Write-Success "Created new profile: $ProfilePath"
    }

    $content = Get-Content -LiteralPath $ProfilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = "" }

    $pattern = "(?s)\r?\n?$([regex]::Escape($ProfileMarkerBegin)).*?$([regex]::Escape($ProfileMarkerEnd))\r?\n?"
    $content = [regex]::Replace($content, $pattern, "`n")

    $lines = @($content -split "\r?\n") | Where-Object {
        $_ -notmatch 'claude-model-switcher\.ps1' -and
        $_ -notmatch '^\s*\$env:CLAUDE_SWITCHER_QUIET\s*=' -and
        $_ -ne '# Claude Code Multi-Model Switcher'
    }
    $content = ($lines -join "`n").TrimEnd()

    $newContent = if ($content) { "$content`n`n$block`n" } else { "$block`n" }
    Set-Content -LiteralPath $ProfilePath -Value $newContent -NoNewline -Encoding UTF8
}

# ---------- 横幅 ----------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Claude Code Multi-Model Switcher Installer               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. 检查 PowerShell 版本 ----------
Write-Info "Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "PowerShell 7+ is required. You are running $($PSVersionTable.PSVersion)"
    Write-Host ""
    Write-Host "Install PowerShell 7:"
    Write-Host "    winget install Microsoft.PowerShell" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Success "PowerShell $($PSVersionTable.PSVersion) OK"

# ---------- 2. 检查 claude 命令 ----------
Write-Info "Checking Claude Code CLI..."
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    Write-Warn "Claude Code CLI not found on PATH."
    Write-Host "    You can install it later: npm install -g @anthropic-ai/claude-code" -ForegroundColor DarkGray
} else {
    Write-Success "Claude Code CLI found at: $($claudeCmd.Source)"
}

# ---------- 3. 下载/安装 ----------
Write-Info "Installing to: $InstallDir"

if (Test-Path -LiteralPath $InstallDir) {
    if (-not $Force) {
        Write-Warn "Directory already exists: $InstallDir"
        $confirm = Read-Host "Overwrite? [y/N]"
        if ($confirm.Trim().ToLower() -notin @('y','yes')) {
            Write-Host "Installation cancelled." -ForegroundColor Yellow
            exit 0
        }
    }
}

$hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
$stagingDir = $null
$cleanupDir = $null

if ($hasGit) {
    Write-Info "Git detected. Cloning repository..."
    $cleanupDir = New-UniqueTempDir -Prefix "claude-model-switcher-git"
    $stagingDir = Join-Path $cleanupDir "repo"
    git clone --depth 1 https://github.com/cunninger/claude-model-switcher.git $stagingDir 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Git clone failed. Falling back to zip download..."
        if (Test-Path -LiteralPath $cleanupDir) {
            Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $stagingDir = $null
        $cleanupDir = $null
        $hasGit = $false
    }
}

if (-not $hasGit) {
    Write-Info "Downloading latest archive..."
    $zipUrl = "https://github.com/cunninger/claude-model-switcher/archive/refs/heads/master.zip"
    $cleanupDir = New-UniqueTempDir -Prefix "claude-model-switcher-zip"
    $zipPath = Join-Path $cleanupDir "claude-model-switcher.zip"
    $extractRoot = Join-Path $cleanupDir "extract"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        Write-Error "Download failed: $_"
        exit 1
    }

    Write-Info "Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force
    $stagingDir = Join-Path $extractRoot "claude-model-switcher-master"
}

Install-StagedDirectory -StagingDir $stagingDir -DestinationDir $InstallDir
if ($cleanupDir -and (Test-Path -LiteralPath $cleanupDir)) {
    Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Success "Files installed to $InstallDir"

# ---------- 4. 配置 $PROFILE ----------
Write-Info "Configuring PowerShell profile..."

$scriptPath = Join-Path $InstallDir "claude-model-switcher.ps1"
Set-ProfileLoaderBlock -ProfilePath $PROFILE -ScriptPath $scriptPath
Write-Success "Updated loader in `$PROFILE"

# ---------- 5. 立即加载 ----------
Write-Info "Loading switcher in current session..."
try {
    . "$InstallDir\claude-model-switcher.ps1"
    Write-Success "Switcher loaded successfully!"
} catch {
    Write-Error "Failed to load: $_"
    Write-Host "    Please run '. `$PROFILE' manually after fixing the issue." -ForegroundColor DarkGray
    exit 1
}

# ---------- 6. 完成提示 ----------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✅ Installation Complete                                    ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Next step: configure your first AI model." -ForegroundColor Cyan
Write-Host ""
Write-Host "    Add-ClaudeModel" -ForegroundColor Yellow
Write-Host ""
Write-Host "Available commands:" -ForegroundColor Gray
Write-Host "    Add-ClaudeModel      - Add a new model (interactive wizard)" -ForegroundColor Gray
Write-Host "    Remove-ClaudeModel   - Remove a model" -ForegroundColor Gray
Write-Host "    Test-ClaudeSwitcher  - Run diagnostics" -ForegroundColor Gray
Write-Host "    Repair-ClaudeSwitcher - Repair common environment issues" -ForegroundColor Gray
Write-Host "    Test-ClaudeConversation - Check current conversation health" -ForegroundColor Gray
Write-Host ""
