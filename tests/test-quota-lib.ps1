#
# test-quota-lib.ps1 -- guards for the Windows half of claude-code-quota.
#
# Two failure modes this catches, both of which have real teeth:
#
#   1. A PowerShell file without a UTF-8 BOM. Windows PowerShell 5.1 decodes a
#      BOM-less .ps1 as ANSI, so an em-dash becomes U+201D -- a character
#      PowerShell accepts as a *string delimiter*. The string closes early, the
#      parser desyncs, and you get four bogus "Missing closing '}'" errors
#      pointing at lines nowhere near the real one. install.ps1 shipped like
#      this.
#
#   2. A missing version gate, or a surviving powershell.exe fallback. 5.1 is
#      not supported: it has to fail loudly at the door, never degrade into
#      mojibake glyphs or a background worker that poisons the shared cache.
#
# No network, no quota consumed, no state touched -- static checks plus the
# PowerShell parser.
#
#   pwsh -NoProfile -File tests/test-quota-lib.ps1

#Requires -Version 7.0

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root

$script:Fails = 0
function Ok  { param([string]$M) Write-Host "  ok   $M" -ForegroundColor DarkGray }
function Bad { param([string]$M) Write-Host "  FAIL $M" -ForegroundColor Red; $script:Fails++ }
function Hdr { param([string]$M) Write-Host "`n-- $M" -ForegroundColor Cyan }

# Entry points: launched as their own process, so a #Requires here aborts
# cleanly. quota-lib.ps1 is deliberately absent -- it is dot-sourced, and a
# #Requires in it would change the *caller's* error behaviour (see CLAUDE.md).
$EntryPoints = @("install.ps1", "statusline.ps1.template", "_quota-fetch-helper.ps1")

$PsFiles = @(& git ls-files "*.ps1" "*.ps1.template")
if ($PsFiles.Count -eq 0) { Write-Host "FAILED: git ls-files found no PowerShell files"; exit 1 }

Hdr "UTF-8 BOM present"
foreach ($f in $PsFiles) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root $f))[0..2]
    if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Ok "$f"
    } else {
        Bad "$f has no UTF-8 BOM -- 5.1 will read it as ANSI and mis-parse it"
    }
}

Hdr "Entry points require PowerShell 7"
foreach ($f in $EntryPoints) {
    if ((Get-Content (Join-Path $Root $f)) -match '^#Requires -Version 7\.0') {
        Ok "$f declares #Requires -Version 7.0"
    } else {
        Bad "$f is an entry point with no '#Requires -Version 7.0'"
    }
}

Hdr "No powershell.exe fallback"
foreach ($f in $PsFiles) {
    $hits = Get-Content (Join-Path $Root $f) |
            Where-Object { $_ -notmatch '^\s*#' } |
            Where-Object { $_ -match '(\{|=|&|Start-Process|-FilePath)\s*"?powershell(\.exe)?"?' }
    if ($hits) { Bad "$f still reaches for powershell.exe: $($hits[0].Trim())" }
    else       { Ok "$f" }
}

Hdr "Files parse under this engine"
foreach ($f in $PsFiles) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $f), [ref]$null, [ref]$errs)
    if ($errs.Count -eq 0) { Ok "$f" } else { Bad "$f has $($errs.Count) parse error(s): $($errs[0].Message)" }
}

# A BOM claims the bytes are UTF-8; verify they actually are. A file saved as
# CP1252 with a BOM bolted on decodes to replacement characters, which is the
# same class of silent corruption from the other direction.
Hdr "Bytes are valid UTF-8"
$strict = New-Object System.Text.UTF8Encoding($true, $true)
foreach ($f in $PsFiles) {
    $raw = [System.IO.File]::ReadAllBytes((Join-Path $Root $f))
    try {
        [void]$strict.GetString($raw)
        Ok "$f"
    } catch {
        Bad "$f is not valid UTF-8 despite its BOM"
    }
}

Pop-Location
Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "All Windows guards passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Fails) failure(s)." -ForegroundColor Red
    exit 1
}
