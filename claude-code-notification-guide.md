# Claude Code 多模型切换 + Windows 通知配置指南

## 概述

本文记录了 Claude Code 在 Windows 上实现**多模型一键切换**和**任务完成 Toast 通知**的完整配置过程，包括踩过的坑和最终解决方案。

最终效果：
- 终端输入 `z`/`k`/`d` 一键切换 GLM-5.1 / Kimi K2.6 / DeepSeek V4-Pro
- 对话历史跨模型共享
- Claude 每次回复完毕，Windows 右下角弹出 Toast 通知

---

## 一、多模型切换配置

### 目录结构

```
C:\Users\<用户名>\
├── .claude\                    ← Claude Code 默认配置目录（全局）
│   └── settings.json
├── .claude-zhipu\              ← 智谱 GLM 私有配置
│   ├── settings.json
│   └── notify.ps1
├── .claude-kimi\               ← Kimi 私有配置
│   ├── settings.json
│   └── notify.ps1
├── .claude-deepseek\           ← DeepSeek 私有配置
│   ├── settings.json
│   └── notify.ps1
└── .claude-shared\             ← 共享对话历史
    ├── conversations\          ← junction → 各模型的 conversations 目录
    └── projects\               ← junction → 各模型的 projects 目录
```

### 核心原理

通过环境变量 `CLAUDE_CONFIG_DIR` 让 Claude Code 读取不同目录下的 `settings.json`，实现模型切换。同时用 **Junction（目录联接）** 把 `conversations` 和 `projects` 目录指向共享位置，实现对话历史跨模型共享。

### 切换脚本

将以下脚本内容加入 PowerShell Profile（`notepad $PROFILE`），或保存为 `.ps1` 文件后 dot-source 加载：

```powershell
# Claude Code 多模型切换器（对话历史共享版）
# 使用方式：z (zhipu), k (kimi), d (deepseek)

$ErrorActionPreference = "Stop"

# ---------- 配置区域 ----------

$script:SharedRoot     = "$env:USERPROFILE\.claude-shared"
$script:SharedConv     = "$script:SharedRoot\conversations"
$script:SharedProjects = "$script:SharedRoot\projects"

$script:Models = @{
    zhipu = @{
        Dir   = "$env:USERPROFILE\.claude-zhipu"
        Name  = "Zhipu GLM-5.1"
        Color = "Cyan"
    }
    kimi = @{
        Dir   = "$env:USERPROFILE\.claude-kimi"
        Name  = "Kimi K2.6"
        Color = "Magenta"
    }
    deepseek = @{
        Dir   = "$env:USERPROFILE\.claude-deepseek"
        Name  = "DeepSeek V4-Pro"
        Color = "Blue"
    }
}

# ---------- 内部函数 ----------

function Initialize-SharedDirs {
    $dirs = @($script:SharedConv, $script:SharedProjects)
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
}

function Link-Or-Junction {
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    if (Test-Path $LinkPath) {
        $item = Get-Item $LinkPath
        if ($item.Attributes -match "ReparsePoint") {
            [System.IO.Directory]::Delete($LinkPath, $false)
        }
        elseif ($item.PSIsContainer) {
            Remove-Item $LinkPath -Recurse -Force
        }
        else {
            Remove-Item $LinkPath -Force
        }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath | Out-Null
        return
    }
    catch {
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
    }
}

function Enter-ModelEnv {
    param(
        [Parameter(Mandatory)][string]$ModelKey
    )

    $cfg = $script:Models[$ModelKey]
    if (-not $cfg) {
        Write-Error "未知模型：$ModelKey"
        return
    }

    $configDir = $cfg.Dir

    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    Initialize-SharedDirs
    Link-Or-Junction -LinkPath "$configDir\conversations" -TargetPath $script:SharedConv
    Link-Or-Junction -LinkPath "$configDir\projects"     -TargetPath $script:SharedProjects

    $env:CLAUDE_CONFIG_DIR = $configDir
    Write-Host "已切换到 $($cfg.Name)" -ForegroundColor $cfg.Color
    Write-Host "Config Dir: $configDir" -ForegroundColor DarkGray
    Write-Host "Shared Conversations: $script:SharedConv" -ForegroundColor DarkGray
}

# ---------- 公开函数 ----------

function zhipu   { Enter-ModelEnv "zhipu";    & claude @args }
function kimi    { Enter-ModelEnv "kimi";     & claude @args }
function deepseek { Enter-ModelEnv "deepseek"; & claude @args }

Set-Alias -Name z -Value zhipu
Set-Alias -Name k -Value kimi
Set-Alias -Name d -Value deepseek

Write-Host "Claude Code 多模型切换器已加载" -ForegroundColor Green
Write-Host "命令: z (zhipu), k (kimi), d (deepseek)" -ForegroundColor Gray
Write-Host "对话历史共享目录: $script:SharedRoot" -ForegroundColor Gray
```

### 各模型 settings.json

每个模型目录下的 `settings.json` 格式相同，只有 `env` 中的 API 地址和模型名不同。

**智谱 GLM-5.1** (`~/.claude-zhipu/settings.json`)：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "你的API密钥",
    "ANTHROPIC_MODEL": "GLM-5.1",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "GLM-5.1",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "GLM-5.1",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "GLM-5.1",
    "ANTHROPIC_REASONING_MODEL": "GLM-5.1"
  },
  "theme": "dark",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "pwsh.exe -NoProfile -File C:/Users/YourUsername/.claude-zhipu/notify.ps1",
            "async": true
          }
        ]
      }
    ]
  }
}
```

> 其他模型替换对应的 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL` 等字段即可。

---

## 二、Windows Toast 通知配置

### 前置条件

安装 BurntToast PowerShell 模块：

```powershell
Install-Module -Name BurntToast -Scope CurrentUser -Force
```

### 通知脚本

每个模型目录下放一个 `notify.ps1`（三个文件内容相同）：

```powershell
$time = Get-Date -Format "HH:mm:ss"
New-BurntToastNotification -Text "Claude Code", "Task complete ($time) - your input is needed"
```

### Hooks 配置（最终正确版本）

在 `settings.json` 中：

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "pwsh.exe -NoProfile -File C:/Users/YourUsername/.claude-zhipu/notify.ps1",
            "async": true
          }
        ]
      }
    ]
  }
}
```

关键点：
- **事件名 `Stop`**：Claude 每次完成回复、等待用户输入时触发
- **不加 `shell` 字段**：使用默认 bash（Git Bash）执行命令
- **用 bash 调用 `pwsh.exe`**：`pwsh.exe -NoProfile -File ...`
- **`async: true`**：通知在后台执行，不阻塞 Claude Code

---

## 三、踩坑记录与排查过程

### 坑 1：Hooks 配置结构搞错

**错误写法**（hooks 是数组）：

```json
"hooks": [
  { "type": "command", "command": "..." }
]
```

**正确写法**（hooks 是对象，键是事件名）：

```json
"hooks": {
  "Stop": [
    { "hooks": [ { "type": "command", "command": "..." } ] }
  ]
}
```

**原因**：Claude Code 的 `hooks` 字段是一个 **对象（record）**，不是数组。顶层键是事件名（`Stop`、`Notification`、`SessionStart` 等），值是 `{ matcher, hooks }` 的数组。Claude Code 内置的 schema 校验会拒绝错误结构。

**教训**：参考 Claude Code settings schema 验证输出确认结构。schema 中 `hooks` 的 `type` 是 `"object"`。

---

### 坑 2：Matcher 值 `idle_prompt` 不存在

**错误写法**：

```json
{ "matcher": "idle_prompt", "hooks": [...] }
```

**正确写法**：

```json
{ "hooks": [...] }
```

或者：

```json
{ "matcher": "", "hooks": [...] }
```

**原因**：`matcher` 用于匹配工具名（如 `"Bash"`、`"Edit|Write"`），在 `Stop` 这类非工具事件上没有意义。`idle_prompt` 不是合法的 matcher 值。`matcher` 字段是可选的，省略即可匹配所有。

**教训**：`matcher` 仅用于 `PreToolUse`、`PostToolUse` 等工具相关事件，用于过滤特定工具。对于 `Stop` 事件，直接省略 `matcher`。

---

### 坑 3：`shell: "powershell"` 导致命令不执行

**错误写法**：

```json
{
  "type": "command",
  "shell": "powershell",
  "command": "-NoProfile -File C:\\Users\\YourUsername\\.claude-zhipu\\notify.ps1"
}
```

**正确写法**：

```json
{
  "type": "command",
  "command": "pwsh.exe -NoProfile -File C:/Users/YourUsername/.claude-zhipu/notify.ps1",
  "async": true
}
```

**原因**：`shell: "powershell"` 在 Windows 上应该使用 `pwsh` 执行，但实际测试中发现通过这种方式执行的命令**完全没有触发**（连日志文件都没有生成）。而改用默认 bash（Git Bash）直接调用 `pwsh.exe` 则一切正常。

**教训**：在 Windows 上，Claude Code 默认使用 Git Bash 作为 shell。对于需要 PowerShell 的操作，最佳做法是**不加 `shell` 字段，在 bash 中直接调用 `pwsh.exe`**。

---

### 坑 4：事件名选错

| 尝试的事件名 | 是否触发 | 说明 |
|---|---|---|
| `Notification` + `matcher: "idle_prompt"` | 否 | matcher 不存在 |
| `Stop` + `shell: "powershell"` | 否 | shell 配置问题（坑 3） |
| `Notification` + `matcher: ""` | 未确认 | 被坑 3 掩盖 |
| `Stop`（bash 调用，无 matcher） | **是** | 正确方案 |
| `SessionStart` | 是 | 但不是我们要的时机 |

**诊断方法**：在多个事件上同时挂一个简单的写文件命令，确认哪些事件会在何时触发：

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "echo SessionStart >> /c/Users/YourUsername/hook-test.log" }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "echo Stop >> /c/Users/YourUsername/hook-test.log" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "echo Notification >> /c/Users/YourUsername/hook-test.log" }] }]
  }
}
```

---

### 坑 5：JSON 转义灾难

**错误尝试**：在 JSON 字符串中内联复杂的 PowerShell 命令：

```json
"command": "-NoProfile -Command \"Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.NotifyIcon]@{Icon=...;Visible=\$true;...}.ShowBalloonTip(5000)\""
```

**原因**：JSON 中的 `\"`、`\\`、`\$` 转义与 PowerShell 语法互相干扰，极易出错且难以调试。

**教训**：**永远不要在 JSON 中写复杂的内联命令**。把逻辑放到 `.ps1` 文件中，JSON 只负责调用文件路径。

---

### 坑 6：`New-BurntToastNotification` vs `System.Windows.Forms.NotifyIcon`

**错误方案**：使用 `System.Windows.Forms.NotifyIcon` 的 BalloonTip：

```powershell
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.ShowBalloonTip(5000, "Title", "Text", "Info")
```

**问题**：在 Windows 10/11 上，BalloonTip 已被 Action Center 的 Toast 通知取代，很多时候不显示。而且需要 `Start-Sleep` 保持进程存活才能看到气泡。

**正确方案**：使用 `BurntToast` 模块：

```powershell
New-BurntToastNotification -Text "Claude Code", "Task complete"
```

**原因**：BurntToast 底层调用 Windows Runtime Toast API，能正确显示 Windows 10/11 风格的 Toast 通知，无需 `Start-Sleep`，且支持操作中心。

---

## 四、完整排查流程（供参考）

遇到 hooks 不工作时，按以下步骤排查：

```
1. 确认 JSON 语法正确
   python -c "import json; json.load(open('settings.json')); print('OK')"

2. 用最简单的命令测试 hook 是否触发
   多个事件 × 简单写文件命令 → 确认哪些事件触发

3. 确认 shell 能执行
   默认 bash（不加 shell 字段）> shell: "powershell"

4. 确认通知脚本能独立运行
   pwsh.exe -NoProfile -File notify.ps1

5. 逐步组装最终配置
   确认每一步都工作后再叠加复杂度
```

---

## 五、最终文件清单

| 文件 | 用途 |
|---|---|
| `~/.claude-zhipu/settings.json` | 智谱模型配置 + hooks |
| `~/.claude-zhipu/notify.ps1` | Toast 通知脚本 |
| `~/.claude-kimi/settings.json` | Kimi 模型配置 + hooks |
| `~/.claude-kimi/notify.ps1` | Toast 通知脚本 |
| `~/.claude-deepseek/settings.json` | DeepSeek 模型配置 + hooks |
| `~/.claude-deepseek/notify.ps1` | Toast 通知脚本 |
| PowerShell Profile | 多模型切换脚本（z/k/d 命令） |
