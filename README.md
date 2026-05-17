# Claude Code 多模型切换器 / Claude Code Multi-Model Switcher

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

## 简介

一个 PowerShell 脚本，让 Claude Code CLI 在多个 AI 模型（OpenAI、DeepSeek、Qwen 等）之间一键切换，同时共享对话历史和自定义命令。

## 功能特性

- **一键切换** — 输入模型名或快捷别名即可启动对应模型的 Claude Code
- **对话历史共享** — 所有模型的对话存储在统一目录，跨模型可 resume
- **配置自动合并** — 基础配置 + 模型特定配置自动合并，无需手动维护多份 settings.json
- **交互式添加模型** — `Add-ClaudeModel` 向导引导完成全部配置
- **跨模型 Resume 安全** — 自动修复未完成的 tool call，避免切换模型后 400 错误
- **Windows Toast 通知** — 任务完成时弹出通知 + 音效提醒
- **动态注册** — 添加/删除模型后立即生效，无需重新加载脚本

## 前置依赖

| 依赖 | 必要性 | 安装方式 |
|---|---|---|
| [PowerShell 7+](https://github.com/PowerShell/PowerShell) | 必须 | `winget install Microsoft.PowerShell` |
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | 必须 | `npm install -g @anthropic-ai/claude-code` |
| [BurntToast](https://github.com/Windos/BurntToast) | 可选（通知功能） | `Install-Module -Name BurntToast -Scope CurrentUser` |

> 仅支持 Windows（使用 Junction/SymbolicLink、Toast 通知等 Windows 特性）。

## 快速开始

```powershell
# 1. Clone 仓库
git clone https://github.com/cunninger/claude-model-switcher.git
cd claude-model-switcher

# 2. 加载脚本（dot-source）
. ./claude-model-switcher.ps1

# 3. 添加第一个模型（交互式向导）
Add-ClaudeModel

# 4. 启动！
# 假设你添加了模型标识 "deepseek"，别名 "d"
deepseek          # 或直接输入别名
d                 # 快捷方式
```

## 持久化加载

将以下内容添加到 PowerShell Profile 中，每次打开终端自动加载：

```powershell
# 在 $PROFILE 中添加
. "D:\你的路径\claude-model-switcher.ps1"
```

## 命令列表

| 命令 | 说明 |
|---|---|
| `Add-ClaudeModel` | 交互式添加新模型 |
| `Remove-ClaudeModel` | 交互式删除模型 |
| `Repair-ClaudeNotify` | 批量修复/更新所有模型的通知脚本 |
| `Set-ClaudeModelSound` | 修改指定模型的通知音效 |
| `Test-ModelNotify` | 试听通知效果 |
| `Repair-ClaudeConversation` | 修复对话中未完成的 tool call |

## 配置文件说明

```
~/.claude-shared/                    # 共享数据根目录
├── conversations/                   # 所有模型的共享对话（Junction 链接）
├── projects/                        # 所有模型的共享项目（Junction 链接）
└── models-registry.json             # 模型注册表

~/.claude-<model>/                   # 每个模型的私有目录
├── settings.json                    # 自动生成，勿手动编辑
├── model-specific.json              # 模型特定配置（API 地址、Key、Hooks）
├── notify.ps1                       # 通知脚本（自动生成）
├── conversations/ → ~/.claude-shared/conversations/  # Junction
├── projects/       → ~/.claude-shared/projects/       # Junction
├── commands/       → ~/.claude/commands/               # Junction
└── skills/         → ~/.claude/skills/                 # Junction
```

### model-specific.json 示例

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-xxx",
    "ANTHROPIC_MODEL": "deepseek-chat"
  },
  "hooks": {}
}
```

## 配套文档

- [通知配置指南](claude-code-notification-guide.md) — 详细说明 Toast 通知和自定义音效的配置

## License

[GPL-3.0](LICENSE)

---

<a id="english"></a>

## Overview

A PowerShell script that lets the Claude Code CLI switch between multiple AI models (OpenAI, DeepSeek, Qwen, etc.) with a single command, while sharing conversation history and custom commands across all models.

## Features

- **One-command switching** — Launch Claude Code with a specific model by typing its name or alias
- **Shared conversation history** — All models share a single conversation store; resume works across models
- **Auto-merged config** — Base settings + model-specific settings are merged automatically
- **Interactive model wizard** — `Add-ClaudeModel` walks you through the full setup
- **Safe cross-model resume** — Automatically repairs incomplete tool calls to prevent API 400 errors
- **Windows Toast notifications** — Desktop notification + sound when Claude finishes
- **Dynamic registration** — Added/removed models take effect immediately

## Prerequisites

| Dependency | Required | Installation |
|---|---|---|
| [PowerShell 7+](https://github.com/PowerShell/PowerShell) | Yes | `winget install Microsoft.PowerShell` |
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | Yes | `npm install -g @anthropic-ai/claude-code` |
| [BurntToast](https://github.com/Windos/BurntToast) | Optional (notifications) | `Install-Module -Name BurntToast -Scope CurrentUser` |

> Windows only — uses Junctions/SymbolicLinks, Toast notifications, and other Windows-specific features.

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/cunninger/claude-model-switcher.git
cd claude-model-switcher

# 2. Load the script (dot-source)
. ./claude-model-switcher.ps1

# 3. Add your first model (interactive wizard)
Add-ClaudeModel

# 4. Launch!
# If you added a model with key "deepseek" and alias "d":
deepseek          # or just type the alias
d                 # shortcut
```

## Persist Across Sessions

Add to your PowerShell `$PROFILE` for auto-loading:

```powershell
. "C:\path\to\claude-model-switcher.ps1"
```

## Commands

| Command | Description |
|---|---|
| `Add-ClaudeModel` | Add a new model (interactive wizard) |
| `Remove-ClaudeModel` | Remove a model (interactive, with confirmation) |
| `Repair-ClaudeNotify` | Batch repair/update notification scripts for all models |
| `Set-ClaudeModelSound` | Change notification sound for a specific model |
| `Test-ModelNotify` | Preview notification effect |
| `Repair-ClaudeConversation` | Fix incomplete tool calls in conversation history |

## License

[GPL-3.0](LICENSE)
