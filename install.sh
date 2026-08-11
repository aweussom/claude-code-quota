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
SKILLS_DIR="${CLAUDE_DIR}/skills/quota"
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

# ── Install /quota skill ──────────────────────────────────────────────────────
header "Installing /quota skill"
if confirm "Install the /quota Claude Code skill?"; then
    mkdir -p "$SKILLS_DIR"
    DEST_SKILL="${SKILLS_DIR}/SKILL.md"
    if [[ -f "$DEST_SKILL" ]]; then
        warn "SKILL.md already exists at ${DEST_SKILL}"
        if confirm "Overwrite it?"; then
            cp "${SCRIPT_DIR}/skills/quota/SKILL.md" "$DEST_SKILL"
            success "Replaced ${DEST_SKILL}"
        else
            info "Skipped."
        fi
    else
        cp "${SCRIPT_DIR}/skills/quota/SKILL.md" "$DEST_SKILL"
        success "Installed ${DEST_SKILL}"
    fi
    # Pre-1.0 installs shipped a command file; remove it to avoid a duplicate /quota
    LEGACY_CMD="${CLAUDE_DIR}/commands/quota.md"
    if [[ -f "$LEGACY_CMD" ]]; then
        warn "Legacy /quota command file found at ${LEGACY_CMD}"
        if confirm "Remove it (superseded by the skill)?"; then
            rm -f "$LEGACY_CMD"
            success "Removed ${LEGACY_CMD}"
        fi
    fi
fi

# ── Statusline integration ────────────────────────────────────────────────────
header "Statusline integration"

SETTINGS="${CLAUDE_DIR}/settings.json"
DEST_STATUSLINE="${CLAUDE_DIR}/statusline.sh"

existing_statusline=""
if [[ -f "$SETTINGS" ]]; then
    existing_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
fi

if [[ -n "$existing_statusline" || -f "$DEST_STATUSLINE" ]]; then
    # Someone already has a statusline — don't touch it, just say how to add quota.
    [[ -n "$existing_statusline" ]] && info "Detected existing statusLine: ${existing_statusline}"
    [[ -f "$DEST_STATUSLINE" ]]    && info "Detected existing ${DEST_STATUSLINE}"
    info "Leaving it unchanged."
    cat <<'SNIPPET'

  To add quota to your own statusline, source the library near the top (before
  you build the display) and call quota_get:

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

  Then read QUOTA_RESULT[] — see statusline.sh.template in this repo for a
  complete renderer (5h, 7d, scoped limits, unknown-after-rollover, and errors),
  and README.md for the full key reference.

SNIPPET
else
    # No statusline at all — install the bundled one and offer to wire it up.
    if confirm "No statusline found. Install the bundled statusline.sh?"; then
        cp "${SCRIPT_DIR}/statusline.sh.template" "$DEST_STATUSLINE"
        chmod +x "$DEST_STATUSLINE"
        success "Installed ${DEST_STATUSLINE}"

        if confirm "Point Claude Code at it by writing settings.json?"; then
            mkdir -p "$CLAUDE_DIR"
            if [[ -f "$SETTINGS" ]]; then
                cp "$SETTINGS" "${SETTINGS}.bak"
                info "Backed up existing settings to ${SETTINGS}.bak"
                tmp=$(mktemp)
                if jq --arg cmd "$DEST_STATUSLINE" \
                      '.statusLine = {"type":"command","command":$cmd}' \
                      "$SETTINGS" > "$tmp" 2>/dev/null; then
                    mv "$tmp" "$SETTINGS"
                    success "Added statusLine to ${SETTINGS}"
                else
                    rm -f "$tmp"
                    warn "Could not update ${SETTINGS} — is it valid JSON?"
                    info "Add this manually:"
                    info '  "statusLine": { "type": "command", "command": "'"${DEST_STATUSLINE}"'" }'
                fi
            else
                jq -n --arg cmd "$DEST_STATUSLINE" \
                   '{statusLine: {type: "command", command: $cmd}}' > "$SETTINGS"
                success "Created ${SETTINGS} with statusLine"
            fi
            info "Restart Claude Code (or open a new session) to see it."
        else
            info "Skipped. Add this to ${SETTINGS} when you're ready:"
            info '  "statusLine": { "type": "command", "command": "'"${DEST_STATUSLINE}"'" }'
        fi
    else
        info "Skipped. statusline.sh.template in this repo is a complete renderer"
        info "if you want to adapt it later."
    fi
fi

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
