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
#
# Cache file: ~/.claude/quota-data.json  (written atomically by this library)
# Lock file:  ~/.claude/.quota-fetch.lock (PID of any in-flight background fetch)
#
# NOTE: Do NOT add `set -euo pipefail` here — this file is sourced by the
#       statusline script and must not alter the parent shell's error behaviour.

# ── Config ────────────────────────────────────────────────────────────────────
_QL_CACHE="${HOME}/.claude/quota-data.json"
_QL_LOCK="${HOME}/.claude/.quota-fetch.lock"
_QL_CREDS="${HOME}/.claude/.credentials.json"
_QL_API="https://api.anthropic.com/api/oauth/usage"
_QL_BETA="oauth-2025-04-20"
_QL_TIMEOUT=20

declare -gA QUOTA_RESULT

# ── Public API ────────────────────────────────────────────────────────────────

# quota_get [ttl_seconds]
#   Fires a background refresh if the cache is older than ttl seconds.
#   On the very first call (no cache file) it blocks briefly for initial data.
#   Always populates QUOTA_RESULT[] from whatever is in the cache file.
quota_get() {
    local ttl="${1:-60}"

    local needs_refresh=true
    if [[ -f "$_QL_CACHE" ]]; then
        local mtime age
        mtime=$(stat -c %Y "$_QL_CACHE" 2>/dev/null) && {
            age=$(( $(date +%s) - mtime ))
            (( age < ttl )) && needs_refresh=false
        }
    fi

    if [[ "$needs_refresh" == "true" ]]; then
        local already_fetching=false
        if [[ -f "$_QL_LOCK" ]]; then
            local pid
            pid=$(cat "$_QL_LOCK" 2>/dev/null)
            [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && already_fetching=true
        fi

        if [[ "$already_fetching" == "false" ]]; then
            if [[ ! -f "$_QL_CACHE" ]]; then
                # First ever call — block briefly so the statusline isn't blank
                _ql_fetch_once
            else
                # Stale cache — refresh in background, show previous data this frame
                { _ql_fetch_once; rm -f "$_QL_LOCK"; } &>/dev/null &
                echo $! > "$_QL_LOCK"
            fi
        fi
    fi

    _ql_parse_cache
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
        payload=$(_ql_build_success "$body" "$now")
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

# Return raw JSON from the cache file, or "null" if absent/corrupt.
_ql_read_cache_raw() {
    [[ ! -f "$_QL_CACHE" ]] && echo "null" && return
    jq '.' "$_QL_CACHE" 2>/dev/null || echo "null"
}

# Atomically write the cache file (parent dir created if needed).
_ql_write() {
    mkdir -p "$(dirname "$_QL_CACHE")"
    printf '%s\n' "$1" > "$_QL_CACHE"
}

# ── Internal: payload builders ────────────────────────────────────────────────

_ql_build_success() {
    local body="$1" ts="$2"
    local cur_pct cur_at cur_in weekly_pct weekly_at weekly_in
    local xena_ena xena_pct xena_cred xena_lim

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
        '{
            schema_version:       2,
            source_url:           $src,
            attempted_at_utc:     $ts,
            fetched_at_utc:       $ts,
            current_session:      { percent_used: $cur_pct,    resets_at: $cur_at,    resets_in: $cur_in },
            weekly_limits:        { percent_used: $weekly_pct, resets_at: $weekly_at, resets_in: $weekly_in },
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

    # Recompute resets_in from timestamps (time has passed since last success)
    if [[ -n "$cur_at" && "$cur_at" != "null" ]]; then
        local r; r=$(_ql_time_until "$cur_at"); [[ -n "$r" ]] && cur_in="$r"
    fi
    if [[ -n "$weekly_at" && "$weekly_at" != "null" ]]; then
        local r; r=$(_ql_time_until "$weekly_at"); [[ -n "$r" ]] && weekly_in="$r"
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
        --arg     last_suc    "$last_success" \
        '{
            schema_version:       2,
            source_url:           $src,
            attempted_at_utc:     $now,
            fetched_at_utc:       $fetched_at,
            current_session:      { percent_used: $cur_pct,    resets_at: $cur_at,    resets_in: $cur_in },
            weekly_limits:        { percent_used: $weekly_pct, resets_at: $weekly_at, resets_in: $weekly_in },
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

    local fields
    fields=$(jq -r '[
        (.quota_used_pct            // "" | tostring),
        (.weekly_used_pct           // "" | tostring),
        (.current_session.resets_in // .resets_in    // ""),
        (.weekly_limits.resets_in   // .weekly_resets // ""),
        (.stale                     // false | tostring),
        (.valid                     // false | tostring)
    ] | join("\t")' "$_QL_CACHE" 2>/dev/null) || return

    IFS=$'\t' read -r \
        QUOTA_RESULT[pct] \
        QUOTA_RESULT[weekly_pct] \
        QUOTA_RESULT[resets_in] \
        QUOTA_RESULT[weekly_resets_in] \
        QUOTA_RESULT[stale] \
        QUOTA_RESULT[valid] \
        <<< "$fields"
}
