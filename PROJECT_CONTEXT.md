# Project Context — Match Words MW1 (match-words-test-1)

## Overview
Defold game project (version 1.12.4). A word-finding game on a pseudo-hexagonal grid (7 columns, pattern `{7,6,7,6,7,6,7}`). Players select adjacent tiles to form valid words loaded from a 64K+ English dictionary. Target letters must be collected to win. Jokers (random + pity) add strategic depth. Paths of length 5+ create boosters.

**Title/Version**: MW1 0.0.1
**Root**: `/Volumes/work/AprilGames/matchwords/match-words-test-1/game.project`
**Bootstrap**: `/main/main.collection`
**Display**: 640x1136 (iPhone portrait), high DPI enabled

## Architecture — Service-based (refactored)

The old monolithic design (`board.script` + `chip.script`) was replaced with a modular service architecture:

| Layer | File | Purpose |
|-------|------|---------|
| **Controller** | `main/main.script` | Thin game controller: input handling, visual tile spawning, animation orchestration |
| **Tile behavior** | `main/factories/tile.script` | Individual tile behavior (sway, zoom, wobble, respawn, remove) |
| **Tile prototype** | `main/factories/tile_factory.go` | Tile GO prototype (label + sprite using recolor shader, grind.atlas) |
| **Board state** | `services/board_service.lua` | Central state keeper: board init, gravity/refill, joker management, target spawning, booster creation, win condition |
| **Board geometry** | `services/board_geometry.lua` | Pure topology math: pseudo-hex neighbors, coordinate bounds, Chebyshev distance |
| **Cell factory** | `services/cell_factory.lua` | Cell/character generation: weighted random chars, jokers (`⭐`), boosters (`💣`/`⚡`/`🌀`) |
| **Dictionary** | `services/dictionary_service.lua` | Dictionary loading & prefix building: parses `WordList_EN.csv`, builds prefix sets for DFS pruning |
| **Move resolver** | `services/move_resolver.lua` | Move validation & resolution: path validation, word enumeration via DFS (joker wildcards), delegate mutations to board_service |
| **Utilities** | `shared/utils.lua` | Pure helper functions: UTF-8, coordinate keys, weighted random, array/set operations |
| **CSV loader** | `utils/csvloader.lua` | (Legacy, not used by dictionary_service) |

## Key files

| File | Purpose |
|------|---------|
| `main/main.script` | Game controller: init, input, spawn, animations, UI updates |
| `main/main.collection` | Bootstrap: main GO (script + tile_factory) + orthographic camera |
| `main/factories/tile.script` | Tile behavior: sway, zoom, wobble, respawn, remove |
| `main/factories/tile_factory.go` | Tile GO prototype (label + sprite with recolor material) |
| `services/board_service.lua` | Central board state keeper |
| `services/board_geometry.lua` | Pseudo-hex grid topology |
| `services/cell_factory.lua` | Cell and character generation |
| `services/dictionary_service.lua` | Word list loading and prefix building |
| `services/move_resolver.lua` | Move validation and resolution pipeline |
| `shared/utils.lua` | Pure utility functions |
| `input/game.input_binding` | MOUSE_BUTTON_1 → "touch" |
| `shaders/color_sprite/recolor.material` | Custom recolor material |
| `shaders/color_sprite/recolor.vp` | Vertex shader (newcolor, outline attributes) |
| `shaders/color_sprite/recolor.fp` | Fragment shader (grayscale→tint, outline) |
| `assets/grind.atlas` | Texture atlas (chip-back animation, grind/chip-back.png) |
| `custom_resources/words/WordList_EN.csv` | English word list (64,596 words with frequency) |
| `custom_resources/words/WordList_RU.csv` | Russian word list (57,684 words, not yet used) |
| `AGENTS.md` | Agent instructions (maintained separately) |

## Game flow

1. **init()**: Load dictionary from CSV → create board state (board_service.init) → acquire input focus → spawn visual tiles
2. **on_input**: Touch `pressed` → AABB pick_tile → try_select_tile (adjacency check, backtracking support, no boosters in path). Touch `released` → confirm_move (if ≥2 tiles selected) or clear_selection
3. **confirm_move**: Calls move_resolver.resolve() → validates path shape → enumerates valid words via DFS → picks first valid word → destroys path → applies gravity → spawns new targets → normalizes jokers → checks win condition
4. **Animations**: Destruction (scale→0.1 OUTBACK), rejection (red flash pingpong), refresh (scale→1 OUTBACK)

## Board geometry details

- **Pattern**: `{7, 6, 7, 6, 7, 6, 7}` (7 columns, alternating heights)
- **Cell size**: 90x120
- **Grid offset**: (-256, 256) — shifted left and up in world space
- **Hex shift**: Even columns shifted down by half cell height (`CELL_HEIGHT * 0.5`)
- **Neighbors**: 6 pseudo-hex neighbors (vertical + diagonal based on column parity), filtered by field bounds

## Tile visual states (via recolor shader tint)

| State | Sprite tint | Label color | Text |
|-------|------------|-------------|------|
| Normal | white (1,1,1,1) | white (1,1,1,1) | cell.char |
| Target | red (1,0,0,1) | red (1,0,0,1) | cell.char + `*` |
| Joker | yellow (1,0.8,0,1) | yellow (1,0.8,0,1) | `⭐R` or `⭐P` |
| Booster | white (1,1,1,1) | white (1,1,1,1) | booster symbol |
| Selected | green (0,1,0,1) | (unchanged) | (unchanged) |

## Joker system

- **Random joker** (`⭐R`): Spawns randomly during cell generation. Acts as wildcard — can represent any alphabet letter.
- **Pity joker** (`⭐P`): Injected by board_service after `idle_moves` threshold. Uses DFS algorithm to find optimal placement (neighbor to target cells, evaluates all possible words through the joker for each letter, picks best scoring position).
- **Limit**: Max 2 jokers total on board at any time (1 random + 1 pity).

## Booster system (path length rewards)

| Path length | Booster | Symbol |
|-------------|---------|--------|
| 5 | Line clear | `⚡` |
| 6 | Bomb | `💣` |
| 7+ | Color bomb | `🌀` |

## External dependencies (read-only, .deps/)

1. **monarch** 6.0.1 — screen/popup navigation
2. **defold-object-interpolation** 1.3.1 — smooth transform interpolation
3. **defold-sharp-sprite** 1.0.0 — RGSS/mipmap texture filtering
4. **defold-xmath** (main) — zero-allocation math native extension
5. **defold-richtext** 5.22.1 — rich text rendering

## Camera

Orthographic, aspect_ratio=1.0, fov=0.7854, near_z=-1, far_z=1. Position defaults to (0,0,0).

## Custom recolor shader

- **Vertex attribute `newcolor`**: RGBA 0.3882, 0.6078, 1.0, 1.0 (blue)
- **Vertex attribute `outline`**: gray 0.5, 0.5, 0.5, alpha 0 (disabled)
- **Fragment uniform `tint`**: white default
- **Logic**: Grayscale pixels replaced with `new_color.rgb`, green-channel mask for outlines
- **Render tag**: "tile"

## Code style conventions

- Indentation: 1 tab (4 spaces)
- Naming: `snake_case` for variables/functions, UPPER_CASE for module-level constants
- Comments: `---@` LuaCATS for type/module/public API docs, `--` for internal
- Requires: `require("module.name")` with parens, dot notation, no leading slash
- State: store instance state in `self`, not local module variables
- No metatables/classes, functional style only
- GUI ↔ game communication via `msg.post()`, not direct module access
- Hash values: can use `hash("...")` inline, or `local HASH_NAME = hash("...")` at module level
- All commands from project root

## Refactoring history

- Old `main/board.script` (monolithic, 482 lines) → split into `services/` modules
- Old `main/chip.script` / `main/chip.go` → renamed to `main/factories/tile.script` / `main/factories/tile_factory.go`
- Game type changed from match-3 (drag-to-connect same-letter) to word-finding (select adjacent tiles to form dictionary-valid words)
- Texture atlas switched from `game.atlas` → `grind.atlas`

## LSP notes

- `.deps/xmath/src/xMath.cpp` errors are false positives (native ext needs Defold SDK)