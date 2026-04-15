# Legacy sounds (retained for migration compatibility)

**⚠️ PLACEHOLDER — These files have potential copyright concerns (Nintendo-derived samples).**

**They are NOT safe for public release.** Must be replaced before shipping publicly with either:
- Original audio commissioned from a sound designer
- CC0 / Public Domain assets (freesound.org, Kenney.nl, OpenGameArt.org)

## Current use

As of the `feat/soundpack-v1` refactor, these files are duplicated into
`../Resources/SoundPacks/default.cipack/sounds/` and loaded through the new
SoundPack system.

This directory is kept for backwards-compatibility fallbacks during the
migration; new code should NOT add files here.

## Status

- `mario_complete.mp3` — task complete
- `mario_permission.mp3` — permission request
- `mario_question.mp3` — AskUserQuestion
- `mario_start.mp3` — app / session start
