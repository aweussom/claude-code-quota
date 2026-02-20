Read `~/.claude/quota-data.json` and display a clear summary of current Claude API quota status.

Show:
- **5-hour session**: % used, resets in (time remaining)
- **Weekly limit**: % used, resets in (time remaining)
- **Data age**: when was it last successfully fetched
- **Status**: fresh / stale (with how long it's been stale)

Keep the output compact — one or two lines is ideal.

---

If the file is missing or the data is stale, explain that the statusline script
populates it automatically. To trigger an immediate fetch manually, run in
PowerShell:

```powershell
. "$env:USERPROFILE\.claude\quota-lib.ps1"; Invoke-QuotaGet -Ttl 0
```

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
```

Substitute the user's actual `$env:USERPROFILE` value for `<you>` —
`%USERPROFILE%` is not expanded by bash (which Claude Code uses to run the
statusline command).
