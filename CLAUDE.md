# CLAUDE.md — working on claude-code-quota

Invariants and traps. Read before changing either library.

## What this is

Two standalone libraries — `quota-lib.ps1` (Windows) and `quota-lib.sh`
(Linux/WSL2) — that read Claude's OAuth quota endpoint and expose the numbers to
a statusline script. They must behave identically and write a byte-compatible
cache. There is no daemon: everything happens inside a statusline refresh.

The core is small and should stay small. Most of the code is not capability, it
is edge-case honesty: never show a figure we can prove is wrong, never corrupt a
cache shared by several sessions, never hammer a failing endpoint.

## Deployment reality (drives most of the design)

**Several Claude Code sessions run at once — typically 3–5 on Windows plus 1–2
in WSL2.** They all share one cache file per environment. Any change to cache
reads, cache writes, or the fetch lock has to hold under concurrent access;
assume 5 processes hit the same code path in the same second.

Windows and WSL2 do *not* share a cache: `~` is `%USERPROFILE%\.claude\` in one
and `/home/<you>/.claude/` in the other. That is intended — see `TODONT.md`.

## Traps that have already bitten us

### PowerShell: `ConvertFrom-Json` turns ISO timestamps into local-time `DateTime`

This is the nastiest one. Reading the cache with `ConvertFrom-Json` does **not**
give you the ISO string you wrote. It gives a `DateTime` in *local* time, and
casting that with `[string]` renders it in locale format with the UTC marker
gone. Re-parsing the result is then wrong by the machine's UTC offset.

On UTC+2 this made a bucket two hours from resetting look **already reset**,
which under the rollover rule blanked the percentage and displayed `5h:?⚠` on a
perfectly healthy account. It also silently skewed rollover detection in the
stale carry-forward path for as long as that code existed.

**Rule: never `[string]`-cast a timestamp read from the cache.** Route every
timestamp through `_QL_DateToIso`, which normalises both `DateTime` and string
inputs to ISO 8601 UTC. `_QL_IsPast`, `_QL_GetTimeUntil` and `_QL_SameInstant`
each call it internally and take an untyped value precisely so a caller cannot
reintroduce this — do not add a `[string]` type constraint to their parameters.

Bash is immune: `jq` returns the raw string.

### Bash: the field separator must not be IFS whitespace

`jq ... | join("\t")` piped into `IFS=$'\t' read -r a b c` is broken. Tab is IFS
*whitespace*, so bash strips leading tabs and collapses runs of them. One empty
field shifts every value after it into the wrong variable.

Concretely: a null 5h percentage put the **weekly** figure into
`QUOTA_RESULT[pct]`, silently, with no marker. It shipped in 1.0.0 and affected
every Linux/WSL2 user.

**Rule: use `0x1F` (unit separator) for `jq` → `read` field splitting.** It is
non-whitespace, so empty fields are preserved. Both parsers already do; keep it
that way, and remember the separator is a literal byte in the source, not the
two-character escape `\x1f` — string-matching tools won't find it by name.

### jq's `//` does not fall through on empty string

`//` treats only `null` and `false` as absent, so `("" // .fallback)` yields
`""`. PowerShell's `IsNullOrWhiteSpace` treats empty as absent. That divergence
made the two libraries disagree on fallback fields. Write the emptiness test
explicitly: `(if ((.x // "") != "") then .x else .fallback end)`.

### `bash -n` proves nothing about correctness

It once passed a `read` whose line continuations had become literal `\n`, which
bash parsed as a variable named `n` — shifting every field by one. Syntactically
valid, semantically wrong. **Always run the test suite, not just the linter.**

## Design rules

- **A successful fetch is authoritative, including by omission.** If the API
  stops reporting a scoped limit, it is gone — delete it. Only a *failed* fetch
  carries previous values forward. This is what makes plan changes a non-event.
- **A cached percentage is trustworthy only until the window it describes
  resets.** Past that we can prove it is obsolete, so drop it and set
  `percent_unknown`; callers render `?`. Never display a spent figure, and never
  silently omit the segment either — an absent segment reads as "no limit".
- **Buckets are independent.** A rolled-over 5h window must not disturb the
  weekly or scoped figures.
- **Never hardcode a model name.** Scoped limits come from `limits[]` and are
  labelled from `scope.model.display_name`, falling back to `model.id` →
  `surface` → `kind`. Buckets arrive and leave with the plan.
- **Cache writes are atomic** (temp file + rename). A torn read parses as "no
  cache", which sends that session down the *blocking* fetch path — the worst
  outcome: statusline latency plus a redundant API call.
- **The fetch lock is created with `O_EXCL` / `FileMode::CreateNew`**, never
  check-then-write, and is treated as abandoned after `_QL_LOCK_MAX_AGE` (120s)
  because PIDs get recycled.
- **The caller's TTL is a floor.** Retries taper after failures using the
  `consecutive_failures` counter already in the cache.
- **Statusline scripts are sourced/dot-sourced.** Do not add `set -euo pipefail`
  to `quota-lib.sh` or `Set-StrictMode` to `quota-lib.ps1` — it would change the
  caller's error behaviour.

## Conventions

- **The version lives in four places**: `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`, and the `_QL_VERSION` / `$script:_QL_Version`
  constant in each library. `marketplace.json` was missed for two releases
  running, and it is the one `/plugin marketplace add` actually reads.
- **The plugin publishes from the default branch, not from tags.** A marketplace
  is a git clone of this repo; installs record a commit SHA. Pushing to `main`
  *is* publishing. Tags and releases are for humans.
- Cache schema changes are additive; bump `schema_version` and keep older
  libraries able to read the file.

## Tests

```bash
bash tests/test-quota-lib.sh        # requires jq; exits 2 if missing
```

Covers the bash library only, over synthetic fixtures shaped like real API
responses. **No network calls** — the suite must never be able to consume quota
or trip a rate limit. It has caught two real bugs that review missed; add a case
whenever you fix something.

PowerShell has no suite yet. Verify changes there against a live fetch *and* a
synthetic stale payload, including the rollover path.
