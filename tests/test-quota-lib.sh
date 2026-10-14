#!/usr/bin/env bash
# Exercise quota-lib.sh's scoped-limit and rollover logic against synthetic
# fixtures that mirror the real /api/oauth/usage response shape.
# No network calls — deterministic, and it can't rate-limit the account.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/quota-lib.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required (apt install jq)"; exit 2; }
source "$LIB" || { echo "FAILED to source $LIB"; exit 1; }

TMP=$(mktemp -d)
_QL_CACHE="$TMP/quota-data.json"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then printf '  ok   %-34s = %s\n' "$1" "'$3'"
    else printf '  FAIL %-34s expected=%s actual=%s\n' "$1" "'$2'" "'$3'"; fails=$((fails+1)); fi
}
iso() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%S.000Z"; }

now=$(date -u +%s)
FUT_5H=$(iso $((now + 3600)))      # 5h window still open
FUT_WK=$(iso $((now + 90000)))     # weekly boundary
FUT_OTHER=$(iso $((now + 40000)))  # a boundary that is NOT the weekly one
PAST=$(iso $((now - 600)))

mkfixture() { # mkfixture <scoped_resets_at>
    jq -n --arg f5 "$FUT_5H" --arg fw "$FUT_WK" --arg fs "$1" '{
      five_hour:   {utilization: 53.0, resets_at: $f5},
      seven_day:   {utilization: 58.0, resets_at: $fw},
      extra_usage: {is_enabled: true, used_credits: 6004.0, utilization: null, monthly_limit: null},
      limits: [
        {kind:"session",       group:"session", percent:53, severity:"normal",   resets_at:$f5, scope:null, is_active:false},
        {kind:"weekly_all",    group:"weekly",  percent:58, severity:"normal",   resets_at:$fw, scope:null, is_active:false},
        {kind:"weekly_scoped", group:"weekly",  percent:90, severity:"critical", resets_at:$fs,
         scope:{model:{id:null,display_name:"Fable"},surface:null}, is_active:true}
      ]
    }'
}

echo "=== TEST 1: success path — scoped extracted, account-wide buckets excluded ==="
_ql_write "$(_ql_build_success "$(mkfixture "$FUT_WK")" "$(_ql_now_utc)")"
check "schema_version"  "3"       "$(jq -r '.schema_version' "$_QL_CACHE")"
# Compare against the library's own constant so a version bump doesn't fail here.
check "lib_version"     "$_QL_VERSION" "$(jq -r '.lib_version' "$_QL_CACHE")"
check "scoped count"    "1"       "$(jq -r '.scoped_limits | length' "$_QL_CACHE")"
check "scoped label"    "Fable"   "$(jq -r '.scoped_limits[0].label' "$_QL_CACHE")"
check "scoped pct"      "90"      "$(jq -r '.scoped_limits[0].percent_used' "$_QL_CACHE")"
check "scoped severity" "critical" "$(jq -r '.scoped_limits[0].severity' "$_QL_CACHE")"
check "scoped resets_in non-empty" "yes" "$([[ -n $(jq -r '.scoped_limits[0].resets_in' "$_QL_CACHE") ]] && echo yes || echo no)"
_ql_parse_cache
check "QR scoped_summary"   "Fable:90%" "${QUOTA_RESULT[scoped_summary]:-}"
check "QR scoped_alert"     "true"      "${QUOTA_RESULT[scoped_alert]:-}"
check "QR scoped_worst"     "Fable"     "${QUOTA_RESULT[scoped_worst]:-}"
check "QR scoped_worst_pct" "90"        "${QUOTA_RESULT[scoped_worst_pct]:-}"
# coincides with weekly boundary -> suppressed, so the statusline shows it once
check "QR worst_resets_in (same boundary)" "" "${QUOTA_RESULT[scoped_worst_resets_in]:-}"

echo "=== TEST 2: scoped bucket on its OWN boundary — countdown surfaces ==="
_ql_write "$(_ql_build_success "$(mkfixture "$FUT_OTHER")" "$(_ql_now_utc)")"
_ql_parse_cache
check "QR worst_resets_in non-empty" "yes" "$([[ -n ${QUOTA_RESULT[scoped_worst_resets_in]:-} ]] && echo yes || echo no)"

echo "=== TEST 3: success with NO scoped bucket — segment disappears ==="
_ql_write "$(_ql_build_success "$(jq -n --arg f5 "$FUT_5H" --arg fw "$FUT_WK" '{
  five_hour:{utilization:53.0,resets_at:$f5}, seven_day:{utilization:58.0,resets_at:$fw},
  extra_usage:{is_enabled:null,used_credits:null,utilization:null,monthly_limit:null},
  limits:[{kind:"session",percent:53,severity:"normal",resets_at:$f5,scope:null,is_active:false}]
}')" "$(_ql_now_utc)")"
check "scoped count" "0" "$(jq -r '.scoped_limits | length' "$_QL_CACHE")"
_ql_parse_cache
check "QR scoped_summary" "" "${QUOTA_RESULT[scoped_summary]:-}"
check "QR scoped_alert"   "false" "${QUOTA_RESULT[scoped_alert]:-}"

echo "=== TEST 4: stale path — carry forward while windows are open ==="
prev=$(jq -n --arg f5 "$FUT_5H" --arg fw "$FUT_WK" '{
  current_session:{percent_used:60,resets_at:$f5,resets_in:"old"},
  weekly_limits:{percent_used:59,resets_at:$fw,resets_in:"old"},
  scoped_limits:[{label:"Fable",kind:"weekly_scoped",percent_used:90,severity:"critical",resets_at:$fw,resets_in:"old",is_active:true}]
}')
_ql_write "$(_ql_build_stale "$prev" "$(_ql_now_utc)" "test 429" "429")"
check "5h carried"       "60"    "$(jq -r '.current_session.percent_used' "$_QL_CACHE")"
check "5h resets_in refreshed (not 'old')" "yes" "$([[ $(jq -r '.current_session.resets_in' "$_QL_CACHE") != "old" ]] && echo yes || echo no)"
check "scoped carried"   "1"     "$(jq -r '.scoped_limits | length' "$_QL_CACHE")"
check "stale flag"       "true"  "$(jq -r '.stale' "$_QL_CACHE")"

echo "=== TEST 5: stale path — ROLLED-OVER buckets dropped, open ones kept ==="
prev=$(jq -n --arg past "$PAST" --arg fw "$FUT_WK" '{
  current_session:{percent_used:60,resets_at:$past,resets_in:"0 min"},
  weekly_limits:{percent_used:59,resets_at:$fw,resets_in:"1d2h"},
  scoped_limits:[
    {label:"Fable",  kind:"weekly_scoped",percent_used:90,severity:"critical",resets_at:$past,resets_in:"0 min",is_active:true},
    {label:"Mythos", kind:"weekly_scoped",percent_used:12,severity:"normal",  resets_at:$fw,  resets_in:"1d2h", is_active:true}
  ]
}')
_ql_write "$(_ql_build_stale "$prev" "$(_ql_now_utc)" "test 429" "429")"
check "5h dropped (rolled over)"  "null" "$(jq -r '.current_session.percent_used' "$_QL_CACHE")"
check "5h resets_in blanked"      ""     "$(jq -r '.current_session.resets_in' "$_QL_CACHE")"
check "7d kept (still open)"      "59"   "$(jq -r '.weekly_limits.percent_used' "$_QL_CACHE")"
check "expired scoped dropped"    "1"    "$(jq -r '.scoped_limits | length' "$_QL_CACHE")"
check "surviving scoped is Mythos" "Mythos" "$(jq -r '.scoped_limits[0].label' "$_QL_CACHE")"
check "5h percent_unknown flagged" "true" "$(jq -r '.current_session.percent_unknown' "$_QL_CACHE")"
check "7d percent_unknown false"   "false" "$(jq -r '.weekly_limits.percent_unknown' "$_QL_CACHE")"
_ql_parse_cache
check "QR pct blank"              ""       "${QUOTA_RESULT[pct]:-}"
check "QR pct_unknown"            "true"   "${QUOTA_RESULT[pct_unknown]:-}"
check "QR weekly_pct intact"      "59"     "${QUOTA_RESULT[weekly_pct]:-}"
check "QR weekly_pct_unknown"     "false"  "${QUOTA_RESULT[weekly_pct_unknown]:-}"
check "QR scoped_summary"         "Mythos:12%" "${QUOTA_RESULT[scoped_summary]:-}"
check "QR scoped_alert (normal only)" "false" "${QUOTA_RESULT[scoped_alert]:-}"

echo "=== TEST 6: multiple scoped buckets — summary + worst selection ==="
_ql_write "$(_ql_build_success "$(jq -n --arg f5 "$FUT_5H" --arg fw "$FUT_WK" '{
  five_hour:{utilization:53.0,resets_at:$f5}, seven_day:{utilization:58.0,resets_at:$fw},
  extra_usage:{is_enabled:null,used_credits:null,utilization:null,monthly_limit:null},
  limits:[
    {kind:"weekly_scoped",percent:12,severity:"normal",resets_at:$fw,scope:{model:{id:null,display_name:"Mythos"},surface:null},is_active:true},
    {kind:"weekly_scoped",percent:90,severity:"critical",resets_at:$fw,scope:{model:{id:null,display_name:"Fable"},surface:null},is_active:true}
  ]
}')" "$(_ql_now_utc)")"
_ql_parse_cache
check "QR scoped_summary (both)" "Mythos:12% Fable:90%" "${QUOTA_RESULT[scoped_summary]:-}"
check "QR worst = highest pct"   "Fable" "${QUOTA_RESULT[scoped_worst]:-}"

echo "=== TEST 7: label fallback when display_name is absent ==="
_ql_write "$(_ql_build_success "$(jq -n --arg fw "$FUT_WK" '{
  five_hour:null, seven_day:null, extra_usage:null,
  limits:[
    {kind:"weekly_scoped",percent:5,severity:"normal",resets_at:$fw,scope:{model:{id:"claude-x-1",display_name:null},surface:null},is_active:true},
    {kind:"surface_scoped",percent:7,severity:"normal",resets_at:$fw,scope:{model:null,surface:"cowork"},is_active:true},
    {kind:"mystery_scoped",percent:9,severity:"normal",resets_at:$fw,scope:{model:null,surface:null},is_active:true}
  ]
}')" "$(_ql_now_utc)")"
check "falls back to model.id"  "claude-x-1"     "$(jq -r '.scoped_limits[0].label' "$_QL_CACHE")"
check "falls back to surface"   "cowork"         "$(jq -r '.scoped_limits[1].label' "$_QL_CACHE")"
check "falls back to kind"      "mystery_scoped" "$(jq -r '.scoped_limits[2].label' "$_QL_CACHE")"

echo "=== TEST 8: tapering retry suppresses a fetch after repeated failures ==="
# fails=4 -> backoff 60*2^3 = 480s, so a 1s TTL must NOT trigger a refresh.
# If backoff were absent this would attempt a network fetch and rewrite the file.
jq -n --arg f5 "$FUT_5H" '{
  current_session:{percent_used:60,resets_at:$f5,resets_in:"1h",percent_unknown:false},
  weekly_limits:{percent_used:59,resets_at:$f5,resets_in:"1h",percent_unknown:false},
  scoped_limits:[], stale:true, valid:false, consecutive_failures:4,
  quota_used_pct:60, weekly_used_pct:59, resets_in:"1h", weekly_resets:"1h"
}' > "$_QL_CACHE"
before=$(stat -c %Y "$_QL_CACHE")
sleep 2
quota_get 1 >/dev/null 2>&1
after=$(stat -c %Y "$_QL_CACHE")
check "cache untouched (fetch suppressed)" "$before" "$after"
check "QR still parsed while suppressed"   "60" "${QUOTA_RESULT[pct]:-}"

# fails=0 with an expired TTL must NOT be suppressed — verify the gate is the
# failure count, not a blanket freeze.  Checked by reading the computed decision
# rather than letting it hit the network.
jq '.consecutive_failures = 0' "$_QL_CACHE" > "$_QL_CACHE.tmp" && mv "$_QL_CACHE.tmp" "$_QL_CACHE"
f=$(jq -r '.consecutive_failures // 0' "$_QL_CACHE")
check "healthy cache reports 0 failures" "0" "$f"

echo "=== TEST 9: fetch lock is mutually exclusive ==="
_QL_LOCK="$TMP/lock"
rm -f "$_QL_LOCK"
_ql_try_lock && a=owned || a=denied
check "first claim succeeds" "owned" "$a"
# Owner is this shell, which is alive and the lock is fresh -> must be denied.
_ql_try_lock && b=owned || b=denied
check "second claim denied while owner lives" "denied" "$b"

echo "=== TEST 10: abandoned lock (dead PID) is stolen ==="
# PID 999999 is above the default pid_max on Linux, so it cannot be running.
printf '999999\n' > "$_QL_LOCK"
_ql_try_lock && c=owned || c=denied
check "dead-owner lock stolen" "owned" "$c"

echo "=== TEST 11: lock older than max age is stolen even if PID is alive ==="
printf '%s\n' "$$" > "$_QL_LOCK"
touch -d "@$(( $(date +%s) - _QL_LOCK_MAX_AGE - 30 ))" "$_QL_LOCK"
_ql_try_lock && d=owned || d=denied
check "recycled-PID guard: stale lock stolen" "owned" "$d"
rm -f "$_QL_LOCK"

echo "=== TEST 12: cache writes are atomic ==="
_QL_CACHE="$TMP/atomic.json"
_ql_write '{"a":1}'
check "cache written"            '{"a":1}' "$(cat "$_QL_CACHE")"
check "no temp files left"       "0"       "$(find "$TMP" -maxdepth 1 -name 'atomic.json.*' | wc -l)"
# Hammer it concurrently; every observed read must be complete, valid JSON.
for i in $(seq 1 25); do _ql_write "$(jq -nc --argjson i "$i" '{n:$i}')" & done >/dev/null 2>&1
bad=0
for i in $(seq 1 40); do jq -e . "$_QL_CACHE" >/dev/null 2>&1 || bad=$((bad+1)); done
wait
check "no torn reads under concurrency" "0" "$bad"
check "no temp files after concurrency" "0" "$(find "$TMP" -maxdepth 1 -name 'atomic.json.*' | wc -l)"

echo "=== TEST 13: countdowns are recomputed from timestamps, not read from the cache ==="
# The stored resets_in strings are deliberately wrong: a live parse must ignore
# them and derive the countdown from resets_at instead.  This is what makes a
# long TTL safe — otherwise the countdown is frozen at fetch time.
_QL_CACHE="$TMP/countdown.json"
jq -n --arg f5 "$(iso $((now + 7200)))" --arg fw "$(iso $((now + 172800)))" '{
  current_session:{percent_used:40,resets_at:$f5,resets_in:"STALE-5H",percent_unknown:false},
  weekly_limits:{percent_used:50,resets_at:$fw,resets_in:"STALE-7D",percent_unknown:false},
  scoped_limits:[], stale:false, valid:true,
  quota_used_pct:40, weekly_used_pct:50, resets_in:"STALE-5H", weekly_resets:"STALE-7D"
}' > "$_QL_CACHE"
_ql_parse_cache
check "5h countdown recomputed" "1h59m" "${QUOTA_RESULT[resets_in]:-}"
check "7d countdown recomputed" "1d23h" "${QUOTA_RESULT[weekly_resets_in]:-}"
check "stored string not used (5h)" "no" "$([[ ${QUOTA_RESULT[resets_in]:-} == STALE-5H ]] && echo yes || echo no)"
check "stored string not used (7d)" "no" "$([[ ${QUOTA_RESULT[weekly_resets_in]:-} == STALE-7D ]] && echo yes || echo no)"

echo "=== TEST 14: countdown falls back to the stored string with no timestamp ==="
jq -n '{
  current_session:{percent_used:40,resets_at:"",resets_in:"2h30m",percent_unknown:false},
  weekly_limits:{percent_used:50,resets_at:"",resets_in:"",percent_unknown:false},
  scoped_limits:[], stale:false, valid:true,
  quota_used_pct:40, weekly_used_pct:50, resets_in:"2h30m", weekly_resets:"4d1h"
}' > "$_QL_CACHE"
_ql_parse_cache
check "falls back to bucket string"  "2h30m" "${QUOTA_RESULT[resets_in]:-}"
check "falls back to legacy top-level" "4d1h" "${QUOTA_RESULT[weekly_resets_in]:-}"

echo "=== TEST 15: provider is decided by ANTHROPIC_BASE_URL, not by the model ==="
# A gateway can serve claude-* model names from somewhere else entirely, so the
# base URL is the only thing that says whose allowance a session spends.
check "unset        -> anthropic" "anthropic" "$(ANTHROPIC_BASE_URL=    _ql_provider)"
check "blank        -> anthropic" "anthropic" "$(ANTHROPIC_BASE_URL='   ' _ql_provider)"
check "api.anthropic.com"         "anthropic" "$(ANTHROPIC_BASE_URL='https://api.anthropic.com' _ql_provider)"
check "anthropic with path"       "anthropic" "$(ANTHROPIC_BASE_URL='https://api.anthropic.com/v1' _ql_provider)"
check "ollama daemon"             "ollama"    "$(ANTHROPIC_BASE_URL='http://127.0.0.1:11434' _ql_provider)"
check "ollama localhost"          "ollama"    "$(ANTHROPIC_BASE_URL='http://localhost:11434/' _ql_provider)"
check "ollama.com"                "ollama"    "$(ANTHROPIC_BASE_URL='https://ollama.com' _ql_provider)"
# Observed from a live `ollama launch claude`: OLLAMA_HOST is a bind address and
# the wrapper copies it into the base URL, so this is 0.0.0.0, not loopback.
check "ollama bind address"       "ollama"    "$(ANTHROPIC_BASE_URL='http://0.0.0.0:11434' _ql_provider)"
# The wrapper names itself in the auth token, which holds whatever address the
# daemon is bound to -- including a LAN address or a non-default port.
check "auth token names ollama"   "ollama"    "$(ANTHROPIC_BASE_URL='http://10.0.0.5:9999' ANTHROPIC_AUTH_TOKEN='ollama' _ql_provider)"
check "matches OLLAMA_HOST"       "ollama"    "$(ANTHROPIC_BASE_URL='http://192.168.1.4:7777' OLLAMA_HOST='192.168.1.4:7777' _ql_provider)"
# A different local proxy is NOT Ollama: same host, different port, no marker.
check "other local proxy"         "other"     "$(ANTHROPIC_BASE_URL='http://127.0.0.1:4000' _ql_provider)"
check "unknown gateway"           "other"     "$(ANTHROPIC_BASE_URL='https://gateway.example.com' _ql_provider)"
# An explicit Anthropic base URL wins over a stray marker in the environment.
check "anthropic beats marker"    "anthropic" "$(ANTHROPIC_BASE_URL='https://api.anthropic.com' ANTHROPIC_AUTH_TOKEN='ollama' _ql_provider)"

echo "=== TEST 16: Ollama balance maps remaining% to used%, and drops scoped ==="
# Ollama reports what is LEFT; everything downstream is in percent USED.  The
# empty scoped_limits is what stops a stale "Fable:0%" following you into an
# Ollama session.
_QL_PROVIDER="ollama"
_QL_CACHE="$TMP/quota-data-ollama.json"
ollama_body=$(jq -n --arg f5 "$FUT_5H" --arg fw "$FUT_WK" '{
  included: {
    session: {remaining_percent: 99.1,  resets_at: $f5},
    weekly:  {remaining_percent: 73.81, resets_at: $fw}
  },
  purchased: {balance_usd: 0.73493}
}')
_ql_write "$(_ql_build_success_ollama "$ollama_body" "$(_ql_now_utc)")"
check "provider recorded"  "ollama"  "$(jq -r '.provider' "$_QL_CACHE")"
check "source_url"         "$_QL_OLLAMA_API" "$(jq -r '.source_url' "$_QL_CACHE")"
check "5h used from remaining"  "0.9"   "$(jq -r '.quota_used_pct' "$_QL_CACHE")"
check "7d used from remaining"  "26.19" "$(jq -r '.weekly_used_pct' "$_QL_CACHE")"
check "balance stored"     "0.73493" "$(jq -r '.purchased_balance_usd' "$_QL_CACHE")"
check "no scoped limits"   "0"       "$(jq -r '.scoped_limits | length' "$_QL_CACHE")"
_ql_parse_cache
check "QR pct"             "0.9"     "${QUOTA_RESULT[pct]:-}"
check "QR weekly_pct"      "26.19"   "${QUOTA_RESULT[weekly_pct]:-}"
check "QR balance_usd"     "0.73493" "${QUOTA_RESULT[balance_usd]:-}"
check "QR scoped_worst"    ""        "${QUOTA_RESULT[scoped_worst]:-}"

echo "=== TEST 17: an exhausted window still reports the purchased balance ==="
spent_body=$(jq -n --arg f5 "$FUT_5H" --arg fw "$FUT_WK" '{
  included: {
    session: {remaining_percent: 0, resets_at: $f5},
    weekly:  {remaining_percent: 40, resets_at: $fw}
  },
  purchased: {balance_usd: 12.5}
}')
_ql_write "$(_ql_build_success_ollama "$spent_body" "$(_ql_now_utc)")"
_ql_parse_cache
check "5h spent"           "100"     "${QUOTA_RESULT[pct]:-}"
check "balance visible"    "12.5"    "${QUOTA_RESULT[balance_usd]:-}"

echo "=== TEST 18: a failed Ollama fetch keeps the balance but drops spent windows ==="
# The percentages describe a window that has since rolled over, so they are
# provably wrong; the purchased balance has no window and is still true.
prev=$(jq -n --arg p "$PAST" '{
  provider:"ollama",
  current_session:{percent_used:80,resets_at:$p,resets_in:"",percent_unknown:false},
  weekly_limits:{percent_used:26,resets_at:$p,resets_in:"",percent_unknown:false},
  scoped_limits:[], purchased_balance_usd: 0.73493,
  quota_used_pct:80, weekly_used_pct:26, valid:true, stale:false,
  consecutive_failures:0
}')
_ql_write "$(_ql_build_stale "$prev" "$(_ql_now_utc)" "Rate limited by Ollama (HTTP 429)." "429")"
_ql_parse_cache
check "5h dropped"          ""        "${QUOTA_RESULT[pct]:-}"
check "5h flagged unknown"  "true"    "${QUOTA_RESULT[pct_unknown]:-}"
check "balance carried"     "0.73493" "${QUOTA_RESULT[balance_usd]:-}"
check "stale"               "true"    "${QUOTA_RESULT[stale]:-}"
check "failures counted"    "1"       "$(jq -r '.consecutive_failures' "$_QL_CACHE")"
_QL_PROVIDER="anthropic"

echo
if (( fails == 0 )); then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; fi
exit $(( fails > 0 ? 1 : 0 ))
