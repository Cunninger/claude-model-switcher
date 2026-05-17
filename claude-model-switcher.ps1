#Requires -PSEdition Core

# Claude Code 多模型切换器（动态注册版）
# 使用方式：
#   1. 运行时加载：. ./claude-model-switcher.ps1
#   2. 添加到 Profile：在 $PROFILE 中写入 . 脚本完整路径
#   3. 添加新模型：直接运行 Add-ClaudeModel，按向导填写即可

# 注意：不在此处设置 $ErrorActionPreference = "Stop"，
# 因为 dot-sourcing 会污染用户会话，导致所有命令出错即终止。
# 改为在需要严格错误处理的函数内部使用 [CmdletBinding()] 或 try/catch。

# ---------- 配置区域 ----------

$script:SharedRoot     = "$env:USERPROFILE\.claude-shared"
$script:SharedConv     = "$script:SharedRoot\conversations"
$script:SharedProjects = "$script:SharedRoot\projects"
$script:RegistryPath   = "$script:SharedRoot\models-registry.json"

# ---------- 内部工具函数 ----------

function ConvertTo-HashtableDeep {
    <#
    递归将 PSCustomObject 转换为 Hashtable，
    统一 JSON 反序列化后的数据类型，避免 Hashtable/PSCustomObject 混用。
    #>
    param([Parameter(ValueFromPipeline)][object]$InputObject)

    process {
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            if ($InputObject -is [System.Collections.IDictionary]) {
                $hash = @{}
                foreach ($key in $InputObject.Keys) {
                    $hash[$key] = ConvertTo-HashtableDeep $InputObject[$key]
                }
                return $hash
            }
            elseif ($InputObject -is [array]) {
                return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
            }
        }
        elseif ($InputObject -is [PSCustomObject]) {
            $hash = @{}
            $InputObject.PSObject.Properties | ForEach-Object {
                $hash[$_.Name] = ConvertTo-HashtableDeep $_.Value
            }
            return $hash
        }
        return $InputObject
    }
}

# ---------- 加载模型注册表 ----------

function Import-ModelRegistry {
    <#
    读取模型注册表 JSON。如果不存在则创建空文件。
    返回 Hashtable，键为模型标识，值为模型元数据。
    #>
    if (-not (Test-Path $script:RegistryPath)) {
        # 首次运行：如果已有传统模型目录，自动迁移到注册表
        $migrated = @{}
        foreach ($legacy in @('zhipu','kimi','deepseek')) {
            $legacyDir = "$env:USERPROFILE\.claude-$legacy"
            if (Test-Path $legacyDir) {
                $migrated[$legacy] = @{
                    name  = $legacy.ToUpper()
                    color = "White"
                    alias = $legacy[0]
                }
            }
        }
        if ($migrated.Count -gt 0) {
            $migrated | ConvertTo-Json -Depth 10 | Set-Content $script:RegistryPath
            Write-Host "已自动迁移现有模型到注册表: $script:RegistryPath" -ForegroundColor Yellow
            return $migrated
        }
        # 纯新环境，创建空注册表（直接写 '{}' 避免 @{} | ConvertTo-Json 在某些 PS 版本输出 []）
        '{}' | Set-Content $script:RegistryPath
        return @{}
    }

    try {
        $raw = Get-Content $script:RegistryPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "注册表 JSON 解析失败: $_，将备份并重建"
        Copy-Item $script:RegistryPath "$script:RegistryPath.bak" -Force -ErrorAction SilentlyContinue
        '{}' | Set-Content $script:RegistryPath
        return @{}
    }
    # ConvertFrom-Json 返回 PSCustomObject，递归转为 Hashtable 统一类型
    if ($raw) {
        return ConvertTo-HashtableDeep $raw
    }
    return @{}
}

$script:Registry = Import-ModelRegistry

# 动态构建 Models 配置（Dir 统一按标识命名）
$script:Models = @{}
foreach ($key in $script:Registry.Keys) {
    $meta = $script:Registry[$key]
    $script:Models[$key] = @{
        Dir   = "$env:USERPROFILE\.claude-$key"
        Name  = $meta.name
        Color = $meta.color
    }
}

# ---------- 内部函数 ----------

function Initialize-SharedDirs {
    <#
    创建共享目录（conversations / projects）
    #>
    $dirs = @($script:SharedConv, $script:SharedProjects)
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
    }
}

function New-DirectoryLink {
    <#
    将 $LinkPath 指向 $TargetPath。
    优先尝试 SymbolicLink（需要管理员或开发者模式），
    失败则回退到 Junction（普通用户可用）。
    #>
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

function Merge-ClaudeSetting {
    <#
    合并基础配置与模型特定配置：
    - 基础配置 (~/.claude/settings.json) 提供通用设置（权限、插件、主题等）
    - 模型目录的 model-specific.json 只保留 env 和 hooks（API 配置和通知脚本）
    - 合并后的配置写入模型目录的 settings.json（自动生成，不应手动编辑）
    #>
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][string]$ConfigDir
    )

    try {
        if (-not (Test-Path $BasePath)) {
            Write-Warning "基础配置不存在: $BasePath，跳过合并"
            return
        }

        $baseJson = Get-Content $BasePath -Raw | ConvertFrom-Json
        $modelSpecificPath = Join-Path $ConfigDir "model-specific.json"
        $modelJson = $null

        # 优先读取 model-specific.json
        if (Test-Path $modelSpecificPath) {
            $modelJson = Get-Content $modelSpecificPath -Raw | ConvertFrom-Json
        }
        # 兼容迁移：如果没有 model-specific.json，尝试从现有 settings.json 中提取
        elseif (Test-Path $ModelPath) {
            $existingJson = Get-Content $ModelPath -Raw | ConvertFrom-Json
            $modelJson = $existingJson | Select-Object env, hooks

            $modelJson | ConvertTo-Json -Depth 10 | Set-Content $modelSpecificPath
            Write-Host "已自动迁移模型差异配置到: $modelSpecificPath" -ForegroundColor Yellow
        }
        # 全新模型：生成空模板
        else {
            $template = [ordered]@{
                env   = @{}
                hooks = @{}
            }
            $template | ConvertTo-Json -Depth 10 | Set-Content $modelSpecificPath
            Write-Warning "新建模型配置模板: $modelSpecificPath，请填写 API 配置后再启动"
            $modelJson = $template
        }

        # 合并：保留模型的 env 和 hooks
        if ($modelJson.env) {
            $baseJson.env = $modelJson.env
        }
        if ($modelJson.hooks) {
            $baseJson.hooks = $modelJson.hooks
        }

        # 标记为自动生成
        $baseJson | Add-Member -NotePropertyName '__generated_by' -NotePropertyValue 'claude-model-switcher' -Force

        # 原子写入（try/finally 确保清理临时文件）
        $tmpPath = "$ModelPath.tmp"
        try {
            $baseJson | ConvertTo-Json -Depth 10 | Set-Content $tmpPath
            Move-Item $tmpPath $ModelPath -Force
        }
        finally {
            if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue }
        }

    }
    catch {
        Write-Warning "配置合并失败: $_"

        if (Test-Path $ModelPath) {
            Write-Host "保留现有 settings.json，使用现有配置启动" -ForegroundColor Yellow
        }
        elseif (Test-Path $BasePath) {
            Copy-Item $BasePath $ModelPath -Force
            Write-Host "已复制基础配置作为保底" -ForegroundColor Yellow
        }
    }
}

function Repair-ClaudeConversation {
    <#
    自动检测并修复未完成的 tool call。
    扫描当前项目最近的 .jsonl 文件，若发现 assistant 消息中有 tool_use
    但没有对应 tool_result，则注入伪造的 user 消息完成链条。
    同时清理 thinking 块、插入模型切换提示、可选截断过长历史。
    支持跨模型 resume 时避免 API 400 错误。
    #>
    param(
        [string]$ProjectDir = $PWD,
        [switch]$DryRun,
        [int]$MaxEvents = 0
    )

    $sanitized = ($ProjectDir -replace ':','') -replace '\\','-'
    $convDir = "$env:USERPROFILE\.claude-shared\projects\$sanitized"
    if (-not (Test-Path $convDir)) { return }

    $files = Get-ChildItem $convDir -Filter "*.jsonl" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $files) { return }

    foreach ($file in $files) {
        $lines = @(Get-Content $file.FullName -Encoding UTF8)
        if ($lines.Count -eq 0) { continue }

        $modified = $false
        $events = $lines | ForEach-Object { $_ | ConvertFrom-Json }

        # ── Step 1: 清理 thinking 块（截断过长 thinking，清理异常 signature）──
        for ($i = 0; $i -lt $events.Count; $i++) {
            $ev = $events[$i]
            if ($ev.type -ne "assistant" -or -not $ev.message.content) { continue }
            foreach ($block in $ev.message.content) {
                if ($block.type -eq "thinking" -and $block.thinking) {
                    $text = $block.thinking
                    if ($text.Length -gt 200) {
                        $block.thinking = $text.Substring(0, 200) + "...[truncated at model switch]"
                        $modified = $true
                    }
                    if ($null -eq $block.signature -or $block.signature -eq $null) {
                        $block | Add-Member -NotePropertyName 'signature' -NotePropertyValue '' -Force
                        $modified = $true
                    }
                }
            }
        }

        # ── Step 2: 检测未闭合的 tool_use ──
        $pending = @{}
        for ($i = 0; $i -lt $events.Count; $i++) {
            $ev = $events[$i]
            if ($ev.type -eq "assistant" -and $ev.message.content) {
                foreach ($block in $ev.message.content) {
                    if ($block.type -eq "tool_use" -and $block.id) {
                        $pending[$block.id] = @{
                            AssistantUuid = $ev.uuid
                            ToolName      = $block.name
                        }
                    }
                }
            }
        }

        # 移除已有 tool_result 匹配的 id
        for ($i = 0; $i -lt $events.Count; $i++) {
            $ev = $events[$i]
            if ($ev.type -eq "user" -and $ev.message.content) {
                foreach ($block in $ev.message.content) {
                    if ($block.type -eq "tool_result" -and $block.tool_use_id) {
                        $pending.Remove($block.tool_use_id)
                    }
                }
            }
        }

        $needsRepair = $pending.Count -gt 0

        if ($needsRepair) {
            Write-Host "发现 $($pending.Count) 个未完成 tool call in $($file.Name)" -ForegroundColor Yellow
        }

        if ($DryRun) {
            foreach ($entry in $pending.Values) {
                Write-Host "  - $($entry.ToolName)"
            }
            if ($modified) { Write-Host "  (thinking 块已清理)" -ForegroundColor DarkGray }
            continue
        }

        # ── Step 3: 重建 JSONL（应用 thinking 清理）──
        $newLines = [System.Collections.Generic.List[string]]::new()
        foreach ($ev in $events) {
            $newLines.Add(($ev | ConvertTo-Json -Depth 10 -Compress))
        }

        if ($modified -and -not $needsRepair) {
            Write-Host "已清理 thinking 块: $($file.Name)" -ForegroundColor DarkGray
        }

        # ── Step 4: 注入 fake tool_result ──
        $lastUuid = $events[-1].uuid
        foreach ($kv in $pending.GetEnumerator()) {
            $toolUseId = $kv.Key
            $entry     = $kv.Value
            $fake = [ordered]@{
                type       = "user"
                parentUuid = $entry.AssistantUuid
                uuid       = [guid]::NewGuid().ToString()
                timestamp  = (Get-Date -Format "o")
                message    = [ordered]@{
                    role    = "user"
                    content = @(
                        [ordered]@{
                            type        = "tool_result"
                            tool_use_id = $toolUseId
                            content     = @(@{ type = "text"; text = "Tool call interrupted by model switch. Please continue based on available context." })
                            is_error    = $true
                        }
                    )
                }
            }
            $fakeLine = $fake | ConvertTo-Json -Depth 10 -Compress
            $newLines.Add($fakeLine)
            $lastUuid = $fake.uuid
            Write-Host "  ✅ 已注入 $($entry.ToolName) 的恢复消息" -ForegroundColor Green
        }

        # ── Step 5: 插入模型切换提示 ──
        if ($needsRepair) {
            $switchHint = [ordered]@{
                type       = "user"
                parentUuid = $lastUuid
                uuid       = [guid]::NewGuid().ToString()
                timestamp  = (Get-Date -Format "o")
                message    = [ordered]@{
                    role    = "user"
                    content = "[System: Model switched. Previous tool calls were interrupted. Continue based on available context.]"
                }
            }
            $newLines.Add(($switchHint | ConvertTo-Json -Depth 10 -Compress))
            Write-Host "  ✅ 已插入模型切换提示" -ForegroundColor Green
        }

        # ── Step 6: 可选历史截断 ──
        if ($MaxEvents -gt 0 -and $newLines.Count -gt $MaxEvents) {
            $headCount = [Math]::Min(5, $newLines.Count)
            $tailCount = [Math]::Min($MaxEvents - $headCount, $newLines.Count - $headCount)
            if ($tailCount -lt 1) { $tailCount = 1 }
            $removedCount = $newLines.Count - $headCount - $tailCount

            $truncated = [System.Collections.Generic.List[string]]::new()
            $truncated.AddRange($newLines.GetRange(0, $headCount))

            # 插入截断摘要
            $lastHeadEvent = $newLines[$headCount - 1] | ConvertFrom-Json
            $truncNotice = [ordered]@{
                type       = "user"
                parentUuid = $lastHeadEvent.uuid
                uuid       = [guid]::NewGuid().ToString()
                timestamp  = (Get-Date -Format "o")
                message    = [ordered]@{
                    role    = "user"
                    content = "[System: Earlier conversation history truncated at model switch. $removedCount events removed.]"
                }
            }
            $truncated.Add(($truncNotice | ConvertTo-Json -Depth 10 -Compress))

            $truncated.AddRange($newLines.GetRange($newLines.Count - $tailCount, $tailCount))
            $newLines = $truncated
            Write-Host "  📏 已截断历史：保留前 $headCount + 后 $tailCount 条（移除 $removedCount 条）" -ForegroundColor DarkGray
        }

        if ($modified -or $needsRepair -or ($MaxEvents -gt 0 -and $newLines.Count -ne $lines.Count)) {
            # 先备份再写入，防止写入中途失败导致对话历史损坏
            Copy-Item $file.FullName "$($file.FullName).bak" -Force -ErrorAction SilentlyContinue
            $newLines | Set-Content $file.FullName -Encoding UTF8
        }
    }
}

function Enter-ClaudeModel {
    <#
    进入指定模型环境：
    1. 确保模型私有配置目录存在
    2. 合并基础通用配置与模型特定的 env/hooks
    3. 将 conversations、projects 链接到共享目录
    4. 将 commands 链接到共享目录（自定义 skill 全模型通用）
    5. 设置 CLAUDE_CONFIG_DIR
    6. 自动修复未完成的 tool call（跨模型 resume 安全）
    #>
    param(
        [Parameter(Mandatory)][string]$ModelKey
    )

    $cfg = $script:Models[$ModelKey]
    if (-not $cfg) {
        Write-Error "未知模型：$ModelKey"
        return
    }

    # 校验颜色值，防止 Write-Host 报错
    $validColors = [System.Enum]::GetNames([System.ConsoleColor])
    if ($cfg.Color -notin $validColors) { $cfg.Color = "White" }

    $configDir = $cfg.Dir

    # 1. 创建私有配置目录
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    # 2. 合并配置
    Merge-ClaudeSetting -BasePath "$env:USERPROFILE\.claude\settings.json" -ModelPath "$configDir\settings.json" -ConfigDir $configDir

    # 3. 链接共享目录
    Initialize-SharedDirs
    New-DirectoryLink -LinkPath "$configDir\conversations" -TargetPath $script:SharedConv
    New-DirectoryLink -LinkPath "$configDir\projects"     -TargetPath $script:SharedProjects

    # 4. 链接 commands 目录（自定义 skill/alias 共享）
    $baseCommandsDir = "$env:USERPROFILE\.claude\commands"
    if (-not (Test-Path $baseCommandsDir)) {
        New-Item -ItemType Directory -Force -Path $baseCommandsDir | Out-Null
    }
    New-DirectoryLink -LinkPath "$configDir\commands" -TargetPath $baseCommandsDir

    # 4b. 链接 skills 目录（第三方 skill 共享）
    $baseSkillsDir = "$env:USERPROFILE\.claude\skills"
    if (-not (Test-Path $baseSkillsDir)) {
        New-Item -ItemType Directory -Force -Path $baseSkillsDir | Out-Null
    }
    New-DirectoryLink -LinkPath "$configDir\skills" -TargetPath $baseSkillsDir

    # 5. 设置环境变量并输出提示
    $env:CLAUDE_CONFIG_DIR = $configDir
    Write-Host "已切换到 $($cfg.Name)" -ForegroundColor $cfg.Color
    Write-Host "Config Dir: $configDir" -ForegroundColor DarkGray
    Write-Host "Shared Conversations: $script:SharedConv" -ForegroundColor DarkGray
    Write-Host "Shared Commands: $baseCommandsDir" -ForegroundColor DarkGray

    # 6. 自动修复未完成的 tool call（跨模型 resume 安全）
    Repair-ClaudeConversation -ProjectDir (Get-Location)
}

function New-ClaudeNotifyScript {
    <#
    为指定模型目录生成 notify.ps1 通知脚本。
    同时在 model-specific.json 中写入对应的 hooks.Stop 配置。
    支持系统预设音效和自定义音频文件（.wav / .mp3）。
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ModelKey,
        [string]$SoundType = "preset",
        [string]$SoundValue = "Reminder"
    )

    $notifyPath = Join-Path $ConfigDir "notify.ps1"
    $modelSpecificPath = Join-Path $ConfigDir "model-specific.json"

    # 生成 notify.ps1 内容
    if ($SoundType -eq "custom") {
        $soundPath = $SoundValue -replace '\\','/'
        $scriptContent = @"
`$time = Get-Date -Format "HH:mm:ss"
`$ext = [System.IO.Path]::GetExtension("$soundPath").ToLower()
if (`$ext -eq ".wav") {
    `$player = New-Object System.Media.SoundPlayer "$soundPath"
    `$player.PlaySync()
}
elseif (`$ext -eq ".mp3") {
    `$wmp = New-Object -ComObject WMPlayer.OCX.7
    `$wmp.URL = "$soundPath"
    `$wmp.controls.play()
    Start-Sleep -Seconds 3
    `$wmp.close()
}
New-BurntToastNotification -Text "Claude Code (`$env:CLAUDE_CONFIG_DIR)", "Task complete (`$time) - your input is needed"
Start-Sleep -Seconds 2
"@
    }
    else {
        $scriptContent = @"
`$time = Get-Date -Format "HH:mm:ss"
New-BurntToastNotification -Text "Claude Code (`$env:CLAUDE_CONFIG_DIR)", "Task complete (`$time) - your input is needed" -Sound "$SoundValue"
"@
    }
    $scriptContent | Set-Content $notifyPath -Encoding UTF8

    # 更新 model-specific.json 的 hooks
    $modelJson = if (Test-Path $modelSpecificPath) {
        Get-Content $modelSpecificPath -Raw | ConvertFrom-Json | ConvertTo-HashtableDeep
    } else { @{ env = @{}; hooks = @{} } }

    if (-not $modelJson.hooks) { $modelJson['hooks'] = @{} }
    if (-not $modelJson.hooks.Contains('Stop')) { $modelJson.hooks['Stop'] = @() }

    # 统一使用正斜杠路径避免 JSON 转义问题
    $notifyPathUnix = $notifyPath -replace '\\','/'
    $hookEntry = @{
        hooks = @(@{
            type = "command"
            command = "pwsh.exe -NoProfile -File $notifyPathUnix"
            async = $true
        })
    }

    $modelJson.hooks['Stop'] = @($hookEntry)

    $modelJson | ConvertTo-Json -Depth 10 | Set-Content $modelSpecificPath

    # 同步更新注册表的 sound 字段
    if ($script:Registry.ContainsKey($ModelKey)) {
        $soundValueToStore = if ($SoundType -eq "custom") { $soundPath } else { $SoundValue }
        $soundObj = @{
            type  = $SoundType
            value = $soundValueToStore
        }
        $entry = $script:Registry[$ModelKey]
        # 注册表已统一为 Hashtable，直接赋值
        $entry['sound'] = $soundObj
        $script:Registry | ConvertTo-Json -Depth 10 | Set-Content $script:RegistryPath
    }
}

function Assert-ClaudeInstalled {
    $claudePath = if ($env:CLAUDE_CLI_PATH) { $env:CLAUDE_CLI_PATH } else { "claude" }
    $cmd = Get-Command $claudePath -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "未找到 claude 命令。请确保 Claude Code CLI 已安装并添加到 PATH，或设置环境变量 `$env:CLAUDE_CLI_PATH = 'C:\完整路径\claude.cmd'"
    }
    return $cmd
}

# ---------- 动态生成模型启动函数 ----------

function Initialize-ModelFunctions {
    <#
    根据注册表动态生成每个模型的启动函数和别名。
    支持脚本重新加载时覆盖旧定义。
    #>
    foreach ($modelKey in $script:Registry.Keys) {
        $meta = $script:Registry[$modelKey]

        # 动态创建函数（使用 global: 作用域确保 dot-sourcing 后可见）
        $funcBody = [scriptblock]::Create(@"
`$claudeCmd = if (`$env:CLAUDE_CLI_PATH) { `$env:CLAUDE_CLI_PATH } else { 'claude' }
Assert-ClaudeInstalled
Enter-ClaudeModel "$modelKey"
& `$claudeCmd @args
"@)
        Set-Item -Path "function:global:$modelKey" -Value $funcBody -Force

        # 创建别名（如果指定）
        if ($meta.alias) {
            if (Get-Alias -Name $meta.alias -ErrorAction SilentlyContinue) {
                Remove-Alias -Name $meta.alias -Force -Scope Global -ErrorAction SilentlyContinue
            }
            Set-Alias -Name $meta.alias -Value $modelKey -Scope Global -Force
        }
    }
}

Initialize-ModelFunctions

# ---------- 公开函数：交互式添加模型 ----------

function Add-ClaudeModel {
    <#
    交互式向导：通过问答方式添加新模型。
    自动创建目录、model-specific.json，并更新注册表。
    添加完成后立即生效，无需重新加载脚本。
    #>
    [CmdletBinding()]
    param()

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    添加新 Claude Code 模型向导" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # --- 步骤 1：模型标识 ---
    Write-Host "`n[1/7] 模型标识" -ForegroundColor Yellow
    Write-Host "用于目录名和函数名，建议英文小写，如 qwen、openai、gpt5" -ForegroundColor DarkGray
    $key = Read-Host "模型标识"
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Error "模型标识不能为空"
        return
    }
    # 清理标识（去除空格和非法字符，转小写）
    $key = $key.Trim().ToLower() -replace '[^a-z0-9_]',''
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Error "模型标识在清理后为空（仅包含特殊字符），请使用字母/数字"
        return
    }
    if ($script:Registry.ContainsKey($key)) {
        Write-Error "模型 '$key' 已存在，请使用其他标识"
        return
    }

    # --- 步骤 2：显示名称 ---
    Write-Host "`n[2/7] 显示名称" -ForegroundColor Yellow
    Write-Host "启动时显示的名称，如 'Qwen 3'、'GPT-5'" -ForegroundColor DarkGray
    $name = Read-Host "显示名称"
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $key
    }

    # --- 步骤 3：快捷别名 ---
    Write-Host "`n[3/7] 快捷别名（可选）" -ForegroundColor Yellow
    Write-Host "单个字母的快捷命令，如 k、z、d。直接回车表示不创建别名" -ForegroundColor DarkGray
    $alias = Read-Host "别名"
    if ($alias) {
        $alias = $alias.Trim().ToLower()
        $existingAlias = $script:Registry.Values | Where-Object { $_.alias -eq $alias }
        if ($existingAlias) {
            Write-Warning "别名 '$alias' 已被使用，将跳过别名创建"
            $alias = $null
        }
    }

    # --- 步骤 4：颜色 ---
    Write-Host "`n[4/7] 选择颜色" -ForegroundColor Yellow
    $colorMap = @("Green","Yellow","White","Red","Cyan","Magenta","Blue")
    for ($i = 0; $i -lt $colorMap.Count; $i++) {
        Write-Host "  $($i + 1). $($colorMap[$i])" -ForegroundColor $colorMap[$i]
    }
    $colorChoice = Read-Host "颜色编号 [1-$($colorMap.Count)]"
    $colorIdx = 0
    if (-not [int]::TryParse($colorChoice, [ref]$colorIdx)) { $colorIdx = 0 }
    $colorIdx--
    if ($colorIdx -lt 0 -or $colorIdx -ge $colorMap.Count) {
        $color = "White"
        Write-Warning "无效选择，使用默认颜色 White"
    }
    else {
        $color = $colorMap[$colorIdx]
    }

    # --- 步骤 5：API 配置 ---
    Write-Host "`n[5/7] API 配置" -ForegroundColor Yellow
    Write-Host "以下参数可在创建后随时修改 model-specific.json 调整" -ForegroundColor DarkGray
    $baseUrl  = Read-Host "API Base URL"
    $apiKey   = Read-Host "API Key     （输入内容仅在本地显示）"
    $modelId  = Read-Host "模型名称    （如 qwen3-235b-a22b、deepseek-v4-pro）"

    # --- 步骤 6：通知音效 ---
    Write-Host "`n[6/7] 通知音效（可选）" -ForegroundColor Yellow
    Write-Host "Claude 回复完毕时的 Windows Toast 通知音效" -ForegroundColor DarkGray
    $soundMap = @(
        @{ Name="无音效"; Value="Silent"; Type="preset" },
        @{ Name="提醒 (Reminder, 推荐)"; Value="Reminder"; Type="preset" },
        @{ Name="默认 (Default)"; Value="Default"; Type="preset" },
        @{ Name="即时消息 (IM)"; Value="IM"; Type="preset" },
        @{ Name="邮件 (Mail)"; Value="Mail"; Type="preset" },
        @{ Name="短信 (SMS)"; Value="SMS"; Type="preset" },
        @{ Name="闹钟 (Alarm)"; Value="Alarm"; Type="preset" },
        @{ Name="来电 (Call)"; Value="Call"; Type="preset" },
        @{ Name="自定义音频文件 (.wav / .mp3)"; Value=""; Type="custom" }
    )
    for ($i = 0; $i -lt $soundMap.Count; $i++) {
        Write-Host "  $($i + 1). $($soundMap[$i].Name)" -ForegroundColor DarkGray
    }
    $soundChoice = Read-Host "音效编号 [1-$($soundMap.Count)]"
    $soundIdx = 0
    if (-not [int]::TryParse($soundChoice, [ref]$soundIdx)) { $soundIdx = 0 }
    $soundIdx--
    if ($soundIdx -lt 0 -or $soundIdx -ge $soundMap.Count) {
        $soundType = "preset"
        $soundValue = "Reminder"
        Write-Warning "无效选择，使用默认音效 Reminder"
    }
    elseif ($soundMap[$soundIdx].Type -eq "custom") {
        $soundType = "custom"
        $customPath = Read-Host "音频文件绝对路径（如 C:\\Music\\notify.wav）"
        if (-not (Test-Path $customPath)) {
            Write-Warning "文件不存在，回退到默认音效 Reminder"
            $soundType = "preset"
            $soundValue = "Reminder"
        }
        elseif ($customPath -notmatch '\.(wav|mp3)$') {
            Write-Warning "仅支持 .wav 或 .mp3，回退到默认音效 Reminder"
            $soundType = "preset"
            $soundValue = "Reminder"
        }
        else {
            $soundValue = $customPath
        }
    }
    else {
        $soundType = "preset"
        $soundValue = $soundMap[$soundIdx].Value
    }
    $soundDisplay = if ($soundType -eq "custom") { "自定义: $soundValue" } else { ($soundMap | Where-Object { $_.Value -eq $soundValue -and $_.Type -eq "preset" }).Name }
    if (-not $soundDisplay) { $soundDisplay = $soundValue }

    # --- 步骤 7：确认 ---
    Write-Host "`n========================================" -ForegroundColor Yellow
    Write-Host "请确认以下信息：" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    Write-Host " 模型标识 : $key"
    Write-Host " 显示名称 : $name"
    Write-Host " 快捷别名 : $(if ($alias) { $alias } else { '（无）' })"
    Write-Host " 终端颜色 : $color"
    Write-Host " 配置目录 : $env:USERPROFILE\.claude-$key"
    Write-Host " API 地址 : $baseUrl"
    Write-Host " 模型名称 : $modelId"
    Write-Host " 通知音效 : $soundDisplay"
    Write-Host "========================================"

    $confirm = Read-Host "`n确认创建？ [Y/n]"
    if ($confirm -and $confirm.Trim().ToLower() -notin @('y','yes')) {
        Write-Host "`n已取消创建。" -ForegroundColor Red
        return
    }

    # --- 执行创建 ---
    try {
        $configDir = "$env:USERPROFILE\.claude-$key"

        # 1. 创建目录
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
        Write-Host "✅ 已创建配置目录" -ForegroundColor Green

        # 2. 创建 model-specific.json
        $modelSpecific = [ordered]@{
            env = [ordered]@{
                ANTHROPIC_BASE_URL              = $baseUrl
                ANTHROPIC_AUTH_TOKEN            = $apiKey
                ANTHROPIC_MODEL                 = $modelId
                ANTHROPIC_DEFAULT_HAIKU_MODEL   = $modelId
                ANTHROPIC_DEFAULT_OPUS_MODEL    = $modelId
                ANTHROPIC_DEFAULT_SONNET_MODEL  = $modelId
                ANTHROPIC_REASONING_MODEL       = $modelId
            }
            hooks = @{}
        }
        $modelSpecific | ConvertTo-Json -Depth 10 | Set-Content "$configDir\model-specific.json"
        Write-Host "✅ 已生成 model-specific.json" -ForegroundColor Green

        # 2b. 生成 notify.ps1 和 hooks
        New-ClaudeNotifyScript -ConfigDir $configDir -ModelKey $key -SoundType $soundType -SoundValue $soundValue
        Write-Host "✅ 已生成 notify.ps1 (音效: $soundDisplay)" -ForegroundColor Green

        # 3. 更新注册表
        $script:Registry[$key] = @{
            name  = $name
            color = $color
            alias = $alias
            sound = @{
                type  = $soundType
                value = if ($soundType -eq "custom") { $soundValue -replace '\\','/' } else { $soundValue }
            }
        }
        $script:Registry | ConvertTo-Json -Depth 10 | Set-Content $script:RegistryPath

        # 4. 动态注册到当前会话（global 作用域确保立即可用）
        $funcBody = [scriptblock]::Create(@"
`$claudeCmd = if (`$env:CLAUDE_CLI_PATH) { `$env:CLAUDE_CLI_PATH } else { 'claude' }
Assert-ClaudeInstalled
Enter-ClaudeModel "$key"
& `$claudeCmd @args
"@)
        Set-Item -Path "function:global:$key" -Value $funcBody -Force
        $script:Models[$key] = @{
            Dir   = $configDir
            Name  = $name
            Color = $color
        }
        if ($alias) {
            if (Get-Alias -Name $alias -ErrorAction SilentlyContinue) {
                Remove-Alias -Name $alias -Force -Scope Global -ErrorAction SilentlyContinue
            }
            Set-Alias -Name $alias -Value $key -Scope Global -Force
        }
        Write-Host "✅ 已注册到模型列表" -ForegroundColor Green

        # 5. 完成提示
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host " 模型 '$name' 创建成功！" -ForegroundColor Green
        Write-Host "========================================"
        if ($alias) {
            Write-Host " 输入 '$alias' 或 '$key' 即可启动" -ForegroundColor Cyan
        }
        else {
            Write-Host " 输入 '$key' 即可启动" -ForegroundColor Cyan
        }
        Write-Host "`n如需修改 API 配置，请编辑：" -ForegroundColor Gray
        Write-Host "  $configDir\model-specific.json" -ForegroundColor DarkGray
        Write-Host "`n如需修改显示名称/颜色/别名，请编辑：" -ForegroundColor Gray
        Write-Host "  $script:RegistryPath" -ForegroundColor DarkGray

    }
    catch {
        Write-Error "创建模型失败: $_"
    }
}

# ---------- 公开函数：交互式删除模型 ----------

function Remove-ClaudeModel {
    <#
    交互式向导：删除已注册的模型。
    会删除配置目录并从注册表中移除，同时清理函数和别名。
    需要二次确认防止误删。
    #>
    [CmdletBinding()]
    param()

    # 检查是否有模型可删除
    if ($script:Registry.Count -eq 0) {
        Write-Warning "当前没有已注册的模型"
        return
    }

    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "    删除 Claude Code 模型" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red

    # 列出当前模型
    Write-Host "`n当前已注册的模型：" -ForegroundColor Yellow
    $idx = 1
    $keyMap = @{}
    foreach ($key in $script:Registry.Keys | Sort-Object) {
        $meta = $script:Registry[$key]
        $aliasInfo = if ($meta.alias) { " [别名: $($meta.alias)]" } else { "" }
        Write-Host "  $idx. $($meta.name)$aliasInfo" -ForegroundColor $meta.color
        $keyMap["$idx"] = $key
        $idx++
    }

    # 选择要删除的模型
    $choice = Read-Host "`n要删除的模型编号"
    if (-not $keyMap.ContainsKey($choice)) {
        Write-Error "无效的选择"
        return
    }

    $modelKey = $keyMap[$choice]
    $meta = $script:Registry[$modelKey]
    $configDir = "$env:USERPROFILE\.claude-$modelKey"

    # 显示要删除的内容
    Write-Host "`n即将删除以下模型：" -ForegroundColor Red
    Write-Host "  模型标识 : $modelKey" -ForegroundColor Yellow
    Write-Host "  显示名称 : $($meta.name)" -ForegroundColor Yellow
    Write-Host "  配置目录 : $configDir" -ForegroundColor Yellow
    if (Test-Path $configDir) {
        $size = (Get-ChildItem $configDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Write-Host "  目录大小 : $([math]::Round($size / 1KB, 2)) KB" -ForegroundColor Yellow
    }

    # 二次确认
    Write-Host "`n⚠️  此操作不可恢复！" -ForegroundColor Red
    $confirm = Read-Host "输入模型标识 '$modelKey' 以确认删除（输入其他内容取消）"
    if ($confirm -ne $modelKey) {
        Write-Host "`n已取消删除。" -ForegroundColor Green
        return
    }

    # 执行删除
    try {
        # 1. 删除配置目录（先安全移除所有 Junction/Link，防止跟随删除共享数据）
        if (Test-Path $configDir) {
            # 按名称逐一移除已知链接，避免遗漏嵌套的 ReparsePoint
            $knownLinks = @('conversations','projects','commands','skills')
            foreach ($link in $knownLinks) {
                $linkPath = Join-Path $configDir $link
                $item = Get-Item $linkPath -Force -ErrorAction SilentlyContinue
                if ($item -and $item.Attributes -match "ReparsePoint") {
                    cmd /c "rmdir `"$linkPath`"" 2>$null
                }
            }
            # 二次检查：如果仍有 ReparsePoint 残留，中止删除以保护共享数据
            $remainingReparse = Get-ChildItem $configDir -Force -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -match "ReparsePoint" }
            if ($remainingReparse) {
                Write-Error "检测到残留的符号链接，中止删除以保护共享数据：$($remainingReparse.FullName -join ', ')"
                return
            }
            Remove-Item $configDir -Recurse -Force
            Write-Host "✅ 已删除配置目录: $configDir" -ForegroundColor Green
        }
        else {
            Write-Host "⚠️  配置目录不存在，跳过: $configDir" -ForegroundColor Yellow
        }

        # 2. 从注册表移除
        $aliasToRemove = $meta.alias
        $script:Registry.Remove($modelKey)
        $script:Registry | ConvertTo-Json -Depth 10 | Set-Content $script:RegistryPath
        Write-Host "✅ 已从注册表移除" -ForegroundColor Green

        # 3. 从 Models 哈希表移除
        $script:Models.Remove($modelKey)

        # 4. 移除函数
        if (Test-Path "function:global:$modelKey") {
            Remove-Item "function:global:$modelKey" -Force
            Write-Host "✅ 已移除函数: $modelKey" -ForegroundColor Green
        }

        # 5. 移除别名
        if ($aliasToRemove -and (Get-Alias -Name $aliasToRemove -ErrorAction SilentlyContinue)) {
            Remove-Alias -Name $aliasToRemove -Force -Scope Global
            Write-Host "✅ 已移除别名: $aliasToRemove" -ForegroundColor Green
        }

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host " 模型 '$($meta.name)' 已彻底删除" -ForegroundColor Green
        Write-Host "========================================"
        Write-Host "`n剩余模型: $($script:Registry.Keys -join ', ')" -ForegroundColor Gray

    }
    catch {
        Write-Error "删除模型失败: $_"
    }
}

# ---------- 公开函数：批量修复通知脚本 ----------

function Repair-ClaudeNotify {
    <#
    为所有已注册模型批量生成/更新 notify.ps1 和 hooks 配置。
    用于：1) 首次迁移现有模型 2) 统一更换所有模型的通知音效
    #>
    [CmdletBinding()]
    param(
        [string]$Sound = "Reminder",
        [switch]$Interactive
    )

    if ($Interactive) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "    批量修复通知脚本（交互模式）" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "将逐个模型配置通知音效`n" -ForegroundColor Yellow

        foreach ($key in $script:Registry.Keys | Sort-Object) {
            $meta = $script:Registry[$key]
            Write-Host "`n----------------------------------------" -ForegroundColor DarkGray
            Write-Host " 正在配置: $($meta.name) [$key]" -ForegroundColor $meta.color
            Write-Host "----------------------------------------" -ForegroundColor DarkGray
            Set-ClaudeModelSound -ModelKey $key
        }
        Write-Host "`n全部完成！" -ForegroundColor Green
        return
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    批量修复通知脚本" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "目标音效: $Sound`n" -ForegroundColor Yellow

    foreach ($key in $script:Registry.Keys | Sort-Object) {
        $configDir = "$env:USERPROFILE\.claude-$key"
        if (-not (Test-Path $configDir)) {
            Write-Warning "目录不存在，跳过: $configDir"
            continue
        }
        New-ClaudeNotifyScript -ConfigDir $configDir -ModelKey $key -SoundType "preset" -SoundValue $Sound
        Write-Host "✅ $key" -ForegroundColor Green
    }

    Write-Host "`n全部完成！" -ForegroundColor Green
}

# ---------- 公开函数：交互式修改模型音效 ----------

function Set-ClaudeModelSound {
    <#
    交互式向导：选择模型并修改其通知音效。
    支持系统预设音效和自定义音频文件（.wav / .mp3）。
    #>
    [CmdletBinding()]
    param(
        [string]$ModelKey = ""
    )

    # --- 步骤 1：选择模型（若未通过参数指定）---
    if (-not $ModelKey) {
        Write-Host "`n当前已注册的模型：" -ForegroundColor Yellow
        $idx = 1
        $keyMap = @{}
        foreach ($k in $script:Registry.Keys | Sort-Object) {
            $meta = $script:Registry[$k]
            $aliasInfo = if ($meta.alias) { " [别名: $($meta.alias)]" } else { "" }
            Write-Host "  $idx. $($meta.name)$aliasInfo" -ForegroundColor $meta.color
            $keyMap["$idx"] = $k
            $idx++
        }
        $choice = Read-Host "`n要修改音效的模型编号/标识/别名"
        $ModelKey = $null
        if ($keyMap.ContainsKey($choice)) {
            $ModelKey = $keyMap[$choice]
        }
        elseif ($script:Registry.ContainsKey($choice)) {
            $ModelKey = $choice
        }
        else {
            $matched = $script:Registry.GetEnumerator() | Where-Object { $_.Value.alias -eq $choice } | Select-Object -First 1
            if ($matched) { $ModelKey = $matched.Key }
        }
        if (-not $ModelKey) {
            Write-Error "无效的选择"
            return
        }
    }

    if (-not $script:Registry.ContainsKey($ModelKey)) {
        Write-Error "未知模型: $ModelKey"
        return
    }

    $meta = $script:Registry[$ModelKey]
    $configDir = "$env:USERPROFILE\.claude-$ModelKey"

    # --- 步骤 2：选择音效类型 ---
    Write-Host "`n[$($meta.name)] 选择音效类型：" -ForegroundColor Yellow
    Write-Host "  1. 系统预设音效" -ForegroundColor DarkGray
    Write-Host "  2. 自定义音频文件 (.wav / .mp3)" -ForegroundColor DarkGray
    $typeChoice = Read-Host "类型编号 [1-2]"

    $soundType = "preset"
    $soundValue = "Reminder"

    if ($typeChoice -eq "2") {
        $soundType = "custom"
        $customPath = Read-Host "音频文件绝对路径（如 C:\\Music\\notify.wav）"
        if (-not (Test-Path $customPath)) {
            Write-Warning "文件不存在，回退到默认音效 Reminder"
            $soundType = "preset"
            $soundValue = "Reminder"
        }
        elseif ($customPath -notmatch '\.(wav|mp3)$') {
            Write-Warning "仅支持 .wav 或 .mp3，回退到默认音效 Reminder"
            $soundType = "preset"
            $soundValue = "Reminder"
        }
        else {
            $soundValue = $customPath
        }
    }
    else {
        $soundType = "preset"
        $soundMap = @(
            @{ Name="无音效"; Value="Silent" },
            @{ Name="提醒 (Reminder, 推荐)"; Value="Reminder" },
            @{ Name="默认 (Default)"; Value="Default" },
            @{ Name="即时消息 (IM)"; Value="IM" },
            @{ Name="邮件 (Mail)"; Value="Mail" },
            @{ Name="短信 (SMS)"; Value="SMS" },
            @{ Name="闹钟 (Alarm)"; Value="Alarm" },
            @{ Name="来电 (Call)"; Value="Call" }
        )
        for ($i = 0; $i -lt $soundMap.Count; $i++) {
            Write-Host "  $($i + 1). $($soundMap[$i].Name)" -ForegroundColor DarkGray
        }
        $presetChoice = Read-Host "音效编号 [1-$($soundMap.Count)]"
        $presetIdx = 0
        if (-not [int]::TryParse($presetChoice, [ref]$presetIdx)) { $presetIdx = 0 }
        $presetIdx--
        if ($presetIdx -lt 0 -or $presetIdx -ge $soundMap.Count) {
            $soundValue = "Reminder"
            Write-Warning "无效选择，使用默认音效 Reminder"
        }
        else {
            $soundValue = $soundMap[$presetIdx].Value
        }
    }

    $soundDisplay = if ($soundType -eq "custom") { "自定义: $soundValue" } else { $soundValue }

    # --- 步骤 3：确认 ---
    Write-Host "`n----------------------------------------" -ForegroundColor Yellow
    Write-Host " 模型 : $($meta.name)" -ForegroundColor Yellow
    Write-Host " 音效 : $soundDisplay" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $confirm = Read-Host "确认修改？ [Y/n]"
    if ($confirm -and $confirm.Trim().ToLower() -notin @('y','yes')) {
        Write-Host "已取消修改。" -ForegroundColor Red
        return
    }

    # --- 步骤 4：执行更新 ---
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }
    New-ClaudeNotifyScript -ConfigDir $configDir -ModelKey $ModelKey -SoundType $soundType -SoundValue $soundValue
    Write-Host "✅ $($meta.name) 音效已更新为: $soundDisplay" -ForegroundColor Green

    # --- 步骤 5：试听 ---
    $test = Read-Host "`n是否立即试听？ [Y/n]"
    if (-not $test -or $test.Trim().ToLower() -in @('y','yes')) {
        Test-ModelNotify -ModelKey $ModelKey
    }
}

# ---------- 公开函数：试听模型通知 ----------

function Test-ModelNotify {
    <#
    立即执行指定模型的 notify.ps1，试听/试看通知效果。
    若未指定 ModelKey，尝试从 $env:CLAUDE_CONFIG_DIR 推断当前模型。
    #>
    [CmdletBinding()]
    param(
        [string]$ModelKey = ""
    )

    # 推断模型
    if (-not $ModelKey) {
        if ($env:CLAUDE_CONFIG_DIR -and ($env:CLAUDE_CONFIG_DIR -match '\\\.claude-([^\\]+)$')) {
            $ModelKey = $matches[1]
        }
        else {
            Write-Error "未指定模型，且无法从 CLAUDE_CONFIG_DIR 推断。请提供 ModelKey 参数。"
            return
        }
    }

    $configDir = "$env:USERPROFILE\.claude-$ModelKey"
    $notifyPath = Join-Path $configDir "notify.ps1"

    if (-not (Test-Path $notifyPath)) {
        Write-Error "通知脚本不存在: $notifyPath。请先为该模型生成通知配置。"
        return
    }

    Write-Host "`n🎵 正在试听 $($ModelKey) 的通知效果..." -ForegroundColor Cyan
    try {
        & pwsh.exe -NoProfile -File $notifyPath
        Write-Host "✅ 试听完成" -ForegroundColor Green
    }
    catch {
        Write-Error "试听失败: $_"
    }
}

# ---------- 提示 ----------

if (-not (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)) {
    Write-Warning "未检测到 BurntToast 模块，通知功能不可用。安装命令: Install-Module -Name BurntToast -Scope CurrentUser"
}

Write-Host "Claude Code 多模型切换器已加载" -ForegroundColor Green
Write-Host "已注册模型: $($script:Registry.Keys -join ', ')" -ForegroundColor Gray
Write-Host "命令: $(($script:Registry.Values | ForEach-Object { if ($_.alias) { "$($_.alias) ($($_.name))" } else { "$($_.name)" } }) -join ', ')" -ForegroundColor Gray
Write-Host "添加新模型: 运行 Add-ClaudeModel" -ForegroundColor Cyan
Write-Host "删除模型: 运行 Remove-ClaudeModel" -ForegroundColor Red
Write-Host "修复通知脚本: 运行 Repair-ClaudeNotify" -ForegroundColor Cyan
Write-Host "修改模型音效: 运行 Set-ClaudeModelSound" -ForegroundColor Cyan
Write-Host "试听通知效果: 运行 Test-ModelNotify" -ForegroundColor Cyan
Write-Host "修复对话状态: 运行 Repair-ClaudeConversation" -ForegroundColor Cyan
Write-Host "对话历史共享目录: $script:SharedRoot" -ForegroundColor DarkGray
