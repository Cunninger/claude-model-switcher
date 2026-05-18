# Shared PowerShell profile loader helpers for Claude Code Multi-Model Switcher.

$script:ProfileMarkerBegin = "# >>> Claude Code Multi-Model Switcher >>>"
$script:ProfileMarkerEnd   = "# <<< Claude Code Multi-Model Switcher <<<"

function Get-ClaudeSwitcherProfileBlock {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [ValidateSet("full", "brief", "none")]
        [string]$Banner = "brief"
    )

    return @"
$script:ProfileMarkerBegin
`$env:CLAUDE_SWITCHER_BANNER = "$Banner"
. "$ScriptPath"
$script:ProfileMarkerEnd
"@
}

function Remove-ClaudeSwitcherProfileBlock {
    param([AllowNull()][string]$Content)

    if ($null -eq $Content) { $Content = "" }

    $pattern = "(?s)\r?\n?$([regex]::Escape($script:ProfileMarkerBegin)).*?$([regex]::Escape($script:ProfileMarkerEnd))\r?\n?"
    $matches = [regex]::Matches($Content, $pattern)
    $cleanContent = [regex]::Replace($Content, $pattern, "`n").TrimEnd()

    $warning = $null
    if ($cleanContent.Contains($script:ProfileMarkerBegin) -or $cleanContent.Contains($script:ProfileMarkerEnd)) {
        $warning = "Profile contains an incomplete Claude switcher marker block; left unmatched marker content unchanged."
    }

    return [pscustomobject]@{
        Content = $cleanContent
        Removed = $matches.Count -gt 0
        Warning = $warning
    }
}

function Set-ClaudeSwitcherProfileLoader {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [ValidateSet("full", "brief", "none")]
        [string]$Banner = "brief"
    )

    $created = $false
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        New-Item -Path $ProfilePath -ItemType File -Force | Out-Null
        $created = $true
    }

    $content = Get-Content -LiteralPath $ProfilePath -Raw -ErrorAction SilentlyContinue
    $removeResult = Remove-ClaudeSwitcherProfileBlock -Content $content
    $block = Get-ClaudeSwitcherProfileBlock -ScriptPath $ScriptPath -Banner $Banner
    $newContent = if ($removeResult.Content) { "$($removeResult.Content)`n`n$block`n" } else { "$block`n" }

    Set-Content -LiteralPath $ProfilePath -Value $newContent -NoNewline -Encoding UTF8

    return [pscustomobject]@{
        Created = $created
        Removed = $removeResult.Removed
        Warning = $removeResult.Warning
    }
}

function Remove-ClaudeSwitcherProfileLoader {
    param([Parameter(Mandatory)][string]$ProfilePath)

    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        return [pscustomobject]@{
            Exists = $false
            Changed = $false
            Removed = $false
            Warning = $null
        }
    }

    $content = Get-Content -LiteralPath $ProfilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = "" }
    $removeResult = Remove-ClaudeSwitcherProfileBlock -Content $content
    $newContent = $removeResult.Content
    if ($newContent) { $newContent = "$newContent`n" }
    $changed = $newContent -ne $content

    if ($changed) {
        Set-Content -LiteralPath $ProfilePath -Value $newContent -NoNewline -Encoding UTF8
    }

    return [pscustomobject]@{
        Exists = $true
        Changed = $changed
        Removed = $removeResult.Removed
        Warning = $removeResult.Warning
    }
}
