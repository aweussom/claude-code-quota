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

echo "=== model label mapping ==="
check "claude-opus-5"             "Opus 5"    "$(label_of claude-opus-5)"
check "claude-opus-4-8"           "Opus 4.8"  "$(label_of claude-opus-4-8)"
check "claude-sonnet-4-6"         "Sonnet 4.6" "$(label_of claude-sonnet-4-6)"
check "claude-haiku-4-5-20251001" "Haiku 4.5" "$(label_of claude-haiku-4-5-20251001)"
check "claude-fable-5"            "Fable 5"   "$(label_of claude-fable-5)"
check "claude-mythos-5"           "Mythos 5"  "$(label_of claude-mythos-5)"
check "unknown id falls through"  "weird-id"  "$(label_of weird-id)"

echo "=== full render (current cache) ==="
render claude-opus-5 | sed 's/^/  /'

echo
if (( fails == 0 )); then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; fi
exit $(( fails > 0 ? 1 : 0 ))
