# claude-code-quota

Displays your Claude Code OAuth quota (5-hour session % and weekly %) live in
your terminal status line, with no daemon process required.

```
claude-sonnet-4-6 │ abc12345 │ ctx:42% │ 5h:68% ↻1 hr 12 min │ my-project │ (main)
```

Works on **Windows 11** (PowerShell — no extra dependencies) and
**Linux / WSL2** (bash + `jq`).

---

## How it works

On every status line refresh Claude Code emits, the library:

1. Checks the age of a local cache file (`~/.claude/quota-data.json`)
2. If fresh enough — returns immediately (no network call)
3. If stale — fires a background refresh (non-blocking), returns the previous
   frame's data immediately; the next frame gets fresh data
4. On the very first call (no cache) — blocks briefly for the initial fetch

The TTL is controlled by the caller:
- **60 seconds** while an active session is running (transcript recently written)
- **5 minutes** while idle

---

## Windows 11 / PowerShell

No WSL required. Uses `Invoke-RestMethod` and `ConvertFrom-Json` — no `jq`,
`curl`, or other external tools needed.

> **Why PowerShell, not bash?**
> Claude Code runs `settings.json` commands via bash on Windows (Git Bash),
> but bash scripts require `jq` for JSON parsing which is not bundled with
> Git for Windows. PowerShell's built-in cmdlets cover everything with zero
> extra installs.

### Quick install

```powershell
pwsh -ExecutionPolicy Bypass -File .\install.ps1
```

The installer:

1. Detects `pwsh` (7+) or falls back to `powershell.exe` (5.1)
2. Checks for the Claude OAuth credentials file
3. Copies `quota-lib.ps1` and `_quota-fetch-helper.ps1` to `%USERPROFILE%\.claude\`
4. Optionally copies `commands\quota.md` (enables the `/quota` slash command)
5. If no statusline exists — installs `statusline.ps1.template` as
   `%USERPROFILE%\.claude\statusline.ps1` and offers to write `settings.json`
6. If an existing statusline is detected — leaves everything unchanged and
   prints an integration snippet showing how to add quota to your script

### Manual integration

#### 1. Copy the library files

```powershell
Copy-Item quota-lib.ps1           "$env:USERPROFILE\.claude\quota-lib.ps1"
Copy-Item _quota-fetch-helper.ps1 "$env:USERPROFILE\.claude\_quota-fetch-helper.ps1"
```

#### 2. Add to your statusline script

Near the top of `%USERPROFILE%\.claude\statusline.ps1`, dot-source the library
and call `Invoke-QuotaGet`:

```powershell
$libPath = "$env:USERPROFILE\.claude\quota-lib.ps1"
if (Test-Path $libPath) {
    . $libPath

    $ttl = 300
    if ($session.transcript_path -and (Test-Path $session.transcript_path)) {
        $tAge = ([DateTimeOffset]::UtcNow -
                 (Get-Item $session.transcript_path).LastWriteTimeUtc).TotalSeconds
        if ($tAge -lt 300) { $ttl = 60 }
    }

    Invoke-QuotaGet -Ttl $ttl
}
```

Then display the values:

```powershell
$qpct     = $QuotaResult['pct']       # "68"
$resetsIn = $QuotaResult['resets_in'] # "1 hr 12 min"
$isStale  = $QuotaResult['stale'] -eq 'true'

if ($qpct -ne "") {
    $display = "${qpct}%"
    if ($isStale)  { $display += "⚠" }
    if ($resetsIn) { $display += " ↻$resetsIn" }
    Write-Output "5h:$display"
}
```

#### 3. Enable the `/quota` slash command (optional)

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\commands" | Out-Null
Copy-Item commands\quota.md "$env:USERPROFILE\.claude\commands\quota.md"
```

Type `/quota` inside Claude Code for an on-demand quota summary. You can also
ask Claude "how do I add quota to my statusline?" and it will walk you through
the integration using the context from this command.

#### 4. Point Claude Code at your statusline script

In `%USERPROFILE%\.claude\settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "pwsh -NonInteractive -ExecutionPolicy Bypass -File C:/Users/<you>/.claude/statusline.ps1"
  }
}
```

> **Important:** use an absolute path with forward slashes. Claude Code
> executes this command via bash on Windows, where `%USERPROFILE%` is **not**
> expanded. The installer writes the correct absolute path automatically.

Use `powershell` instead of `pwsh` if you only have PowerShell 5.1.

### `$QuotaResult` reference

| Key | Value |
|-----|-------|
| `pct` | 5-hour session usage %, or `""` |
| `weekly_pct` | 7-day usage %, or `""` |
| `resets_in` | Time until 5h reset, e.g. `"1 hr 12 min"`, or `""` |
| `weekly_resets_in` | Time until weekly reset, or `""` |
| `stale` | `"true"` if the last fetch failed, `"false"` otherwise |
| `valid` | `"true"` if the last fetch succeeded |

### Execution policy

Windows blocks unsigned scripts by default. Run once to allow local scripts:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Or keep using `-ExecutionPolicy Bypass` in the `settings.json` command (no
elevated rights needed, already included in the installer's output).

### Performance

- `pwsh` (PowerShell 7+): ~100–200 ms cold start — recommended
- `powershell.exe` (5.1): ~300–500 ms cold start — works but slower

The background refresh adds no extra latency: it runs as a detached process
while the statusline immediately returns the previous frame's cached data.

---

## Linux / WSL2

### Requirements

- Claude Code with OAuth login (`claude login`)
- `jq` and `curl` — `sudo apt install jq curl`
- Bash 4.2+

### Quick install

```bash
bash install.sh
```

The installer:

1. Checks for `jq` and `curl`
2. Copies `quota-lib.sh` to `~/.claude/`
3. Optionally copies `commands/quota.md` (enables the `/quota` slash command)
4. Prints a snippet to add to your existing statusline script

### Manual integration

#### 1. Copy the library

```bash
cp quota-lib.sh ~/.claude/quota-lib.sh
```

#### 2. Add to your statusline script

Near the top of `~/.claude/statusline.sh` (before you build the display),
source the library and call `quota_get`:

```bash
_QL_LIB="${HOME}/.claude/quota-lib.sh"
if [[ -f "$_QL_LIB" ]]; then
    source "$_QL_LIB"

    _quota_ttl=300
    _transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
    if [[ -n "$_transcript_path" && -f "$_transcript_path" ]]; then
        _t_age=$(( $(date +%s) - $(stat -c %Y "$_transcript_path" 2>/dev/null || echo 0) ))
        (( _t_age < 300 )) && _quota_ttl=60
    fi

    quota_get "$_quota_ttl"
fi
```

Then display the values:

```bash
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
```

#### 3. Enable the `/quota` slash command (optional)

```bash
mkdir -p ~/.claude/commands
cp commands/quota.md ~/.claude/commands/quota.md
```

#### 4. Point Claude Code at your statusline script

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

### `QUOTA_RESULT` array reference

| Key | Value |
|-----|-------|
| `pct` | 5-hour session usage %, or `""` |
| `weekly_pct` | 7-day usage %, or `""` |
| `resets_in` | Time until 5h reset, e.g. `"1 hr 12 min"`, or `""` |
| `weekly_resets_in` | Time until weekly reset, or `""` |
| `stale` | `"true"` if last fetch failed, `"false"` otherwise |
| `valid` | `"true"` if last fetch succeeded |

---

## Cache file format

`~/.claude/quota-data.json` (same path on Windows) — schema version 2:

```json
{
  "schema_version": 2,
  "current_session": { "percent_used": 68, "resets_at": "...", "resets_in": "1 hr 12 min" },
  "weekly_limits":   { "percent_used": 31, "resets_at": "...", "resets_in": "4 d 2 hr 5 min" },
  "extra_usage":     { "is_enabled": null, "utilization": null, "used_credits": null, "monthly_limit": null },
  "quota_used_pct":  68,
  "weekly_used_pct": 31,
  "resets_in":       "1 hr 12 min",
  "weekly_resets":   "4 d 2 hr 5 min",
  "valid": true,
  "stale": false,
  "consecutive_failures": 0
}
```

Both the PowerShell and bash libraries write the same format, so the cache is
shared if you use both (e.g. running Claude Code natively on Windows while also
using WSL2).

## Notes

- The OAuth beta header (`oauth-2025-04-20`) may need updating if Anthropic
  releases a new API version. Update `_QL_Beta` in `quota-lib.ps1` or
  `_QL_BETA` in `quota-lib.sh`.
- On Linux/WSL2, credentials are read from `~/.claude/.credentials.json`.
  If Claude Code stores them in your Windows home, edit `_QL_CREDS` at the
  top of `quota-lib.sh` to point at the correct path.
