#!/usr/bin/env bash
# Render statusline.sh.template against the current cache for a range of model
# IDs, and assert the friendly model label is derived correctly.
#
# Read-only: renders to stdout, touches no config.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$REPO/statusline.sh.template"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 2; }
[[ -f "$TPL" ]] || { echo "FAIL: $TPL not found"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SL="$TMP/statusline.sh"
tr -d '\r' < "$TPL" > "$SL"      # tolerate CRLF from a Windows checkout
chmod +x "$SL"

fails=0
check() { # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then printf '  ok   %-34s = %s\n' "$1" "'$3'"
    else printf '  FAIL %-34s expected=%s actual=%s\n' "$1" "'$2'" "'$3'"; fails=$((fails+1)); fi
}

render() { # render <model-id> -> plain text, escape codes stripped
    printf '%s' "{\"model\":\"$1\",\"cwd\":\"$REPO\",\"context_window\":{\"used_percentage\":37.4}}" \
      | bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

label_of() { render "$1" | sed 's/ *|.*//'; }   # first segment, before the branch

# Current Claude Code sends model as an object; $2 may be empty for "no display_name".
render_obj() { # render_obj <id> <display_name>
    local dn=""; [[ -n "$2" ]] && dn=",\"display_name\":\"$2\""
    printf '%s' "{\"model\":{\"id\":\"$1\"$dn},\"cwd\":\"$REPO\"}" \
      | bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
label_of_obj() { render_obj "$1" "$2" | sed 's/ *|.*//'; }

echo "=== model label mapping ==="
check "claude-opus-5"             "Opus 5"    "$(label_of claude-opus-5)"
check "claude-opus-4-8"           "Opus 4.8"  "$(label_of claude-opus-4-8)"
check "claude-sonnet-4-6"         "Sonnet 4.6" "$(label_of claude-sonnet-4-6)"
check "claude-haiku-4-5-20251001" "Haiku 4.5" "$(label_of claude-haiku-4-5-20251001)"
check "claude-fable-5"            "Fable 5"   "$(label_of claude-fable-5)"
check "claude-mythos-5"           "Mythos 5"  "$(label_of claude-mythos-5)"
check "unknown id falls through"  "weird-id"  "$(label_of weird-id)"

echo "=== model as object {id, display_name} ==="
check "display_name wins"            "Fable 5"         "$(label_of_obj claude-fable-5 "Fable 5")"
check "display_name verbatim"        "My Model"        "$(label_of_obj claude-fable-5 "My Model")"
check "id-only object is mapped"     "Opus 4.8"        "$(label_of_obj claude-opus-4-8 "")"
check "unknown family: id, not JSON" "claude-zephyr-6" "$(label_of_obj claude-zephyr-6 "")"

echo "=== provider segments (synthetic cache, no network) ==="
# A private HOME with the library in place: quota_get reads this cache and the
# TTL keeps it from fetching, so these two cases never touch the network.
QHOME="$TMP/home"; mkdir -p "$QHOME/.claude"
cp "$REPO/quota-lib.sh" "$QHOME/.claude/quota-lib.sh"

render_with() { # render_with <base_url> <model-id>
    printf '%s' "{\"model\":\"$2\",\"cwd\":\"$REPO\",\"context_window\":{\"used_percentage\":17}}" \
      | HOME="$QHOME" ANTHROPIC_BASE_URL="$1" bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

# An Ollama session with the 5h window spent: percentages come from the Ollama
# cache, there is no scoped segment, and the purchased balance appears because
# requests now cost money.
jq -n --arg f5 "$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)" \
      --arg fw "$(date -u -d '+3 days'  +%Y-%m-%dT%H:%M:%SZ)" '{
  schema_version:3, provider:"ollama",
  current_session:{percent_used:100, resets_at:$f5, resets_in:"", percent_unknown:false},
  weekly_limits:{percent_used:26.19, resets_at:$fw, resets_in:"", percent_unknown:false},
  scoped_limits:[], purchased_balance_usd:0.73493,
  quota_used_pct:100, weekly_used_pct:26.19, valid:true, stale:false,
  consecutive_failures:0
}' > "$QHOME/.claude/quota-data-ollama.json"

out=$(render_with "http://127.0.0.1:11434" "glm-5.3-flash:cloud")
check "ollama: model label"  "glm-5.3-flash:cloud" "$(sed 's/ *|.*//' <<< "$out")"
check "ollama: 5h segment"   "yes" "$(grep -q '5h:100%' <<< "$out" && echo yes || echo no)"
check "ollama: 7d segment"   "yes" "$(grep -q '7d:26.19%' <<< "$out" && echo yes || echo no)"
check "ollama: balance shown" "yes" "$(grep -q '\$0\.73' <<< "$out" && echo yes || echo no)"
check "ollama: no scoped"    "no"  "$(grep -q 'Fable' <<< "$out" && echo yes || echo no)"

# Some other gateway: the Anthropic numbers do not describe this session and we
# have none for whatever does, so no quota segments at all.
out=$(render_with "http://127.0.0.1:4000" "some-model")
check "other: no 5h"      "no" "$(grep -q '5h:'    <<< "$out" && echo yes || echo no)"
check "other: no 7d"      "no" "$(grep -q '7d:'    <<< "$out" && echo yes || echo no)"
check "other: no error"   "no" "$(grep -q 'quota:' <<< "$out" && echo yes || echo no)"
check "other: ctx kept"   "yes" "$(grep -q 'ctx:17%' <<< "$out" && echo yes || echo no)"

echo "=== full render (current cache) ==="
render claude-opus-5 | sed 's/^/  /'

echo
if (( fails == 0 )); then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; fi
exit $(( fails > 0 ? 1 : 0 ))
