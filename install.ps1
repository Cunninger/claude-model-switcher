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

# ---------- 颜色工具 ----------
function Write-Info    { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Error   { param([string]$Message) Write-Host "  $Message" -ForegroundColor Red }

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

if (Test-Path $InstallDir) {
    if (-not $Force) {
        Write-Warn "Directory already exists: $InstallDir"
        $confirm = Read-Host "Overwrite? [y/N]"
        if ($confirm.Trim().ToLower() -notin @('y','yes')) {
            Write-Host "Installation cancelled." -ForegroundColor Yellow
            exit 0
        }
    }
    Remove-Item -Recurse -Force $InstallDir
}

$hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

if ($hasGit) {
    Write-Info "Git detected. Cloning repository..."
    git clone --depth 1 https://github.com/cunninger/claude-model-switcher.git $InstallDir 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Git clone failed. Falling back to zip download..."
        $hasGit = $false
    }
}

if (-not $hasGit) {
    Write-Info "Downloading latest archive..."
    $zipUrl = "https://github.com/cunninger/claude-model-switcher/archive/refs/heads/master.zip"
    $zipPath = "$env:TEMP\claude-model-switcher.zip"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        Write-Error "Download failed: $_"
        exit 1
    }

    Write-Info "Extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force
    $extracted = "$env:TEMP\claude-model-switcher-master"

    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    Move-Item -Path $extracted -Destination $InstallDir -Force
    Remove-Item $zipPath -ErrorAction SilentlyContinue
}

Write-Success "Files installed to $InstallDir"

# ---------- 4. 配置 $PROFILE ----------
Write-Info "Configuring PowerShell profile..."

$profileLine = @"
`$env:CLAUDE_SWITCHER_QUIET = "1"
. "$InstallDir\claude-model-switcher.ps1"
"@

# 确保 $PROFILE 文件存在
if (-not (Test-Path $PROFILE)) {
    New-Item -Path $PROFILE -ItemType File -Force | Out-Null
    Write-Success "Created new profile: $PROFILE"
}

# 检查是否已存在（避免重复添加）
$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($profileContent -and $profileContent.Contains("claude-model-switcher.ps1")) {
    Write-Warn "Profile already contains claude-model-switcher loader."
    Write-Host "    Run '. `$PROFILE' manually if you want to reload." -ForegroundColor DarkGray
} else {
    Add-Content -Path $PROFILE -Value "`n# Claude Code Multi-Model Switcher`n$profileLine`n"
    Write-Success "Added loader to `$PROFILE"
}

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
Write-Host ""
