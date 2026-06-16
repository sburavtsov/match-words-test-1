--[[
board_service.lua

The central state keeper for the game board.
Handles:
- Board initialization (grid, targets, joker limits)
- Target spawn logic
- Gravity and refill
- Joker normalization
- Pity joker injection
- Target counting and collection

All mutations go through this module. It owns the board state.
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local cell_factory = require("services.cell_factory")

local board_service = {}

local CONSTANTS = cell_factory.get_constants()

-- ──────────────────────────────────────────────────
-- Internal: validate targets against alphabet
-- ──────────────────────────────────────────────────

local function validate_targets(targets, alphabet)
	local valid = {}
	for i = 1, #alphabet do
		valid[alphabet[i]] = true
	end
	valid["QU"] = true

	for i = 1, #targets do
		local t = targets[i]
		if not valid[t] then
			error("Target letter not in alphabet: " .. tostring(t))
		end
	end
end

-- ──────────────────────────────────────────────────
-- Internal: count current targets on board
-- ──────────────────────────────────────────────────

local function count_targets(state)
	local count = 0
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.is_target then
				count = count + 1
			end
		end
	end
	return count
end

-- ──────────────────────────────────────────────────
-- Internal: joker stats
-- ──────────────────────────────────────────────────

local function joker_stats(state)
	local stats = {
		total = 0,
		random = 0,
		pity = 0
	}

	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.char == CONSTANTS.CHAR_JOKER then
				stats.total = stats.total + 1

				if cell.joker_type == CONSTANTS.JOKER_RANDOM then
					stats.random = stats.random + 1
				elseif cell.joker_type == CONSTANTS.JOKER_PITY then
					stats.pity = stats.pity + 1
				else
					stats.random = stats.random + 1
				end
			end
		end
	end

	return stats
end

-- ──────────────────────────────────────────────────
-- Public: can we spawn a random joker?
-- ──────────────────────────────────────────────────

function board_service.can_spawn_random_joker(state)
	local stats = joker_stats(state)
	return stats.total < 2 and stats.random < 1
end

-- ──────────────────────────────────────────────────
-- Public: can we inject a pity joker?
-- ──────────────────────────────────────────────────

function board_service.can_inject_pity_joker(state)
	local stats = joker_stats(state)
	return stats.total < 2 and stats.pity < 1
end

-- ──────────────────────────────────────────────────
-- Public: initialize board state
-- ──────────────────────────────────────────────────

function board_service.init(options)
	options = options or {}

	local board = {
		pattern = utils.copy_array(options.pattern or {7, 6, 7, 6, 7, 6, 7, 6, 7}),
		num_cols = 0,
		max_rows = 0,
		difficulty = options.difficulty or 0.6,
		use_random_joker = (options.use_random_joker ~= false),
		use_pity_joker = (options.use_pity_joker ~= false),
		joker_base_chance = options.joker_base_chance or 0.015,
		alphabet = {},
		bg_weights = {}
	}

	board.num_cols = #board.pattern
	board.max_rows = utils.array_max(board.pattern)

	-- Derive alphabet and weights from dictionary if provided.
	local dictionary = options.dictionary or {}
	board.alphabet = dictionary.alphabet or {
		"A","B","C","D","E","F","G","H","I","J","K","L","M",
		"N","O","P","Q","R","S","T","U","V","W","X","Y","Z"
	}
	board.bg_weights = dictionary.bg_weights or {
		vowels = {
			letters = {"E","A","O","I","U","Y"},
			weights = {40, 30, 25, 20, 8, 3}
		},
		consonants = {
			letters = {"S","T","R","N","L","D","C","M","P","H","G","B","F","W","K","V","J","X","Z","Q"},
			weights = {30, 30, 25, 25, 20, 15, 15, 12, 12, 10, 8, 6, 5, 5, 3, 1, 1, 1, 1, 1}
		}
	}

	-- Derived values.
	board.current_joker_chance = board.joker_base_chance * (1.0 - board.difficulty ^ 2)
	board.joker_pity_threshold = math.floor(3 + board.difficulty ^ 2 * 10)

	-- Prepare pending targets.
	local target_letters = options.target_letters or {"A", "S", "D", "F", "G"}
	local pending_targets = {}

	for i = 1, #target_letters do
		local t = tostring(target_letters[i])
		if options.force_ascii_upper ~= false then
			t = string.upper(t)
		end
		if t == "Q" then
			t = "QU"
		end
		pending_targets[#pending_targets + 1] = t
	end

	validate_targets(pending_targets, board.alphabet)

	-- Build state.
	local state = {
		board = board,
		grid = {},
		neighbors_map = {},
		pending_targets = pending_targets,
		target_goal = #pending_targets,
		targets_collected = 0,
		idle_moves = 0,
		last_anchors = {}
	}

	state.neighbors_map = board_geometry.build_neighbors_map(board)

	-- Initialize empty grid.
	for x = 1, board.num_cols do
		state.grid[x] = {}
	end

	-- Fill with regular characters (no jokers on start).
	for x = 1, board.num_cols do
		for y = 1, board.pattern[x] do
			state.grid[x][y] = cell_factory.create_cell(board, {
				allow_joker = false
			})
		end
	end

	-- Post-init: spawn first target and normalize.
	board_service.spawn_target(state)
	board_service.normalize_jokers(state)

	return state
end

-- ──────────────────────────────────────────────────
-- Public: spawn target letter
-- ──────────────────────────────────────────────────

function board_service.spawn_target(state)
	if #state.pending_targets == 0 then
		return false
	end

	local current_targets = count_targets(state)
	if current_targets >= 3 then
		return false
	end

	local base_prob = 1.0 - (state.board.difficulty * 0.6)
	local prob = math.max(0.0, base_prob - 0.4 * current_targets)

	if math.random() >= prob then
		return false
	end

	local cols, weights = board_geometry.column_spawn_weights(state.board, state.board.difficulty)

	-- Filter columns that have space in upper half.
	local available_cols = {}
	local available_weights = {}

	for i = 1, #cols do
		local x = cols[i]
		local half_height = math.ceil(state.board.pattern[x] / 2)
		local has_space = false

		for y = 1, half_height do
			local cell = state.grid[x][y]
			if cell ~= nil and not cell.is_target and not cell.is_booster then
				has_space = true
				break
			end
		end

		if has_space then
			available_cols[#available_cols + 1] = x
			available_weights[#available_weights + 1] = weights[i]
		end
	end

	if #available_cols == 0 then
		return false
	end

	local chosen_x = utils.weighted_choice(available_cols, available_weights)

	-- Pick random empty cell in upper half.
	local half_height = math.ceil(state.board.pattern[chosen_x] / 2)
	local candidates = {}

	for y = 1, half_height do
		local cell = state.grid[chosen_x][y]
		if cell ~= nil and not cell.is_target and not cell.is_booster then
			candidates[#candidates + 1] = y
		end
	end

	if #candidates == 0 then
		return false
	end

	local chosen_y = candidates[math.random(1, #candidates)]
	local target_char = table.remove(state.pending_targets, 1)

	state.grid[chosen_x][chosen_y] = cell_factory.create_cell(state.board, {
		char = target_char,
		is_target = true,
		allow_joker = false
	})

	return true
end

-- ──────────────────────────────────────────────────
-- Public: apply gravity and refill
-- ──────────────────────────────────────────────────

function board_service.apply_gravity(state)
	for x = 1, state.board.num_cols do
		local col_height = state.board.pattern[x]
		local new_col = {}

		-- Collect non-empty cells from bottom to top.
		for y = col_height, 1, -1 do
			local cell = state.grid[x][y]
			if cell ~= nil then
				new_col[#new_col + 1] = cell
			end
		end

		-- Fill new cells at the end (top side).
		while #new_col < col_height do
			new_col[#new_col + 1] = cell_factory.create_cell(state.board, {
				allow_joker = true
			})
		end

		-- Write back from bottom to top.
		local read_idx = 1
		for y = col_height, 1, -1 do
			state.grid[x][y] = new_col[read_idx]
			read_idx = read_idx + 1
		end
	end

	board_service.normalize_jokers(state)
end

-- ──────────────────────────────────────────────────
-- Public: normalize joker limits
-- ──────────────────────────────────────────────────

function board_service.normalize_jokers(state)
	local first_random = nil
	local first_pity = nil
	local extras = {}

	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.char == CONSTANTS.CHAR_JOKER then
				local jt = cell.joker_type

				if jt ~= CONSTANTS.JOKER_RANDOM and jt ~= CONSTANTS.JOKER_PITY then
					jt = CONSTANTS.JOKER_RANDOM
					cell.joker_type = CONSTANTS.JOKER_RANDOM
				end

				if jt == CONSTANTS.JOKER_RANDOM then
					if first_random == nil then
						first_random = {x = x, y = y}
					else
						extras[#extras + 1] = {x = x, y = y}
					end
				elseif jt == CONSTANTS.JOKER_PITY then
					if first_pity == nil then
						first_pity = {x = x, y = y}
					else
						extras[#extras + 1] = {x = x, y = y}
					end
				end
			end
		end
	end

	-- Handle total > 2 case.
	local stats = joker_stats(state)
	if stats.total > 2 then
		local keep = {}
		if first_random then
			keep[board_geometry.coord_key(first_random.x, first_random.y)] = true
		end
		if first_pity then
			keep[board_geometry.coord_key(first_pity.x, first_pity.y)] = true
		end

		for x = 1, state.board.num_cols do
			for y = 1, state.board.pattern[x] do
				local cell = state.grid[x][y]
				if cell and cell.char == CONSTANTS.CHAR_JOKER then
					local key = board_geometry.coord_key(x, y)
					if not keep[key] then
						state.grid[x][y] = cell_factory.create_cell(state.board, {
							allow_joker = false
						})
					end
				end
			end
		end
	else
		for i = 1, #extras do
			local p = extras[i]
			state.grid[p.x][p.y] = cell_factory.create_cell(state.board, {
				allow_joker = false
			})
		end
	end
end

-- ──────────────────────────────────────────────────
-- Public: inject pity joker
-- ──────────────────────────────────────────────────

function board_service.inject_pity_joker(state, dictionary)
	if not state.board.use_pity_joker then
		return false
	end

	if not board_service.can_inject_pity_joker(state) then
		return false
	end

	-- Collect all current targets.
	local targets = {}
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.is_target then
				targets[#targets + 1] = {x = x, y = y}
			end
		end
	end

	if #targets == 0 then
		return false
	end

	local best_x, best_y, best_score = nil, nil, -1
	local alphabet = dictionary.alphabet or state.board.alphabet

	-- For each target, check its non-booster neighbors.
	for i = 1, #targets do
		local target = targets[i]
		local neighbors = state.neighbors_map[target.x][target.y]

		for j = 1, #neighbors do
			local n = neighbors[j]
			local cell = state.grid[n.x][n.y]

			if cell and not cell.is_target and not cell.is_booster and cell.char ~= CONSTANTS.CHAR_JOKER then
				-- Temporarily place pity joker.
				local original = utils.copy_cell(cell)
				state.grid[n.x][n.y] = cell_factory.create_cell(state.board, {
					char = CONSTANTS.CHAR_JOKER,
					joker_type = CONSTANTS.JOKER_PITY,
					allow_joker = false
				})

				local found = {}
				local visited = {}
				local path = {{x = n.x, y = n.y}}
				visited[board_geometry.coord_key(n.x, n.y)] = true

				-- DFS from each alphabet letter through the joker.
				for a = 1, #alphabet do
					local assumed = alphabet[a]
					if dictionary.prefixes[assumed] then
						board_service._pity_dfs(state, dictionary, n.x, n.y, assumed, visited, path, found)
					end
				end

				-- Restore original cell.
				state.grid[n.x][n.y] = original

				-- Find best word that includes both target and candidate.
				for k = 1, #found do
					local item = found[k]
					local has_target = false
					local has_candidate = false

					for p = 1, #item.path do
						local pt = item.path[p]
						if pt.x == target.x and pt.y == target.y then
							has_target = true
						end
						if pt.x == n.x and pt.y == n.y then
							has_candidate = true
						end
					end

					if has_target and has_candidate then
						local freq = dictionary.word_frequencies[item.word] or 1.0
						local score = utils.utf8_len(item.word) * freq

						if score > best_score then
							best_score = score
							best_x = n.x
							best_y = n.y
						end
					end
				end
			end
		end
	end

	if best_x and board_service.can_inject_pity_joker(state) then
		state.grid[best_x][best_y] = cell_factory.create_cell(state.board, {
			char = CONSTANTS.CHAR_JOKER,
			joker_type = CONSTANTS.JOKER_PITY,
			allow_joker = false
		})

		board_service.normalize_jokers(state)
		return true
	end

	return false
end

-- Internal DFS for pity joker analysis.
function board_service._pity_dfs(state, dictionary, cx, cy, current_word, visited, path, found)
	if not dictionary.prefixes[current_word] then
		return
	end

	if dictionary.valid_words[current_word] then
		found[#found + 1] = {
			word = current_word,
			path = utils.copy_path(path)
		}
	end

	if utils.utf8_len(current_word) >= 8 then
		return
	end

	local neighbors = state.neighbors_map[cx][cy]
	local alphabet = dictionary.alphabet or state.board.alphabet

	for i = 1, #neighbors do
		local n = neighbors[i]
		local key = board_geometry.coord_key(n.x, n.y)

		if not visited[key] then
			local cell = state.grid[n.x][n.y]

			if cell and not cell.is_booster then
				visited[key] = true
				path[#path + 1] = {x = n.x, y = n.y}

				if cell.char == CONSTANTS.CHAR_JOKER then
					for a = 1, #alphabet do
						local next_word = current_word .. alphabet[a]
						if dictionary.prefixes[next_word] then
							board_service._pity_dfs(state, dictionary, n.x, n.y, next_word, visited, path, found)
						end
					end
				else
					local next_word = current_word .. cell.char
					if dictionary.prefixes[next_word] then
						board_service._pity_dfs(state, dictionary, n.x, n.y, next_word, visited, path, found)
					end
				end

				path[#path] = nil
				visited[key] = nil
			end
		end
	end
end

-- ──────────────────────────────────────────────────
-- Public: count targets in path
-- ──────────────────────────────────────────────────

function board_service.count_targets_in_path(state, move_coords)
	local count = 0
	for i = 1, #move_coords do
		local p = move_coords[i]
		local cell = state.grid[p.x][p.y]
		if cell and cell.is_target then
			count = count + 1
		end
	end
	return count
end

-- ──────────────────────────────────────────────────
-- Public: destroy cells and create booster
-- ──────────────────────────────────────────────────

function board_service.resolve_word_path(state, move_coords, tile_len)
	local booster = nil
	if tile_len == 5 then
		booster = CONSTANTS.BOOSTER_LINE
	elseif tile_len == 6 then
		booster = CONSTANTS.BOOSTER_BOMB
	elseif tile_len >= 7 then
		booster = CONSTANTS.BOOSTER_COLOR
	end

	for i = 1, #move_coords do
		local p = move_coords[i]
		if i == #move_coords and booster then
			state.grid[p.x][p.y] = cell_factory.create_cell(state.board, {
				char = booster,
				is_booster = true,
				allow_joker = false
			})
		else
			state.grid[p.x][p.y] = nil
		end
	end

	return booster
end

-- ──────────────────────────────────────────────────
-- Public: debug dump
-- ──────────────────────────────────────────────────

function board_service.debug_dump(state)
	local lines = {}

	for y = 1, state.board.max_rows do
		local row = {}
		for x = 1, state.board.num_cols do
			if y <= state.board.pattern[x] then
				local cell = state.grid[x][y]
				if cell == nil then
					row[#row + 1] = " . "
				else
					local text = cell.char
					if cell.is_target then
						text = text .. "*"
					elseif cell.char == CONSTANTS.CHAR_JOKER then
						if cell.joker_type == CONSTANTS.JOKER_RANDOM then
							text = text .. "R"
						else
							text = text .. "P"
						end
					end
					row[#row + 1] = string.format("%-3s", text)
				end
			else
				row[#row + 1] = "   "
			end
		end
		lines[#lines + 1] = table.concat(row, " ")
	end

	return table.concat(lines, "\n")
end

return board_service