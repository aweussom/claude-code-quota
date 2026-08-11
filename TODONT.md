# TODONT.md

Things tried that did not work, or that work but are not worth doing. Read
before proposing anything structural — several of the entries below sound
obviously sensible, which is exactly why they get proposed again.

---

## Read the quota off the rendered page instead of the API

**Tried:** screenshot the `claude.ai/settings/usage` page every 60 seconds and
extract the numbers with a 235B-parameter vision model (Qwen3-VL via Ollama
Cloud). Later, a browser-scrape variant using Claude Code's `--chrome` flag,
which survives in the repo as `claude_quota_chrome.ps1`.

**Verdict:** don't. Abandoned after one day.

**Why not:** Claude Code already authenticates against
`api.anthropic.com/api/oauth/usage`, which returns the same figures as JSON. The
screenshot pipeline was a deliberate learning exercise in Windows screen capture
and vision-model parsing, not a serious attempt — but it is a fair illustration
of the trap: a 235-billion-parameter model reading a number that was already
sitting in an HTTP response. The screen-scrape path also breaks on multi-monitor
setups and DPI scaling, and sends screenshots off the machine.

The Chrome variant does extract the figures correctly and is kept as a proof of
concept. It is not needed for normal use and should not be developed further.

---

## Fall back to the rate-limit headers on `/v1/messages`

**Tried:** a one-token Haiku call to `api.anthropic.com/v1/messages`, reading
`anthropic-ratelimit-unified-5h-utilization` and friends from the response
headers, as a fallback for `/api/oauth/usage` disappearing or its
`oauth-2025-04-20` beta header rotating.

**Verdict:** don't build it. Investigated and measured; deliberately declined.

**Why not:** it works — verified on a live subscription token, returning
`unified-5h-utilization: 0.53` against the endpoint's `five_hour.utilization:
53.0`, with reset timestamps matching to sub-second. Cost is ~$0.000013 per call
(8 input + 1 output token at Haiku 4.5 rates), which is below the 0.01
granularity of the very number it reports.

It still isn't worth it:

- **It cannot carry the feature that matters.** The headers expose 5h, 7d and
  overage only; they self-describe as `representative-claim = five_hour`. No
  `limits[]`, so no scoped limits, no `severity`, no `used_credits`. The one
  bucket that has actually mattered in practice (a per-model weekly cap) is
  invisible to it.
- **It addresses a failure never observed.** The rationale was the undocumented
  endpoint or beta header rotating. That has not happened. The failure that *did*
  happen was a 429 — and by design the fallback must not fire on 429 (same
  account, same limits; a second endpoint would be a second thing to rate-limit).
  Tapering retries fixed that case instead, and did so for every failure mode.
- Both paths share one OAuth token and one host, so it is no help against a dead
  token, a network outage, or an api.anthropic.com outage.

If the primary endpoint ever really does move, revisit — but note the display
degrades to no scoped segment, which is acceptable and needs no special-casing
(delete-by-omission already handles it).

---

## Adaptive TTL driven by an activity signal

**Tried:** design only. Shorten the cache TTL when quota is moving and lengthen
it when idle, to cut API calls.

**Verdict:** don't. Dropped before implementation.

**Why not:** three separate reasons, any one sufficient.

- **The obvious signal is wrong.** The first design keyed "idle" off
  `transcript_path` mtime, but that is per-session while quota is per-account. A
  session sitting idle says nothing about whether the account is spending — the
  quota may be going to another session, claude.ai, the Chrome extension, or
  another machine.
- **The corrected signal is nearly always "active".** Deriving activity from
  observed rate-of-change in the cache would be account-wide and correct, but
  with 3–5 sessions typically running, the account is essentially always active.
  The long-idle branch would almost never engage.
- **It doesn't buy anything.** The payoff is fewer API calls, and calls are
  already effectively free: the fetch lock means N concurrent sessions produce
  *one* fetch per TTL window, so at a 60s active TTL the machine polls ~60 times
  an hour regardless of session count — orders of magnitude below any limit. The
  cost would be new persisted state, a schema bump, and a heuristic to tune.

If call volume ever needs reducing, raise the idle TTL — a one-line change with
no new state.

**Prerequisite that *was* worth doing:** recomputing `resets_in` locally on cache
hits. The countdown used to be frozen at fetch time, so any TTL increase made it
under-report by the length of the TTL. That is fixed and is worth keeping
regardless.

---

## Share one cache file between Windows and WSL2

**Tried:** documented (incorrectly) as automatic in 1.0.0–1.1.0; the README
claimed the cache "is shared if you use both".

**Verdict:** don't. Claim removed; two independent caches is the intended
arrangement.

**Why not:** it was never true — `~` resolves to `%USERPROFILE%\.claude\` on
Windows and `/home/<you>/.claude/` under WSL2, so installing in both simply
yields two caches. Making it true (by overriding `_QL_CACHE`) buys almost
nothing and costs two real things: the WSL2 side would `stat` and parse the file
across `/mnt/c` on every statusline refresh, and mismatched library versions make
the scoped segment flap, because an older library's write omits `scoped_limits`
and delete-by-omission correctly honours that as a removal.

A second cache costs one extra fetch per TTL. That is cheaper than either
problem.

The format *is* compatible in both directions, which is worth keeping — a cache
written by one library is readable by the other.

---

## Tab-delimited `jq` → `read` field splitting

**Tried:** `jq ... | join("\t")` into `IFS=$'\t' read -r a b c`. Shipped in
1.0.0.

**Verdict:** never again. Replaced with `0x1F`.

**Why not:** tab is IFS *whitespace*, so bash strips leading tabs and collapses
runs of them; a single empty field shifts every value after it. In practice a
null 5h percentage put the weekly figure into `QUOTA_RESULT[pct]` — wrong number,
displayed confidently, no marker, on every Linux/WSL2 install. Found only because
a test asserted an empty field. See `CLAUDE.md`.

---

## Trusting `bash -n` as a correctness check

**Verdict:** it is a syntax check and nothing more.

**Why not:** it passed a `read` statement whose line continuations had become
literal `\n`, which bash parsed as a variable named `n` — shifting every field by
one. Valid syntax, broken behaviour, and the same class of bug the surrounding
commit was fixing. Run `tests/test-quota-lib.sh`.
