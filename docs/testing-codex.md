# Testing CoderIsland — Codex session

This doc covers tests for the **Codex** integration only
(`parseCodexState` + the Codex hook chain). For the Claude Code side,
see `docs/testing-claude.md`.

---

# Testing CoderIsland

There are two complementary test layers. Both should pass before any
change to `AgentManager.parseCodexState`, `AgentManager.applyHookEvent`,
or the Codex branch of `HookInstaller` / `HookServer` ships.

| Layer | What it catches | How to run |
|---|---|---|
| **Parser unit tests** (`CodexParserTests.swift`) | Bugs in rollout-tail interpretation: `task_complete` detection, `turn_aborted` handling, response-item fallback, "new user prompt after completion" overrides. | `CODER_ISLAND_RUN_CODEX_PARSER_TESTS=1` env var on app launch |
| **E2E dynamic tests** (Codex-driven) | Bugs in the live Codex hook relay (`SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop`), `hooks.json` registration drift, and spurious completion sounds during active turns. | Drive Codex through a fixed Bash-only sequence, then diff `hook-ingress.log`; separately smoke-test one non-Bash turn to confirm the jsonl parser still drives the UI. |

---

## Layer 1: CodexParserTests

Synthetic rollout fragments fed directly to
`AgentManager.parseCodexState(from:)`. Pure in-memory, runs in
milliseconds, no live Codex session required.

### Where it lives
- **Test file**: `CoderIsland/Agents/CodexParserTests.swift`
- **Driver**: `AppDelegate.applicationDidFinishLaunching` checks the env
  var / argv flag and calls `CodexParserTests.runAll()` before normal
  startup.

### Running

```bash
# Either:
CODER_ISLAND_RUN_CODEX_PARSER_TESTS=1 /path/to/CoderIsland.app/Contents/MacOS/CoderIsland &
sleep 2; pkill -9 CoderIsland
cat ~/Library/Logs/CoderIsland/codex-parser-tests.log

# Or:
/path/to/CoderIsland.app/Contents/MacOS/CoderIsland --run-codex-parser-tests &
sleep 2; pkill -9 CoderIsland
```

The log starts with a one-line summary (`Codex parser tests: N/N passed,
X failed`) followed by per-case ✅/❌ blocks with expected vs actual.

### Cases currently covered

| # | Case | Asserts |
|---|---|---|
| 1 | empty rollout | default `.idle` |
| 2 | `task_started` only | `.running` + "Thinking..." |
| 3 | recent `response_item function_call` with no task event in tail | `.running` + function name fallback |
| 4 | `task_started` + latest function call | `.running` + latest function name |
| 5 | normal `task_complete` | `.justFinished` |
| 6 | `task_complete` followed by a newer user prompt | `.running` (old completion overridden) |
| 7 | `turn_aborted reason=interrupted` | `.idle` |
| 8 | non-interrupted `turn_aborted` | `.error` + "Aborted" |

### Adding a new case

1. Open `CodexParserTests.swift` and find `allCases()`.
2. Use the small entry builders (`taskStarted`, `taskComplete`,
   `turnAborted`, `userMessage`, `responseItemFunctionCall`) to
   construct the synthetic rollout tail.
3. Append a `CodexParserTestCase(...)` with `expectedStatus` and
   optionally `expectedSubtitleContains`.
4. Re-run with the env var; verify the new case passes.

If you need a new entry shape, add a helper next to the existing ones
and keep it restricted to fields `parseCodexState` actually reads.

---

## Layer 2: E2E dynamic tests (Codex-driven)

These verify the **live integration** between Codex and CoderIsland.
Unlike the Claude test, the hook side is smaller: Codex only exposes 5
events total, and tool-level hooks currently fire only for the **Bash**
tool. Non-Bash activity still has to be observed through rollout polling.

### Prerequisites

| Check | How |
|---|---|
| App is running | `pgrep -lf CoderIsland` returns a pid |
| HookServer is listening | `curl -s -m 1 -X POST http://localhost:19876/event -H "Content-Type: application/json" -d '{"hook_event_name":"Ping"}'` returns `{}` |
| Codex hooks enabled | `rg -n "codex_hooks\\s*=\\s*true" ~/.codex/config.toml` |
| `hooks.json` contains coder-island relay | `sed -n '1,220p' ~/.codex/hooks.json` shows `coder-island-event` under `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` |
| Session ID known | First 8 chars of the current Codex thread id; easiest source is the latest `SessionStart` / `UserPromptSubmit` line in `~/Library/Logs/CoderIsland/hook-ingress.log` |

### Important limitation

Codex currently fires `PreToolUse` / `PostToolUse` only for **Bash**.
Do not write an E2E expectation list that assumes hooks for file reads,
edits, web fetches, or any other native tool. Those are parser-only on
our side.

### Protocol A: Hook relay with a fixed Bash sequence

#### Step 1: Capture baseline cursor

Run **as the first Bash tool of the turn**:

```bash
echo "BASELINE: HOOK=$(wc -l < ~/Library/Logs/CoderIsland/hook-ingress.log) SOUND=$(wc -l < ~/Library/Logs/CoderIsland/sound-trace.log)"
```

The cursor is the `HOOK=` count. This Bash itself generates a
`PreToolUse Bash` entry at the cursor line and a `PostToolUse Bash`
immediately after. Count those as `op0`.

> ⚠ **Cursor purity**: do NOT run extra Bash commands between the
> baseline Bash and the fixed sequence. The Baseline Bash is part of the
> expected event window.

#### Step 2: Execute a strict serial Bash sequence

Each tool must be in its own tool-call block so Codex dispatches them
sequentially, not in parallel.

Use any three trivial successful Bash commands. Example:

| op | Tool | Expected events |
|---|---|---|
| op1 | `Bash pwd` | Pre+Post Bash |
| op2 | `Bash printf 'codex-e2e\n'` | Pre+Post Bash |
| op3 | `Bash uname -s` | Pre+Post Bash |

After the last Bash command, let Codex finish the response normally. The
turn should end with one `Stop` event for the same session id.

#### Step 3: Verify the `hook-ingress.log` sequence

Use this Python snippet (parametrize `cursor` and `my_sid`):

```python
import re

expected = [
    ("op0   Bash (cursor)", "PostToolUse", "Bash"),
    ("op1   Bash pwd", "PreToolUse", "Bash"),
    ("op1   Bash pwd", "PostToolUse", "Bash"),
    ("op2   Bash printf", "PreToolUse", "Bash"),
    ("op2   Bash printf", "PostToolUse", "Bash"),
    ("op3   Bash uname", "PreToolUse", "Bash"),
    ("op3   Bash uname", "PostToolUse", "Bash"),
    ("turn  Stop", "Stop", ""),
]

cursor = 120
my_sid = "7b83a9fe"

with open('/Users/luo/Library/Logs/CoderIsland/hook-ingress.log') as f:
    lines = f.readlines()
window = lines[cursor:cursor + len(expected) + 6]
pattern = re.compile(r'(\S+)\s+(\w+)\s+sid=(\S+?)(?:\s+agent=(\S+))?(?:\s+tool=(\w+))?\s*$')

mine = []
for line in window:
    m = pattern.match(line.strip())
    if m and m.group(3) == my_sid:
        mine.append((m.group(2), m.group(5) or ""))

passes, fails = 0, 0
for i, (label, exp_event, exp_tool) in enumerate(expected):
    if i >= len(mine):
        print(f"❌ [{i+1:2}] {label} — MISSING")
        fails += 1
        continue
    actual_event, actual_tool = mine[i]
    if actual_event == exp_event and actual_tool == exp_tool:
        print(f"✅ [{i+1:2}] {label}")
        passes += 1
    else:
        print(f"❌ [{i+1:2}] {label}")
        print(f"    expected: {exp_event}/{exp_tool}")
        print(f"    actual:   {actual_event}/{actual_tool}")
        fails += 1

print(f"Codex hook events: {passes}/{len(expected)} passed, {fails} failed")
```

#### Step 4: Verify silence on `sound-trace.log` during the active turn

There should be **zero** new `taskComplete` sound entries before the
final `Stop`.

```python
sound_baseline = 50
with open('/Users/luo/Library/Logs/CoderIsland/sound-trace.log') as f:
    sound_lines = f.readlines()
new_sounds = [l for l in sound_lines[sound_baseline:] if 'taskComplete' in l]
if len(new_sounds) == 1:
    print("✅ exactly one taskComplete for the completed turn")
elif len(new_sounds) == 0:
    print("❌ missing taskComplete")
else:
    print(f"❌ {len(new_sounds)} taskComplete entries:")
    for l in new_sounds:
        print(f"   {l.rstrip()[:140]}")
```

If this fails with multiple sounds, the scan loop and hook updates are
double-counting the same completion.

### Protocol B: Non-Bash parser smoke test

This covers the Codex-specific gap: non-Bash tools do **not** emit
tool-level hooks, so CoderIsland must derive "running" state from the
rollout tail.

1. Submit a prompt that is likely to use a non-Bash tool first.
   Examples:
   - read a local source file
   - inspect git status without shelling out
   - apply a small edit with the native patch tool
2. Wait for the island subtitle to change away from idle.
3. Inspect the active rollout tail:
   ```bash
   tail -n 20 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
   ```
4. Confirm there is a recent `response_item` whose payload is a
   `function_call`, and that CoderIsland's subtitle matches that
   function name (or "Thinking..." if there is no visible function call
   yet).
5. Confirm `hook-ingress.log` does **not** show fake tool events for
   that non-Bash tool. The only tool-level hook entries should still be
   `tool=Bash`.

The point of this smoke test is not the exact tool name. The point is:
non-Bash work must still look active in the UI even though Codex does
not tell us about it via hooks.

### One-off checks for the remaining Codex hook events

#### SessionStart

Open a fresh Codex thread (or relaunch Codex Desktop into a thread) and
verify a new ingress line appears:

```bash
tail -n 20 ~/Library/Logs/CoderIsland/hook-ingress.log
```

Expected:
- `SessionStart sid=...`

#### UserPromptSubmit

From an idle thread, submit a new prompt and inspect the next few lines:

```bash
tail -n 20 ~/Library/Logs/CoderIsland/hook-ingress.log
```

Expected:
- `UserPromptSubmit sid=...`
- then, if the turn shells out, the later `PreToolUse tool=Bash` /
  `PostToolUse tool=Bash` entries

### Common pitfalls

| Pitfall | Symptom | Fix |
|---|---|---|
| `codex_hooks = false` | `hook-ingress.log` never updates for Codex turns | Enable it in `~/.codex/config.toml`, restart Codex |
| `hooks.json` missing coder-island relay | No Codex hook events despite app running | Toggle hooks in the app or relaunch CoderIsland so `HookInstaller.install()` rewrites `~/.codex/hooks.json` |
| Expecting Read/Edit hooks from Codex | Verification script reports missing tool events | Restrict the hook expectation list to Bash-only |
| Parallel Bash calls | Pre/Post entries interleave unexpectedly | Force one tool call per block |
| Baseline cursor polluted | Sequence offset does not line up | Re-run with the baseline Bash as the only command before `op1` |
| Stale Codex parser log | Summary counts look wrong | Delete `~/Library/Logs/CoderIsland/codex-parser-tests.log` before rerunning |

---

## Bugs this test plan is meant to catch

| Layer | Bug class |
|---|---|
| Parser unit tests | `task_complete` misread as still running, `turn_aborted` misclassified, response-item fallback regressing to idle |
| E2E hook relay | Missing `UserPromptSubmit` / `Stop`, broken `hooks.json` registration, Bash hook events not reaching `HookServer` |
| E2E sound check | Duplicate completion sounds from hook + scan races |
| Parser smoke | Non-Bash Codex turns becoming invisible because we accidentally relied on hooks that Codex never emits |
