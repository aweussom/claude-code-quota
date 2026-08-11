---
name: quota
description: Show current Claude quota status (5-hour session and weekly usage) from the local claude-code-quota cache. Use when the user asks about their quota, usage limits, remaining capacity, or when limits reset.
---

Read `~/.claude/quota-data.json` and display a clear summary of current Claude
API quota status.

Show:
- **5-hour session**: % used, resets in (time remaining)
- **Weekly limit**: % used, resets in (time remaining)
- **Scoped limits**: every entry in `scoped_limits` (if the array is present and
  non-empty) as `label: % used`, plus its `resets_at`. These are *separate*
  allowances from the 5h and weekly buckets — a scoped limit at 90% does not
  mean the weekly limit is at 90%, and hitting it restricts only that model or
  surface. Call out any entry whose `severity` is above `normal`. Omit the
  section entirely when the array is absent or empty.
- **Data age**: when was it last successfully fetched
- **Status**: fresh / stale (with how long it's been stale)
- **Error**: if `stale` or not `valid`, always show the `error` (or
  `stale_reason`) field — it says *why* the last fetch failed (e.g. expired
  OAuth token, network error, rate limit) and is the answer to "what does the
  ⚠ in my statusline mean?"
- **Version**: the `lib_version` field, if present (installed claude-code-quota version)

If `scoped_limits` is missing while the rest of the data is present, the cache
was written from a source that cannot see scoped limits — check `source_url`
and say so rather than reporting "no scoped limits".

Keep the output compact — one or two lines is ideal.

---

If the file is missing or the data is stale, explain that the statusline script
populates it automatically. To trigger an immediate fetch manually:

On Windows (PowerShell):

```powershell
. "$env:USERPROFILE\.claude\quota-lib.ps1"; Invoke-QuotaGet -Ttl 0
```

On Linux / WSL2 (bash):

```bash
source ~/.claude/quota-lib.sh && quota_get 0
```

---

If the quota library is not installed at all (`~/.claude/quota-lib.ps1` on
Windows, `~/.claude/quota-lib.sh` on Linux is missing), the user has the skill
but not the statusline integration. Offer to set it up: locate the
claude-code-quota source directory (if installed as a plugin, search under
`~/.claude/plugins` for a directory containing `install.ps1`; otherwise it is
the cloned repo) and run `install.ps1` (Windows) or `install.sh` (Linux) from
there — or follow the manual integration steps in its README.md.

---

If the user asks how to add quota to their existing statusline script, show
them how to dot-source `quota-lib.ps1` and use `$QuotaResult`. Use the
absolute path to the lib (forward slashes, no `%USERPROFILE%`), for example:

```powershell
# Near the top of your statusline script, before building output:
$libPath = "C:/Users/<you>/.claude/quota-lib.ps1"   # use your actual path
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

# Then in your output section:
$q = $QuotaResult['pct']        # "68"  (5-hour % used)
$r = $QuotaResult['resets_in']  # "1 hr 12 min"
$w = $QuotaResult['weekly_pct'] # "31"  (7-day % used)
# $QuotaResult['stale'] is "true" if the last fetch failed
# $QuotaResult['error'] says why it failed, or "" — show it when pct is empty
```

Substitute the user's actual `$env:USERPROFILE` value for `<you>` —
`%USERPROFILE%` is not expanded by bash (which Claude Code uses to run the
statusline command). If the statusline outputs non-ASCII glyphs (like `⚠`),
it must set `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` near
the top, or captured stdout mangles them to `?`.

On Linux, the equivalent uses `source ~/.claude/quota-lib.sh`, `quota_get $ttl`
and the `QUOTA_RESULT[]` associative array — see the README of
claude-code-quota for the full snippet.
