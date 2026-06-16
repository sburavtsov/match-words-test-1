# Project Context — Match Words MW1 (match-words-test-1)

## Overview
Defold game project (version 1.12.4). A 7x7 letter-matching grid where players drag-to-connect adjacent chips with matching letters. Chip types: Plain (A-Z). Special types (striped, wrapped, bomb) exist as constants but are not yet implemented.

**Title/Version**: MW1 0.0.1
**Root**: `/Volumes/work/AprilGames/matchwords/match-words-test-1/game.project`
**Bootstrap**: `/main/main.collection`
**Display**: 1024x1024, high DPI enabled

## Key files

| File | Purpose |
|------|---------|
| `main/board.script` | 7x7 board controller: build, collapse, link, fill |
| `main/chip.script` | Chip behavior: sway, zoom, wobble, respawn, remove |
| `main/chip.go` | Chip game object prototype (label + sprite) |
| `main/main.collection` | Bootstrap: board GO + camera GO |
| `input/game.input_binding` | MOUSE_BUTTON_1 → "touch" |
| `shaders/color_sprite/recolor.material` | Custom recolor material |
| `shaders/color_sprite/recolor.vp` | Vertex shader (newcolor, outline attributes) |
| `shaders/color_sprite/recolor.fp` | Fragment shader (grayscale→tint, outline) |
| `assets/game.atlas` | Texture atlas (chip_back animation) |
| `AGENTS.md` | Agent instructions (maintained here) |

## board.script details

### Constants (UPPER_CASE)
```lua
local BLOCKSIZE = 96      -- Distance between block centers
local EDGE = 80            -- Left/right edge
local BOTTOM_EDGE = 80     -- Bottom edge
local BOARDWIDTH = 7       -- Columns
local BOARDHEIGHT = 7      -- Rows
local TYPE_PLAIN = hash("plain")
local TYPE_STRIPED_H = hash("striped-h")
local TYPE_STRIPED_V = hash("striped-v")
```

### Functions
- **`build_board()`** — Creates 7x7 random board with factory-created chips, uses math.random(65, 90) for A-Z
- **`collapse_board(board, callback)`** — Gravity slide (y-axis, OUTBOUNCE animation, 0.3s)
- **`iterate_chips(board)`** — Iterator for non-empty slots (column-major)
- **`remove_chip(board, chip)`** — Delete single chip, nil the slot
- **`remove_chips(board, chips)`** — Bulk remove via iterating list
- **`remove_link(board, link, callback)`** — Ignores <3 length links, removes chips, 0.3s delay
- **`add_to_link(self, x, y)`** — Adjacency check (±1), color match via `symb`, backtracking support
- **`empty_slots(board)`** — Collect nil slots as {x, y} tables
- **`fill_slots(board, empty_slots, callback)`** — Drop new chips from y=1000 into empty slots, OUTBOUNCE 0.3s, timer 1s

### Message handlers
- `start_level` → `build_board()`
- `post-reaction` → `collapse_board()` → `empty_slots()` → `fill_slots()`

### Input handling
- `on_input`: "touch" action, `pressed` starts linking, `released` removes link and posts `post-reaction`
- Camera projection: `camera.screen_xy_to_world(action.screen_x, action.screen_y, "camera#camera")`

## chip.script details

### Properties
- `symb` (default 65 = 'A')
- `blink` (default 0)

### Constants
```lua
local NORMAL_SCALE = 0.45
local ZOOMED_SCALE = 0.6
local TYPE_PLAIN = hash("plain")
local TYPE_STRIPED_H = hash("striped-h")
local TYPE_STRIPED_V = hash("striped-v")
local TYPE_WRAPPED = hash("wrapped")
local TYPE_BOMB = hash("bomb")
```

### Message handlers
- `respawn` — set position, enable sprite
- `sway` — gentle Z-rotation ping-pong (random interval 2-4s)
- `zoom_and_wobble` — scale to 0.6 + Z wobble (-4 degrees)
- `reset` — restore normal scale + rotation, restart sway
- `remove` — `go.delete()`

## chip.go structure
- **Script**: `/main/chip.script`
- **Label "character"**: 128x128, text "A", default.font, label-df material, z=0.1, scale 8x
- **Sprite "back"**: chip_back animation, recolor.material, game.atlas

## Camera
Orthographic, position (512, 512), aspect_ratio=1.0, fov=0.7854, near_z=-1, far_z=1

## Custom recolor shader
- **Vertex attribute `newcolor`**: RGBA 0.3882, 0.6078, 1.0, 1.0 (blue)
- **Vertex attribute `outline`**: gray 0.5, 0.5, 0.5, alpha 0 (disabled)
- **Fragment uniform `tint`**: white default
- **Logic**: Grayscale pixels replaced with `new_color.rgb`, green-channel mask for outlines
- **Render tag**: "tile"

## External dependencies (read-only, .deps/)
1. **monarch** 6.0.1 — screen/popup navigation
2. **defold-object-interpolation** 1.3.1 — smooth transform interpolation
3. **defold-sharp-sprite** 1.0.0 — RGSS/mipmap texture filtering
4. **defold-xmath** (main) — zero-allocation math native extension

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

## Recent fixes applied
1. `board.script` line 60: `type = type` → `type = TYPE_PLAIN` (was referencing global `type()`)
2. `board.script` line 255: `last.color` → `last.symb` (non-existent field, broke color matching)
3. `board.script` line 319: `math.random(65, 91)` → `math.random(65, 90)` (was generating `[`)
4. All constants renamed to UPPER_CASE in both files
5. Trailing whitespace removed from both files
6. Various spacing fixes (commas, operators)

## Git status
- Active branch (not main)
- Multiple changes staged/committed to AGENTS.md and Lua scripts
- Working directory: clean after fixes

## LSP notes
- `.deps/xmath/src/xMath.cpp` errors are false positives (native ext needs Defold SDK)
- `main/chip.go` protobuf error is false positive (LSP misidentifies components field)