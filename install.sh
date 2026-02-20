#!/usr/bin/env bash
#
# install.sh — Install claude-code-quota into ~/.claude/
#
# Usage:
#   bash install.sh            # interactive
#   bash install.sh --yes      # non-interactive (accept all defaults)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
COMMANDS_DIR="${CLAUDE_DIR}/commands"
YES=false

# ── Args ──────────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo "  $*"; }
success() { echo "  ✓ $*"; }
warn()    { echo "  ⚠ $*"; }
header()  { echo; echo "── $* ──────────────────────────────────────────"; }

confirm() {
    # confirm "Question?" default_yes|default_no
    local prompt="$1" default="${2:-default_yes}"
    [[ "$YES" == "true" ]] && return 0
    local yn_prompt
    [[ "$default" == "default_yes" ]] && yn_prompt="[Y/n]" || yn_prompt="[y/N]"
    read -r -p "  ${prompt} ${yn_prompt} " reply
    reply="${reply:-}"
    case "$reply" in
        ""|[Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Dependency check ──────────────────────────────────────────────────────────
header "Checking dependencies"
missing=()
for cmd in jq curl bash; do
    if command -v "$cmd" &>/dev/null; then
        success "$cmd found ($(command -v "$cmd"))"
    else
        warn "$cmd NOT found"
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    echo "ERROR: Missing required commands: ${missing[*]}"
    echo "       Install with: sudo apt install ${missing[*]}"
    exit 1
fi

# ── Check credentials ─────────────────────────────────────────────────────────
header "Checking Claude Code credentials"
CREDS="${CLAUDE_DIR}/.credentials.json"
if [[ -f "$CREDS" ]]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
    if [[ -n "$token" ]]; then
        success "OAuth token found in ${CREDS}"
    else
        warn "Credentials file exists but no claudeAiOauth.accessToken found."
        warn "Run 'claude login' first."
    fi
else
    warn "No credentials file at ${CREDS}"
    warn "Run 'claude login' first, or use --credentials-file with the daemon."
fi

# ── Install quota-lib.sh ──────────────────────────────────────────────────────
header "Installing quota-lib.sh"
mkdir -p "$CLAUDE_DIR"

DEST_LIB="${CLAUDE_DIR}/quota-lib.sh"
if [[ -f "$DEST_LIB" ]]; then
    warn "quota-lib.sh already exists at ${DEST_LIB}"
    if confirm "Overwrite it?"; then
        cp "${SCRIPT_DIR}/quota-lib.sh" "$DEST_LIB"
        success "Replaced ${DEST_LIB}"
    else
        info "Skipped."
    fi
else
    cp "${SCRIPT_DIR}/quota-lib.sh" "$DEST_LIB"
    success "Installed ${DEST_LIB}"
fi

# ── Install /quota slash command ──────────────────────────────────────────────
header "Installing /quota slash command"
if confirm "Install the /quota Claude Code slash command?"; then
    mkdir -p "$COMMANDS_DIR"
    DEST_CMD="${COMMANDS_DIR}/quota.md"
    if [[ -f "$DEST_CMD" ]]; then
        warn "quota.md already exists at ${DEST_CMD}"
        if confirm "Overwrite it?"; then
            cp "${SCRIPT_DIR}/commands/quota.md" "$DEST_CMD"
            success "Replaced ${DEST_CMD}"
        else
            info "Skipped."
        fi
    else
        cp "${SCRIPT_DIR}/commands/quota.md" "$DEST_CMD"
        success "Installed ${DEST_CMD}"
    fi
fi

# ── Statusline integration ────────────────────────────────────────────────────
header "Statusline integration"

SETTINGS="${CLAUDE_DIR}/settings.json"
if [[ -f "$SETTINGS" ]]; then
    current_statusline=$(jq -r '.statusLine // empty' "$SETTINGS" 2>/dev/null)
    if [[ -n "$current_statusline" ]]; then
        info "Detected existing statusLine config in settings.json."
    fi
fi

cat <<'SNIPPET'

  Add this block near the top of your ~/.claude/statusline.sh (before building
  display components), to source quota-lib.sh and call quota_get:

  ────────────────────────────────────────────────────────────────────────────
  _QL_LIB="${HOME}/.claude/quota-lib.sh"
  if [[ -f "$_QL_LIB" ]]; then
      source "$_QL_LIB"
      _transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
      _quota_ttl=300
      if [[ -n "$_transcript_path" && -f "$_transcript_path" ]]; then
          _t_age=$(( $(date +%s) - $(stat -c %Y "$_transcript_path" 2>/dev/null || echo 0) ))
          (( _t_age < 300 )) && _quota_ttl=60
      fi
      quota_get "$_quota_ttl"
  fi
  ────────────────────────────────────────────────────────────────────────────

  Then display quota values:

  ────────────────────────────────────────────────────────────────────────────
  _qpct="${QUOTA_RESULT[pct]:-}"
  if [[ -n "$_qpct" && "$_qpct" != "null" ]]; then
      if awk "BEGIN{exit !($_qpct + 0 > 75)}" 2>/dev/null; then
          _qcolor='\033[31m'
      elif awk "BEGIN{exit !($_qpct + 0 > 50)}" 2>/dev/null; then
          _qcolor='\033[33m'
      else
          _qcolor='\033[32m'
      fi
      _qstale="${QUOTA_RESULT[stale]:-false}"
      _qresets="${QUOTA_RESULT[resets_in]:-}"
      _qdisplay="${_qpct}%"
      [[ "$_qstale" == "true" ]] && _qdisplay="${_qdisplay}⚠"
      [[ -n "$_qresets" && "$_qresets" != "null" ]] && _qdisplay="${_qdisplay} ↻${_qresets}"
      echo -e "${_qcolor}5h:${_qdisplay}\033[0m"
  fi
  ────────────────────────────────────────────────────────────────────────────

  See README.md for the full QUOTA_RESULT[] key reference.

SNIPPET

# ── Test fetch ────────────────────────────────────────────────────────────────
header "Testing"
if confirm "Run a test fetch now to verify credentials and API access?" "default_no"; then
    echo
    info "Sourcing quota-lib.sh and calling quota_get 0 (force refresh)..."
    # shellcheck source=/dev/null
    source "$DEST_LIB"
    if quota_get 0; then
        echo
        info "Result:"
        info "  5h usage  : ${QUOTA_RESULT[pct]:-n/a}%"
        info "  resets in : ${QUOTA_RESULT[resets_in]:-n/a}"
        info "  weekly    : ${QUOTA_RESULT[weekly_pct]:-n/a}%"
        info "  stale     : ${QUOTA_RESULT[stale]:-n/a}"
        echo
        success "Fetch succeeded. Cache written to ${CLAUDE_DIR}/quota-data.json"
    else
        warn "Fetch returned non-zero. Check ${CLAUDE_DIR}/quota-data.json for details."
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Done. See README.md for full documentation."
echo "────────────────────────────────────────────────────────────────────────────"
echo
