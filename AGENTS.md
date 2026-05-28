# Agent Instructions

This repository is a **Defold** game project. The project root is the folder containing `game.project`.

## Project map

- **Root config**: `game.project`
- **Main game content**: `main/` (board controller, chip game object, chip behavior, main collection)
- **Assets**: `assets/` (chip_back.png, bg.jpg, game.atlas)
- **Input bindings**: `input/game.input_binding`
- **Custom shaders**: `shaders/color_sprite/` (recolor vertex/fragment shaders and material)
- **Documentation/reference**: `doc/` (linker.jpg)
- **Dependencies (read-only context)**: `.deps/` — 4 external libraries + Defold engine builtins
  - `monarch/` — screen/popup navigation manager (6.0.1)
  - `object_interpolation/` — transform interpolation native extension (1.3.1)
  - `sharp_sprite/` — RGSS/mipmap shader-based texture filtering (1.0.0)
  - `xmath/` — zero-allocation vector/quaternion/matrix math native extension (main branch)
  - `builtins/` — Defold engine builtins (1.12.4)
- **Build output**: `build/` (compiled `.luac`, `.collectionc`, `.goc`, etc.)
- **Agent skills**: `.agents/skills/` (project-specific instructions and automation scripts)
- **Screens**: `screens/<screen_name>/` *(not yet created — intended future structure)*
- **Popups**: `popups/<popup_name>/` *(not yet created — intended future structure)*

Key Defold settings from `game.project`:

- **Title/Version**: MW1 0.0.1
- **Bootstrap collection**: `/main/main.collection`
- **Input binding**: `/input/game.input_bindingc`
- **Display**: 1024x1024, high DPI enabled
- **Physics scale**: 0.02
- **Script shared_state**: 1 (enabled)
- **Max counts**: sprite=256, label=256, particle_fx=256, particle_count=4096

**Resource paths in `game.project`**: Values like `main_collection`, `game_binding`, `app_icon` use Defold resource identifiers. A trailing `c` suffix denotes compiled resources and is expected — do not treat it as a typo.

## Main game structure

- **Board** (`main/board.script`): 7x7 letter-matching grid controller. Manages chip spawning via factory, linking (drag-to-connect), gravity collapse, and fill-from-above.
- **Chip** (`main/chip.go` → `main/chip.script`): Individual letter tile with a label component (`"character"`) and sprite component (`"back"`) using the custom recolor material. Spawned via factory from board.script.
- **Camera**: Orthographic camera at position (512, 512) in the main collection.

### Main collection (`main/main.collection`)

Two game objects:
- **`board`**: script component (`/main/board.script`) + embedded factory (`chip_factory`, prototype `/main/chip.go`)
- **`camera`**: embedded camera component (orthographic, aspect_ratio=1.0, fov=0.7854, near_z=-1, far_z=1) at position (512, 512)

### Chip game object (`main/chip.go`)

- Script component: `/main/chip.script`
- Label `"character"`: 128x128, text "A", `/builtins/fonts/default.font`, label-df material, z=0.1, scale 8x
- Sprite `"back"`: animation `chip_back`, `/shaders/color_sprite/recolor.material`, texture `/assets/game.atlas`

### Board controller (`main/board.script`)

**Constants**: `blocksize=96`, `edge=80`, `bottom_edge=80`, `boardwidth=7`, `boardheight=7`. Chip types: `type_plain`, `type_striped_h`, `type_striped_v`.

**Functions**: `build_board()` (random A-Z chips via factory), `collapse_board()` (gravity slide with OUTBOUNCE animation), `iterate_chips()`, `remove_chip()`/`remove_chips()`, `remove_link()` (ignores <3 length), `add_to_link()` (adjacency+color matching+backtracking), `empty_slots()`, `fill_slots()` (drop from y=1000 with OUTBOUNCE).

**Message handlers**: `start_level` → build_board, `post-reaction` → collapse + fill.

**Input**: `on_input` handles `"touch"` action. `pressed` starts linking, `released` removes link and triggers `post-reaction`.

### Chip behavior (`main/chip.script`)

**Properties**: `symb` (default 65 = 'A'), `blink` (default 0).

**Constants**: `normal_scale=0.45`, `zoomed_scale=0.6`. Types: `type_plain`, `type_striped_h`, `type_striped_v`, `type_wrapped`, `type_bomb`.

**Message handlers**: `respawn` (set position, enable sprite), `sway` (gentle Z-rotation ping-pong), `zoom_and_wobble` (scale+rotate on interaction), `reset` (restore normal), `remove` (go.delete).

## Input bindings (`input/game.input_binding`)

Single mouse trigger: `MOUSE_BUTTON_1` → action `"touch"`.

## Custom recolor shader

Located in `shaders/color_sprite/`. Used by chip sprites (`"tile"` render tag) to enable per-vertex color tinting:

- **Material constants**: `tint` (vec4 fragment uniform, default white), `newcolor` (vertex attribute, `SEMANTIC_TYPE_COLOR`, default RGBA 0.3882, 0.6078, 1.0, 1.0 = blue), `outline` (vertex attribute, default gray 0.5, 0.5, 0.5, alpha 0 = disabled).
- **Vertex shader** (`recolor.vp`): passes `view_proj`, `position`, `texcoord0`, `newcolor`, `outline` → `new_color`, `new_outline` to fragment shader.
- **Fragment shader** (`recolor.fp`): recolorizes grayscale/desaturated pixels using `new_color.rgb` (detected via `sprite.r + sprite.g == sprite.g * 2`), optionally renders outlines via green-channel mask (`sprite.g >= 1.0 && outline.w >= 1.0`), applies `tint` uniform.

## External libraries

### Monarch screen manager

Screen/popup navigation library (`require("monarch.monarch")`). Provides stack-based screen navigation with animated GUI transitions. Use the `monarch-screen-setup` skill when creating new screens or popups.

Key modules:
- `monarch.monarch` — main API (screen stacks, transitions, focus events)
- `monarch.screen_factory` — screen registration via `#collectionfactory`
- `monarch.screen_proxy` — screen registration via `#collectionproxy`
- `monarch.transitions.gui` — GUI-based transition animations
- `monarch.transitions.easings` — easing function wrappers

### Object Interpolation

Native extension for smooth transform interpolation. Add `object_interpolation` component to a game object and configure its `target_object` property.

API: `object_interpolation.set_enabled(bool)`, `object_interpolation.is_enabled()`. Constants: `object_interpolation.APPLY_TRANSFORM_NONE`, `object_interpolation.APPLY_TRANSFORM_TARGET`.

### Sharp Sprite

Shader-based texture filtering to reduce aliasing on scaled sprites. Provides drop-in replacement materials in three variants:
- **`/sharp_sprite/rgss/`** — Rotated Grid Super-Sampling (2x2 rotated offset sampling)
- **`/sharp_sprite/mipmap_bias/`** — Hardware mipmapping with negative LOD bias
- **`/sharp_sprite/rgss_bias/`** — RGSS + mipmap bias combined

When the project uses Sharp Sprite, use RGSS materials from `/sharp_sprite/rgss/` instead of builtins for all supported component types: Sprite, GUI, ParticleFX, Spine, Tilemap, Font, Label.

### xmath

Zero-allocation vector/quaternion/matrix math native extension (`require("xmath")` not needed — available globally as `xmath`). All operations write results into a pre-allocated first argument to avoid Lua GC pressure. Use when writing performance-critical math code.

API categories:
- **Arithmetic**: `add`, `sub`, `mul`, `div`
- **Vector**: `cross`, `mul_per_elem`, `normalize`, `rotate`, `vector`
- **Quaternion**: `conj`, `quat_axis_angle`, `quat_basis`, `quat_from_to`, `quat_rotation_[x/y/z]`, `quat`, `quat_matrix4`
- **Vector + Quat**: `lerp`, `slerp`
- **Matrix**: `matrix`, `matrix_axis_angle`, `matrix_from_quat`, `matrix_frustum`, `matrix_inv`, `matrix_look_at`, `matrix4_orthographic`, `matrix_ortho_inv`, `matrix4_perspective`, `matrix_rotation_[x/y/z]`, `matrix_translation`, `matrix4_compose`, `matrix4_scale`
- **Utility**: `clamp`

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

## Important repo-specific caveats

- **Git commit messages**: use the following format: `Short description` in English language ONLY.