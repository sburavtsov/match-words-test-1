--[[
board_geometry.lua

Pure topology and coordinate math.
No game state, no cell generation, just geometry.

Provides:
- in_field(board, x, y)
- get_neighbors(board, x, y)
- are_neighbors(board, ax, ay, bx, by)
- chebyshev_dist(ax, ay, bx, by)
- coord_key(x, y)
]]--

local board_geometry = {}

-- ──────────────────────────────────────────────────
-- Field boundary check
-- ──────────────────────────────────────────────────

function board_geometry.in_field(board, x, y)
	if x < 1 or x > board.num_cols then
		return false
	end

	local col_height = board.pattern[x]
	if y < 1 or y > col_height then
		return false
	end

	return true
end

-- ──────────────────────────────────────────────────
-- Neighbor generation (pseudo-hex grid)
-- ──────────────────────────────────────────────────

function board_geometry.get_neighbors(board, x, y)
	local raw = {}

	-- Vertical neighbors always exist.
	raw[#raw + 1] = {x = x, y = y - 1}
	raw[#raw + 1] = {x = x, y = y + 1}

	if x % 2 == 1 then
		-- Odd column: shift up.
		raw[#raw + 1] = {x = x - 1, y = y - 1}
		raw[#raw + 1] = {x = x - 1, y = y}
		raw[#raw + 1] = {x = x + 1, y = y - 1}
		raw[#raw + 1] = {x = x + 1, y = y}
	else
		-- Even column: shift down.
		raw[#raw + 1] = {x = x - 1, y = y}
		raw[#raw + 1] = {x = x - 1, y = y + 1}
		raw[#raw + 1] = {x = x + 1, y = y}
		raw[#raw + 1] = {x = x + 1, y = y + 1}
	end

	-- Filter by field bounds.
	local valid = {}
	for i = 1, #raw do
		local n = raw[i]
		if board_geometry.in_field(board, n.x, n.y) then
			valid[#valid + 1] = n
		end
	end

	return valid
end

-- ──────────────────────────────────────────────────
-- Pre-build neighbor map for entire board
-- ──────────────────────────────────────────────────

function board_geometry.build_neighbors_map(board)
	local map = {}

	for x = 1, board.num_cols do
		map[x] = {}
		for y = 1, board.pattern[x] do
			map[x][y] = board_geometry.get_neighbors(board, x, y)
		end
	end

	return map
end

-- ──────────────────────────────────────────────────
-- Direct neighbor check
-- ──────────────────────────────────────────────────

function board_geometry.are_neighbors(board, ax, ay, bx, by)
	local neighbors = board_geometry.get_neighbors(board, ax, ay)
	for i = 1, #neighbors do
		local n = neighbors[i]
		if n.x == bx and n.y == by then
			return true
		end
	end
	return false
end

-- ──────────────────────────────────────────────────
-- Distance metrics
-- ──────────────────────────────────────────────────

function board_geometry.chebyshev_dist(ax, ay, bx, by)
	return math.max(math.abs(ax - bx), math.abs(ay - by))
end

function board_geometry.coord_key(x, y)
	return x .. "|" .. y
end

-- ──────────────────────────────────────────────────
-- Column weight calculation for target spawn
-- ──────────────────────────────────────────────────

function board_geometry.column_spawn_weights(board, difficulty)
	local center_x = (board.num_cols + 1) / 2.0
	local max_dist = math.max(1, math.floor(board.num_cols / 2))

	local cols = {}
	local weights = {}

	for x = 1, board.num_cols do
		local norm_dist = math.abs(x - center_x) / max_dist
		local weight

		if difficulty < 0.4 then
			weight = ((1.0 - norm_dist) ^ 3) * (1.0 - difficulty * 2.0) + 0.01
		else
			weight = (norm_dist ^ 4) * difficulty + 0.01
		end

		cols[#cols + 1] = x
		weights[#weights + 1] = weight
	end

	return cols, weights
end

return board_geometry