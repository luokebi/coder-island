# Testing CoderIsland — Claude Code session

This doc covers tests for the **Claude Code** integration only
(jsonl parser + Claude Code hook chain). For the parallel Codex
session tests, see `docs/testing-codex.md`.

---

# Testing CoderIsland

There are two complementary test layers. Both should pass before
any change to `AgentManager.parseLastMessage` or `HookServer` ships.

| Layer | What it catches | How to run |
|---|---|---|
| **Parser unit tests** (`ParserTests.swift`) | Bugs in jsonl tail interpretation: status detection, sidechain leakage, stop-reason edge cases, completion-marker generation. | `CODER_ISLAND_RUN_PARSER_TESTS=1` env var on app launch |
| **E2E dynamic tests** (Claude-driven) | Bugs in the live hook chain: shell relay → HookServer → AppDelegate → SwiftUI; HookServer response formats Claude Code actually understands; spurious sounds during active turns. | Drive Claude through a fixed operation sequence and diff `hook-ingress.log` against the expected list. |

---

## Layer 1: ParserTests

Synthetic jsonl fragments fed directly to
`AgentManager.parseLastMessage(from:)`. Pure in-memory, runs in
milliseconds, no app state required.

### Where it lives
- **Test file**: `CoderIsland/Agents/ParserTests.swift`
- **Driver**: `AppDelegate.applicationDidFinishLaunching` checks the env
  var / argv flag and calls `ParserTests.runAll()` before normal startup.

### Running

```bash
# Either:
CODER_ISLAND_RUN_PARSER_TESTS=1 /path/to/CoderIsland.app/Contents/MacOS/CoderIsland &
sleep 2; pkill -9 CoderIsland
cat ~/Library/Logs/CoderIsland/parser-tests.log

# Or:
/path/to/CoderIsland.app/Contents/MacOS/CoderIsland --run-parser-tests &
sleep 2; pkill -9 CoderIsland
```

The log starts with a one-line summary (`Parser tests: N/N passed, X
failed`) followed by per-case ✅/❌ blocks with expected vs actual.

### Cases currently covered

| # | Case | Asserts |
|---|---|---|
| 1 | empty transcript | default `.running` |
| 2 | user prompt only | `.running` + "Thinking..." |
| 3 | assistant Bash tool_use | `.running` + `$ <command>` |
| 4 | tool_result after Bash | `.running` + matching tool subtitle |
| 5 | normal end_turn | `.justFinished` |
| 6 | **bug fix**: trailing `system stop_hook_summary` | `.justFinished` even if assistant text has `stop_reason=null` |
| 7 | intermediate thinking only | `.running` (don't snap-decide) |
| 8 | **regression**: intermediate narration text between tool calls | `.running` (must NOT be treated as finished) |
| 9 | `stop_hook_summary` followed by new user prompt | `.running` (the new prompt overrides) |
| 10 | user "[Request interrupted]" marker | `.idle` |
| 11 | sidechain end_turn does not leak | parent stays `.running` |

### Adding a new case

1. Open `ParserTests.swift` and find `allCases()`.
2. Use the entry-builder helpers (`userText`, `assistantToolUse`,
   `assistantTextEndTurn`, `systemStopHookSummary`, etc.) to construct
   the synthetic transcript.
3. Append a `ParserTestCase(...)` with `expectedStatus` and optionally
   `expectedSubtitleContains`.
4. Re-run with the env var; verify the new case passes.

If you need a new entry shape (e.g. a permission-mode entry), add a
helper next to the existing ones — keep them small and explicit.

---

## Layer 2: E2E dynamic tests (Claude-driven)

These verify the **live integration** between Claude Code's hook
system and CoderIsland. They cannot be automated as a single script
because the test driver IS the Claude Code session that the app is
observing. Instead, the protocol is: Claude executes a deterministic
operation sequence, and a Python verification snippet diffs the
resulting log entries against the expected list.

### Prerequisites

| Check | How |
|---|---|
| App is running | `pgrep -lf CoderIsland` returns a pid |
| HookServer is listening | `curl -s -m 1 -X POST http://localhost:19876/event -H "Content-Type: application/json" -d '{"hook_event_name":"Ping"}'` returns `{}` |
| Session ID known | First 8 chars of the current session id (look at `~/.claude/sessions/<pid>.json` or the path of cached images) |
| `askHooksEnabled` defaults set | `defaults read $(plutil -extract CFBundleIdentifier raw CoderIsland/Info.plist) askHooksEnabled` returns `1` |

### Protocol

#### Step 1: Capture baseline cursor

Run **as the very first** operation — nothing else between this and
Step 2:

```bash
echo "BASELINE: HOOK=$(wc -l < ~/Library/Logs/CoderIsland/hook-ingress.log) SOUND=$(wc -l < ~/Library/Logs/CoderIsland/sound-trace.log)"
```

The cursor line is the `wc -l` value. Note that this Bash itself
generates a `PreToolUse Bash` entry at the cursor line, and a
`PostToolUse Bash` immediately after. Both are part of the test
sequence — call them `op0`.

> ⚠ **Cursor purity**: do NOT call any other tool between this Bash
> and Step 2. If you do (even a small `tail` or `cat`), the cursor
> drifts and the verification gets confused. Past lesson:
> https://github.com/.../commit/6e7ba9c (we lost a test run to this).

#### Step 2: Execute the operation sequence — strictly serial

Each tool MUST be in its own `function_calls` block (one tool per
assistant response chunk). This guarantees Claude Code dispatches
them sequentially, not in parallel.

A representative 7-step sequence covering most tool families:

| op  | Tool | Expected events |
|---|---|---|
| op1 | `Read <existing file>` | Pre+Post Read |
| op2 | `Grep <pattern> in <file>` | Pre+Post Grep |
| op3 | `Glob <pattern>` | Pre+Post Glob |
| op4 | `Write <tempfile>` | Pre+Post Write |
| op5 | `Edit <tempfile>` | Pre+Post Edit |
| op6 | `Read <missing file>` | Pre + **PostToolUseFailure** Read |
| op7 | `Bash rm <tempfile>` | Pre+Post Bash |

Use `/tmp/coder-island-e2e-test.txt` as the temp file so cleanup is
easy and the project tree isn't touched.

#### Step 3: Verify the hook-ingress sequence

Use this Python snippet (parametrize `cursor`, `expected`, and
`my_sid`):

```python
import re

expected = [
    ("op0   Bash (cursor)",     "PostToolUse",         "Bash"),
    ("op1   Read",              "PreToolUse",          "Read"),
    ("op1   Read",              "PostToolUse",         "Read"),
    ("op2   Grep",              "PreToolUse",          "Grep"),
    ("op2   Grep",              "PostToolUse",         "Grep"),
    ("op3   Glob",              "PreToolUse",          "Glob"),
    ("op3   Glob",              "PostToolUse",         "Glob"),
    ("op4   Write",             "PreToolUse",          "Write"),
    ("op4   Write",             "PostToolUse",         "Write"),
    ("op5   Edit",              "PreToolUse",          "Edit"),
    ("op5   Edit",              "PostToolUse",         "Edit"),
    ("op6   Read (missing)",    "PreToolUse",          "Read"),
    ("op6   Read (missing)",    "PostToolUseFailure",  "Read"),
    ("op7   Bash (cleanup)",    "PreToolUse",          "Bash"),
    ("op7   Bash (cleanup)",    "PostToolUse",         "Bash"),
]

cursor = 648    # line count from Step 1
my_sid = "7b83a9fe"  # first 8 chars of current session id

with open('/Users/luo/Library/Logs/CoderIsland/hook-ingress.log') as f:
    lines = f.readlines()
window = lines[cursor:cursor + len(expected) + 4]
pattern = re.compile(r'(\S+)\s+(\w+)\s+sid=(\S+?)(?:\s+tool=(\w+))?\s*$')

mine = []
for l in window:
    m = pattern.match(l.strip())
    if m and m.group(3) == my_sid:
        mine.append((m.group(2), m.group(4) or ""))

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

print(f"Hook events: {passes}/{len(expected)} passed, {fails} failed")
```

#### Step 4: Verify silence on `sound-trace.log`

During an *active* turn (any time before the user's next prompt is
submitted), there should be **zero** new `taskComplete` entries.

```python
sound_baseline = 158  # from Step 1
with open('/Users/luo/Library/Logs/CoderIsland/sound-trace.log') as f:
    sound_lines = f.readlines()
new_sounds = [l for l in sound_lines[sound_baseline:] if 'taskComplete' in l]
if new_sounds:
    print(f"❌ {len(new_sounds)} spurious taskComplete:")
    for l in new_sounds:
        print(f"   {l.rstrip()[:140]}")
else:
    print("✅ no spurious taskComplete during the active turn")
```

If this fails, the parser is incorrectly treating something as a
turn end mid-turn — almost certainly a regression in the
`hasTrailingStopHookSummary` check or an over-eager heuristic in
`parseLastMessage`.

### Interactive test cases

These cannot run silently — they require the human to click in the
notch banner. Use them as ad-hoc verifications when changing the
ask / permission flow.

#### AskUserQuestion banner

1. Capture cursor as in Step 1.
2. Call `AskUserQuestion` with 2-3 distinct option labels.
3. Tell the user to click an option (any one).
4. Verify the log:
   ```bash
   sed -n '<cursor+1>,<cursor+10>p' ~/Library/Logs/CoderIsland/hook-ingress.log
   ```
   Expected:
   - `PreToolUse sid=... tool=AskUserQuestion`
   - `AskUserQuestion sid=... tool=AskUserQuestion` (the `/ask` ingress entry)
   - `PostToolUse sid=... tool=AskUserQuestion` — should fire **within ~3 seconds** of the click
5. The tool result string Claude receives should be exactly the
   clicked option's `label` field, with **no user notes**. If you see
   `user notes:` in the result, the hook fell back to terminal UI.

#### PermissionRequest banner

Requires the session to NOT be in `bypassPermissions` mode (in
bypass mode there is nothing to permission-check, so the hook never
fires). To switch out: in the terminal where Claude is running, press
`Shift+Tab` to cycle to `default` or `acceptEdits` mode.

1. Capture cursor.
2. Call `WebFetch` against a URL whose domain is not yet in
   `permissions.allow` for the current cwd.
3. Tell the user to click `Yes`, `Yes don't ask again`, or `No` in the
   banner.
4. Verify:
   - `PermissionRequest sid=... tool=WebFetch` (the `/permission` ingress entry)
   - For "Yes don't ask again", inspect
     `<cwd>/.claude/settings.local.json` — Claude Code should have
     written a new `WebFetch(domain:<host>)` rule into `permissions.allow`.

### Common pitfalls

| Pitfall | Symptom | Fix |
|---|---|---|
| App not running | `hook-ingress.log` doesn't update at all | `pgrep CoderIsland`; relaunch via `open /path/to/CoderIsland.app` |
| Parallel tool calls | Events appear interleaved (Pre 1, Pre 2, Post 1, Post 2) | Issue each tool in its own `function_calls` block |
| Bash between cursor and op1 | Sequence offset by 2 (one Pre+Post pair) | Capture cursor as the *only* tool before op1 |
| `bypassPermissions` mode | `WebFetch` succeeds without firing PermissionRequest | Switch session out of bypass via `Shift+Tab` |
| Hook script edits not picked up | Old behavior persists | Just relaunch the app — the script file is rewritten on each `HookInstaller.install()` and Claude Code reads it on every hook call (no session restart needed for script content). For settings.json `hooks` block changes, restart the Claude session. |
| Stale ParserTests log | Counts look wrong | Delete the log first: `rm ~/Library/Logs/CoderIsland/parser-tests.log` |

---

## Bugs the test layers have caught (history)

| Date | Layer | Bug |
|---|---|---|
| 2026-04-08 | E2E dynamic | `/ask` returned `{"result":"..."}` instead of the proper `hookSpecificOutput.decision.updatedInput.answers` shape — banner clicks didn't reach Claude, Claude fell back to terminal UI. |
| 2026-04-08 | Parser unit + E2E sound check | "Text with stop_reason=null → finished" was too broad — fired on every mid-turn narration text. Replaced with the trailing `stop_hook_summary` check. |
| 2026-04-08 | Parser unit | Sidechain (Task subagent) `end_turn` was leaking into the main session and triggering spurious completion sounds. Fixed by `isSidechain` filter. |
| 2026-04-07 | E2E dynamic | HookServer / hook scripts had subtle response format issues that only surfaced when actually running tools through real Claude Code. |
