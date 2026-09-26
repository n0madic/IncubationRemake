# Incubation — reverse engineering and a Godot remake

An open reconstruction of **Incubation: Time Is Running Out** (Blue Byte, 1997)
and its *Wilderness Missions* add-on:

- **`docs/`** — specifications of the game's file formats and of its behaviour
  (turns, combat, AI, scripts, campaign, effects, cutscenes), each claim backed
  by a check over the whole shipped corpus or by the decompiled executable;
- **`tools/`** — dependency-free Python 3 parsers, extractors and checkers that
  prove those specifications, plus a converter that turns an installation into
  data the remake can load;
- **`godot/`** — a remake in Godot 4.7 that plays the missions and the campaign,
  with the original's rules, units, models, animations, sound, briefings and
  real-time cutscenes.

This is a work in progress. [`docs/00-overview.md`](docs/00-overview.md) lists
every format with its status and coverage.

> **No game data is included.** This repository contains only original code and
> documentation. To use it you need your own copy of the game — the GOG release
> is the one everything here is tested against. Extracted assets, converted
> caches and test fixtures are generated locally and are never committed.
>
> Not affiliated with or endorsed by Blue Byte or Ubisoft. *Incubation* and
> *Battle Isle* are trademarks of their respective owners.

## Requirements

- A legally owned installation of *Incubation* (GOG).
- Python 3.10 or newer. No third-party packages.
- [Godot 4.7](https://godotengine.org/) for the remake (the `godot` binary on
  `PATH`, or pass `GODOT=/path/to/Godot`).
- GNU Make.

## Getting started

Put the game installation (or a symlink to it) at `gog_incubation/` in the
repository root, or pass `GAME_ROOT=/path/to/install` to `make`. The tools only
**read** that directory; treat it as read-only.

### Check the formats

```bash
make check-formats
```

Runs every parser over 100 % of its format's files. Every check fails on an
empty corpus, so a wrong path cannot pass.

### Play the remake

1. Convert the installation into the remake's cache, written to Godot's user
   directory for this project:

   ```bash
   python3 tools/remake_convert.py gog_incubation --campaign-maps \
       --instant-action-maps -o "<user dir>/caches"
   ```

   where `<user dir>` is

   | OS | Path |
   |---|---|
   | macOS | `~/Library/Application Support/Godot/app_userdata/Incubation - Remake` |
   | Linux | `~/.local/share/godot/app_userdata/Incubation - Remake` |
   | Windows | `%APPDATA%\Godot\app_userdata\Incubation - Remake` |

   Started without a cache, the game says what to run instead of failing
   silently.

2. Launch it:

   ```bash
   godot --path godot                          # the title screen
   godot --path godot -- --mission=_C_141      # straight into one mission
   godot --path godot -- --campaign=1          # a new campaign
   ```

   Cheats are available on the backquote (`` ` ``) line in game, or as
   `--cheats=god,ammo,kill,moves`.

A Russian installation can be layered over the cache with
`--language-pack Russian=<root>`; see
[`docs/92` §7.6](docs/92-remake-architecture.md).

## Building

```bash
make build            # the host platform
make build-macos      # also: build-windows, build-linux, build-android, build-ios
```

Exports are debug builds by default (`EXPORT_MODE=release` for release). Android
packages carry a converted payload (`make android-cache`); iOS needs an Apple
Team ID in `godot/export_presets.cfg` and Xcode. `make help` lists every target.

## Tests

```bash
make test             # format checks, cache check, Godot suites
make fixtures         # rebuild the Godot test fixtures from your installation first
```

The Godot suites compare the GDScript implementation against executable Python
models of the specifications. Further harnesses that run the original
executable under Wine to capture reference behaviour are described in
[`tools/dbgcall/README.md`](tools/dbgcall/README.md).

## Documentation

Start with [`docs/00-overview.md`](docs/00-overview.md). The documents are
numbered by family: `10`–`11` maps and saves, `20`–`29` scripts and game
behaviour, `30`–`31` Eng3d geometry, `40`–`43` models, animation, cutscenes
and presentation, `50`–`70` textures, sprites and tables, `90`–`91` research
method, `92` the remake's architecture and `93`–`101` the development reports.
Unknowns are marked **UNVERIFIED** and every document ends with its open
questions.

## License

The code and documentation in this repository are released under the
[MIT License](LICENSE). The license does not cover the original game, its data
or its trademarks.
