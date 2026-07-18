#!/usr/bin/env pwsh
# ccstatusline-install.ps1 — installs/updates/uninstalls ccstatusline with a
# Claude Code usage widget, for native Windows (PowerShell 5.1+ or 7+).
# Mirrors ccstatusline-install.sh (macOS/Linux). Only real dependency: Node.js
# (used for npx and, via ConvertFrom-Json, isn't even needed for JSON here).
#
# Usage:
#   .\ccstatusline-install.ps1              interactive install/repair
#   .\ccstatusline-install.ps1 -Uninstall   remove ccstatusline + aliases
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Section($msg) { Write-Host ""; Write-Host "▸ $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "  ✓ $msg" -ForegroundColor Green }
function WarnMsg($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function FailMsg($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Info($msg)    { Write-Host "  · $msg" -ForegroundColor DarkGray }
function Test-Tool([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

Write-Host "╭─────────────────────────────────────────────╮"
Write-Host "│  ccstatusline · Windows installer for Claude │"
Write-Host "╰─────────────────────────────────────────────╯"

Info "Platform: windows"

$CcstatusDir = Join-Path $HOME ".config\ccstatusline"
$CcstatusSettings = Join-Path $CcstatusDir "settings.json"

# Windows PowerShell 5.1 (the one that ships with Windows) and PowerShell 7+
# use different CurrentUserAllHosts profile files, and most machines have
# both installed. Writing the alias to only whichever one launched this
# script means it silently "doesn't work" in the other shell, so both known
# locations are targeted regardless of which one is running right now.
$ProfilePaths = @(
    (Join-Path $HOME "Documents\WindowsPowerShell\profile.ps1"),
    (Join-Path $HOME "Documents\PowerShell\profile.ps1")
) | Select-Object -Unique

# ============================================================
# Checking required tools
# ============================================================
function Install-Node {
    if (Test-Tool node) { Ok "Node.js detected ($(node -v))"; return $true }
    WarnMsg "Node.js not found. Installing it (needed to run ccstatusline via npx)..."
    if (Test-Tool winget) {
        # Per-user install: no admin elevation prompt, and it lands in this
        # user's own profile instead of a machine-wide location. Falls back to
        # a plain (machine-scope) install if the manifest doesn't support
        # --scope user.
        winget install -e --id OpenJS.NodeJS.LTS --scope user --accept-source-agreements --accept-package-agreements | Out-Null
        if (-not (Test-Tool node)) {
            winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements | Out-Null
        }
    } elseif (Test-Tool choco) {
        choco install nodejs-lts -y | Out-Null
    } else {
        FailMsg "No supported package manager found (winget/choco). Install Node.js manually: https://nodejs.org/"
        return $false
    }
    if (-not (Test-Tool node)) {
        FailMsg "Node.js was installed but isn't on PATH yet. Close and reopen your terminal, then re-run this script."
        return $false
    }
    Ok "Node.js installed successfully ($(node -v))"
    return $true
}

Section "Checking required tools"
if (-not (Install-Node)) { exit 1 }

# ============================================================
# Resolve the real claude.exe path, so generated aliases call it
# directly instead of depending on shell resolution at call time.
# ============================================================
function Resolve-ClaudeBin {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $HOME ".local\bin\claude.exe"),
        (Join-Path $HOME ".claude\local\claude.exe")
    )
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA "npm\claude.cmd") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\claude.exe") }

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$ClaudeRealBin = Resolve-ClaudeBin
if ($ClaudeRealBin) {
    Ok "Resolved claude binary: $ClaudeRealBin"
} else {
    WarnMsg "Could not resolve an absolute path for 'claude'. Aliases will call 'claude' directly, so any existing function in your profile still works."
}

$CcstatuslineInstalled = Test-Path $CcstatusSettings

$existDirsRaw = @(Get-ChildItem -Path $HOME -Directory -Filter ".claude-*" -Force -ErrorAction SilentlyContinue)
$ExistNames = @(); $ExistDirs = @()
foreach ($d in $existDirsRaw) {
    $ExistNames += ($d.Name -replace '^\.claude-', '')
    $ExistDirs += $d.FullName
}

# ============================================================
# Uninstall
# ============================================================
function Remove-AliasBlock([string]$name) {
    foreach ($p in $ProfilePaths) {
        if (-not (Test-Path $p)) { continue }
        $content = Get-Content $p -Raw
        if (-not $content) { continue }
        $pattern = "(?ms)\r?\n?# ccstatusline-alias:$([regex]::Escape($name)) start.*?# ccstatusline-alias:$([regex]::Escape($name)) end\r?\n?"
        $new = [regex]::Replace($content, $pattern, "`n")
        Set-Content -Path $p -Value $new.Trim("`n") -NoNewline
    }
}

function Invoke-Uninstall {
    Section "Uninstalling ccstatusline"
    if (-not $CcstatuslineInstalled -and $ExistNames.Count -eq 0) {
        Info "Nothing to uninstall — no ccstatusline config or accounts found."
        exit 0
    }
    $confirm = Read-Host "  Remove ccstatusline config, statusLine settings and PowerShell aliases. Continue? [y/N]"
    if ($confirm.ToLower() -notin @('y', 'yes')) {
        Info "Uninstall cancelled."
        exit 0
    }

    for ($i = 0; $i -lt $ExistNames.Count; $i++) {
        $d = $ExistDirs[$i]; $name = $ExistNames[$i]
        $settingsFile = Join-Path $d "settings.json"
        if (Test-Path $settingsFile) {
            try {
                $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
                if ($s.PSObject.Properties.Match('statusLine').Count -gt 0) {
                    $s.PSObject.Properties.Remove('statusLine')
                }
                $s | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsFile
                Ok "Removed statusLine from $settingsFile"
            } catch { }
        }
        Remove-AliasBlock $name
        Ok "Removed alias claude-$name from PowerShell profiles"
    }
    if (Test-Path $CcstatusDir) {
        Remove-Item -Recurse -Force $CcstatusDir
        Ok "Removed $CcstatusDir"
    }

    Write-Host ""
    Write-Host "== Uninstall complete ==" -ForegroundColor Green
    Write-Host "Account directories (~\.claude-*) were kept — they may hold credentials unrelated to ccstatusline."
    Write-Host "Open a new terminal to apply the alias removal."
    exit 0
}

if ($Uninstall) { Invoke-Uninstall }

# ============================================================
# Menu
# ============================================================
$Mode = "fresh"
if ($CcstatuslineInstalled) {
    Section "Existing installation detected"
    foreach ($n in $ExistNames) { Ok "Active account: '$n'" }
    Write-Host ""
    Write-Host "  What would you like to do?"
    Write-Host "    1) Repair aliases and update statusline (Recommended)"
    Write-Host "    2) Reconfigure everything from scratch"
    Write-Host "    3) Uninstall ccstatusline and remove aliases"
    $menuChoice = Read-Host "  Choose an option [1]"
    switch ($menuChoice) {
        "2" { $Mode = "reset" }
        "3" { Invoke-Uninstall }
        default { $Mode = "verify" }
    }
}

# ============================================================
# Account slots
# ============================================================
$AllCfgDirs = @(); $AllCfgNames = @()
function Add-UniqueCfgDir([string]$dir, [string]$name) {
    if ($script:AllCfgDirs -contains $dir) { return }
    $script:AllCfgDirs += $dir
    $script:AllCfgNames += $name
}

function Ensure-AccountExtras([string]$nombre, [string]$cfgDir) {
    Remove-AliasBlock $nombre

    $claudeCall = if ($ClaudeRealBin) { "& `"$ClaudeRealBin`" @args" } else { "claude @args" }
    $block = @"

# ccstatusline-alias:$nombre start
function claude-$nombre {
    `$prevConfigDir = `$env:CLAUDE_CONFIG_DIR
    `$env:CLAUDE_CONFIG_DIR = "$cfgDir"
    try { $claudeCall } finally { `$env:CLAUDE_CONFIG_DIR = `$prevConfigDir }
}
# ccstatusline-alias:$nombre end
"@
    foreach ($p in $ProfilePaths) {
        $profileDir = Split-Path $p -Parent
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
        if (-not (Test-Path $p)) { New-Item -ItemType File -Path $p -Force | Out-Null }
        Add-Content -Path $p -Value $block
    }
    Ok "Alias added successfully: claude-$nombre"
}

function Set-AccountSlots([int]$count) {
    for ($i = 1; $i -le $count; $i++) {
        Section "Configuring Account $i of $count"
        $nombreRaw = Read-Host "  Short account name [$i]"
        if ([string]::IsNullOrWhiteSpace($nombreRaw)) { $nombreRaw = "$i" }
        $nombre = ($nombreRaw.ToLower() -replace '[^a-z0-9-]', '')
        if ([string]::IsNullOrEmpty($nombre)) { WarnMsg "Invalid name, skipping slot."; continue }
        $cfgDir = Join-Path $HOME ".claude-$nombre"
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Add-UniqueCfgDir $cfgDir $nombre
        Ensure-AccountExtras $nombre $cfgDir
    }
}

if ($Mode -eq "fresh" -or $Mode -eq "reset") {
    Section "How many Claude Code accounts will you use?"
    $nCuentasRaw = Read-Host "  Amount [2]"
    $nCuentas = if ([string]::IsNullOrWhiteSpace($nCuentasRaw)) { 2 } else { [int]$nCuentasRaw }
    Set-AccountSlots $nCuentas
} else {
    for ($i = 0; $i -lt $ExistNames.Count; $i++) {
        Add-UniqueCfgDir $ExistDirs[$i] $ExistNames[$i]
        Ensure-AccountExtras $ExistNames[$i] $ExistDirs[$i]
    }
}

# ============================================================
# ccstatusline runtime & settings
# ============================================================
New-Item -ItemType Directory -Path $CcstatusDir -Force | Out-Null

if (Test-Tool npx) {
    $CcsCmd = "npx -y ccstatusline@latest"
} else {
    npm install -g ccstatusline | Out-Null
    $CcsCmd = "ccstatusline"
}

$UsageScriptPath = Join-Path $CcstatusDir "usage.ps1"
$UsageCommand = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$UsageScriptPath`""
$Sep = [string][char]0xE0B0

$SettingsObj = [ordered]@{
    version = 3
    lines = @(
        @(
            [ordered]@{ id = "1"; type = "model"; color = "hex:ECEFF4"; backgroundColor = "hex:BF616A" },
            [ordered]@{ id = "5"; type = "context-percentage-usable"; color = "hex:2E3440"; backgroundColor = "hex:EBCB8B" },
            [ordered]@{ id = "3"; type = "custom-command"; color = "hex:FDF6E3"; backgroundColor = "hex:5E81AC"; commandPath = $UsageCommand; timeout = 5000 },
            [ordered]@{ id = "7"; type = "session-clock"; color = "hex:2E3440"; backgroundColor = "hex:A3BE8C" }
        ),
        @(
            [ordered]@{ id = "493b0a05-78ed-46f4-a625-44658237886f"; type = "current-working-dir"; color = "hex:ECEFF4"; backgroundColor = "bgMagenta" }
        ),
        @()
    )
    flexMode = "full-until-compact"
    compactThreshold = 60
    colorLevel = 3
    defaultPadding = " "
    minimalistMode = $true
    powerline = [ordered]@{
        enabled = $true
        separators = @($Sep)
        separatorInvertBackground = @($false)
        endCaps = @($Sep)
        theme = "custom"
    }
}
$SettingsObj | ConvertTo-Json -Depth 10 | Set-Content -Path $CcstatusSettings -Encoding utf8

# ============================================================
# usage.ps1 — the widget script
# ------------------------------------------------------------
# Written with an explicit UTF-8 BOM (via .NET, not Set-Content -Encoding
# utf8) because that flag means different things depending on who's running
# this installer: PowerShell 7's "utf8" omits the BOM, Windows PowerShell
# 5.1's includes it. Without the BOM, 5.1's script parser can't detect the
# encoding, falls back to the system codepage, and mangles every emoji in
# the file into mojibake that breaks the string literals around them.
# ============================================================
$UsageScriptContent = @'
# ccstatusline usage widget (Windows). Shows five_hour/seven_day rate-limit
# buckets when present (Pro/Max-style accounts); falls back to dollar spend
# when they're absent (enterprise-style accounts, which don't get rate-limit
# windows at all).
$ErrorActionPreference = 'SilentlyContinue'
# Any uncaught exception anywhere below (file I/O, TLS, JSON edge cases) should
# make the widget render nothing, not exit 1 with the error swallowed by
# ccstatusline (it pipes this script's stderr to /dev/null).
trap { exit 0 }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# PowerShell on Windows encodes piped/redirected stdout using the system's
# ANSI/OEM codepage by default, not UTF-8, so the emoji here would otherwise
# come out as "?" once ccstatusline reads this script's output through a
# pipe (exactly what happens: execSync captures stdout non-interactively).
try { $OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$ClaudeOAuthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$CacheMaxAge = 300
$UsageUrl = "https://api.anthropic.com/api/oauth/usage"

$ConfigDirRaw = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "default" }
$CacheKey = ($ConfigDirRaw -replace '[^A-Za-z0-9]', '_')
$CacheFile = Join-Path $env:TEMP "ccstatusline-usage-cache-$CacheKey.json"

function Get-Token {
    $credFile = if ($env:CLAUDE_CONFIG_DIR) {
        Join-Path $env:CLAUDE_CONFIG_DIR ".credentials.json"
    } else {
        Join-Path $HOME ".claude\.credentials.json"
    }
    if (-not (Test-Path $credFile)) { return $null }
    try {
        $cred = Get-Content $credFile -Raw | ConvertFrom-Json
        return $cred.claudeAiOauth.accessToken
    } catch {
        return $null
    }
}

$Token = Get-Token
if ([string]::IsNullOrEmpty($Token)) { exit 0 }

function Invoke-UsageFetch {
    $headers1 = @{ Authorization = "Bearer $Token"; "anthropic-beta" = "oauth-2025-04-20" }
    $body = $null
    try {
        $resp = Invoke-WebRequest -Uri $UsageUrl -Headers $headers1 -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $body = $resp.Content
    } catch { $body = $null }

    if ($body) {
        $parsed = $null
        try { $parsed = $body | ConvertFrom-Json } catch { $parsed = $null }
        if ($parsed -and $parsed.error) { return $false }
        if ($parsed -and $parsed.spend -and $parsed.spend.enabled -eq $true) {
            Set-Content -Path $CacheFile -Value $body -NoNewline
            return $true
        }
    }

    $headers2 = @{ Authorization = "Bearer $Token"; "X-OAuth-Client-ID" = $ClaudeOAuthClientId; "anthropic-beta" = "oauth-2025-04-20" }
    $body2 = $null
    try {
        $resp2 = Invoke-WebRequest -Uri $UsageUrl -Headers $headers2 -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $body2 = $resp2.Content
    } catch { $body2 = $null }
    if (-not $body2) { return $false }
    $parsed2 = $null
    try { $parsed2 = $body2 | ConvertFrom-Json } catch { $parsed2 = $null }
    if ($parsed2 -and $parsed2.error) { return $false }
    Set-Content -Path $CacheFile -Value $body2 -NoNewline
    return $true
}

$CacheAge = [double]::PositiveInfinity
if (Test-Path $CacheFile) {
    $mtime = (Get-Item $CacheFile).LastWriteTimeUtc
    $CacheAge = ((Get-Date).ToUniversalTime() - $mtime).TotalSeconds
}
if ($CacheAge -gt $CacheMaxAge) { Invoke-UsageFetch | Out-Null }
if (-not (Test-Path $CacheFile)) { exit 0 }

$RawData = Get-Content $CacheFile -Raw
if ([string]::IsNullOrWhiteSpace($RawData)) { exit 0 }
try { $Data = $RawData | ConvertFrom-Json } catch { exit 0 }

# Format-ResetIn <resets_at value>  -> "<Xd/Xh/Xm> left", or "" if missing/past/unparseable
# ConvertFrom-Json auto-converts ISO8601 strings to [datetime] already, so
# $rawValue may arrive as either a string or a pre-parsed [datetime].
function Format-ResetIn($rawValue) {
    if (-not $rawValue) { return "" }
    if ($rawValue -is [datetime]) {
        $target = $rawValue
    } else {
        try { $target = [datetime]::Parse($rawValue, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return "" }
    }
    $ms = ($target.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalMinutes
    if ($ms -le 0) { return "" }
    $totalMin = [math]::Round($ms)
    $d = [math]::Floor($totalMin / 1440); $h = [math]::Floor(($totalMin % 1440) / 60); $m = $totalMin % 60
    if ($d -gt 0) { return "${d}d${h}h" }
    if ($h -gt 0) { return "${h}h${m}m" }
    return "${m}m"
}

# Get-NextMonthResetIn -> "<Xd/Xh/Xm> left" until the 1st of next month, 00:00
# UTC (enterprise spend caps reset monthly and the API doesn't expose a
# resets_at for them, so this is computed rather than read from the response)
function Get-NextMonthResetIn {
    $nowUtc = (Get-Date).ToUniversalTime()
    $year = $nowUtc.Year; $month = $nowUtc.Month + 1
    if ($month -gt 12) { $month = 1; $year++ }
    $target = [datetime]::new($year, $month, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $totalMin = [math]::Round(($target - $nowUtc).TotalMinutes)
    $d = [math]::Floor($totalMin / 1440); $h = [math]::Floor(($totalMin % 1440) / 60); $m = $totalMin % 60
    if ($d -gt 0) { return "${d}d${h}h" }
    if ($h -gt 0) { return "${h}h${m}m" }
    return "${m}m"
}

$Out = ""
$Buckets = ""
$MaxPct = 0
foreach ($b in @(
    @{ key = "five_hour"; label = "5h" },
    @{ key = "seven_day"; label = "7d" },
    @{ key = "seven_day_sonnet"; label = "son" }
)) {
    $val = $Data.($b.key).utilization
    if ($null -eq $val) { continue }
    $pct = [math]::Round([double]$val)
    $reset = Format-ResetIn $Data.($b.key).resets_at
    $seg = " $($b.label):$pct%"
    if ($reset -ne "") { $seg += "(⏳$reset)" }
    $Buckets += $seg
    if ($pct -gt $MaxPct) { $MaxPct = $pct }
}

if ($Buckets -ne "") {
    $icon = if ($MaxPct -ge 90) { "🔴" } elseif ($MaxPct -ge 70) { "🟡" } else { "🟢" }
    $Out = "$icon$Buckets"
} elseif ($Data.spend -and $Data.spend.enabled -eq $true) {
    $usedMinor = if ($null -ne $Data.spend.used.amount_minor) { [double]$Data.spend.used.amount_minor } else { 0 }
    $limitMinor = if ($null -ne $Data.spend.limit.amount_minor) { [double]$Data.spend.limit.amount_minor } else { 0 }
    $used = [math]::Round($usedMinor / 100, 2)
    $limit = [math]::Round($limitMinor / 100, 2)
    $percent = if ($limit -gt 0) { [math]::Round(($used / $limit) * 100) } else { 0 }
    $icon = if ($percent -ge 90) { "🔴" } elseif ($percent -ge 70) { "🟡" } else { "🟢" }
    $Out = "$icon `$$($used.ToString('0.00'))/`$$($limit.ToString('0.00')) ($percent%)"
    $reset = Get-NextMonthResetIn
    if ($reset -ne "") { $Out += " (⏳$reset)" }
}

if ($Out -ne "") { Write-Output $Out }
'@
[System.IO.File]::WriteAllText($UsageScriptPath, $UsageScriptContent, [System.Text.UTF8Encoding]::new($true))

# ============================================================
# Wire each account's settings.json to the statusline
# ============================================================
foreach ($d in $AllCfgDirs) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $settingsFile = Join-Path $d "settings.json"
    $obj = $null
    if (Test-Path $settingsFile) {
        try { $obj = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch { $obj = $null }
    }
    if ($null -eq $obj) { $obj = [PSCustomObject]@{} }
    $statusLine = [ordered]@{
        type = "command"
        command = $CcsCmd
        padding = 0
        refreshInterval = 10
    }
    if ($obj.PSObject.Properties.Match('statusLine').Count -gt 0) {
        $obj.statusLine = $statusLine
    } else {
        $obj | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine
    }
    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsFile -Encoding utf8
}

Write-Host ""
Write-Host "== Setup ready ==" -ForegroundColor Green
Write-Host "1. Open a new terminal (Windows PowerShell or PowerShell 7 — aliases were added to both)."
Write-Host "2. Open a fresh session with each corresponding alias."
Write-Host ""
Info "To uninstall later, run: .\ccstatusline-install.ps1 -Uninstall"
