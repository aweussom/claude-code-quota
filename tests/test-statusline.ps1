#
# test-statusline.ps1 -- render statusline.ps1.template against synthetic
# session JSON and assert the model label, for both shapes Claude Code has
# used: a bare ID string (old) and an object {id, display_name} (current).
#
# Why this exists: the object shape stringifies as "@{id=...; display_name=...}"
# under -match, so the regex matched by accident for known families while any
# other family assigned the object itself to $modelLabel and crashed the
# string concatenation -- dropping the model and the git branch from the line,
# with the error on stderr where a statusline never shows it.
#
# No network, no quota consumed: USERPROFILE is pointed at an empty temp dir
# so the template finds no quota-lib.ps1 and skips the fetch entirely.
#
#   pwsh -NoProfile -File tests/test-statusline.ps1

#Requires -Version 7.0

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Tpl  = Join-Path $Root "statusline.ps1.template"
if (-not (Test-Path $Tpl -PathType Leaf)) { Write-Host "FAIL: $Tpl not found"; exit 1 }

# -File insists on a .ps1 extension, so stage a copy.
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccq-sl-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Tmp | Out-Null
$Sl = Join-Path $Tmp "statusline.ps1"
Copy-Item $Tpl $Sl

$script:Fails = 0
function Check {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) { Write-Host ("  ok   {0,-34} = '{1}'" -f $Label, $Actual) -ForegroundColor DarkGray }
    else { Write-Host ("  FAIL {0,-34} expected='{1}' actual='{2}'" -f $Label, $Expected, $Actual) -ForegroundColor Red; $script:Fails++ }
}

function Render {
    param([string]$SessionJson)
    # Empty USERPROFILE => no quota-lib.ps1 => no fetch. 2>&1 so a thrown error
    # lands in the output and fails the comparison instead of vanishing.
    $saved = $env:USERPROFILE
    try {
        $env:USERPROFILE = $Tmp
        $out = $SessionJson | & ([Environment]::ProcessPath) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Sl 2>&1 | Out-String
    } finally { $env:USERPROFILE = $saved }
    ($out -replace "`e\[[0-9;]*m", "").Trim()
}
function LabelOf { param([string]$Json) ((Render $Json) -split "\s*\|")[0].Trim() }

$cwd = ($Root -replace '\\', '/')
function StrJson { param([string]$Id) "{`"model`":`"$Id`",`"cwd`":`"$cwd`",`"context_window`":{`"used_percentage`":37.4}}" }
function ObjJson {
    param([string]$Id, [string]$DisplayName)
    $dn = if ($DisplayName) { ",`"display_name`":`"$DisplayName`"" } else { "" }
    "{`"model`":{`"id`":`"$Id`"$dn},`"cwd`":`"$cwd`"}"
}

Write-Host "`n-- model as ID string (legacy)" -ForegroundColor Cyan
Check "claude-opus-5"             "Opus 5"     (LabelOf (StrJson "claude-opus-5"))
Check "claude-opus-4-8"           "Opus 4.8"   (LabelOf (StrJson "claude-opus-4-8"))
Check "claude-sonnet-4-6"         "Sonnet 4.6" (LabelOf (StrJson "claude-sonnet-4-6"))
Check "claude-haiku-4-5-20251001" "Haiku 4.5"  (LabelOf (StrJson "claude-haiku-4-5-20251001"))
Check "claude-fable-5"            "Fable 5"    (LabelOf (StrJson "claude-fable-5"))
Check "claude-mythos-5"           "Mythos 5"   (LabelOf (StrJson "claude-mythos-5"))
Check "unknown id falls through"  "weird-id"   (LabelOf (StrJson "weird-id"))

Write-Host "`n-- model as object {id, display_name} (current)" -ForegroundColor Cyan
Check "display_name wins"            "Fable 5"         (LabelOf (ObjJson "claude-fable-5" "Fable 5"))
Check "display_name verbatim"        "My Model"        (LabelOf (ObjJson "claude-fable-5" "My Model"))
Check "id-only object is mapped"     "Opus 4.8"        (LabelOf (ObjJson "claude-opus-4-8" ""))
Check "unknown family: id, not blob" "claude-zephyr-6" (LabelOf (ObjJson "claude-zephyr-6" ""))

# The crash symptom was the branch vanishing along with the model: assert the
# second segment is still there for the case that used to throw.
Write-Host "`n-- branch survives an unlisted family" -ForegroundColor Cyan
$segs = (Render (ObjJson "claude-zephyr-6" "")) -split "\s*\|\s*"
$branch = (& git -C $Root branch --show-current 2>$null)
if ($branch) { Check "second segment is the branch" $branch.Trim() $segs[1] }
else         { Write-Host "  skip  not on a branch" -ForegroundColor DarkGray }

# Without quota-lib.ps1 the line must shrink to model/branch/ctx -- not spray
# "Cannot index into a null array" and render "5h:% | 7d:% | :%".
Write-Host "`n-- no quota-lib in reach: degrade, don't error" -ForegroundColor Cyan
$full = Render (StrJson "claude-fable-5")
Write-Host ("  " + $full)
Check "no error text"      "" ([string]($full | Select-String -Pattern "InvalidOperation|Cannot index" | Select-Object -First 1))
Check "no quota segments"  "" ([string]($full | Select-String -Pattern "5h:|7d:|quota:" | Select-Object -First 1))
Check "ctx still rendered" "ctx:37%" ((($full -split "\s*\|\s*") | Where-Object { $_ -like "ctx:*" }) -join "")

# Provider segments. A private USERPROFILE holding quota-lib.ps1 and a cache:
# the TTL keeps Invoke-QuotaGet from fetching, so neither case touches the
# network or consumes an allowance.
Write-Host "`n-- provider segments (synthetic cache, no network)" -ForegroundColor Cyan
$QHome = Join-Path $Tmp "home"
New-Item -ItemType Directory -Path (Join-Path $QHome ".claude") -Force | Out-Null
Copy-Item (Join-Path $Root "quota-lib.ps1") (Join-Path $QHome ".claude\quota-lib.ps1")

function RenderWith {
    param([string]$BaseUrl, [string]$SessionJson)
    $savedProfile = $env:USERPROFILE
    $savedBase    = $env:ANTHROPIC_BASE_URL
    try {
        $env:USERPROFILE = $QHome
        $env:ANTHROPIC_BASE_URL = $BaseUrl
        $out = $SessionJson | & ([Environment]::ProcessPath) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Sl 2>&1 | Out-String
    } finally {
        $env:USERPROFILE = $savedProfile
        if ($null -eq $savedBase) { Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue }
        else { $env:ANTHROPIC_BASE_URL = $savedBase }
    }
    return ($out -replace "`e\[[0-9;]*m", "").Trim()
}

# An Ollama session with the 5h window spent: no scoped segment, and the
# purchased balance shows because requests now cost money.
@{
    schema_version  = 3
    provider        = "ollama"
    current_session = @{ percent_used = 100;   resets_at = (Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm:ssZ"); resets_in = ""; percent_unknown = $false }
    weekly_limits   = @{ percent_used = 26.19; resets_at = (Get-Date).ToUniversalTime().AddDays(3).ToString("yyyy-MM-ddTHH:mm:ssZ");  resets_in = ""; percent_unknown = $false }
    scoped_limits   = @()
    purchased_balance_usd = 0.73493
    quota_used_pct  = 100
    weekly_used_pct = 26.19
    valid = $true; stale = $false; consecutive_failures = 0
} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $QHome ".claude\quota-data-ollama.json") -Encoding UTF8

$out = RenderWith "http://127.0.0.1:11434" (StrJson "glm-5.3-flash:cloud")
Write-Host ("  " + $out)
Check "ollama: 5h segment"    "yes" $(if ($out -match "5h:100%")   { "yes" } else { "no" })
Check "ollama: 7d segment"    "yes" $(if ($out -match "7d:26\.19%"){ "yes" } else { "no" })
Check "ollama: balance shown" "yes" $(if ($out -match "\`$0\.73")  { "yes" } else { "no" })
Check "ollama: no scoped"     "no"  $(if ($out -match "Fable")     { "yes" } else { "no" })

# Some other gateway: the Anthropic numbers do not describe this session and we
# have none for whatever does, so no quota segments at all.
$out = RenderWith "http://127.0.0.1:4000" (StrJson "some-model")
Write-Host ("  " + $out)
Check "other: no quota segments" "no"  $(if ($out -match "5h:|7d:|quota:") { "yes" } else { "no" })
Check "other: ctx kept"          "yes" $(if ($out -match "ctx:37%")        { "yes" } else { "no" })

Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host ""
if ($script:Fails -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$($script:Fails) CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
