#
# install.ps1 — Install claude-code-quota into %USERPROFILE%\.claude\ (Windows)
#
# Usage:
#   .\install.ps1              # interactive
#   .\install.ps1 -Yes         # non-interactive (accept all defaults)
#
# Requirements:
#   PowerShell 7.0+ (pwsh). Windows PowerShell 5.1 is NOT supported.
#   Claude Code with OAuth login (run: claude login)
#
# Execution policy — if you see "cannot be loaded because running scripts is
# disabled", run the installer without changing any policy:
#   pwsh -ExecutionPolicy Bypass -File .\install.ps1
#
# On managed machines (GPO/Intune) the Bypass flag can be overridden by
# MachinePolicy/UserPolicy; there, set a persistent per-user policy instead:
#   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
# See the "Execution policy" section in README.md for how to tell which
# case applies (Get-ExecutionPolicy -List).

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Alias("y")]
    [switch]$Yes   # Accept all prompts automatically
)

$ErrorActionPreference = "Stop"
$ScriptDir  = $PSScriptRoot
$ClaudeDir  = "$env:USERPROFILE\.claude"
$SkillsDir  = "$ClaudeDir\skills\quota"

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Info    { param([string]$Msg) Write-Host "  $Msg" }
function Write-Success { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "  [!]  $Msg" -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "  [X]  $Msg" -ForegroundColor Red }
function Write-Hdr     { param([string]$Msg) Write-Host "`n-- $Msg " -ForegroundColor Cyan }

function Confirm-Step {
    param([string]$Question, [switch]$DefaultNo)
    if ($Yes) { return $true }
    $hint = if ($DefaultNo) { "[y/N]" } else { "[Y/n]" }
    $reply = Read-Host "  $Question $hint"
    if ($DefaultNo) {
        return $reply -match '^[Yy]'
    }
    return ($reply -eq "" -or $reply -match '^[Yy]')
}

function Copy-FileWithPrompt {
    param([string]$Src, [string]$Dst, [string]$Label)
    if (Test-Path $Dst -PathType Leaf) {
        Write-Warn "$Label already exists at $Dst"
        if (-not (Confirm-Step "Overwrite it?")) {
            Write-Info "Skipped."
            return
        }
    }
    Copy-Item -Path $Src -Destination $Dst -Force
    Write-Success "Installed $Dst"
}

# ── Header ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  claude-code-quota  Windows installer" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ── PowerShell version check ──────────────────────────────────────────────────
Write-Hdr "PowerShell version"
$psVer = $PSVersionTable.PSVersion
Write-Info "PowerShell $psVer"

# Belt and braces. The #Requires above already refuses to run this script on
# 5.1, but it is only reachable once the file parses -- and 5.1 reads a
# BOM-less UTF-8 .ps1 as ANSI, which turns an em-dash into U+201D, a character
# PowerShell accepts as a string delimiter. The parser then dies before
# #Requires is ever evaluated. Keep every .ps1 BOM'd AND keep this check;
# neither one alone fails cleanly.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Err "PowerShell 7.0+ is required. This is $psVer."
    Write-Err "Install from: https://aka.ms/powershell, then re-run under pwsh:"
    Write-Err "  pwsh -ExecutionPolicy Bypass -File .\install.ps1"
    exit 1
}

# The statusline command written into settings.json invokes `pwsh` by name, so
# it must resolve on PATH for Claude Code -- not merely for this shell.
if ($null -eq (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Err "'pwsh' is not on PATH."
    Write-Err "Claude Code launches the statusline as 'pwsh ...', so PATH must resolve it."
    Write-Err "Install from: https://aka.ms/powershell, or add the existing pwsh.exe to PATH."
    exit 1
}
Write-Success "pwsh $psVer"

# ── Credentials check ─────────────────────────────────────────────────────────
Write-Hdr "Claude Code credentials"
$credsPath = "$ClaudeDir\.credentials.json"
if (Test-Path $credsPath -PathType Leaf) {
    try {
        $creds = Get-Content $credsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $token = $creds.claudeAiOauth.accessToken
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            Write-Success "OAuth token found in $credsPath"
        } else {
            Write-Warn "Credentials file exists but no claudeAiOauth.accessToken."
            Write-Warn "Run 'claude login' first."
        }
    } catch {
        Write-Warn "Could not parse $credsPath — run 'claude login' first."
    }
} else {
    Write-Warn "No credentials file at $credsPath"
    Write-Warn "Run 'claude login' first."
}

# ── Create target directory ───────────────────────────────────────────────────
if (-not (Test-Path $ClaudeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
}

# ── Install quota-lib.ps1 ─────────────────────────────────────────────────────
Write-Hdr "Installing quota-lib.ps1"
Copy-FileWithPrompt `
    -Src "$ScriptDir\quota-lib.ps1" `
    -Dst "$ClaudeDir\quota-lib.ps1" `
    -Label "quota-lib.ps1"

# ── Install _quota-fetch-helper.ps1 ──────────────────────────────────────────
Write-Hdr "Installing _quota-fetch-helper.ps1"
Copy-FileWithPrompt `
    -Src "$ScriptDir\_quota-fetch-helper.ps1" `
    -Dst "$ClaudeDir\_quota-fetch-helper.ps1" `
    -Label "_quota-fetch-helper.ps1"

# ── Install /quota skill ──────────────────────────────────────────────────────
Write-Hdr "Installing /quota skill"
if (Confirm-Step "Install the /quota Claude Code skill?") {
    if (-not (Test-Path $SkillsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null
    }
    Copy-FileWithPrompt `
        -Src "$ScriptDir\skills\quota\SKILL.md" `
        -Dst "$SkillsDir\SKILL.md" `
        -Label "SKILL.md"
    # Pre-1.0 installs shipped a command file; remove it to avoid a duplicate /quota
    $legacyCmd = "$ClaudeDir\commands\quota.md"
    if (Test-Path $legacyCmd -PathType Leaf) {
        Write-Warn "Legacy /quota command file found at $legacyCmd"
        if (Confirm-Step "Remove it (superseded by the skill)?") {
            Remove-Item $legacyCmd -Force
            Write-Success "Removed $legacyCmd"
        }
    }
}

# ── Statusline + settings.json ────────────────────────────────────────────────
Write-Hdr "Statusline integration"

$pwshCmd        = "pwsh"   # guaranteed present by the version check above
$statuslineDst  = "$ClaudeDir\statusline.ps1"
$statuslineAbs  = $statuslineDst -replace '\\', '/'
$settingsCmd    = "$pwshCmd -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $statuslineAbs"
$settingsPath   = "$ClaudeDir\settings.json"

# Read existing settings.json once, up front.
$existingSettings   = $null
$existingStatusCmd  = $null
if (Test-Path $settingsPath -PathType Leaf) {
    try {
        $existingSettings  = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $existingStatusCmd = $existingSettings.statusLine.command
    } catch {
        Write-Warn "Could not parse existing $settingsPath"
    }
}

# ── Statusline script ─────────────────────────────────────────────────────────
$statuslineJustInstalled = $false
if (Test-Path $statuslineDst -PathType Leaf) {
    Write-Info "Existing statusline.ps1 found at $statuslineDst — leaving it unchanged."
} else {
    Copy-Item -Path "$ScriptDir\statusline.ps1.template" -Destination $statuslineDst -Force
    Write-Success "Installed statusline.ps1 → $statuslineDst"
    $statuslineJustInstalled = $true
}

# ── settings.json ─────────────────────────────────────────────────────────────
#
# Three cases:
#   A. A different statusLine command already exists in settings.json
#      (user has their own setup) → show integration snippet, don't touch it.
#   B. Already has the correct command → confirm and move on.
#   C. No command yet → offer to write settings.json.

$hasConflictingCmd = (-not [string]::IsNullOrWhiteSpace($existingStatusCmd)) -and
                     ($existingStatusCmd -ne $settingsCmd)

if ($hasConflictingCmd) {
    # ── Case A: different command already in settings.json ────────────────────
    Write-Info "Existing statusLine command in settings.json:"
    Write-Info "  $existingStatusCmd"
    # First token of the command is the host executable; compare its leaf name.
    $existingExe = (($existingStatusCmd -split '\s+', 2)[0]).Trim('"')
    $existingLeaf = [System.IO.Path]::GetFileNameWithoutExtension($existingExe)
    if ($existingLeaf -ieq 'powershell') {
        Write-Err "That command launches Windows PowerShell 5.1, which is not supported."
        Write-Err "Replace 'powershell' with 'pwsh' in $settingsPath -- under 5.1 the"
        Write-Err "statusline aborts on its #Requires and your status line stays blank."
    }
    Write-Info "Leaving settings.json unchanged."
    Write-Host @"

  To add quota to your existing statusline, dot-source quota-lib.ps1 near
  the top of your statusline script (before you build the output string):

  ------------------------------------------------------------------
  `$libPath = "`$env:USERPROFILE\.claude\quota-lib.ps1"
  if (Test-Path `$libPath) {
      . `$libPath
      `$ttl = 300
      if (`$session.transcript_path -and (Test-Path `$session.transcript_path)) {
          `$tAge = ([DateTimeOffset]::UtcNow -
                   (Get-Item `$session.transcript_path).LastWriteTimeUtc).TotalSeconds
          if (`$tAge -lt 300) { `$ttl = 60 }
      }
      Invoke-QuotaGet -Ttl `$ttl
  }
  ------------------------------------------------------------------

  Then use `$QuotaResult in your output:
    `$QuotaResult['pct']          # "68"  (5-hour % used)
    `$QuotaResult['resets_in']    # "1 hr 12 min"
    `$QuotaResult['weekly_pct']   # "31"  (7-day % used)
    `$QuotaResult['stale']        # "true" / "false"
    `$QuotaResult['error']        # why the last fetch failed, or ""

  Tip: if you installed the /quota skill, ask Claude:
    /quota  →  then ask "how do I add quota to my statusline?"

"@

} elseif ($existingStatusCmd -eq $settingsCmd) {
    # ── Case B: already correct ───────────────────────────────────────────────
    Write-Success "settings.json already has the correct statusLine command."

} else {
    # ── Case C: fresh install ─────────────────────────────────────────────────
    if ($statuslineJustInstalled) {
        Write-Info "statusline.ps1 installed. Now wiring it up in settings.json..."
        Write-Host ""
    }
    Write-Host @"
  settings.json command (absolute path — %%USERPROFILE%% is not expanded by bash):

  ------------------------------------------------------------------
  {
    "statusLine": {
      "type": "command",
      "command": "$settingsCmd"
    }
  }
  ------------------------------------------------------------------
"@
    if (Confirm-Step "Write this statusLine command to ${settingsPath}?") {
        if ($null -eq $existingSettings) {
            $existingSettings = [PSCustomObject]@{}
        }
        $existingSettings | Add-Member -Force -MemberType NoteProperty -Name statusLine -Value ([PSCustomObject]@{
            type    = "command"
            command = $settingsCmd
        })
        $existingSettings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
        Write-Success "Written: $settingsPath"
        Write-Info "(Restart Claude Code for the statusline to take effect.)"
    }
}

# ── Test fetch ────────────────────────────────────────────────────────────────
Write-Hdr "Test fetch"
if (Confirm-Step "Run a test fetch now to verify credentials and API access?" -DefaultNo) {
    Write-Info "Dot-sourcing quota-lib.ps1 and calling Invoke-QuotaGet -Ttl 0 ..."
    Write-Host ""
    try {
        . "$ClaudeDir\quota-lib.ps1"
        Invoke-QuotaGet -Ttl 0
        Write-Host ""
        Write-Info "Result:"
        Write-Info "  5h usage  : $($QuotaResult['pct'])%"
        Write-Info "  resets in : $($QuotaResult['resets_in'])"
        Write-Info "  weekly    : $($QuotaResult['weekly_pct'])%"
        Write-Info "  stale     : $($QuotaResult['stale'])"
        if ($QuotaResult['error'] -ne "") {
            Write-Warn "  error     : $($QuotaResult['error'])"
        }
        Write-Host ""
        Write-Success "Fetch succeeded. Cache written to $ClaudeDir\quota-data.json"
    } catch {
        Write-Warn "Fetch failed: $($_.Exception.Message)"
        Write-Warn "Check that 'claude login' has been run and credentials exist."
    }
}

# ── Execution policy reminder ─────────────────────────────────────────────────
Write-Hdr "Execution policy"
Write-Host @"
  Windows blocks unsigned scripts by default. The -ExecutionPolicy Bypass
  flag in the settings.json command (already included above) handles this
  on unmanaged machines — no policy change needed.

  On managed machines (Entra-joined, GPO/Intune) Bypass can be overridden
  by MachinePolicy/UserPolicy. If the statusline shows no output, run:

      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

  To check which case applies:  Get-ExecutionPolicy -List
  (see the "Execution policy" section in README.md for details)

"@

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Done.  See README.md for full documentation." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
