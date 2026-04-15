# SoundPack Manifest Schema

> **Schema version**: 1  
> **File format**: `.cipack` directory (or `.zip` in v2) containing `manifest.json` + referenced sound files

## Directory layout

```
my-pack.cipack/
├── manifest.json          # required — this schema
├── sounds/                # recommended — all audio files go here
│   ├── complete.wav
│   ├── complete-alt.wav
│   └── permission.wav
└── README.md              # optional
```

## manifest.json

```jsonc
{
  "schemaVersion": 1,                          // required: integer, must be 1
  "id": "com.example.retro-chiptune",          // required: reverse-DNS unique ID
  "name": "Retro Chiptune",                    // required: human-readable name
  "version": "1.0.0",                          // required: semver
  "author": {                                  // required
    "name": "Jane Doe",                        // required
    "url": "https://jane.example",             // optional
    "avatar": "author.png"                     // optional, relative path in pack
  },
  "license": "CC0-1.0",                        // required: SPDX identifier or custom string
  "description": "Retro 8-bit sounds.",        // optional
  "preview": "sounds/preview.mp3",             // optional, used in Settings UI preview
  "defaults": {                                // optional
    "volume": 0.7,                             // default master volume for this pack, 0.0-1.0
    "randomizeVariants": true                  // if false, always plays first file in array
  },
  "sounds": {                                  // required: at least one category
    "<categoryId>": [                          // array of entries; engine picks by weight
      {
        "file": "sounds/path.wav",             // required: relative path from pack root
        "weight": 1.0,                         // optional, default 1.0; higher = more likely
        "volume": 1.0                          // optional, per-file volume multiplier
      }
    ]
  }
}
```

## Supported category IDs (v1)

Packs do NOT need to define all categories. If a category is missing, playback falls back to:
1. User's per-category override (if any)
2. Silence (v1) — future: fall back to built-in default pack

| Section | Category ID | Fires when |
|---|---|---|
| session | `sessionStart` | New AI session begins (reserved in v1 — not auto-triggered) |
| session | `taskComplete` | AI finishes a turn (Claude `Stop` hook) |
| session | `taskError` | Tool call or API error (reserved in v1) |
| interactions | `inputRequired` | Permission approval pending |
| interactions | `inputQuestion` | AskUserQuestion pending |
| interactions | `taskAcknowledge` | User submits a prompt (reserved in v1) |
| filters | `userSpam` | Rapid prompt submissions (reserved in v1) |
| filters | `resourceLimit` | Context window compacting (reserved in v1) |
| system | `appStarted` | Coder Island launches |
| system | `remoteConnected` | SSH Remote tunnel established (reserved, awaiting SSH Remote feature) |

## File formats

- Accepted: `.wav`, `.mp3`, `.aiff`, `.m4a`, `.caf`
- Recommended: 16-bit / 44.1kHz WAV for best predictability
- Max single file size: 5 MB (enforced at load)

## Validation rules (enforced by `SoundPackManifest` Codable init)

1. `schemaVersion` must equal `1`
2. `id` must match `^[a-z0-9]+(\.[a-z0-9-]+)+$`
3. `version` must be valid semver
4. All `file` paths must resolve within the pack directory (no `..`)
5. At least one category must have at least one entry
6. License field is required but NOT validated against SPDX — free-form string accepted

## License notes

- Built-in packs shipped with Coder Island must use OSI-approved or CC0 license
- User-imported packs can use any license (at user's own risk)
- Coder Island displays the license field prominently in Settings

## Future (v2+)

- `.zip` packing/unpacking
- Per-category `visuals/` subdir for notch animations
- `requires` field for Coder Island minimum version
- Signature verification for curated marketplace
