--[[
target_service.lua

Размещение целевых символов (BR-P01, BR-P02).

API:
  target_service.count_active(state) -> n
  target_service.count_in_path(state, move_coords) -> n
  target_service.try_spawn(state) -> bool, info
    -- Использует state.pending_targets как очередь.
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local cell_factory = require("services.cell_factory")
local event_logger = require("services.event_logger")

local target_service = {}

function target_service.count_active(state)
	local count = 0
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.is_target then count = count + 1 end
		end
	end
	return count
end

function target_service.count_in_path(state, move_coords)
	local n = 0
	for i = 1, #move_coords do
		local p = move_coords[i]
		local c = state.grid[p.x][p.y]
		if c and c.is_target then n = n + 1 end
	end
	return n
end

-- BR-P01 + BR-P02.
function target_service.try_spawn(state)
	local board = state.board
	local cfg = board.cfg

	if not state.pending_targets or #state.pending_targets == 0 then
		event_logger.log("target_skip", {reason = "no_pending"})
		return false
	end

	-- BR-P01 §112.
	local active = target_service.count_active(state)
	local max_active = cfg.max_active_targets or 3
	if active >= max_active then
		event_logger.log("target_skip", {reason = "max_active", active = active})
		return false
	end

	-- BR-P01 §113.
	local base_prob = cfg.target_spawn_base_prob
	if base_prob == nil then
		base_prob = 1.0 - (board.difficulty * 0.6)
	end
	local prob = math.max(0.0, base_prob - 0.4 * active)
	if math.random() >= prob then
		event_logger.log("target_skip", {reason = "prob", prob = prob, active = active})
		return false
	end

	-- BR-P02: веса колонок.
	local cols, weights = board_geometry.target_column_weights(board, board.difficulty, cfg)

	-- BR-P02 §121: верхняя половина.
	local avail_cols, avail_weights = {}, {}
	for i = 1, #cols do
		local x = cols[i]
		local half = math.ceil(board.pattern[x] / 2)
		local has_space = false
		for y = 1, half do
			local cell = state.grid[x][y]
			-- BR-P01 §115.
			if cell and not cell.is_target and not cell.is_booster
			   and cell.char ~= cell_factory.get_constants().CHAR_JOKER then
				has_space = true; break
			end
		end
		if has_space then
			avail_cols[#avail_cols + 1] = x
			avail_weights[#avail_weights + 1] = weights[i]
		end
	end

	if #avail_cols == 0 then
		event_logger.log("target_skip", {reason = "no_space"})
		return false
	end

	local chosen_x = utils.weighted_choice(avail_cols, avail_weights)
	local half = math.ceil(board.pattern[chosen_x] / 2)
	local candidates = {}
	for y = 1, half do
		local cell = state.grid[chosen_x][y]
		if cell and not cell.is_target and not cell.is_booster
		   and cell.char ~= cell_factory.get_constants().CHAR_JOKER then
			candidates[#candidates + 1] = y
		end
	end
	if #candidates == 0 then return false end

	local chosen_y = candidates[math.random(1, #candidates)]
	local target_char = table.remove(state.pending_targets, 1)

	state.grid[chosen_x][chosen_y] = cell_factory.create_target_cell(target_char, {origin = "target"})
	state.last_target_pos = {x = chosen_x, y = chosen_y, char = target_char}

	event_logger.log("target_spawned", {
		x = chosen_x, y = chosen_y, char = target_char,
		remaining = #state.pending_targets,
		prob = prob, active = active
	})

	return true, {x = chosen_x, y = chosen_y, char = target_char}
end

-- BR-D04 §100: подсчёт собранных целей и обнуление прогресса.
function target_service.collect_in_path(state, move_coords)
	local n = target_service.count_in_path(state, move_coords)
	if n > 0 then
		state.targets_collected = (state.targets_collected or 0) + n
		state.idle_moves = 0
	else
		state.idle_moves = (state.idle_moves or 0) + 1
	end
	return n
end

return target_service
