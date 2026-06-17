# Agent Instructions

This repository is a **Defold** game project. The project root is the folder containing `game.project`.

## Project map

- **Root config**: `game.project`
- **Main game content**: `main/` (main.script, tile factory, HUD)
- **Services**: `services/` (board, move resolution, dictionary, geometry, cell factory, config, field init, joker, letter bag, spawn, target, delta repair, event logging)
- **Shared utilities**: `shared/utils.lua`
- **CSV loader**: `utils/csvloader.lua`
- **Assets**: `assets/` (chip_back.png, bg.jpg, game.atlas, fonts/)
- **Input bindings**: `input/game.input_binding`
- **Custom shaders**: `shaders/color_sprite/` (recolor vertex/fragment shaders and material)
- **Debugger**: `debugger/` (VSCode Lua debugger integration)
- **Dependencies (read-only context)**: `.deps/` — 5 external libraries + Defold engine builtins
  - `monarch/` — screen/popup navigation manager (6.0.1)
  - `object_interpolation/` — transform interpolation native extension (1.3.1)
  - `sharp_sprite/` — RGSS/mipmap shader-based texture filtering (1.0.0)
  - `xmath/` — zero-allocation vector/quaternion/matrix math native extension (main branch)
  - `richtext/` — rich text rendering extension (5.22.1)
  - `builtins/` — Defold engine builtins
- **Build output**: `build/` (compiled `.luac`, `.collectionc`, `.goc`, etc.)
- **Agent skills**: `.agents/skills/` (project-specific instructions and automation scripts)
- **Popups**: `popups/<popup_name>/` (Monarch-registered popup overlays)

Key Defold settings from `game.project`:

- **Title/Version**: MW1 0.0.1
- **Bootstrap collection**: `/main/main.collection`
- **Input binding**: `/input/game.input_bindingc`
- **Display**: 640x1136, high DPI enabled
- **Physics scale**: 0.02
- **Script shared_state**: 1 (enabled)
- **Max counts** (increased from defaults): sprite=256, label=256, particle_fx=256, particle_count=4096
- **Dependencies**: monarch 6.0.1, object_interpolation 1.3.1, sharp_sprite 1.0.0, xmath (main), richtext 5.22.1

**Resource paths in `game.project`**: Values like `main_collection`, `game_binding`, `app_icon` use Defold resource identifiers. A trailing `c` suffix denotes compiled resources and is expected — do not treat it as a typo.

**Board pattern varies by level** (7 cols in main.script, 9 in config default). The grid is not square — each column has its own height.

## Main game structure

### Main collection (`main/main.collection`)

Three game objects:
- **`main`** (position 0,0): script component (`/main/main.script`) + embedded factory (`tile_factory`, prototype `/main/factories/tile_factory.go`). Main game controller — owns all game state.
- **`camera`** (position 0,-50): embedded camera component (aspect_ratio=1.0, orthographic)
- **`hud`**: referenced GUI component (`/main/hud.gui`) for HUD text display
- **`win_popup`** (Monarch): screen_factory script + collectionfactory for win overlay popup

### Main controller (`main/main.script`)

Main game controller script:
- **init**: seeds RNG, loads dictionary (RU, 57684 entries), inits board (7x6x7x6x7x6x7 pattern, 5 target letters БДКУЗ, random+mercy jokers), spawns tile grid from factory
- **spawn_grid**: clears old tiles, creates new ones from board state via factory
- **update_tile_visual**: per-cell visual update — targets (red+*), boosters (white), jokers (gold+⭐R/⭐P), normal letters (white)
- **update_ui**: sends HUD update message to hud#gui
- **on_input**: touch-based path selection (drag to select, release to confirm), cancel on right-click
- **pick_tile**: screen-to-world coordinate lookup with AABB hit testing
- **confirm_move**: calls move_resolver.resolve(), on success animates destruction → gravity/refill, on win triggers Monarch popup
- **animate_destruction**: scale-down + delete with callback chain
- **animate_reject**: red flash ping-pong for invalid moves
- **animate_gravity_refill**: survivors slide down, new tiles drop from above with easing
- **on_message**: handles `restart` from win_popup — full reinit

### Tile behavior (`main/factories/tile.script`)

Tile game object script (prototype):
- Properties: `symb` (default 65), `blink` (default 0)
- Constants: `NORMAL_SCALE=0.45`, `ZOOMED_SCALE=0.6`
- Message handlers: `respawn` (reposition + enable), `sway` (Z-rotation ping-pong), `zoom_and_wobble` (scale+rotate), `reset`, `remove`

### HUD GUI (`main/hud.gui` + `main/hud.gui_script`)

Four text nodes at bottom-left and bottom-center: targets, moves, pending, current word.
Handles `update_hud` messages with display data.

### Tile game object (`main/factories/tile_factory.go`)

- Script component: `/main/factories/tile.script`
- Label `"character"`: 128x128, text "A", `/builtins/fonts/default.font`, label-df material, z=0.1, scale 8x
- Sprite `"back"`: animation `chip_back`, `/shaders/color_sprite/recolor.material`, texture `/assets/game.atlas`

## Services

### Board service (`services/board_service.lua`)
Central state-keeper. Full lifecycle: init → field generation → move resolution → gravity → fill → repair → normalize.
- `init(options)` — creates board state, inits letter bag, runs field_initializer.build()
- `apply_gravity(state)` — column-by-column gravity collapse
- `fill_after_gravity(state)` — delegates to spawn_service
- `resolve_word_path(state, coords, tile_len)` — destroys path cells, optionally creates booster (if `enable_boosters` in config)
- `normalize_jokers(state)` — delegates to joker_service
- `maybe_analyze_random_joker(state)` — periodic random joker placement
- `spawn_target(state)` / `count_targets_in_path(state, coords)` — target management
- `debug_dump(state)` — ASCII grid dump with markers
- `collect_deltas(state)` — init empty delta record

### Move resolver (`services/move_resolver.lua`)
Validates and resolves player moves:
- `validate_path_shape(state, coords)` — boundary, adjacency, booster check
- `enumerate_words(state, dictionary, coords)` — DFS with joker substitution
- `pick_best_word(dictionary, words)` — Pool A > B > C, then length, then freq
- **`resolve(state, coords, dictionary)`** — full pipeline: validate → enumerate → pick → remove path/boosters → collect targets → mercy joker → gravity → fill → delta zone → normalize → spawn target → delta repair → random joker → re-normalize → win check → return result with `is_win`

### Dictionary service (`services/dictionary_service.lua`)
Loads and indexes word lists:
- `init(options)` — loads CSV, deduplicates, sorts by freq, splits into pools A (3000)/B (8000)/C (rest), builds prefix set for DFS pruning, computes letter frequencies and spawn weights (BR-V02)
- Filter: only `flag=0` and `flag=1` words accepted (both loaded)
- `allowed_letters(dictionary, difficulty, cfg, targets)` — rare letter filtering
- Exports `RU_ALPHABET`, `RU_VOWELS`, `DEFAULT_ALPHABET`

### Board geometry (`services/board_geometry.lua`)
Pure coordinate math:
- Hex neighbor generation (odd/even column offset rules), adjacency checks
- BFS radius, delta zone (union of radius neighborhoods)
- Column weighting for target placement (center vs edge)
- `foreach_cell(state, fn)` iterator

### Cell factory (`services/cell_factory.lua`)
Cell object creation:
- Constants: `CHAR_JOKER="@"`, types: random/mercy, boosters: § ± #
- `create_letter_cell`, `create_target_cell`, `create_joker_cell`, `create_booster_cell`
- `is_joker(cell)`, `joker_type(cell)`, `is_ordinary(cell)`
- Exports `get_constants()` for CHAR_JOKER and other constants

### Config (`services/config.lua`)
Single source of balance parameters — all BR-referenced fields:
- Difficulty, pool limits, repair params, target limits, joker limits, FTUE, vowel control, letter frequency weights, boosters disabled by default
- `config.get()`, `config.apply(overrides)`, `config.reset()`

### Field initializer (`services/field_initializer.lua`)
Anchor-first field generation (BR-F01/F02/F03):
- Place target-anchor word → place non-intersecting entry words → fill from letter bag
- Direction preferences: 65% vertical, 25% horizontal, 10% diagonal
- Target placement weighted by difficulty (center for low, edge for high)

### Joker service (`services/joker_service.lua`)
- `stats(state)` — count jokers by type
- `normalize(state)` — enforce limits (max_total=2, max_random=1, max_mercy=1)
- `analyze_random_joker(state, dictionary)` — every N moves, score windows, place if freq below threshold
- `try_mercy_joker(state, dictionary)` — on idle moves threshold, find Pool A/B word through target via joker

### Letter bag (`services/letter_bag.lua`)
Frequency-weighted letter pool (BR-F04):
- `create(dictionary, cell_count, difficulty, cfg, targets)` — build weighted pool
- `draw(bag, restrict_set?)` — random draw with vowel/consonant restriction
- Auto-refill at 10% remaining

### Spawn service (`services/spawn_service.lua`)
Letter spawning with vowel control (BR-G01/G02):
- Local vowel ratio per 3-column window, adjusts draw category
- `fill_empty_cells(state)` — fills all nil cells

### Target service (`services/target_service.lua`)
- `count_active(state)`, `count_in_path(state, coords)`
- `try_spawn(state)` — weighted column selection, upper half placement
- `collect_in_path(state, coords)` — collect targets, manage idle_moves

### Delta repair (`services/delta_repair.lua`)
Always-on delta-zone repair (BR-D01/D02/D03):
- `collect_delta_zone(state, deltas)` — union radius of changed cells
- `run(state, dictionary, deltas)` — find Pool A words (len 3-4) in zone, minimum replacements, Pool-C-only protection

### Event logger (`services/event_logger.lua`)
Flat structured logging with circular buffer:
- `log(event_type, payload)`, `drain()`, `peek()`, `reset()`
- Canonical event types: session_start, level_start/end, move, repair, joker events, target, deadlock

## Input bindings (`input/game.input_binding`)

Single mouse trigger: `MOUSE_BUTTON_1` → action `"touch"`.

## Custom recolor shader

Located in `shaders/color_sprite/`. Used by tile sprites (`"tile"` render tag) to enable per-vertex color tinting:

- **Material constants**: `tint` (vec4 fragment uniform, default white), `newcolor` (vertex attribute RGBA 0.3882, 0.6078, 1.0, 1.0 = blue), `outline` (gray 0.5, 0.5, 0.5, alpha 0 = disabled).
- **Vertex shader** (`recolor.vp`): passes `view_proj`, `position`, `texcoord0`, `newcolor`, `outline` to fragment.
- **Fragment shader** (`recolor.fp`): recolorizes grayscale pixels via green-channel detection, optionally renders outlines, applies tint uniform.

## External libraries

### Monarch screen manager

Screen/popup navigation library (`require("monarch.monarch")`). Provides stack-based navigation with animated GUI transitions. Popups are registered in `main.collection` via `screen_factory` script + `collectionfactory`.

Key API:
- `monarch.show("popup_name")` — open popup
- `monarch.back()` — close topmost popup
- `monarch.screen_exists("name")`, `monarch.is_busy()`, `monarch.top()`

See `monarch-screen-setup` skill for popup creation workflow.

### Object Interpolation

Native extension for smooth transform interpolation. Add `object_interpolation` component to a game object.

### Sharp Sprite

Shader-based texture filtering (RGSS). Provides drop-in replacement materials for sprite/GUI/particlefx/spine/tilemap components.

### xmath

Zero-allocation vector/quaternion/matrix math (`require("xmath")` not needed — global). All operations use pre-allocated first argument.

### Rich Text (`richtext`)

Rich text rendering extension for styled text in GUI.

## Win condition and popup

When `move_resolver.resolve()` returns `is_win=true`, `main/main.script` shows the Monarch popup `win_popup` after all game animations complete. The popup displays "Победа!" and a "Restart" button. On button click, it sends `restart` message to `main:/main#script`, which:
1. Deletes all tile game objects
2. Reinitializes board via `board_service.init()`
3. Respawns grid
4. Closes the popup via `monarch.back()`

## Include directories

- Use `.deps/` as an include directory for resolving module references and understanding dependency APIs.
- **NEVER modify any files inside `.deps/`** — these are downloaded dependencies provided strictly as read-only context.

## Defold file formats

- **Lua scripts**: `.lua`, `.script`, `.gui_script`, `.render_script`, `.editor_script`.
- **Metadata assets** (Protocol Buffer Text Format): `.collection`, `.go`, `.sprite`, `.tilemap`, `.tilesource`, `.atlas`, `.font`, `.particlefx`, `.sound`, `.label`, `.gui`, `.model`, `.mesh`, `.material`, `.collisionobject`, `.texture_profiles`, `.display_profiles`.
- **Manifests** (YAML): `.appmanifest`, `.manifest` - platform-specific libraries and build flags.
- **Buffers** (JSON): `.buffer` - streams of data (positions, colors, etc.) used as input for Mesh components.
- **Shaders** (GLSL): `.vp`, `.fp`, `.glsl`.
- **Project config** (INI): `game.project`.
- **Properties** (INI): `game.properties`, `ext.properties` - parameters available in `game.project`.
- **2D assets**: `.png`, `.jpg`.
- **3D assets** (GTLF): `.gltf`, `.glb`.
- **Sound assets**: `.ogg`, `.wav`, `.opus` (OPUS requires modification of the appmanifest).

## Editing Defold assets

When creating or editing Defold asset files, use the corresponding `defold-*-editing` skill to get the correct file format and structure. Always load the skill **before** writing or modifying the file.

When creating new screens, popups, or setting up navigation between them, load the `monarch-screen-setup` skill first.

When writing performance-critical math code or optimizing vector/quaternion/matrix operations, load the `xmath-usage` skill first.

## Code style guidelines

### Lua scripts (.lua, .script, .gui_script, .render_script, .editor_script)

- **Indentation**: 1 tab (4 spaces).
- **Naming**: `snake_case` for variables, functions, files, and folders. Keep resource paths absolute (`/assets/...`) where Defold expects them.
- **Comments**:
  - Use **LuaCATS** (`---@...`) annotations for types, module/public API docs.
- **Whitespace**:
  - Empty lines must be truly empty (no spaces/tabs).
  - Avoid trailing whitespace.
- **Defold API**: strictly follow the Defold API - always verify against the official documentation using the `defold-api-fetch` skill. There are no hidden or undocumented APIs - only use functions, messages, and properties that are explicitly described in the docs. For conceptual guidance on how Defold features work (components, physics, rendering, input, etc.), use the `defold-docs-fetch` skill. For practical implementation patterns and sample code, use the `defold-examples-fetch` skill.
- **Defensive checks**: Do NOT assume data is missing or constantly re-check field existence in tables. If YOU set a field, it EXISTS. Similarly, do NOT check for standard Lua API availability (e.g., `io` and `io.open` always exist in standard Lua). Avoid unnecessary defensive programming.
- **Paradigm**: do not use metatables or imitate classes. Use functional, data-based structures only.
- **Logging**: use `print()` to look at the game state. Add logs for transactions, initializations, important events.
- **GUI and game state separation**: GUI scripts (`.gui_script`) should NOT directly access game logic modules. All communication between game logic and UI must be message-based (`msg.post()`) to maintain clear separation of concerns. GUI should be purely data-driven, receiving all necessary data through messages and updating its display accordingly. This ensures UI remains decoupled from game implementation details.
- **Script instance state**: In `.script`, `.gui_script`, `.render_script` files, store instance-specific state in the `self` table, NOT in local module variables. Local variables at the module level are shared across ALL instances of the script, which causes bugs when multiple instances exist. Use `self.my_variable` instead of `local my_variable`. Not applicable for local functions - keep them local. If you need to call local function that it's defined below, to use forward declarations or reorganize the functions.
- **Local functions**: NEVER create local functions inside other functions. Local functions are only allowed at module scope. Anonymous lambda functions (inline callbacks) are acceptable.
- **require**: 
  - Always call `require` with parentheses: `require("module")`, NOT `require "module"`.
  - Use dot notation for module paths: `require("screens.flappy_bird.gameplay")`, NOT `require("/screens/flappy_bird/gameplay")`.
  - Module paths are relative to the project root and use dots (`.`) instead of slashes (`/`) as separators.
  - Do NOT use leading slashes in require paths.
  - Examples: `require("monarch.monarch")`, `require("screens.flappy_bird.gameplay")`, `require("main.utils")`.
- **Hash values**: `hash("...")` can be left inline without premature optimization. It's acceptable to use `message_id == hash("trigger_response")` directly. If you need to reuse a hash value multiple times, you can declare it as a module-level constant in `UPPER_CASE` format: `local TRIGGER_RESPONSE = hash("trigger_response")`.
- **Constants**: Module-level constants can be declared as local variables in `UPPER_CASE` format: `local TRIGGER_RESPONSE = hash("trigger_response")`, `local MAX_HEALTH = 100`.
- **msg.url format**: Always remember the format `[socket:][path][#fragment]`:
  - `socket` - collection name (world)
  - `path` - game object instance id (can be relative or global)
  - `fragment` - component id
  - Shorthands: `"."` for current game object, `"#"` for current component
  - Examples: `msg.url("#my_component")`, `msg.url("collection:/path/to/go#component")`, `msg.url(socket, path, fragment)`, `msg.url(nil, hash("id"), hash("script"))`, `msg.url(nil, go.get_id("physics"), "collisionobject")`

### Python

- Write for Python 3.11. Do NOT write code to support earlier versions of Python. Always use modern Python practices appropriate for Python 3.11. Always use full type annotations, generics, and other modern practices.

## Shell

- **Windows**: use PowerShell.
- **Linux**: use bash.
- **macOS**: use zsh.

## Commands

All commands run from the project root (the folder with `game.project`).

- **Build & Run via editor** - use the `defold-project-build` skill. Requires the Defold editor to be running with the project open. Builds the project, returns compilation errors, and launches the game if the build succeeds.
- **Fetch dependencies** - `python3 .agents/skills/defold-project-setup/scripts/fetch_deps.py` (re-run after editing `game.project` dependency URLs)

## Validation checklist

- Build via the running editor succeeds (`defold-project-build` skill).
- `.deps/` is up to date with `game.project` dependencies (run fetch_deps.py after dependency changes).

## Session memory — last changes

### Task: Difficulty slider + Restart button on HUD

Moved difficulty slider and restart button from `win_popup` to `main/hud.gui` so they're always visible.

**Files changed:**
- `main/hud.gui` — added 5 nodes: `difficulty_label`, `slider_track`, `slider_thumb`, `restart_btn`, `restart_text`
- `main/hud.gui_script` — full slider logic: `on_input` drag with `drag_offset_x`, sends `set_difficulty` messages on drag, sends `restart` message with `{ difficulty = self.slider_value_num }` on button click
- `main/main.script` — `on_input` returns `false` (not `true`) so HUD also receives touch; added `set_difficulty` message handler that updates `game_state.difficulty`; `restart` message now forwards difficulty param
- `popups/win_popup/win_popup.gui` — removed slider nodes
- `popups/win_popup/win_popup.gui_script` — simplified (no slider, restart via monarch message with no params)

**Key fixes:**
1. `main.script.on_input` must return `false` — returning `true` consumes the input in Defold, preventing HUD from receiving touch events
2. Slider drag needs `drag_offset_x` (cursor offset from thumb center at press) to avoid sudden jump when grabbing thumb off-center

**Joker verification confirmed:**
- `joker_service.analyze_random_joker()` → `JOKER_RANDOM` (type `"random"`, symbol `"@"` with "⭐R" suffix)
- `joker_service.try_mercy_joker()` → `JOKER_MERCY` (type `"mercy"`, symbol `"@"` with "⭐P" suffix)
- Both are called from `move_resolver.resolve()`, gated by `config.lua` params: `use_random_joker`, `use_mercy_joker`, `max_random_jokers`, `max_mercy_jokers`, `max_total_jokers`
- `board_service.init()` stores `difficulty` in `state.board.difficulty` and `state.board.cfg.difficulty`

## Important repo-specific caveats

- **Git commit messages**: use the following format: `Short description` in English language ONLY.