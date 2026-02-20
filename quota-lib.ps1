#
# quota-lib.ps1 — Self-contained quota library for Claude Code statusline (Windows)
#
# Dot-source this file, then call:
#   Invoke-QuotaGet [-Ttl <seconds>]
#
# Results are in the script-scope hashtable $QuotaResult:
#   pct              – 5-hour session usage % (number string, or "")
#   weekly_pct       – 7-day usage % (number string, or "")
#   resets_in        – "2 hr 30 min" until 5h reset (or "")
#   weekly_resets_in – human string until weekly reset (or "")
#   stale            – "true" | "false"
#   valid            – "true" | "false"
#
# Cache file: $env:USERPROFILE\.claude\quota-data.json
# Lock file:  $env:USERPROFILE\.claude\.quota-fetch.lock
#
# NOTE: This file is dot-sourced by the statusline script.  Do NOT use
#       Set-StrictMode or alter error-action preferences at script scope.

# ── Config ────────────────────────────────────────────────────────────────────
$script:_QL_Cache   = "$env:USERPROFILE\.claude\quota-data.json"
$script:_QL_Lock    = "$env:USERPROFILE\.claude\.quota-fetch.lock"
$script:_QL_Creds   = "$env:USERPROFILE\.claude\.credentials.json"
$script:_QL_Api     = "https://api.anthropic.com/api/oauth/usage"
$script:_QL_Beta    = "oauth-2025-04-20"
$script:_QL_Timeout = 20

# Populated by Invoke-QuotaGet; readable after dot-sourcing.
$script:QuotaResult = @{
    pct              = ""
    weekly_pct       = ""
    resets_in        = ""
    weekly_resets_in = ""
    stale            = "false"
    valid            = "false"
}

# ── Public API ────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
Fetches or returns cached Claude quota data.

.DESCRIPTION
Checks the age of the local cache file.  If fresh, returns immediately.
If stale (or absent), fires a background refresh and returns the previous
data.  On the very first call (no cache) blocks briefly for initial data.
Populates $QuotaResult with the result.

.PARAMETER Ttl
Cache TTL in seconds.  Default: 60.
#>
function Invoke-QuotaGet {
    param([int]$Ttl = 60)

    $needsRefresh = $true
    if (Test-Path $script:_QL_Cache -PathType Leaf) {
        try {
            $mtime = (Get-Item $script:_QL_Cache -ErrorAction Stop).LastWriteTimeUtc
            $age   = ([DateTimeOffset]::UtcNow - $mtime).TotalSeconds
            if ($age -lt $Ttl) { $needsRefresh = $false }
        } catch {}
    }

    if ($needsRefresh) {
        $alreadyFetching = $false
        if (Test-Path $script:_QL_Lock -PathType Leaf) {
            try {
                $lockPid = [int](Get-Content $script:_QL_Lock -ErrorAction Stop)
                if ($null -ne (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
                    $alreadyFetching = $true
                }
            } catch {}
        }

        if (-not $alreadyFetching) {
            if (-not (Test-Path $script:_QL_Cache -PathType Leaf)) {
                # First ever call — block briefly so the statusline isn't blank
                _QL_FetchOnce
            } else {
                # Stale cache — refresh in background, return previous data this frame
                $helperPath = "$env:USERPROFILE\.claude\_quota-fetch-helper.ps1"
                $pwshExe    = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
                try {
                    $proc = Start-Process $pwshExe `
                        -ArgumentList "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "`"$helperPath`"" `
                        -WindowStyle Hidden `
                        -PassThru `
                        -ErrorAction Stop
                    if ($null -ne $proc) {
                        [string]$proc.Id | Set-Content -Path $script:_QL_Lock -Encoding UTF8
                    }
                } catch {
                    # Fall back to synchronous fetch if Start-Process fails
                    _QL_FetchOnce
                }
            }
        }
    }

    _QL_ParseCache
}

# ── Internal: timestamp ───────────────────────────────────────────────────────

function _QL_NowUtc {
    return [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

# ── Internal: credentials ─────────────────────────────────────────────────────

function _QL_GetToken {
    if (-not (Test-Path $script:_QL_Creds -PathType Leaf)) { return $null }
    try {
        $raw   = Get-Content $script:_QL_Creds -Raw -Encoding UTF8 -ErrorAction Stop
        $creds = $raw | ConvertFrom-Json -ErrorAction Stop
        $token = $creds.claudeAiOauth.accessToken
        if ([string]::IsNullOrWhiteSpace($token)) { return $null }
        return $token
    } catch {
        return $null
    }
}

# ── Internal: value helpers ───────────────────────────────────────────────────

# Returns an integer or 2-dp decimal for a 0–100 percent, or $null.
function _QL_NormalizePercent {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    try { $num = [double]$Value } catch { return $null }
    if ($num -lt 0 -or $num -gt 100) { return $null }
    if ([Math]::Abs($num - [Math]::Round($num)) -lt 0.0000001) {
        return [int][Math]::Round($num)
    }
    return [Math]::Round($num, 2)
}

# Normalise a resets_at value (may be a DateTime object auto-parsed by
# Invoke-RestMethod/ConvertFrom-Json, or already an ISO string) to an
# unambiguous ISO 8601 UTC string suitable for storage and later parsing.
function _QL_DateToIso {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
    if ($Value -is [DateTime])       { return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
    return [string]$Value
}

# ISO 8601 timestamp → "X d Y hr Z min" (or "" for missing/past).
function _QL_GetTimeUntil {
    param([AllowNull()][string]$IsoTimestamp)
    if ([string]::IsNullOrWhiteSpace($IsoTimestamp)) { return "" }
    try {
        $target = [DateTimeOffset]::Parse(
                      $IsoTimestamp,
                      [System.Globalization.CultureInfo]::InvariantCulture,
                      [System.Globalization.DateTimeStyles]::RoundtripKind
                  ).UtcDateTime
        $delta  = $target - (Get-Date).ToUniversalTime()
    } catch { return "" }
    if ($delta.TotalSeconds -le 0) { return "0 min" }
    $totalMinutes = [int][Math]::Floor($delta.TotalMinutes)
    $days  = [int][Math]::Floor($totalMinutes / 1440)
    $hours = [int][Math]::Floor(($totalMinutes % 1440) / 60)
    $mins  = $totalMinutes % 60
    if ($days  -gt 0) { return "${days}d${hours}h" }
    if ($hours -gt 0) { return "${hours}h${mins}m" }
    return "${mins}m"
}

# Safe nested property read — returns $null if any segment is absent.
function _QL_GetObjectValue {
    param($Object, [string[]]$Path)
    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current) { return $null }
        if ($current.PSObject.Properties.Name -notcontains $segment) { return $null }
        $current = $current.$segment
    }
    return $current
}

# ── Internal: cache I/O ───────────────────────────────────────────────────────

function _QL_ReadCacheRaw {
    if (-not (Test-Path $script:_QL_Cache -PathType Leaf)) { return $null }
    try {
        return Get-Content $script:_QL_Cache -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
}

function _QL_Write {
    param([string]$Json)
    $dir = Split-Path $script:_QL_Cache -Parent
    if (-not (Test-Path $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Json | Set-Content -Path $script:_QL_Cache -Encoding UTF8
}

# ── Internal: payload builders ────────────────────────────────────────────────

function _QL_BuildSuccess {
    param($UsageData, [string]$Ts)

    $fiveHour = $UsageData.five_hour
    $sevenDay = $UsageData.seven_day
    $extra    = $UsageData.extra_usage

    $curPct    = if ($null -ne $fiveHour) { _QL_NormalizePercent $fiveHour.utilization } else { $null }
    $curAt     = if ($null -ne $fiveHour -and $null -ne $fiveHour.resets_at) { _QL_DateToIso $fiveHour.resets_at } else { "" }
    $curIn     = if (-not [string]::IsNullOrWhiteSpace($curAt))  { _QL_GetTimeUntil $curAt  } else { "" }

    $weeklyPct = if ($null -ne $sevenDay) { _QL_NormalizePercent $sevenDay.utilization } else { $null }
    $weeklyAt  = if ($null -ne $sevenDay -and $null -ne $sevenDay.resets_at) { _QL_DateToIso $sevenDay.resets_at } else { "" }
    $weeklyIn  = if (-not [string]::IsNullOrWhiteSpace($weeklyAt)) { _QL_GetTimeUntil $weeklyAt } else { "" }

    $payload = [ordered]@{
        schema_version       = 2
        source_url           = $script:_QL_Api
        attempted_at_utc     = $Ts
        fetched_at_utc       = $Ts
        current_session      = [ordered]@{ percent_used = $curPct;    resets_at = $curAt;    resets_in = $curIn    }
        weekly_limits        = [ordered]@{ percent_used = $weeklyPct; resets_at = $weeklyAt; resets_in = $weeklyIn }
        extra_usage          = [ordered]@{
            is_enabled    = if ($null -ne $extra) { $extra.is_enabled    } else { $null }
            utilization   = if ($null -ne $extra) { _QL_NormalizePercent $extra.utilization } else { $null }
            used_credits  = if ($null -ne $extra) { $extra.used_credits  } else { $null }
            monthly_limit = if ($null -ne $extra) { $extra.monthly_limit } else { $null }
        }
        quota_used_pct       = $curPct
        weekly_used_pct      = $weeklyPct
        resets_in            = $curIn
        weekly_resets        = $weeklyIn
        updated              = $Ts
        valid                = $true
        stale                = $false
        stale_since          = $null
        stale_reason         = ""
        last_success_updated = $Ts
        error                = ""
        api_status_code      = 200
        consecutive_failures = 0
    }
    return $payload | ConvertTo-Json -Depth 10
}

function _QL_BuildStale {
    param($Previous, [string]$NowUtc, [string]$ErrorText, $StatusCode)

    $curPct         = $null
    $weeklyPct      = $null
    $curAt          = ""
    $weeklyAt       = ""
    $curIn          = ""
    $weeklyIn       = ""
    $extraIsEnabled = $null
    $extraUtil      = $null
    $extraCredits   = $null
    $extraLimit     = $null
    $sourceUrl      = $script:_QL_Api
    $fetchedAt      = ""
    $lastSuccess    = ""
    $staleSince     = $NowUtc
    $prevFailures   = 0

    if ($null -ne $Previous) {
        $curPct    = _QL_NormalizePercent (_QL_GetObjectValue $Previous @("current_session", "percent_used"))
        if ($null -eq $curPct) {
            $curPct = _QL_NormalizePercent (_QL_GetObjectValue $Previous @("quota_used_pct"))
        }

        $weeklyPct = _QL_NormalizePercent (_QL_GetObjectValue $Previous @("weekly_limits", "percent_used"))
        if ($null -eq $weeklyPct) {
            $weeklyPct = _QL_NormalizePercent (_QL_GetObjectValue $Previous @("weekly_used_pct"))
        }

        $v = _QL_GetObjectValue $Previous @("current_session", "resets_at")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $curAt = [string]$v }

        $v = _QL_GetObjectValue $Previous @("weekly_limits", "resets_at")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $weeklyAt = [string]$v }

        $v = _QL_GetObjectValue $Previous @("current_session", "resets_in")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $curIn = [string]$v }
        else {
            $v = _QL_GetObjectValue $Previous @("resets_in")
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $curIn = [string]$v }
        }

        $v = _QL_GetObjectValue $Previous @("weekly_limits", "resets_in")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $weeklyIn = [string]$v }
        else {
            $v = _QL_GetObjectValue $Previous @("weekly_resets")
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $weeklyIn = [string]$v }
        }

        $extraIsEnabled = _QL_GetObjectValue $Previous @("extra_usage", "is_enabled")
        $extraUtil      = _QL_NormalizePercent (_QL_GetObjectValue $Previous @("extra_usage", "utilization"))
        $extraCredits   = _QL_GetObjectValue $Previous @("extra_usage", "used_credits")
        $extraLimit     = _QL_GetObjectValue $Previous @("extra_usage", "monthly_limit")

        $v = _QL_GetObjectValue $Previous @("source_url")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $sourceUrl = [string]$v }

        $v = _QL_GetObjectValue $Previous @("fetched_at_utc")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $fetchedAt = [string]$v }

        $v = _QL_GetObjectValue $Previous @("last_success_updated")
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) {
            $lastSuccess = [string]$v
        } elseif ([bool](_QL_GetObjectValue $Previous @("valid"))) {
            $v2 = _QL_GetObjectValue $Previous @("updated")
            if (-not [string]::IsNullOrWhiteSpace([string]$v2)) { $lastSuccess = [string]$v2 }
        }
        if ([string]::IsNullOrWhiteSpace($lastSuccess) -and -not [string]::IsNullOrWhiteSpace($fetchedAt)) {
            $lastSuccess = $fetchedAt
        }

        $oldStale = [bool](_QL_GetObjectValue $Previous @("stale"))
        if ($oldStale) {
            $v = _QL_GetObjectValue $Previous @("stale_since")
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $staleSince = [string]$v }
        }

        $v = _QL_GetObjectValue $Previous @("consecutive_failures")
        if ($null -ne $v) { try { $prevFailures = [int]$v } catch {} }
    }

    # Recompute resets_in from stored timestamps (time has passed since last success)
    if (-not [string]::IsNullOrWhiteSpace($curAt)) {
        $r = _QL_GetTimeUntil $curAt
        if (-not [string]::IsNullOrWhiteSpace($r)) { $curIn = $r }
    }
    if (-not [string]::IsNullOrWhiteSpace($weeklyAt)) {
        $r = _QL_GetTimeUntil $weeklyAt
        if (-not [string]::IsNullOrWhiteSpace($r)) { $weeklyIn = $r }
    }

    $payload = [ordered]@{
        schema_version       = 2
        source_url           = $sourceUrl
        attempted_at_utc     = $NowUtc
        fetched_at_utc       = $fetchedAt
        current_session      = [ordered]@{ percent_used = $curPct;    resets_at = $curAt;    resets_in = $curIn    }
        weekly_limits        = [ordered]@{ percent_used = $weeklyPct; resets_at = $weeklyAt; resets_in = $weeklyIn }
        extra_usage          = [ordered]@{
            is_enabled    = $extraIsEnabled
            utilization   = $extraUtil
            used_credits  = $extraCredits
            monthly_limit = $extraLimit
        }
        quota_used_pct       = $curPct
        weekly_used_pct      = $weeklyPct
        resets_in            = $curIn
        weekly_resets        = $weeklyIn
        updated              = $NowUtc
        valid                = $false
        stale                = $true
        stale_since          = $staleSince
        stale_reason         = $ErrorText
        last_success_updated = $lastSuccess
        error                = $ErrorText
        api_status_code      = $StatusCode
        consecutive_failures = ($prevFailures + 1)
    }
    return $payload | ConvertTo-Json -Depth 10
}

# ── Internal: HTTP fetch ──────────────────────────────────────────────────────

<#
.SYNOPSIS
Fetches the Anthropic usage API and writes quota-data.json.

.DESCRIPTION
Called synchronously on first run, or from _quota-fetch-helper.ps1 in the
background on subsequent stale-cache refreshes.
#>
function Invoke-QuotaFetchOnce {
    $nowUtc = _QL_NowUtc
    $token  = _QL_GetToken

    if ($null -eq $token) {
        $prev    = _QL_ReadCacheRaw
        $payload = _QL_BuildStale $prev $nowUtc "Cannot read OAuth token." $null
        _QL_Write $payload
        return
    }

    $headers = @{
        "Authorization"  = "Bearer $token"
        "anthropic-beta" = $script:_QL_Beta
        "Accept"         = "application/json"
    }

    try {
        $data    = Invoke-RestMethod -Method Get -Uri $script:_QL_Api -Headers $headers `
                       -TimeoutSec $script:_QL_Timeout -ErrorAction Stop
        $payload = _QL_BuildSuccess $data $nowUtc
    } catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}

        $msg = if ($statusCode -eq 401) {
            "OAuth token rejected (HTTP 401). Re-authenticate Claude Code."
        } elseif ($statusCode -eq 429) {
            "Rate limited by API (HTTP 429)."
        } elseif ($null -ne $statusCode) {
            "API request failed (HTTP $statusCode)."
        } else {
            "Request failed (network error or timeout)."
        }

        $prev    = _QL_ReadCacheRaw
        $payload = _QL_BuildStale $prev $nowUtc $msg $statusCode
    }

    _QL_Write $payload
}

# ── Internal: populate $QuotaResult from cache ────────────────────────────────

function _QL_ParseCache {
    $script:QuotaResult = @{
        pct              = ""
        weekly_pct       = ""
        resets_in        = ""
        weekly_resets_in = ""
        stale            = "false"
        valid            = "false"
    }

    if (-not (Test-Path $script:_QL_Cache -PathType Leaf)) { return }

    try {
        $data = Get-Content $script:_QL_Cache -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch { return }

    $v = _QL_GetObjectValue $data @("quota_used_pct")
    if ($null -ne $v) { $script:QuotaResult['pct'] = [string]$v }

    $v = _QL_GetObjectValue $data @("weekly_used_pct")
    if ($null -ne $v) { $script:QuotaResult['weekly_pct'] = [string]$v }

    $v = _QL_GetObjectValue $data @("current_session", "resets_in")
    if ([string]::IsNullOrWhiteSpace([string]$v)) { $v = _QL_GetObjectValue $data @("resets_in") }
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $script:QuotaResult['resets_in'] = [string]$v }

    $v = _QL_GetObjectValue $data @("weekly_limits", "resets_in")
    if ([string]::IsNullOrWhiteSpace([string]$v)) { $v = _QL_GetObjectValue $data @("weekly_resets") }
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $script:QuotaResult['weekly_resets_in'] = [string]$v }

    $stale = _QL_GetObjectValue $data @("stale")
    $script:QuotaResult['stale'] = if ($stale -eq $true) { "true" } else { "false" }

    $valid = _QL_GetObjectValue $data @("valid")
    $script:QuotaResult['valid'] = if ($valid -eq $true) { "true" } else { "false" }
}
