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
#   error            – human-readable reason for the last failure (or "")
#
# Model/surface-scoped limits (a separate allowance from the 5h and weekly
# buckets — e.g. a per-model weekly cap).  Empty when the account has none:
#   scoped_summary   – "Fable:89% Mythos:12%", or ""
#   scoped_alert     – "true" if any scoped limit has severity != normal
#   scoped_worst     – label of the highest scoped limit, or ""
#   scoped_worst_pct – its percentage, or ""
#   scoped_worst_resets_in – its countdown, but ONLY when it differs from the
#                            weekly reset; "" when they coincide (the usual
#                            case), so callers don't print it twice.
#
# Cache file: $env:USERPROFILE\.claude\quota-data.json
# Lock file:  $env:USERPROFILE\.claude\.quota-fetch.lock
#
# NOTE: This file is dot-sourced by the statusline script.  Do NOT use
#       Set-StrictMode or alter error-action preferences at script scope.

# ── Config ────────────────────────────────────────────────────────────────────
$script:_QL_Version = "2.1.0"
$script:_QL_Cache   = "$env:USERPROFILE\.claude\quota-data.json"
$script:_QL_Lock    = "$env:USERPROFILE\.claude\.quota-fetch.lock"
$script:_QL_Creds   = "$env:USERPROFILE\.claude\.credentials.json"
$script:_QL_Api     = "https://api.anthropic.com/api/oauth/usage"
$script:_QL_Beta    = "oauth-2025-04-20"
$script:_QL_Timeout = 20

# `ollama launch claude` points Claude Code at the local Ollama daemon, so the
# session spends an Ollama allowance and no Anthropic quota at all.  Separate
# cache and lock: a different account with different semantics, and both may be
# in use on the same machine at the same time.
$script:_QL_OllamaApi   = "https://ollama.com/api/balance"
$script:_QL_OllamaCache = "$env:USERPROFILE\.claude\quota-data-ollama.json"
$script:_QL_OllamaLock  = "$env:USERPROFILE\.claude\.quota-fetch-ollama.lock"
$script:_QL_Provider    = "anthropic"
# A held lock older than this is treated as abandoned.  Needed because PIDs get
# recycled: without an age bound, a lock whose PID is reused by an unrelated
# process reads as a live fetch and blocks refreshes indefinitely.
$script:_QL_LockMaxAge = 120

# Populated by Invoke-QuotaGet; readable after dot-sourcing.
$script:QuotaResult = @{
    pct                    = ""
    weekly_pct             = ""
    resets_in              = ""
    weekly_resets_in       = ""
    stale                  = "false"
    valid                  = "false"
    error                  = ""
    pct_unknown            = "false"
    weekly_pct_unknown     = "false"
    scoped_summary         = ""
    scoped_alert           = "false"
    scoped_worst           = ""
    scoped_worst_pct       = ""
    scoped_worst_resets_in = ""
    balance_usd            = ""
    provider               = "anthropic"
}

# ── Internal: which account this session spends ──────────────────────────────
#
# ANTHROPIC_BASE_URL is the only reliable signal: a wrapper sets it before
# starting Claude Code, and the statusline inherits it.  The model ID is not
# enough — a gateway can serve claude-* names from somewhere else entirely.
#
# Ollama is claimed only on its own port or its own host.  Any other local
# proxy (litellm and friends) is "other": we can prove the Anthropic numbers
# are wrong, but we have nothing to put in their place.
function _QL_ResolveProvider {
    $base = $env:ANTHROPIC_BASE_URL
    if ([string]::IsNullOrWhiteSpace($base)) { return "anthropic" }

    $hostPart = $base -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $hostPart = ($hostPart -split '[/?#]')[0]

    if ($hostPart -match '^api\.anthropic\.com(:\d+)?$') { return "anthropic" }
    if ($hostPart -match '(^|\.)ollama\.com(:\d+)?$')    { return "ollama" }
    if ($hostPart -match '^(127\.0\.0\.1|localhost|\[::1\]):11434$') { return "ollama" }
    return "other"
}

# Point the cache, lock and endpoint at the provider this session is spending.
# Called from Invoke-QuotaGet and again from Invoke-QuotaFetchOnce, because the
# background worker reaches the fetch without going through Invoke-QuotaGet.
function _QL_UseProvider {
    $script:_QL_Provider = _QL_ResolveProvider
    if ($script:_QL_Provider -eq "ollama") {
        $script:_QL_Cache = $script:_QL_OllamaCache
        $script:_QL_Lock  = $script:_QL_OllamaLock
        $script:_QL_Api   = $script:_QL_OllamaApi
    }
    return $script:_QL_Provider
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

    if ((_QL_UseProvider) -eq "other") {
        # Some other gateway is answering.  We know the Anthropic figures do not
        # describe this session, and we have no numbers for whatever does, so
        # report nothing rather than something wrong.
        $script:QuotaResult = @{
            pct = ""; weekly_pct = ""; resets_in = ""; weekly_resets_in = ""
            stale = "false"; valid = "false"; error = ""
            pct_unknown = "false"; weekly_pct_unknown = "false"
            scoped_summary = ""; scoped_alert = "false"; scoped_worst = ""
            scoped_worst_pct = ""; scoped_worst_resets_in = ""
            balance_usd = ""; provider = "other"
        }
        return
    }

    # Taper retries after repeated failures so a failing endpoint isn't hit on
    # every refresh: 60s, 120s, 240s ... capped at 15 min.  Uses the
    # consecutive_failures counter already in the cache — no extra state.  The
    # caller's TTL is a floor, never shortened.
    $effTtl = $Ttl
    $prevForBackoff = _QL_ReadCacheRaw
    if ($null -ne $prevForBackoff) {
        $fails = 0
        try { $fails = [int](_QL_GetObjectValue $prevForBackoff @("consecutive_failures")) } catch {}
        if ($fails -gt 0) {
            $backoff = 60
            for ($i = 1; $i -lt $fails -and $backoff -lt 900; $i++) { $backoff *= 2 }
            if ($backoff -gt 900) { $backoff = 900 }
            if ($backoff -gt $effTtl) { $effTtl = $backoff }
        }
    }

    $needsRefresh = $true
    if (Test-Path $script:_QL_Cache -PathType Leaf) {
        try {
            $mtime = (Get-Item $script:_QL_Cache -ErrorAction Stop).LastWriteTimeUtc
            $age   = ([DateTimeOffset]::UtcNow - $mtime).TotalSeconds
            if ($age -lt $effTtl) { $needsRefresh = $false }
        } catch {}
    }

    if ($needsRefresh -and (_QL_TryLock)) {
        if (-not (Test-Path $script:_QL_Cache -PathType Leaf)) {
            # First ever call — block briefly so the statusline isn't blank
            try { Invoke-QuotaFetchOnce } finally { _QL_ReleaseLock }
        } else {
            # Stale cache — refresh in background, return previous data this frame
            $helperPath = "$env:USERPROFILE\.claude\_quota-fetch-helper.ps1"
            # Reuse the exact host already executing us (pwsh 7+, enforced by
            # the statusline's #Requires). Never fall back to powershell.exe:
            # 5.1 mis-decodes the helper's UTF-8 and would poison the shared
            # cache that every session reads.
            $pwshExe    = [Environment]::ProcessPath
            if ([string]::IsNullOrWhiteSpace($pwshExe)) { $pwshExe = "pwsh" }
            try {
                $proc = Start-Process $pwshExe `
                    -ArgumentList "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "`"$helperPath`"" `
                    -WindowStyle Hidden `
                    -PassThru `
                    -ErrorAction Stop
                if ($null -ne $proc) {
                    # Hand ownership to the helper: this process exits as soon as
                    # the statusline is drawn, so leaving our PID in the lock would
                    # make it look abandoned while the fetch is still running.
                    [string]$proc.Id | Set-Content -Path $script:_QL_Lock -Encoding UTF8
                } else {
                    _QL_ReleaseLock
                }
            } catch {
                # Fall back to synchronous fetch if Start-Process fails
                try { Invoke-QuotaFetchOnce } finally { _QL_ReleaseLock }
            }
        }
    }

    _QL_ParseCache
    $script:QuotaResult.provider = $script:_QL_Provider
}

# ── Internal: fetch lock ──────────────────────────────────────────────────────

<#
.SYNOPSIS
Tries to claim the fetch lock.  Returns $true if this process owns it.

.DESCRIPTION
Creation uses FileMode::CreateNew rather than Test-Path-then-write: with several
Claude Code sessions refreshing a cold cache, a check-then-write lock lets all of
them pass the check and fetch simultaneously.
#>
function _QL_TryLock {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open(
                      $script:_QL_Lock,
                      [System.IO.FileMode]::CreateNew,
                      [System.IO.FileAccess]::Write,
                      [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("$PID`n")
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            return $true
        } catch {}

        # Someone holds it.  Steal only if the owner is gone or the lock is old
        # enough that we no longer trust the PID (see $_QL_LockMaxAge).
        $ownerAlive = $false
        try {
            $age = ([DateTimeOffset]::UtcNow -
                    (Get-Item $script:_QL_Lock -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds
            if ($age -le $script:_QL_LockMaxAge) {
                $lockPid = [int]((Get-Content $script:_QL_Lock -Raw -ErrorAction Stop).Trim())
                if ($null -ne (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
                    $ownerAlive = $true
                }
            }
        } catch {}
        if ($ownerAlive) { return $false }   # a live fetch really is in flight
        Remove-Item $script:_QL_Lock -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function _QL_ReleaseLock {
    Remove-Item $script:_QL_Lock -Force -ErrorAction SilentlyContinue
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
    param([AllowNull()]$Timestamp)
    $IsoTimestamp = _QL_DateToIso $Timestamp
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

# ── Internal: scoped limits ───────────────────────────────────────────────────
#
# The API's limits[] array mixes the account-wide buckets (session, weekly_all —
# both scope=null) with narrower allowances that apply to one model or surface
# (scope != null).  Those narrower ones come and go with the plan, so nothing
# here hardcodes a model name: the label is read from the payload.

# True when an ISO 8601 timestamp is in the past (or unparseable).
function _QL_IsPast {
    param([AllowNull()]$Timestamp)
    $IsoTimestamp = _QL_DateToIso $Timestamp
    if ([string]::IsNullOrWhiteSpace($IsoTimestamp)) { return $false }
    try {
        $t = [DateTimeOffset]::Parse(
                 $IsoTimestamp,
                 [System.Globalization.CultureInfo]::InvariantCulture,
                 [System.Globalization.DateTimeStyles]::RoundtripKind
             ).UtcDateTime
    } catch { return $false }
    return ($t -le (Get-Date).ToUniversalTime())
}

# Human label for a scoped limit.  display_name is the only field populated
# today (model.id is null), so fall back through everything else we might get.
function _QL_ScopeLabel {
    param($Scope, [AllowNull()][string]$Kind)
    if ($null -ne $Scope) {
        foreach ($path in @(@("model", "display_name"), @("model", "id"), @("surface"))) {
            $v = _QL_GetObjectValue $Scope $path
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Kind)) { return $Kind }
    return "scoped"
}

# Extract scoped limits from a live API response.  Rebuilt from scratch on every
# success, so a bucket the account no longer has simply stops appearing.
function _QL_BuildScopedLimits {
    param($UsageData)

    $out = @()
    $limits = _QL_GetObjectValue $UsageData @("limits")
    if ($null -eq $limits) { return , [array]$out }

    foreach ($entry in @($limits)) {
        if ($null -eq $entry) { continue }

        # scope == null marks the account-wide buckets, already reported as
        # current_session / weekly_limits.
        $scope = _QL_GetObjectValue $entry @("scope")
        if ($null -eq $scope) { continue }

        $pct = _QL_NormalizePercent (_QL_GetObjectValue $entry @("percent"))
        if ($null -eq $pct) { continue }

        $at = _QL_DateToIso (_QL_GetObjectValue $entry @("resets_at"))
        $out += [ordered]@{
            label        = _QL_ScopeLabel $scope ([string](_QL_GetObjectValue $entry @("kind")))
            kind         = [string](_QL_GetObjectValue $entry @("kind"))
            percent_used = $pct
            severity     = [string](_QL_GetObjectValue $entry @("severity"))
            resets_at    = $at
            resets_in    = if (-not [string]::IsNullOrWhiteSpace($at)) { _QL_GetTimeUntil $at } else { "" }
            is_active    = _QL_GetObjectValue $entry @("is_active")
        }
    }
    return , [array]$out
}

# Carry scoped limits across a failed fetch.  Only a *failed* fetch preserves
# them — a successful one is authoritative, including by omission.  Buckets whose
# window has already rolled over are dropped: the cached percentage is known
# wrong and there's no fresh value to replace it with.
function _QL_CarryScopedLimits {
    param($Previous)

    $out = @()
    $prev = _QL_GetObjectValue $Previous @("scoped_limits")
    if ($null -eq $prev) { return , [array]$out }

    foreach ($entry in @($prev)) {
        if ($null -eq $entry) { continue }

        $at = _QL_DateToIso (_QL_GetObjectValue $entry @("resets_at"))
        if (_QL_IsPast $at) { continue }

        $pct = _QL_NormalizePercent (_QL_GetObjectValue $entry @("percent_used"))
        if ($null -eq $pct) { continue }

        $out += [ordered]@{
            label        = [string](_QL_GetObjectValue $entry @("label"))
            kind         = [string](_QL_GetObjectValue $entry @("kind"))
            percent_used = $pct
            severity     = [string](_QL_GetObjectValue $entry @("severity"))
            resets_at    = $at
            resets_in    = if (-not [string]::IsNullOrWhiteSpace($at)) { _QL_GetTimeUntil $at } else { "" }
            is_active    = _QL_GetObjectValue $entry @("is_active")
        }
    }
    return , [array]$out
}

# ── Internal: cache I/O ───────────────────────────────────────────────────────

function _QL_ReadCacheRaw {
    if (-not (Test-Path $script:_QL_Cache -PathType Leaf)) { return $null }
    try {
        return Get-Content $script:_QL_Cache -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
}

# Write the cache file atomically (parent dir created if needed).
#
# Write-then-rename matters here: several Claude Code sessions share one cache,
# so writing in place lets a concurrent reader see a half-written file.  A torn
# read parses as "no cache", which sends that session down the *blocking* fetch
# path — statusline latency plus a redundant API call.
function _QL_Write {
    param([string]$Json)
    $dir = Split-Path $script:_QL_Cache -Parent
    if (-not (Test-Path $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$($script:_QL_Cache).$PID.tmp"
    try {
        $Json | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $script:_QL_Cache -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        # Fall back to an in-place write rather than leaving no cache at all.
        try { $Json | Set-Content -Path $script:_QL_Cache -Encoding UTF8 } catch {}
    }
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
        schema_version       = 3
        lib_version          = $script:_QL_Version
        source_url           = $script:_QL_Api
        attempted_at_utc     = $Ts
        fetched_at_utc       = $Ts
        current_session      = [ordered]@{ percent_used = $curPct;    resets_at = $curAt;    resets_in = $curIn;    percent_unknown = $false }
        weekly_limits        = [ordered]@{ percent_used = $weeklyPct; resets_at = $weeklyAt; resets_in = $weeklyIn; percent_unknown = $false }
        scoped_limits        = _QL_BuildScopedLimits $UsageData
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

        $v = _QL_DateToIso (_QL_GetObjectValue $Previous @("current_session", "resets_at"))
        if (-not [string]::IsNullOrWhiteSpace($v)) { $curAt = $v }

        $v = _QL_DateToIso (_QL_GetObjectValue $Previous @("weekly_limits", "resets_at"))
        if (-not [string]::IsNullOrWhiteSpace($v)) { $weeklyAt = $v }

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

    # Recompute resets_in from stored timestamps (time has passed since last
    # success).  If a window has already rolled over we can prove the carried
    # percentage is obsolete — the usage reset and we never saw the new figure —
    # so drop it rather than displaying a number we know is wrong.  Callers
    # render "" as "no data" and omit the segment, which beats a stale reading
    # that looks authoritative.  Same rule _QL_CarryScopedLimits applies.
    $curUnknown    = $false
    $weeklyUnknown = $false
    if (-not [string]::IsNullOrWhiteSpace($curAt)) {
        if (_QL_IsPast $curAt) {
            $curPct = $null; $curAt = ""; $curIn = ""; $curUnknown = $true
        } else {
            $r = _QL_GetTimeUntil $curAt
            if (-not [string]::IsNullOrWhiteSpace($r)) { $curIn = $r }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($weeklyAt)) {
        if (_QL_IsPast $weeklyAt) {
            $weeklyPct = $null; $weeklyAt = ""; $weeklyIn = ""; $weeklyUnknown = $true
        } else {
            $r = _QL_GetTimeUntil $weeklyAt
            if (-not [string]::IsNullOrWhiteSpace($r)) { $weeklyIn = $r }
        }
    }

    # Purchased balance does not reset on a window boundary, so unlike the
    # percentages it is still true when a fetch fails.
    $balance = $null
    if ($null -ne $Previous) {
        $b = _QL_GetObjectValue $Previous @("purchased_balance_usd")
        if ($null -ne $b) { try { $balance = [double]$b } catch { $balance = $null } }
    }

    $payload = [ordered]@{
        schema_version       = 3
        lib_version          = $script:_QL_Version
        provider             = $script:_QL_Provider
        source_url           = $sourceUrl
        attempted_at_utc     = $NowUtc
        fetched_at_utc       = $fetchedAt
        current_session      = [ordered]@{ percent_used = $curPct;    resets_at = $curAt;    resets_in = $curIn;    percent_unknown = $curUnknown    }
        weekly_limits        = [ordered]@{ percent_used = $weeklyPct; resets_at = $weeklyAt; resets_in = $weeklyIn; percent_unknown = $weeklyUnknown }
        scoped_limits        = _QL_CarryScopedLimits $Previous
        extra_usage          = [ordered]@{
            is_enabled    = $extraIsEnabled
            utilization   = $extraUtil
            used_credits  = $extraCredits
            monthly_limit = $extraLimit
        }
        purchased_balance_usd = $balance
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
    if ((_QL_UseProvider) -eq "ollama") { Invoke-QuotaFetchOnceOllama; return }

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
        $data = Invoke-RestMethod -Method Get -Uri $script:_QL_Api -Headers $headers `
                    -TimeoutSec $script:_QL_Timeout -ErrorAction Stop
        if ($null -eq $data -or ($null -eq $data.five_hour -and $null -eq $data.seven_day)) {
            # HTTP 200 but no usage fields — API format changed or body isn't JSON
            $prev    = _QL_ReadCacheRaw
            $payload = _QL_BuildStale $prev $nowUtc "API response could not be parsed (no usage fields)." 200
        } else {
            $payload = _QL_BuildSuccess $data $nowUtc
        }
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

<#
.SYNOPSIS
Fetches https://ollama.com/api/balance and writes quota-data-ollama.json.

.DESCRIPTION
Response shape:
  {"included":{"session":{"remaining_percent":99.1,"resets_at":"..."},
               "weekly": {"remaining_percent":73.81,"resets_at":"..."}},
   "purchased":{"balance_usd":0.73493}}

Undocumented, and it moved from /api/usage during an October 2026 deploy, so a
body without .included counts as a failure rather than as "no limits".
#>
function Invoke-QuotaFetchOnceOllama {
    $nowUtc = _QL_NowUtc
    $token  = $env:OLLAMA_API_KEY

    if ([string]::IsNullOrWhiteSpace($token)) {
        $prev = _QL_ReadCacheRaw
        _QL_Write (_QL_BuildStale $prev $nowUtc "OLLAMA_API_KEY is not set." $null)
        return
    }

    $headers = @{
        "Authorization" = "Bearer $token"
        "Accept"        = "application/json"
    }

    try {
        $data = Invoke-RestMethod -Method Get -Uri $script:_QL_OllamaApi -Headers $headers `
                    -TimeoutSec $script:_QL_Timeout -ErrorAction Stop
        if ($null -eq $data -or $null -eq $data.included) {
            $prev    = _QL_ReadCacheRaw
            $payload = _QL_BuildStale $prev $nowUtc "Ollama response could not be parsed (no included block)." 200
        } else {
            $payload = _QL_BuildSuccessOllama $data $nowUtc
        }
    } catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}

        $msg = if ($statusCode -eq 401) {
            "Ollama API key rejected (HTTP 401)."
        } elseif ($statusCode -eq 429) {
            "Rate limited by Ollama (HTTP 429)."
        } elseif ($null -ne $statusCode) {
            "Ollama request failed (HTTP $statusCode)."
        } else {
            "Request failed (network error or timeout)."
        }

        $prev    = _QL_ReadCacheRaw
        $payload = _QL_BuildStale $prev $nowUtc $msg $statusCode
    }

    _QL_Write $payload
}

# Ollama reports what is LEFT; everything downstream is in percent USED.
function _QL_BuildSuccessOllama {
    param($BalanceData, [string]$Ts)

    $session = $BalanceData.included.session
    $weekly  = $BalanceData.included.weekly

    $curPct = $null
    if ($null -ne $session -and $null -ne $session.remaining_percent) {
        $curPct = _QL_NormalizePercent (100 - [double]$session.remaining_percent)
    }
    $curAt = if ($null -ne $session -and $null -ne $session.resets_at) { _QL_DateToIso $session.resets_at } else { "" }
    $curIn = if (-not [string]::IsNullOrWhiteSpace($curAt)) { _QL_GetTimeUntil $curAt } else { "" }

    $weeklyPct = $null
    if ($null -ne $weekly -and $null -ne $weekly.remaining_percent) {
        $weeklyPct = _QL_NormalizePercent (100 - [double]$weekly.remaining_percent)
    }
    $weeklyAt = if ($null -ne $weekly -and $null -ne $weekly.resets_at) { _QL_DateToIso $weekly.resets_at } else { "" }
    $weeklyIn = if (-not [string]::IsNullOrWhiteSpace($weeklyAt)) { _QL_GetTimeUntil $weeklyAt } else { "" }

    $balance = $null
    if ($null -ne $BalanceData.purchased -and $null -ne $BalanceData.purchased.balance_usd) {
        try { $balance = [double]$BalanceData.purchased.balance_usd } catch { $balance = $null }
    }

    # Same schema as the Anthropic path, so _QL_ParseCache and the statusline
    # templates need no provider-specific branches.  scoped_limits is empty
    # because Ollama has no per-model allowances: that is what stops a stale
    # "Fable:0%" segment following you into an Ollama session.
    $payload = [ordered]@{
        schema_version        = 3
        lib_version           = $script:_QL_Version
        provider              = "ollama"
        source_url            = $script:_QL_OllamaApi
        attempted_at_utc      = $Ts
        fetched_at_utc        = $Ts
        current_session       = [ordered]@{ percent_used = $curPct;    resets_at = $curAt;    resets_in = $curIn;    percent_unknown = $false }
        weekly_limits         = [ordered]@{ percent_used = $weeklyPct; resets_at = $weeklyAt; resets_in = $weeklyIn; percent_unknown = $false }
        scoped_limits         = @()
        extra_usage           = [ordered]@{ is_enabled = $null; utilization = $null; used_credits = $null; monthly_limit = $null }
        purchased_balance_usd = $balance
        quota_used_pct        = $curPct
        weekly_used_pct       = $weeklyPct
        resets_in             = $curIn
        weekly_resets         = $weeklyIn
        updated               = $Ts
        valid                 = $true
        stale                 = $false
        stale_since           = $null
        stale_reason          = ""
        last_success_updated  = $Ts
        error                 = ""
        api_status_code       = 200
        consecutive_failures  = 0
    }
    return $payload | ConvertTo-Json -Depth 10
}

# ── Internal: populate $QuotaResult from cache ────────────────────────────────

function _QL_ParseCache {
    $script:QuotaResult = @{
        pct                    = ""
        weekly_pct             = ""
        resets_in              = ""
        weekly_resets_in       = ""
        stale                  = "false"
        valid                  = "false"
        error                  = ""
        pct_unknown            = "false"
        weekly_pct_unknown     = "false"
        scoped_summary         = ""
        scoped_alert           = "false"
        scoped_worst           = ""
        scoped_worst_pct       = ""
        scoped_worst_resets_in = ""
        balance_usd            = ""
        provider               = $script:_QL_Provider
    }

    if (-not (Test-Path $script:_QL_Cache -PathType Leaf)) { return }

    try {
        $data = Get-Content $script:_QL_Cache -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $script:QuotaResult['error'] = "Cannot parse quota-data.json (delete it to reset)."
        return
    }

    $v = _QL_GetObjectValue $data @("quota_used_pct")
    if ($null -ne $v) { $script:QuotaResult['pct'] = [string]$v }

    $v = _QL_GetObjectValue $data @("weekly_used_pct")
    if ($null -ne $v) { $script:QuotaResult['weekly_pct'] = [string]$v }

    # Invariant culture: a comma decimal separator would reach the statusline
    # and break the numeric comparison that decides whether to show it.
    $v = _QL_GetObjectValue $data @("purchased_balance_usd")
    if ($null -ne $v) {
        try { $script:QuotaResult['balance_usd'] = ([double]$v).ToString([cultureinfo]::InvariantCulture) } catch {}
    }

    # Recompute countdowns from the stored timestamps rather than trusting the
    # strings written at fetch time.  On a cache hit those strings are as old as
    # the cache, so a 5-minute TTL means a countdown that under-reports by up to
    # 5 minutes — and any longer TTL makes it worse.  Fall back to the stored
    # string only when there's no timestamp to compute from.
    $script:QuotaResult['resets_in']        = _QL_CountdownFor $data @("current_session") @("resets_in")
    $script:QuotaResult['weekly_resets_in'] = _QL_CountdownFor $data @("weekly_limits")   @("weekly_resets")

    $stale = _QL_GetObjectValue $data @("stale")
    $script:QuotaResult['stale'] = if ($stale -eq $true) { "true" } else { "false" }

    $valid = _QL_GetObjectValue $data @("valid")
    $script:QuotaResult['valid'] = if ($valid -eq $true) { "true" } else { "false" }

    $v = _QL_GetObjectValue $data @("error")
    if ([string]::IsNullOrWhiteSpace([string]$v)) { $v = _QL_GetObjectValue $data @("stale_reason") }
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $script:QuotaResult['error'] = [string]$v }

    # "We know this bucket exists but not its current value" — distinct from
    # "no data at all".  Callers should render "?" rather than omitting the
    # segment, so a rolled-over window doesn't read as "no limit".
    if ((_QL_GetObjectValue $data @("current_session", "percent_unknown")) -eq $true) {
        $script:QuotaResult['pct_unknown'] = "true"
    }
    if ((_QL_GetObjectValue $data @("weekly_limits", "percent_unknown")) -eq $true) {
        $script:QuotaResult['weekly_pct_unknown'] = "true"
    }

    _QL_ParseScopedLimits $data
}

# Flatten scoped_limits into the display-ready $QuotaResult keys.
function _QL_ParseScopedLimits {
    param($Data)

    $scoped = _QL_GetObjectValue $Data @("scoped_limits")
    if ($null -eq $scoped) { return }

    $weeklyAt = _QL_DateToIso (_QL_GetObjectValue $Data @("weekly_limits", "resets_at"))
    $parts    = @()
    $worst    = $null
    $worstPct = -1
    $alert    = $false

    foreach ($entry in @($scoped)) {
        if ($null -eq $entry) { continue }
        $label = [string](_QL_GetObjectValue $entry @("label"))
        $pct   = _QL_NormalizePercent (_QL_GetObjectValue $entry @("percent_used"))
        if ([string]::IsNullOrWhiteSpace($label) -or $null -eq $pct) { continue }

        $parts += "${label}:${pct}%"

        $sev = [string](_QL_GetObjectValue $entry @("severity"))
        if (-not [string]::IsNullOrWhiteSpace($sev) -and $sev -ne "normal") { $alert = $true }

        if ([double]$pct -gt $worstPct) { $worstPct = [double]$pct; $worst = $entry }
    }

    if ($parts.Count -gt 0) { $script:QuotaResult['scoped_summary'] = ($parts -join " ") }
    if ($alert)             { $script:QuotaResult['scoped_alert']   = "true" }
    if ($null -eq $worst)   { return }

    $script:QuotaResult['scoped_worst']     = [string](_QL_GetObjectValue $worst @("label"))
    $script:QuotaResult['scoped_worst_pct'] = [string](_QL_NormalizePercent (_QL_GetObjectValue $worst @("percent_used")))

    # Only surface a separate countdown when this bucket resets on a different
    # boundary than the weekly one — today they coincide, so printing both would
    # just be noise.  A promotional bucket on its own cadence lights up for free.
    $at = _QL_DateToIso (_QL_GetObjectValue $worst @("resets_at"))
    if ([string]::IsNullOrWhiteSpace($at)) { return }
    if (-not (_QL_SameInstant $at $weeklyAt)) {
        $script:QuotaResult['scoped_worst_resets_in'] = _QL_CountdownFor $worst @() @("resets_in")
    }
}

# Live countdown for one bucket: derive it from the bucket's resets_at, and only
# fall back to the string stored at fetch time when no timestamp is available.
# $BucketPath is the bucket object (e.g. @("current_session")); $LegacyPath is
# the flat top-level key kept for older cache files (e.g. @("resets_in")).
function _QL_CountdownFor {
    param($Data, [string[]]$BucketPath, [string[]]$LegacyPath)

    # _QL_DateToIso, not [string]: ConvertFrom-Json turns an ISO timestamp into a
    # local-time DateTime, and casting that to string drops the UTC marker — the
    # countdown then comes out wrong by the machine's UTC offset, which is enough
    # to make a live bucket look already-reset.
    $at = _QL_DateToIso (_QL_GetObjectValue $Data ($BucketPath + @("resets_at")))
    if (-not [string]::IsNullOrWhiteSpace($at)) {
        $r = _QL_GetTimeUntil $at
        if (-not [string]::IsNullOrWhiteSpace($r)) { return $r }
    }
    $v = _QL_GetObjectValue $Data ($BucketPath + @("resets_in"))
    if ([string]::IsNullOrWhiteSpace([string]$v)) { $v = _QL_GetObjectValue $Data $LegacyPath }
    if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    return ""
}

# Two ISO timestamps within a minute of each other — close enough that they're
# the same reset boundary (the API's differ by microseconds).
function _QL_SameInstant {
    param([AllowNull()]$RawA, [AllowNull()]$RawB)
    $A = _QL_DateToIso $RawA
    $B = _QL_DateToIso $RawB
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try {
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $ta = [DateTimeOffset]::Parse($A, $culture, $styles).UtcDateTime
        $tb = [DateTimeOffset]::Parse($B, $culture, $styles).UtcDateTime
    } catch { return $false }
    return ([Math]::Abs(($ta - $tb).TotalSeconds) -lt 60)
}
