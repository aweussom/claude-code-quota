# Overage guard for Claude Code

A hook that stops Claude Code before it spends extra usage (pay per token).

With extra usage switched on and no spend limit, 5h or 7d at 100 % does not stop Claude Code. It just carries on and bills. Only scoped limits (Fable) stop it. I figured this out from one Team seat's billing (2026-11-17), not from Anthropic docs.

The guard runs on UserPromptSubmit and PreToolUse. It blocks (exit 2) when 5h, 7d or a scoped bucket is at 98 % or more and `extra_usage.is_enabled` is true. If the cached figure is older than 120 s it fetches a new one itself, through the installed quota-lib, with the same lock and cache as the statusline. If it cannot get a figure younger than 15 min, it blocks.

The hook is not part of the plugin. Install it by hand, per machine.

## Platforms

| Platform | Status |
|---|---|
| Windows 11, pwsh 7 | tested 2026-11-18 |
| Linux / WSL2 | fetch path tested 2026-11-18 |
| macOS | not supported: quota-lib.sh uses GNU `stat -c` and the token is in the Keychain. The guard blocks with a message saying so. |

## Requirements

- claude-code-quota installed (`~/.claude/quota-lib.ps1` or `~/.claude/quota-lib.sh`).
- Python 3.10+ (`python` on Windows, `python3` on Linux).

## Install

1. Save the two scripts below as `~/.claude/hooks/overage_guard.py` and `~/.claude/hooks/overage_guard_ctl.py`.
2. Register the hooks (backs up `settings.json` first):

   ```bash
   python3 ~/.claude/hooks/overage_guard_ctl.py on      # Windows: python
   python3 ~/.claude/hooks/overage_guard_ctl.py status
   ```

3. Restart running Claude Code sessions. Hooks load at startup.
4. Test:

   ```bash
   echo '{"hook_event_name":"UserPromptSubmit"}' | python3 -I ~/.claude/hooks/overage_guard.py; echo "exit=$?"
   tail -n 3 ~/.claude/overage-guard.log
   ```

   Exit 0 and a `buckets=...` line means it works. Exit 2 prints why.

## Operating

- Bypass for one session: start Claude Code with `CLAUDE_ALLOW_OVERAGE=1`.
- Switch off: `overage_guard_ctl.py off`. Running sessions obey at once through `~/.claude/overage-guard.disabled`.
- Do not delete `overage_guard.py` while a session that loaded it is running. `python <missing file>` exits 2, which reads as "blocked".
- Log: `~/.claude/overage-guard.log`, one line per check. It is not rotated.

## Limits

- The guard sees the counter with up to ~120 s lag, so 98 % and not 100 %. One long model response can still cross the line between two checks.
- A 401 from the quota endpoint (expired login) blocks until you log in again. That is intended - without a figure there is nothing to check.
- This is a seatbelt. The real limit is a spend limit set by the Team owner.


## overage_guard.py

```python
#!/usr/bin/env python3
"""Block Claude Code before it spends extra usage (pay-per-token overage).

Why: with extra usage enabled and no spend limit, hitting 100% of the 5h or
7d bucket does not stop Claude Code; it keeps going and bills per token. Only
scoped limits (Fable) stop it. This hook makes every bucket a hard stop.

Runs as UserPromptSubmit and PreToolUse hook. Exit 2 = block (stderr is shown
to the user / fed to Claude). Exit 0 = allow, prints nothing to stdout because
UserPromptSubmit stdout is injected into the conversation.

Reads ~/.claude/quota-data.json, the cache claude-code-quota's statusline
writes. When that is older than REFRESH_AFTER_SEC it fetches itself, through
quota-lib.ps1 on Windows or quota-lib.sh on Linux/WSL2 (same lock, same
atomic write, same cache), because the
statusline does not redraw while the console is idle: the first prompt after
a break always found a stale cache and was blocked.

Bypass on purpose:  CLAUDE_ALLOW_OVERAGE=1
Switch off:         python ~/.claude/hooks/overage_guard_ctl.py off
                    (creates DISABLE_FILE, which running sessions honour at
                    once, and removes the hook from settings.json)

Never delete this file while a session that loaded the hook is running:
`python missing.py` exits 2, which a UserPromptSubmit hook reports as "block".
"""
import datetime
import json
import logging
import os
import pathlib
import shutil
import subprocess
import sys
import time

BLOCK_AT_PCT = 98        # not 100: the cache lags the real counter by up to ~60s
MAX_CACHE_AGE_MIN = 15   # last good figure older than this proves nothing about now
REFRESH_AFTER_SEC = 120  # fetch ourselves when the last good figure is older than this
FETCH_TIMEOUT_SEC = 35   # quota-lib's HTTP timeout is 20s, plus pwsh startup
LOCK_WAIT_SEC = 25       # how long to wait for someone else's fetch to land

CLAUDE_DIR = pathlib.Path.home() / ".claude"
CACHE_FILE = CLAUDE_DIR / "quota-data.json"
LOCK_FILE = CLAUDE_DIR / ".quota-fetch.lock"
QUOTA_LIB_PS = CLAUDE_DIR / "quota-lib.ps1"   # Windows
QUOTA_LIB_SH = CLAUDE_DIR / "quota-lib.sh"    # Linux / WSL2 (GNU stat; not macOS)
DISABLE_FILE = CLAUDE_DIR / "overage-guard.disabled"
LOG_FILE = CLAUDE_DIR / "overage-guard.log"

# Exit codes of FETCH_PS, below.
FETCH_DONE = 0
FETCH_LOCK_HELD = 3
FETCH_NOT_ANTHROPIC = 4

# _QL_UseProvider first so lock, cache and endpoint all point at the provider
# quota-lib thinks this session spends. Lock taken with CreateNew (O_EXCL);
# never check-then-write, five sessions may arrive in the same second.
FETCH_PS = (
    ". '{lib}'; "
    "if ((_QL_UseProvider) -ne 'anthropic') {{ exit 4 }}; "
    "if (-not (_QL_TryLock)) {{ exit 3 }}; "
    "try {{ Invoke-QuotaFetchOnce }} finally {{ _QL_ReleaseLock }}; "
    "exit 0"
)

# Same contract in bash. _ql_try_lock uses noclobber (O_EXCL).
FETCH_SH = (
    'source "$1" || exit 5; '
    '_QL_PROVIDER=$(_ql_provider); '
    '[[ "$_QL_PROVIDER" == anthropic ]] || exit 4; '
    '_ql_try_lock || exit 3; '
    '_ql_fetch_once; rm -f "$_QL_LOCK"; '
    'exit 0'
)

logging.basicConfig(
    filename=LOG_FILE,
    encoding="utf-8",
    format="%(asctime)s %(levelname)s %(filename)s:%(lineno)d %(funcName)s — %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("overage_guard")


def block(reason):
    log.warning("BLOCK: %s", reason)
    print(f"overage-guard: {reason}", file=sys.stderr)
    print("overage-guard: bypass deliberately with CLAUDE_ALLOW_OVERAGE=1, "
          "or switch off: python ~/.claude/hooks/overage_guard_ctl.py off", file=sys.stderr)
    sys.exit(2)


def parse_utc(iso):
    try:
        return datetime.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        block(f"{CACHE_FILE} holds a timestamp that is not ISO 8601: {iso!r}")


def seconds_since(iso):
    now = datetime.datetime.now(datetime.timezone.utc)
    return (now - parse_utc(iso)).total_seconds()


def read_cache():
    """Return the cache dict, or None if it does not exist yet."""
    if not CACHE_FILE.is_file():
        return None
    try:
        return json.loads(CACHE_FILE.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        # Writes are atomic renames, so this is not a torn file; something else is wrong.
        block(f"cannot read {CACHE_FILE}: {exc}")


def retry_backoff_sec(cache):
    """Same taper as Invoke-QuotaGet: 60s, 120s, 240s ... capped at 15 min."""
    fails = int(cache.get("consecutive_failures") or 0)
    if fails == 0:
        return 0
    backoff = 60
    for _ in range(1, fails):
        if backoff >= 900:
            break
        backoff *= 2
    return min(backoff, 900)


def wants_fetch(cache):
    """Decide whether this hook call should hit the API itself."""
    if cache is None:
        return True, "no cache yet"

    last_ok = cache.get("last_success_updated")
    if last_ok and seconds_since(last_ok) < REFRESH_AFTER_SEC:
        return False, f"last success {seconds_since(last_ok):.0f}s ago is fresh enough"

    last_try = cache.get("attempted_at_utc") or cache.get("updated")
    backoff = retry_backoff_sec(cache)
    if last_try and backoff and seconds_since(last_try) < backoff:
        return False, (f"{cache.get('consecutive_failures')} failures in a row, last attempt "
                       f"{seconds_since(last_try):.0f}s ago, backing off {backoff}s")

    return True, f"last success {last_ok!r} is older than {REFRESH_AFTER_SEC}s"


def fetch_command():
    """argv that runs one locked fetch through the installed quota-lib."""
    if os.name == "nt":
        pwsh = shutil.which("pwsh")
        if pwsh is None:
            block("pwsh (PowerShell 7) not on PATH; needed to fetch quota via quota-lib.ps1.")
        if not QUOTA_LIB_PS.is_file():
            block(f"{QUOTA_LIB_PS} missing. Install claude-code-quota, or bypass.")
        command = FETCH_PS.format(lib=str(QUOTA_LIB_PS).replace("'", "''"))
        return [pwsh, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-Command", command], QUOTA_LIB_PS

    if sys.platform == "darwin":
        # quota-lib.sh uses GNU `stat -c` and reads ~/.claude/.credentials.json;
        # on macOS the token lives in the Keychain. It cannot fetch here.
        block("macOS is not supported by claude-code-quota, so quota cannot be checked.")
    bash = shutil.which("bash")
    if bash is None:
        block("bash not on PATH; needed to fetch quota via quota-lib.sh.")
    if not QUOTA_LIB_SH.is_file():
        block(f"{QUOTA_LIB_SH} missing. Install claude-code-quota, or bypass.")
    return [bash, "-c", FETCH_SH, "overage_guard", str(QUOTA_LIB_SH)], QUOTA_LIB_SH


def fetch_quota():
    argv, lib = fetch_command()
    log.info("fetching quota via %s, expecting a fresh %s", lib, CACHE_FILE)
    started = time.monotonic()
    try:
        result = subprocess.run(
            argv, capture_output=True, text=True, timeout=FETCH_TIMEOUT_SEC,
        )
    except subprocess.TimeoutExpired:
        block(f"quota fetch did not finish in {FETCH_TIMEOUT_SEC}s.")
    elapsed = time.monotonic() - started
    log.info("fetch exit=%s after %.1fs stderr=%r", result.returncode, elapsed, result.stderr.strip())

    if result.returncode == FETCH_DONE:
        return
    if result.returncode == FETCH_NOT_ANTHROPIC:
        log.info("quota-lib resolves this session to a non-Anthropic provider")
        return
    if result.returncode == FETCH_LOCK_HELD:
        log.info("another process holds %s, waiting up to %ss for its fetch", LOCK_FILE, LOCK_WAIT_SEC)
        deadline = time.monotonic() + LOCK_WAIT_SEC
        while LOCK_FILE.exists() and time.monotonic() < deadline:
            time.sleep(0.5)
        log.info("lock %s after wait", "still held" if LOCK_FILE.exists() else "released")
        return
    block(f"quota fetch via {lib.name} failed (exit {result.returncode}): {result.stderr.strip()[:300]}")


def main():
    hook_input = {}
    raw = sys.stdin.read()
    if raw.strip():
        hook_input = json.loads(raw)
    event = hook_input.get("hook_event_name", "?")
    tool = hook_input.get("tool_name", "")
    log.info("checking event=%s tool=%s", event, tool)

    if DISABLE_FILE.exists():
        log.info("%s exists, guard switched off", DISABLE_FILE)
        return

    if os.environ.get("CLAUDE_ALLOW_OVERAGE") == "1":
        log.info("CLAUDE_ALLOW_OVERAGE=1, allowing without checking")
        return

    # Same rule as claude-code-quota: ANTHROPIC_BASE_URL decides who is billed.
    base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    if base_url and "api.anthropic.com" not in base_url:
        log.info("ANTHROPIC_BASE_URL=%s is not Anthropic, nothing to guard", base_url)
        return

    cache = read_cache()
    fetch, why = wants_fetch(cache)
    log.info("fetch=%s because %s", fetch, why)
    if fetch:
        fetch_quota()
        cache = read_cache()

    if cache is None:
        block(f"{CACHE_FILE} still missing after a fetch attempt.")

    last_ok = cache.get("last_success_updated")
    if not last_ok:
        block(f"{CACHE_FILE} has no successful fetch (error: {cache.get('error')!r}).")
    age_min = seconds_since(last_ok) / 60
    if age_min > MAX_CACHE_AGE_MIN:
        block(f"last good quota figure is {age_min:.0f} min old (limit {MAX_CACHE_AGE_MIN}); "
              f"fetch failing: {cache.get('error')!r} "
              f"({cache.get('consecutive_failures')} failures in a row).")

    extra = cache.get("extra_usage") or {}
    extra_enabled = extra.get("is_enabled")
    credits_usd = (extra.get("used_credits") or 0) / 100

    buckets = [
        ("5h", (cache.get("current_session") or {}).get("percent_used")),
        ("7d", (cache.get("weekly_limits") or {}).get("percent_used")),
    ]
    for scoped in cache.get("scoped_limits") or []:
        buckets.append((scoped.get("label", "scoped"), scoped.get("percent_used")))

    full_buckets = []
    for name, pct in buckets:
        if pct is not None and float(pct) >= BLOCK_AT_PCT:
            full_buckets.append(f"{name}:{pct}%")

    log.info("buckets=%s extra_enabled=%s extra_spent=$%.2f age=%.1fmin",
             buckets, extra_enabled, credits_usd, age_min)

    if not full_buckets:
        return

    if extra_enabled is False:
        # Anthropic stops us itself; no money at stake.
        log.info("full %s but extra usage is off, Anthropic will stop it", full_buckets)
        return

    block(f"{', '.join(full_buckets)} is at/over {BLOCK_AT_PCT}%. Continuing would bill "
          f"extra usage (spent this month: ${credits_usd:.2f}). Wait for the reset "
          "(5h/7d are shared by all models; switching model only helps for a scoped bucket).")


if __name__ == "__main__":
    # An uncaught exception exits 1, which Claude Code treats as a non-blocking
    # error: the guard would fail open without a word. Fail closed instead.
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        log.exception("guard crashed")
        block(f"guard crashed: {exc!r} (traceback in {LOG_FILE})")
```

## overage_guard_ctl.py

```python
#!/usr/bin/env python3
"""Switch overage_guard.py on or off in Claude Code's user settings.

    python ~/.claude/hooks/overage_guard_ctl.py status
    python ~/.claude/hooks/overage_guard_ctl.py off
    python ~/.claude/hooks/overage_guard_ctl.py on

off: creates ~/.claude/overage-guard.disabled and removes every hook whose
     command mentions overage_guard.py from ~/.claude/settings.json and
     settings.local.json. Sessions already running keep the hook they loaded
     at startup, so the disable file is what frees them: the guard checks it
     first and allows. The guard file itself is left in place on purpose;
     a running session calling `python <missing file>` gets exit 2 = blocked.
on:  removes the disable file and adds the hook for UserPromptSubmit and
     PreToolUse (all tools) to ~/.claude/settings.json.

settings.json is backed up next to itself before every write, and written
via temp file + rename.
"""
import datetime
import json
import logging
import os
import pathlib
import sys

CLAUDE_DIR = pathlib.Path.home() / ".claude"
GUARD = CLAUDE_DIR / "hooks" / "overage_guard.py"
DISABLE_FILE = CLAUDE_DIR / "overage-guard.disabled"
SETTINGS_FILES = [CLAUDE_DIR / "settings.json", CLAUDE_DIR / "settings.local.json"]
MARKER = "overage_guard.py"
EVENTS = ["UserPromptSubmit", "PreToolUse"]
HOOK_TIMEOUT_SEC = 60  # guard may fetch: pwsh startup + 20s HTTP + lock wait

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(filename)s:%(lineno)d %(funcName)s — %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("overage_guard_ctl")


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def save(path, settings):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.bak-{stamp}")
    backup.write_bytes(path.read_bytes())
    log.info("backed up %s to %s", path, backup)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    log.info("wrote %s", path)


def guard_hooks(settings):
    """Yield (event, group_index, hook_index, command) for every guard hook."""
    hooks = settings.get("hooks") or {}
    for event, groups in hooks.items():
        for gi, group in enumerate(groups):
            for hi, hook in enumerate(group.get("hooks") or []):
                command = hook.get("command", "")
                if MARKER in command:
                    yield event, gi, hi, command


def strip_guard(settings):
    """Remove guard hooks; drop groups and events left empty. Returns count removed."""
    hooks = settings.get("hooks") or {}
    removed = 0
    for event in list(hooks):
        kept_groups = []
        for group in hooks[event]:
            kept = []
            for hook in group.get("hooks") or []:
                if MARKER in hook.get("command", ""):
                    removed += 1
                    continue
                kept.append(hook)
            if kept:
                group["hooks"] = kept
                kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if "hooks" in settings and not settings["hooks"]:
        del settings["hooks"]
    return removed


def cmd_status():
    print(f"guard file:   {GUARD} {'present' if GUARD.is_file() else 'MISSING'}")
    print(f"disable file: {DISABLE_FILE} {'present (guard OFF)' if DISABLE_FILE.exists() else 'absent'}")
    for path in SETTINGS_FILES:
        if not path.is_file():
            continue
        found = list(guard_hooks(load(path)))
        print(f"{path}: {len(found)} guard hook(s)")
        for event, _, _, command in found:
            print(f"  {event}: {command}")


def cmd_off():
    DISABLE_FILE.write_text("overage_guard switched off by overage_guard_ctl.py\n", encoding="utf-8")
    log.info("created %s; running sessions now allow every prompt", DISABLE_FILE)
    for path in SETTINGS_FILES:
        if not path.is_file():
            continue
        settings = load(path)
        removed = strip_guard(settings)
        if removed == 0:
            log.info("%s has no guard hooks", path)
            continue
        save(path, settings)
        log.info("removed %d guard hook(s) from %s", removed, path)
    log.info("new sessions start without the hook; leave %s in place until old ones exit", GUARD)


def cmd_on():
    if not GUARD.is_file():
        log.error("%s missing; put it back before switching on", GUARD)
        sys.exit(1)
    path = SETTINGS_FILES[0]
    settings = load(path)
    strip_guard(settings)  # no duplicates if run twice
    # Linux often has no `python`; a missing interpreter is a non-blocking hook
    # error, i.e. the guard would fail open without a word.
    interpreter = "python" if os.name == "nt" else "python3"
    command = f"{interpreter} -I {GUARD.as_posix()}"
    hooks = settings.setdefault("hooks", {})
    for event in EVENTS:
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": command, "timeout": HOOK_TIMEOUT_SEC}]}
        )
    save(path, settings)
    log.info("added %r for %s in %s", command, EVENTS, path)
    if DISABLE_FILE.exists():
        DISABLE_FILE.unlink()
        log.info("removed %s; running sessions that loaded the hook are guarded again", DISABLE_FILE)
    log.info("sessions started before now do not have the hook; restart them")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("on", "off", "status"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    action = sys.argv[1]
    if action == "status":
        cmd_status()
    elif action == "off":
        cmd_off()
    else:
        cmd_on()


if __name__ == "__main__":
    main()
```
