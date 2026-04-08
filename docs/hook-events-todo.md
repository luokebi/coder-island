# Claude Code Hook Events — Coverage & Backlog

Authoritative source: `HOOK_EVENTS` in Claude Code 2.1.x
`src/entrypoints/sdk/coreTypes.ts:25` (26 events total).

## ✅ Intercepted

| Event | Matcher | Script | Purpose |
|---|---|---|---|
| `PermissionRequest` | `AskUserQuestion` | `coder-island-ask` | Route AskUserQuestion to notch banner |
| `PermissionRequest` | `Bash\|Edit\|MultiEdit\|Write\|NotebookEdit\|Read\|Glob\|Grep\|Task\|WebFetch\|WebSearch` | `coder-island-permission` | Route tool permission prompts to notch banner |
| `PreToolUse` | `*` | `coder-island-event` | Real-time "running $tool" subtitle |
| `PostToolUse` | `*` | `coder-island-event` | Real-time tool completion |
| `PostToolUseFailure` | `*` | `coder-island-event` | Show tool error in subtitle |
| `Stop` | `*` | `coder-island-event` | Authoritative main-agent turn end (replaces fragile jsonl `end_turn` detection) |
| `StopFailure` | `*` | `coder-island-event` | Turn ended with error → `.error` status |
| `UserPromptSubmit` | `*` | `coder-island-event` | Reset idle, clear completion marker, subtitle → "Thinking..." |

Hook script relay pattern: `coder-island-event` is a single shell script
registered under every lifecycle key above. It POSTs INPUT to
`http://localhost:19876/event`; `HookServer.swift` dispatches by
`hook_event_name` to `AgentManager.applyHookEvent`.

Subagent events (payload has `agent_id`) are currently **dropped** in
`AgentManager.applyHookEvent` — not yet modelled in the UI.

## ✅ Codex coverage

Source of truth: `codex-rs/app-server-protocol/schema/typescript/v2/HookEventName.ts`
— Codex exposes only **5 hook events** (vs Claude Code's 26).

Settings file: `~/.codex/hooks.json` (separate from Claude's
`~/.claude/settings.json`). Toggle: `codex_hooks = true` in
`~/.codex/config.toml` (Codex feature flag — users who installed
vibe-island already have this enabled).

| Event | Matcher | Handler | Notes |
|---|---|---|---|
| `SessionStart` | `*` | `coder-island-event` | Instant new-session discovery. Matcher is regex-capable; `source` field is "startup" or "resume" |
| `UserPromptSubmit` | (ignored) | `coder-island-event` | Matcher field ignored by Codex runtime |
| `PreToolUse` | `*` | `coder-island-event` | **Only fires for Bash tool** — `tool_name` in payload is always `"Bash"` |
| `PostToolUse` | `*` | `coder-island-event` | Same Bash-only limitation |
| `Stop` | (ignored) | `coder-island-event` | Payload carries `last_assistant_message` and `stop_hook_active` |

Codex hook entries **coexist** with any third-party entries already in
`hooks.json` (e.g. vibe-island). `HookInstaller.registerInCodexSettings`
only replaces its own `coder-island` entries on each key.

Payload field names match Claude Code's (`hook_event_name`,
`session_id`, `cwd`, `transcript_path`, `tool_name`, `tool_input`,
etc.) so `HookServer /event` and `AgentManager.applyHookEvent` handle
both agents through the same code path. Codex's `session_id` is a
`ThreadId` UUID that matches the id assigned to each session by
`scanCodexSessions`.

### Codex-specific gaps
- **Tool-level hooks only cover Bash.** File edits, writes, reads,
  web fetches, etc. fire no PreToolUse / PostToolUse — their tool
  activity has to come from jsonl tail parsing of
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (already handled by
  `parseCodexState`).
- **No permission-request hook.** Codex's permission flow is entirely
  internal; we can't mirror Claude Code's Allow/Deny banner there.
- **No subagent events.** Codex doesn't expose SubagentStop / nested
  agent lifecycle.
- **No compact / elicitation / failure-variant events.**

## ⬜ Not yet intercepted

### 🟡 Medium value — solid wins if/when we need them

| Event | Why it matters | Notes |
|---|---|---|
| `SessionStart` | Instant new-session detection, no 3s poll delay; payload has initial cwd/gitBranch/customTitle | Today: `scanClaudeCodeSessions` reads `~/.claude/sessions/*.json` pid files; slow-ish to discover |
| `SessionEnd` | Instant session removal; payload carries exit reason (`clear`/`resume`/`logout`/`prompt_input_exit`/`bypass_permissions_disabled`/`other` per `EXIT_REASONS`) | Today: we guess via `isProcessRunning(pid:)` |
| `SubagentStart` / `SubagentStop` | Show Task-tool subagent lifecycle inside the parent card; would need subagent modelling in AgentSession | Subagent transcripts live at `~/.claude/projects/*/subagents/agent-*.jsonl` — not yet parsed |
| `Notification` | Claude Code's native "needs attention" notifications (idle waiting, turn timeout, etc.) — this is what vibe-island listens on `*` | Probably enables a "nudge" toast pattern |
| `PermissionDenied` | Final-denial notification after the permission hook chain. Currently invisible — user only sees the tool "not running" | Good for red error banner |
| `PreCompact` / `PostCompact` | Show "Compacting context..." progress; compaction is 10–60s and currently unexplained in UI | |
| `Elicitation` / `ElicitationResult` | MCP server-initiated Q&A (distinct from Claude's own AskUserQuestion). Only relevant if the user runs MCP servers that elicit | |
| `TaskCreated` / `TaskCompleted` | Claude Code 2.x TodoWrite / TaskList system. Could show per-session task progress in the card | |

### 🟢 Low priority / niche

| Event | Why skipped |
|---|---|
| `Setup` | One-off init, not useful for UI |
| `ConfigChange` | settings.json mutations; minor |
| `InstructionsLoaded` | CLAUDE.md load; debug-only |
| `CwdChanged` | Rare, not user-facing |
| `FileChanged` | Requires explicit `watchPaths` opt-in; no general use |
| `WorktreeCreate` / `WorktreeRemove` | git worktree feature; niche |
| `TeammateIdle` | Multi-agent team mode; not general |

## Architectural gaps even with more hooks

These are issues the hook path alone won't fix — tracked for future work:

- **Subagent modelling.** Task-launched agents are entirely invisible: their
  `agent_id`-bearing events are dropped in `applyHookEvent`, and we don't
  parse `~/.claude/projects/*/subagents/agent-*.jsonl`.
- **Streaming tool output.** PostToolUse fires once the tool is done; Bash
  long-runs show no interim progress. Would need to tee the tool stdout
  through a separate channel.
- **Thinking state.** Claude's `thinking` content blocks produce no hook
  events — a long think looks like idle tool_use to us.
- **Race between jsonl poll and hook state.** Today the scan loop can
  overwrite hook-set subtitle within 1s. Not wrong but visually noisy.
- **Hook trust dialog.** Claude Code gates hook execution behind an
  interactive trust prompt (`src/utils/hooks.ts:shouldSkipHookDueToTrust`).
  In non-interactive CLI invocations hooks are skipped entirely.
