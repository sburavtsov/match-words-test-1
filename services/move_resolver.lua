--[[
move_resolver.lua

Validates player moves and resolves them.
Pure logic, no state mutation except through board_service.

Handles:
- Path shape validation
- Dictionary word enumeration
- Target collection
- Post-move processing (gravity, spawn, joker normalization)
- Win condition detection

Usage:
local result = move_resolver.resolve(board_state, move_coords, dictionary)
if result.ok then
	print(result.chosen_word, result.is_win)
end
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local board_service = require("services.board_service")
local cell_factory = require("services.cell_factory")

local move_resolver = {}

local CONSTANTS = cell_factory.get_constants()

-- ──────────────────────────────────────────────────
-- Internal: validate path shape
-- ──────────────────────────────────────────────────

local function validate_path_shape(state, move_coords)
	if type(move_coords) ~= "table" or #move_coords == 0 then
		return false, "move_coords is empty"
	end

	local visited = {}

	for i = 1, #move_coords do
		local p = move_coords[i]
		if type(p) ~= "table" or p.x == nil or p.y == nil then
			return false, "bad coordinate at index " .. i
		end

		if not board_geometry.in_field(state.board, p.x, p.y) then
			return false, "out of bounds at index " .. i
		end

		local cell = state.grid[p.x][p.y]
		if cell == nil then
			return false, "path contains empty cell at index " .. i
		end

		if cell.is_booster then
			return false, "path contains booster at index " .. i
		end

		local key = board_geometry.coord_key(p.x, p.y)
		if visited[key] then
			return false, "path reuses cell at index " .. i
		end
		visited[key] = true

		if i > 1 then
			local prev = move_coords[i - 1]
			if not board_geometry.are_neighbors(state.board, prev.x, prev.y, p.x, p.y) then
				return false, "non-neighbor step between " .. (i - 1) .. " and " .. i
			end
		end
	end

	return true
end

-- ──────────────────────────────────────────────────
-- Internal: enumerate all valid words for a path
-- ──────────────────────────────────────────────────

local function enumerate_words(state, dictionary, move_coords)
	local valid_set = {}
	local alphabet = dictionary.alphabet or state.board.alphabet

	local function step(index, current_word)
		if index > #move_coords then
			if dictionary.valid_words[current_word] then
				valid_set[current_word] = true
			end
			return
		end

		local p = move_coords[index]
		local cell = state.grid[p.x][p.y]

		if cell.char == CONSTANTS.CHAR_JOKER then
			for a = 1, #alphabet do
				local next_word = current_word .. alphabet[a]
				if dictionary.prefixes[next_word] then
					step(index + 1, next_word)
				end
			end
		else
			local next_word = current_word .. cell.char
			if dictionary.prefixes[next_word] then
				step(index + 1, next_word)
			end
		end
	end

	step(1, "")
	return utils.set_to_sorted_array(valid_set)
end

-- ──────────────────────────────────────────────────
-- Public: resolve player move
-- ──────────────────────────────────────────────────

function move_resolver.resolve(state, move_coords, dictionary)
	if not state then
		return {ok = false, error = "state is nil"}
	end

	if not dictionary or not dictionary.valid_words or not dictionary.prefixes then
		return {ok = false, error = "dictionary incomplete"}
	end

	local ok, err = validate_path_shape(state, move_coords)
	if not ok then
		return {ok = false, error = err}
	end

	local valid_words = enumerate_words(state, dictionary, move_coords)

	if #valid_words == 0 then
		return {ok = false, error = "no valid words for this path"}
	end

	-- Game logic: resolve the move.
	local chosen_word = valid_words[1]
	local tile_len = #move_coords

	-- Count targets before destruction.
	local targets_collected = board_service.count_targets_in_path(state, move_coords)

	-- Destroy path and create booster.
	local booster = board_service.resolve_word_path(state, move_coords, tile_len)

	-- Update idle moves.
	if targets_collected > 0 then
		state.idle_moves = 0
	else
		state.idle_moves = state.idle_moves + 1
	end

	state.targets_collected = state.targets_collected + targets_collected

	-- Pity joker injection before gravity.
	local pity_injected = false
	if state.board.use_pity_joker and state.idle_moves >= state.board.joker_pity_threshold then
		pity_injected = board_service.inject_pity_joker(state, dictionary)
		if pity_injected then
			state.idle_moves = 0
		end
	end

	-- Apply gravity and fill.
	board_service.apply_gravity(state)

	-- Spawn new target.
	board_service.spawn_target(state)

	-- Normalize joker limits.
	board_service.normalize_jokers(state)

	-- Check win condition.
	local is_win = (state.targets_collected >= state.target_goal)

	return {
		ok = true,
		chosen_word = chosen_word,
		valid_words = valid_words,
		tile_len = tile_len,
		booster_created = booster,
		targets_collected_now = targets_collected,
		total_targets_collected = state.targets_collected,
		targets_remaining = state.target_goal - state.targets_collected,
		pity_injected = pity_injected,
		is_win = is_win,
		idle_moves = state.idle_moves
	}
end

return move_resolver