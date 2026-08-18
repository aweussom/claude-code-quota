#!/usr/bin/env bash
#
# quota-lib.sh — Self-contained quota library for Claude Code statusline
#
# Source this file, then call:
#   quota_get [ttl_seconds]
#
# Results are in the global associative array QUOTA_RESULT[]:
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
#   scoped_summary   – "Fable:90% Mythos:12%", or ""
#   scoped_alert     – "true" if any scoped limit has severity != normal
#   scoped_worst     – label of the highest scoped limit, or ""
#   scoped_worst_pct – its percentage, or ""
#   scoped_worst_resets_in – its countdown, but ONLY when it differs from the
#                            weekly reset; "" when they coincide (the usual
#                            case), so callers don't print it twice.
#
# Cache file: ~/.claude/quota-data.json  (written atomically by this library)
# Lock file:  ~/.claude/.quota-fetch.lock (PID of any in-flight background fetch)
#
# NOTE: Do NOT add `set -euo pipefail` here — this file is sourced by the
#       statusline script and must not alter the parent shell's error behaviour.

# ── Config ────────────────────────────────────────────────────────────────────
_QL_VERSION="2.0.0"
_QL_CACHE="${HOME}/.claude/quota-data.json"
_QL_LOCK="${HOME}/.claude/.quota-fetch.lock"
_QL_CREDS="${HOME}/.claude/.credentials.json"
_QL_API="https://api.anthropic.com/api/oauth/usage"
_QL_BETA="oauth-2025-04-20"
_QL_TIMEOUT=20
# A held lock older than this is treated as abandoned.  Needed because PIDs get
# recycled: without an age bound, a lock whose PID is reused by an unrelated
# process reads as a live fetch and blocks refreshes indefinitely.
_QL_LOCK_MAX_AGE=120

declare -gA QUOTA_RESULT

# ── Public API ────────────────────────────────────────────────────────────────

# quota_get [ttl_seconds]
#   Fires a background refresh if the cache is older than ttl seconds.
#   On the very first call (no cache file) it blocks briefly for initial data.
#   Always populates QUOTA_RESULT[] from whatever is in the cache file.
quota_get() {
    local ttl="${1:-60}"

    # Taper retries after repeated failures so a failing endpoint isn't hit on
    # every refresh: 60s, 120s, 240s ... capped at 15 min.  Uses the
    # consecutive_failures counter already in the cache — no extra state.  The
    # caller's TTL is a floor, never shortened.
    local eff_ttl="$ttl"
    if [[ -f "$_QL_CACHE" ]]; then
        local fails backoff i
        fails=$(jq -r '.consecutive_failures // 0' "$_QL_CACHE" 2>/dev/null)
        [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
        if (( fails > 0 )); then
            backoff=60
            for (( i = 1; i < fails && backoff < 900; i++ )); do backoff=$(( backoff * 2 )); done
            (( backoff > 900 )) && backoff=900
            (( backoff > eff_ttl )) && eff_ttl="$backoff"
        fi
    fi

    local needs_refresh=true
    if [[ -f "$_QL_CACHE" ]]; then
        local mtime age
        mtime=$(stat -c %Y "$_QL_CACHE" 2>/dev/null) && {
            age=$(( $(date +%s) - mtime ))
            (( age < eff_ttl )) && needs_refresh=false
        }
    fi

    if [[ "$needs_refresh" == "true" ]] && _ql_try_lock; then
        if [[ ! -f "$_QL_CACHE" ]]; then
            # First ever call — block briefly so the statusline isn't blank
            _ql_fetch_once
            rm -f "$_QL_LOCK"
        else
            # Stale cache — refresh in background, show previous data this frame.
            # The child restamps the lock with its own PID: this shell exits as
            # soon as the statusline is drawn, so leaving the parent's PID there
            # would make the lock look abandoned while the fetch is still running.
            { printf '%s\n' "$BASHPID" > "$_QL_LOCK"; _ql_fetch_once; rm -f "$_QL_LOCK"; } &>/dev/null &
        fi
    fi

    _ql_parse_cache
}

# ── Internal: fetch lock ──────────────────────────────────────────────────────

# Try to claim the fetch lock.  Returns 0 if we own it, 1 if someone else does.
#
# Creation goes through noclobber (O_EXCL) rather than test-then-write: with
# several sessions refreshing a cold cache, a check-then-write lock lets all of
# them pass the check and fetch simultaneously.
_ql_try_lock() {
    local attempt pid mtime age
    for attempt in 1 2; do
        if ( set -o noclobber; printf '%s\n' "$$" > "$_QL_LOCK" ) 2>/dev/null; then
            return 0
        fi
        # Someone holds it.  Steal only if the owner is gone or the lock is old
        # enough that we no longer trust the PID (see _QL_LOCK_MAX_AGE).
        pid=$(cat "$_QL_LOCK" 2>/dev/null)
        if mtime=$(stat -c %Y "$_QL_LOCK" 2>/dev/null); then
            age=$(( $(date +%s) - mtime ))
        else
            age=$(( _QL_LOCK_MAX_AGE + 1 ))
        fi
        if (( age <= _QL_LOCK_MAX_AGE )) && [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 1        # a live fetch really is in flight
        fi
        rm -f "$_QL_LOCK"
    done
    return 1
}

# ── Internal: fetch ───────────────────────────────────────────────────────────

_ql_fetch_once() {
    local now token tmpfile http_code curl_rc body payload prev

    now=$(_ql_now_utc)

    if ! token=$(_ql_get_token); then
        prev=$(_ql_read_cache_raw)
        _ql_write "$(_ql_build_stale "$prev" "$now" "Cannot read OAuth token." "null")"
        return 1
    fi

    tmpfile=$(mktemp)
    curl_rc=0
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        --max-time "$_QL_TIMEOUT" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: $_QL_BETA" \
        -H "Accept: application/json" \
        "$_QL_API" 2>/dev/null) || curl_rc=$?
    body=$(cat "$tmpfile"); rm -f "$tmpfile"

    if [[ $curl_rc -ne 0 || -z "$http_code" || "$http_code" == "000" ]]; then
        prev=$(_ql_read_cache_raw)
        payload=$(_ql_build_stale "$prev" "$now" "Request failed (network error or timeout)." "null")
    elif [[ "$http_code" == "200" ]]; then
        if echo "$body" | jq -e '(.five_hour // .seven_day) != null' >/dev/null 2>&1; then
            payload=$(_ql_build_success "$body" "$now")
        else
            # HTTP 200 but no usage fields — API format changed or body isn't JSON
            prev=$(_ql_read_cache_raw)
            payload=$(_ql_build_stale "$prev" "$now" "API response could not be parsed (no usage fields)." "200")
        fi
    elif [[ "$http_code" == "401" ]]; then
        prev=$(_ql_read_cache_raw)
        payload=$(_ql_build_stale "$prev" "$now" "OAuth token rejected (HTTP 401). Re-authenticate Claude Code." "401")
    elif [[ "$http_code" == "429" ]]; then
        prev=$(_ql_read_cache_raw)
        payload=$(_ql_build_stale "$prev" "$now" "Rate limited by API (HTTP 429)." "429")
    else
        prev=$(_ql_read_cache_raw)
        payload=$(_ql_build_stale "$prev" "$now" "API request failed (HTTP $http_code)." "$http_code")
    fi

    _ql_write "$payload"
}

# ── Internal: small helpers ───────────────────────────────────────────────────

_ql_now_utc() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }

_ql_get_token() {
    [[ ! -f "$_QL_CREDS" ]] && return 1
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$_QL_CREDS" 2>/dev/null)
    [[ -z "$token" ]] && return 1
    echo "$token"
}

# Output a valid JSON number (integer or 2-dp float) for a 0–100 percentage,
# or "null" if the input is missing, out of range, or non-numeric.
_ql_norm_pct() {
    local v="$1"
    [[ -z "$v" || "$v" == "null" ]] && echo "null" && return
    awk -v v="$v" 'BEGIN {
        if (v !~ /^-?[0-9]+(\.[0-9]*)?$/) { print "null"; exit }
        n = v + 0
        if (n < 0 || n > 100) { print "null"; exit }
        r = int(n + 0.5); d = n - r; if (d < 0) d = -d
        if (d < 0.0000001) { printf "%d\n", r } else { printf "%.2f\n", n }
    }'
}

# Human-readable duration from now until an ISO 8601 timestamp.
_ql_time_until() {
    local ts="$1"
    [[ -z "$ts" || "$ts" == "null" ]] && echo "" && return
    local target now delta
    target=$(date -d "$ts" +%s 2>/dev/null) || { echo ""; return; }
    now=$(date -u +%s); delta=$(( target - now ))
    (( delta <= 0 )) && echo "0 min" && return
    local total_min=$(( delta / 60 ))
    local days=$(( total_min / 1440 ))
    local hours=$(( (total_min % 1440) / 60 ))
    local mins=$(( total_min % 60 ))
    if   (( days > 0 ));  then echo "${days}d${hours}h"
    elif (( hours > 0 )); then echo "${hours}h${mins}m"
    else echo "${mins}m"
    fi
}

# ── Internal: scoped limits ───────────────────────────────────────────────────
#
# The API's limits[] array mixes the account-wide buckets (session, weekly_all —
# both scope=null) with narrower allowances that apply to one model or surface
# (scope != null).  Those narrower ones come and go with the plan, so nothing
# here hardcodes a model name: the label is read from the payload.

# Extract scoped limits from a live API response body.  Rebuilt from scratch on
# every success, so a bucket the account no longer has stops appearing.
# resets_in is left empty here — jq can't do date arithmetic; see _ql_scoped_pass.
_ql_scoped_from_body() {
    echo "$1" | jq -c '
        [ (.limits // [])[]
          | select(.scope != null and .percent != null)
          | {
              label:        (.scope.model.display_name // .scope.model.id // .scope.surface // .kind // "scoped"),
              kind:         (.kind // ""),
              percent_used: .percent,
              severity:     (.severity // ""),
              resets_at:    (.resets_at // ""),
              resets_in:    "",
              is_active:    .is_active
            }
        ]' 2>/dev/null || echo "[]"
}

# Refresh each entry's resets_in from its stored resets_at.
# $2 = "true" to also drop buckets whose window has already rolled over — used on
# the stale path, where the cached percentage is known wrong and there is no
# fresh value to replace it with.
_ql_scoped_pass() {
    local arr="$1" drop_expired="${2:-false}"
    local n
    n=$(echo "$arr" | jq 'length' 2>/dev/null) || { echo "[]"; return; }
    [[ -z "$n" || "$n" == "0" ]] && { echo "[]"; return; }

    local out="[]" i at r target now entry
    now=$(date -u +%s)
    for (( i = 0; i < n; i++ )); do
        at=$(echo "$arr" | jq -r ".[$i].resets_at // \"\"")
        r=""
        if [[ -n "$at" && "$at" != "null" ]]; then
            target=$(date -d "$at" +%s 2>/dev/null) || target=""
            if [[ "$drop_expired" == "true" && -n "$target" ]] && (( target <= now )); then
                continue
            fi
            r=$(_ql_time_until "$at")
        fi
        entry=$(echo "$arr" | jq -c --arg r "$r" ".[$i] + {resets_in: \$r}") || continue
        out=$(jq -c -n --argjson acc "$out" --argjson e "$entry" '$acc + [$e]') || continue
    done
    printf '%s' "$out"
}

# Live countdown for one bucket: derive it from the bucket's resets_at, falling
# back to the string stored at fetch time only when there is no timestamp.
#   $1 = resets_at (ISO 8601, may be empty)
#   $2 = resets_in stored at fetch time (fallback, may be empty)
_ql_countdown_for() {
    local at="$1" stored="$2" r
    if [[ -n "$at" && "$at" != "null" ]]; then
        r=$(_ql_time_until "$at")
        [[ -n "$r" ]] && { printf '%s' "$r"; return; }
    fi
    [[ "$stored" == "null" ]] && stored=""
    printf '%s' "$stored"
}

# Return raw JSON from the cache file, or "null" if absent/corrupt.
_ql_read_cache_raw() {
    [[ ! -f "$_QL_CACHE" ]] && echo "null" && return
    jq '.' "$_QL_CACHE" 2>/dev/null || echo "null"
}

# Write the cache file atomically (parent dir created if needed).
#
# Write-then-rename matters here: several Claude Code sessions share one cache,
# so a plain redirect (truncate, then write) lets a concurrent reader see a
# half-written file.  A torn read parses as "no cache", which sends that session
# down the *blocking* fetch path — statusline latency plus a redundant API call.
# rename(2) within the same directory is atomic, so readers see old or new, never
# a mixture.
_ql_write() {
    mkdir -p "$(dirname "$_QL_CACHE")"
    local tmp
    if ! tmp=$(mktemp "${_QL_CACHE}.XXXXXX" 2>/dev/null); then
        printf '%s\n' "$1" > "$_QL_CACHE"   # last resort; better than no cache
        return
    fi
    if printf '%s\n' "$1" > "$tmp"; then
        mv -f "$tmp" "$_QL_CACHE" || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# ── Internal: payload builders ────────────────────────────────────────────────

_ql_build_success() {
    local body="$1" ts="$2"
    local cur_pct cur_at cur_in weekly_pct weekly_at weekly_in scoped
    local xena_ena xena_pct xena_cred xena_lim

    scoped=$(_ql_scoped_pass "$(_ql_scoped_from_body "$body")" false)

    cur_pct=$(_ql_norm_pct "$(echo "$body" | jq -r '.five_hour.utilization // "null"')")
    cur_at=$(echo "$body" | jq -r '.five_hour.resets_at // ""')
    cur_in=$( [[ -n "$cur_at" && "$cur_at" != "null" ]] && _ql_time_until "$cur_at" || echo "" )

    weekly_pct=$(_ql_norm_pct "$(echo "$body" | jq -r '.seven_day.utilization // "null"')")
    weekly_at=$(echo "$body" | jq -r '.seven_day.resets_at // ""')
    weekly_in=$( [[ -n "$weekly_at" && "$weekly_at" != "null" ]] && _ql_time_until "$weekly_at" || echo "" )

    xena_ena=$(echo "$body" | jq '.extra_usage.is_enabled // null')
    xena_pct=$(_ql_norm_pct "$(echo "$body" | jq -r '.extra_usage.utilization // "null"')")
    xena_cred=$(echo "$body" | jq '.extra_usage.used_credits // null')
    xena_lim=$(echo "$body"  | jq '.extra_usage.monthly_limit // null')

    jq -n \
        --arg     src        "$_QL_API" \
        --arg     ts         "$ts" \
        --argjson cur_pct    "$cur_pct" \
        --arg     cur_at     "$cur_at" \
        --arg     cur_in     "$cur_in" \
        --argjson weekly_pct "$weekly_pct" \
        --arg     weekly_at  "$weekly_at" \
        --arg     weekly_in  "$weekly_in" \
        --argjson xena_ena   "$xena_ena" \
        --argjson xena_pct   "$xena_pct" \
        --argjson xena_cred  "$xena_cred" \
        --argjson xena_lim   "$xena_lim" \
        --argjson scoped     "$scoped" \
        --arg     ver        "$_QL_VERSION" \
        '{
            schema_version:       3,
            lib_version:          $ver,
            source_url:           $src,
            attempted_at_utc:     $ts,
            fetched_at_utc:       $ts,
            current_session:      { percent_used: $cur_pct,    resets_at: $cur_at,    resets_in: $cur_in,    percent_unknown: false },
            weekly_limits:        { percent_used: $weekly_pct, resets_at: $weekly_at, resets_in: $weekly_in, percent_unknown: false },
            scoped_limits:        $scoped,
            extra_usage:          { is_enabled: $xena_ena, utilization: $xena_pct, used_credits: $xena_cred, monthly_limit: $xena_lim },
            quota_used_pct:       $cur_pct,
            weekly_used_pct:      $weekly_pct,
            resets_in:            $cur_in,
            weekly_resets:        $weekly_in,
            updated:              $ts,
            valid:                true,
            stale:                false,
            stale_since:          null,
            stale_reason:         "",
            last_success_updated: $ts,
            error:                "",
            api_status_code:      200,
            consecutive_failures: 0
        }'
}

_ql_build_stale() {
    local prev="$1" now_utc="$2" err_text="$3" status_code="$4"

    local cur_pct="null" weekly_pct="null"
    local cur_at="" weekly_at="" cur_in="" weekly_in=""
    local xena_ena="null" xena_pct="null" xena_cred="null" xena_lim="null"
    local src="$_QL_API" fetched_at="" last_success=""
    local stale_since="$now_utc" prev_failures=0
    local scoped="[]"
    local cur_unknown="false" weekly_unknown="false"

    # Only a *failed* fetch carries scoped limits forward — a successful one is
    # authoritative, including by omission.
    if [[ -n "$prev" && "$prev" != "null" ]]; then
        scoped=$(_ql_scoped_pass "$(echo "$prev" | jq -c '.scoped_limits // []' 2>/dev/null || echo '[]')" true)
    fi

    if [[ -n "$prev" && "$prev" != "null" ]]; then
        local v

        v=$(echo "$prev" | jq -r '.current_session.percent_used // empty')
        if [[ -n "$v" ]]; then
            cur_pct=$(_ql_norm_pct "$v")
        else
            cur_pct=$(_ql_norm_pct "$(echo "$prev" | jq -r '.quota_used_pct // "null"')")
        fi

        v=$(echo "$prev" | jq -r '.weekly_limits.percent_used // empty')
        if [[ -n "$v" ]]; then
            weekly_pct=$(_ql_norm_pct "$v")
        else
            weekly_pct=$(_ql_norm_pct "$(echo "$prev" | jq -r '.weekly_used_pct // "null"')")
        fi

        cur_at=$(echo "$prev" | jq -r '.current_session.resets_at // ""')
        weekly_at=$(echo "$prev" | jq -r '.weekly_limits.resets_at // ""')

        v=$(echo "$prev" | jq -r '.current_session.resets_in // empty')
        [[ -n "$v" && "$v" != "null" ]] \
            && cur_in="$v" \
            || cur_in=$(echo "$prev" | jq -r '.resets_in // ""')

        v=$(echo "$prev" | jq -r '.weekly_limits.resets_in // empty')
        [[ -n "$v" && "$v" != "null" ]] \
            && weekly_in="$v" \
            || weekly_in=$(echo "$prev" | jq -r '.weekly_resets // ""')

        xena_ena=$(echo "$prev"  | jq '.extra_usage.is_enabled // null')
        xena_pct=$(_ql_norm_pct "$(echo "$prev" | jq -r '.extra_usage.utilization // "null"')")
        xena_cred=$(echo "$prev" | jq '.extra_usage.used_credits // null')
        xena_lim=$(echo "$prev"  | jq '.extra_usage.monthly_limit // null')

        v=$(echo "$prev" | jq -r '.source_url // empty')
        [[ -n "$v" ]] && src="$v"

        fetched_at=$(echo "$prev" | jq -r '.fetched_at_utc // ""')

        last_success=$(echo "$prev" | jq -r '.last_success_updated // ""')
        if [[ -z "$last_success" ]]; then
            local is_valid
            is_valid=$(echo "$prev" | jq -r '.valid // false')
            if [[ "$is_valid" == "true" ]]; then
                last_success=$(echo "$prev" | jq -r '.updated // ""')
            fi
            [[ -z "$last_success" && -n "$fetched_at" ]] && last_success="$fetched_at"
        fi

        local old_stale old_ss
        old_stale=$(echo "$prev" | jq -r '.stale // false')
        if [[ "$old_stale" == "true" ]]; then
            old_ss=$(echo "$prev" | jq -r '.stale_since // empty')
            [[ -n "$old_ss" && "$old_ss" != "null" ]] && stale_since="$old_ss"
        fi

        v=$(echo "$prev" | jq -r '.consecutive_failures // 0')
        [[ "$v" =~ ^[0-9]+$ ]] && prev_failures="$v"
    fi

    # Recompute resets_in from timestamps (time has passed since last success).
    # If a window has already rolled over we can prove the carried percentage is
    # obsolete — the usage reset and we never saw the new figure — so drop it
    # rather than displaying a number we know is wrong.  Callers render "" as
    # "no data" and omit the segment, which beats a stale reading that looks
    # authoritative.  Same rule _ql_scoped_pass applies to scoped buckets.
    local _now r t
    _now=$(date -u +%s)
    if [[ -n "$cur_at" && "$cur_at" != "null" ]]; then
        t=$(date -d "$cur_at" +%s 2>/dev/null) || t=""
        if [[ -n "$t" ]] && (( t <= _now )); then
            cur_pct="null"; cur_at=""; cur_in=""; cur_unknown="true"
        else
            r=$(_ql_time_until "$cur_at"); [[ -n "$r" ]] && cur_in="$r"
        fi
    fi
    if [[ -n "$weekly_at" && "$weekly_at" != "null" ]]; then
        t=$(date -d "$weekly_at" +%s 2>/dev/null) || t=""
        if [[ -n "$t" ]] && (( t <= _now )); then
            weekly_pct="null"; weekly_at=""; weekly_in=""; weekly_unknown="true"
        else
            r=$(_ql_time_until "$weekly_at"); [[ -n "$r" ]] && weekly_in="$r"
        fi
    fi

    local consec=$(( prev_failures + 1 ))
    local jq_status_code jq_stale_since
    [[ -n "$status_code" && "$status_code" != "null" ]] \
        && jq_status_code="$status_code" || jq_status_code="null"
    [[ -n "$stale_since" ]] \
        && jq_stale_since="\"$stale_since\"" || jq_stale_since="null"

    jq -n \
        --arg     src         "$src" \
        --arg     now         "$now_utc" \
        --arg     fetched_at  "$fetched_at" \
        --argjson cur_pct     "$cur_pct" \
        --arg     cur_at      "$cur_at" \
        --arg     cur_in      "$cur_in" \
        --argjson weekly_pct  "$weekly_pct" \
        --arg     weekly_at   "$weekly_at" \
        --arg     weekly_in   "$weekly_in" \
        --argjson xena_ena    "$xena_ena" \
        --argjson xena_pct    "$xena_pct" \
        --argjson xena_cred   "$xena_cred" \
        --argjson xena_lim    "$xena_lim" \
        --argjson stale_since "$jq_stale_since" \
        --arg     err         "$err_text" \
        --argjson http_code   "$jq_status_code" \
        --argjson consec      "$consec" \
        --argjson scoped      "$scoped" \
        --argjson cur_unk     "$cur_unknown" \
        --argjson weekly_unk  "$weekly_unknown" \
        --arg     last_suc    "$last_success" \
        --arg     ver         "$_QL_VERSION" \
        '{
            schema_version:       3,
            lib_version:          $ver,
            source_url:           $src,
            attempted_at_utc:     $now,
            fetched_at_utc:       $fetched_at,
            current_session:      { percent_used: $cur_pct,    resets_at: $cur_at,    resets_in: $cur_in,    percent_unknown: $cur_unk },
            weekly_limits:        { percent_used: $weekly_pct, resets_at: $weekly_at, resets_in: $weekly_in, percent_unknown: $weekly_unk },
            scoped_limits:        $scoped,
            extra_usage:          { is_enabled: $xena_ena, utilization: $xena_pct, used_credits: $xena_cred, monthly_limit: $xena_lim },
            quota_used_pct:       $cur_pct,
            weekly_used_pct:      $weekly_pct,
            resets_in:            $cur_in,
            weekly_resets:        $weekly_in,
            updated:              $now,
            valid:                false,
            stale:                true,
            stale_since:          $stale_since,
            stale_reason:         $err,
            last_success_updated: $last_suc,
            error:                $err,
            api_status_code:      $http_code,
            consecutive_failures: $consec
        }'
}

# ── Internal: populate QUOTA_RESULT[] from cache file ────────────────────────

_ql_parse_cache() {
    QUOTA_RESULT=()
    [[ ! -f "$_QL_CACHE" ]] && return

    # NOTE: the field separator must NOT be IFS whitespace.  With IFS=$'\t',
    # bash strips leading tabs and collapses runs of them, so a single empty
    # field shifts every value after it into the wrong variable — a null 5h
    # percentage used to land the weekly figure in QUOTA_RESULT[pct].  \x1f
    # (unit separator) is non-whitespace, so empty fields are preserved.
    local fields
    fields=$(jq -r '[
        (.quota_used_pct            // "" | tostring),
        (.weekly_used_pct           // "" | tostring),
        (.current_session.resets_at // ""),
        (.weekly_limits.resets_at   // ""),
        (if ((.current_session.resets_in // "") != "") then .current_session.resets_in else (.resets_in // "") end),
        (if ((.weekly_limits.resets_in   // "") != "") then .weekly_limits.resets_in   else (.weekly_resets // "") end),
        (.stale                     // false | tostring),
        (.valid                     // false | tostring),
        (.error                     // .stale_reason // ""),
        (if (.current_session.percent_unknown // false) then "true" else "false" end),
        (if (.weekly_limits.percent_unknown   // false) then "true" else "false" end)
    ] | join("")' "$_QL_CACHE" 2>/dev/null) || {
        QUOTA_RESULT[error]="Cannot parse quota-data.json (delete it to reset)."
        return
    }

    local _cur_at _weekly_at _cur_in _weekly_in
    IFS=$'\x1f' read -r \
        QUOTA_RESULT[pct] \
        QUOTA_RESULT[weekly_pct] \
        _cur_at \
        _weekly_at \
        _cur_in \
        _weekly_in \
        QUOTA_RESULT[stale] \
        QUOTA_RESULT[valid] \
        QUOTA_RESULT[error] \
        QUOTA_RESULT[pct_unknown] \
        QUOTA_RESULT[weekly_pct_unknown] \
        <<< "$fields"

    # Derive the countdowns from the stored timestamps instead of trusting the
    # strings written at fetch time.  On a cache hit those strings are as old as
    # the cache, so a 5-minute TTL means a countdown that under-reports by up to
    # 5 minutes, and a longer TTL makes it worse.  Fall back to the stored string
    # only when there is no timestamp to compute from.
    QUOTA_RESULT[resets_in]=$(_ql_countdown_for "$_cur_at" "$_cur_in")
    QUOTA_RESULT[weekly_resets_in]=$(_ql_countdown_for "$_weekly_at" "$_weekly_in")

    _ql_parse_scoped
}

# Flatten scoped_limits into the display-ready QUOTA_RESULT keys.
_ql_parse_scoped() {
    QUOTA_RESULT[scoped_summary]=""
    QUOTA_RESULT[scoped_alert]="false"
    QUOTA_RESULT[scoped_worst]=""
    QUOTA_RESULT[scoped_worst_pct]=""
    QUOTA_RESULT[scoped_worst_resets_in]=""

    local fields
    fields=$(jq -r '
        ((.scoped_limits // []) | map(select(.label != null and .percent_used != null))) as $v
        | ($v | sort_by(.percent_used) | last) as $w
        | [ ($v | map("\(.label):\(.percent_used)%") | join(" ")),
            (if (($v | map(select((.severity // "normal") != "normal")) | length) > 0)
             then "true" else "false" end),
            ($w.label // ""),
            (($w.percent_used // "") | tostring),
            ($w.resets_at // ""),
            ($w.resets_in // ""),
            (.weekly_limits.resets_at // "") ]
        | join("")' "$_QL_CACHE" 2>/dev/null) || return

    # \x1f, not \t — see the separator note in _ql_parse_cache.
    local summary alert w_label w_pct w_at w_in weekly_at
    IFS=$'\x1f' read -r summary alert w_label w_pct w_at w_in weekly_at <<< "$fields"

    QUOTA_RESULT[scoped_summary]="$summary"
    QUOTA_RESULT[scoped_alert]="${alert:-false}"
    QUOTA_RESULT[scoped_worst]="$w_label"
    QUOTA_RESULT[scoped_worst_pct]="$w_pct"

    # Only surface a separate countdown when this bucket resets on a different
    # boundary than the weekly one — today they coincide, so printing both would
    # just be noise.  A promotional bucket on its own cadence lights up for free.
    [[ -z "$w_at" || -z "$weekly_at" ]] && return
    local a b delta
    a=$(date -d "$w_at" +%s 2>/dev/null)      || return
    b=$(date -d "$weekly_at" +%s 2>/dev/null) || return
    delta=$(( a > b ? a - b : b - a ))
    (( delta >= 60 )) && QUOTA_RESULT[scoped_worst_resets_in]=$(_ql_countdown_for "$w_at" "$w_in")
    return 0
}
