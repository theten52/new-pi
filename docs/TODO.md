# NewPi Development TODOs

Tracked blockers and follow-ups discovered during autonomous development.

## Phase 4 — Session persistence

| ID | Item | Status | Notes |
|---|---|---|---|
| P4-UI | Sidebar session list + resume | done | Phase 4b/c |
| P4-BRANCH | Branch/fork UI for tree sessions | deferred | v1: linear resume only |
| P4-RESUME-PROVIDER | Restore provider profile from session header on resume | pending | Currently uses default profile |
| P4-CLI | CLI session commands | deferred | `new-pi sessions list` etc. |

## Phase 5 — Deferred

| ID | Item | Notes |
|---|---|---|
| P5-AGENTS | AGENTS.md loader | Planned after Phase 4 |
| P5-SKILLS | Swift Skills protocol | |
| P5-COMPACT | Context compaction | |

## Phase 6 — UI polish

| ID | Item | Notes |
|---|---|---|
| P6-PROVIDER-PICKER | In-chat provider switch | |
| P6-TEST-CONN | Settings "Test provider" button | |
| P6-MARKDOWN | Transcript markdown rendering | |

## Known environment noise (no action)

- `com.apple.linkd.autoShortcut` — App Intents registration in Xcode debug; benign
- `ViewBridge Terminated` — Settings window close; benign
