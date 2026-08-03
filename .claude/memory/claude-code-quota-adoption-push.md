---
name: claude-code-quota-adoption-push
description: State of the 2026-07-28 adoption push for the claude-code-quota repo — what shipped in v1.0.0 and which distribution steps remain
metadata: 
  node_type: memory
  type: project
  originSessionId: c91aea9c-70de-4f87-bca8-b3fd6608d1cb
  modified: 2026-07-28T20:57:40.380Z
---

On 2026-07-28 we did an adoption push for github.com/aweussom/claude-code-quota (the user's OSS statusline quota tool): tagged v1.0.0, added GitHub topics, packaged the repo as a self-hosting Claude Code plugin (`.claude-plugin/plugin.json` + `marketplace.json`, install via `/plugin marketplace add aweussom/claude-code-quota`), converted `commands/quota.md` to `skills/quota/SKILL.md`, added `lib_version` stamping to the cache payload, and fixed the ⚠-mangled-to-? OEM-code-page bug.

Submitted to the community plugin marketplace on 2026-07-28 (validation/safety scan is automated; catalog sync to anthropics/claude-plugins-community can lag ~a day).

Blog post published 2026-07-28: https://aweussom.github.io/i-fired-the-quota-robot-and-hired-a-json-file.html ("The Robot Read My Claude Quota With 235 Billion Parameters. I Fired It and Hired a JSON File."). dev.to mirrors via RSS auto-draft; the user publishes the draft manually on dev.to.

Remaining steps the user hasn't done yet:
- PR the tool into the awesome-claude-code list.
- Publish the auto-drafted dev.to mirror once the RSS import picks it up.

Key constraint learned from docs: Claude Code plugins cannot configure `statusLine` — that stays in the user's settings.json, so install.ps1/install.sh remain the wiring path.
