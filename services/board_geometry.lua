--[[
board_geometry.lua

Pure topology and coordinate math (расширено под ТЗ).
Никакого игрового состояния, только геометрия.

Добавлено относительно исходной версии:
- radius_neighbors(state, x, y, radius)  — для delta-zone (BR-D01)
- column_windows(board, width, only_lower_half) — для random joker (BR-J01)
- target_column_weights(board, difficulty, cfg) — BR-P02 (вынесено сюда)
- foreach_cell(state, fn) — утилита обхода
- collect_lower_half_cells(state) — BR-J01 §127

Обратная совместимость: in_field, get_neighbors, are_neighbors,
chebyshev_dist, coord_key, build_neighbors_map, column_spawn_weights —
сохранены, сигнатуры не изменились.
]]--

local board_geometry = {}

-- ── Boundary check ────────────────────────────────

function board_geometry.in_field(board, x, y)
	if x < 1 or x > board.num_cols then return false end
	local h = board.pattern[x]
	if y < 1 or y > h then return false end
	return true
end

-- ── Neighbor generation (offset hex) ──────────────

function board_geometry.get_neighbors(board, x, y)
	local raw = {}
	raw[#raw + 1] = {x = x, y = y - 1}
	raw[#raw + 1] = {x = x, y = y + 1}

	if x % 2 == 1 then
		raw[#raw + 1] = {x = x - 1, y = y - 1}
		raw[#raw + 1] = {x = x - 1, y = y}
		raw[#raw + 1] = {x = x + 1, y = y - 1}
		raw[#raw + 1] = {x = x + 1, y = y}
	else
		raw[#raw + 1] = {x = x - 1, y = y}
		raw[#raw + 1] = {x = x - 1, y = y + 1}
		raw[#raw + 1] = {x = x + 1, y = y}
		raw[#raw + 1] = {x = x + 1, y = y + 1}
	end

	local valid = {}
	for i = 1, #raw do
		local n = raw[i]
		if board_geometry.in_field(board, n.x, n.y) then
			valid[#valid + 1] = n
		end
	end
	return valid
end

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

function board_geometry.are_neighbors(board, ax, ay, bx, by)
	local ns = board_geometry.get_neighbors(board, ax, ay)
	for i = 1, #ns do
		local n = ns[i]
		if n.x == bx and n.y == by then return true end
	end
	return false
end

-- ── Distance / keys ──────────────────────────────

function board_geometry.chebyshev_dist(ax, ay, bx, by)
	return math.max(math.abs(ax - bx), math.abs(ay - by))
end

function board_geometry.coord_key(x, y)
	return x .. "|" .. y
end

-- ── BR-D01: radius neighbors через граф соседства ─

-- Возвращает множество клеток в радиусе r от (x,y) по графу соседства
-- (включая саму клетку). Радиус 0 = только клетка; 1 = клетка + соседи;
-- 2 = BFS на 2 связи и т.д.
function board_geometry.radius_neighbors(board, neighbors_map, x, y, radius)
	local visited = {}
	local frontier = {{x = x, y = y}}
	visited[board_geometry.coord_key(x, y)] = {x = x, y = y, depth = 0}

	for depth = 1, radius do
		local next_frontier = {}
		for i = 1, #frontier do
			local p = frontier[i]
			local ns = neighbors_map and neighbors_map[p.x] and neighbors_map[p.x][p.y]
				or board_geometry.get_neighbors(board, p.x, p.y)
			for j = 1, #ns do
				local n = ns[j]
				local key = board_geometry.coord_key(n.x, n.y)
				if not visited[key] then
					visited[key] = {x = n.x, y = n.y, depth = depth}
					next_frontier[#next_frontier + 1] = n
				end
			end
		end
		frontier = next_frontier
		if #frontier == 0 then break end
	end

	local out = {}
	for _, v in pairs(visited) do out[#out + 1] = v end
	return out
end

-- Объединение radius_neighbors для набора начальных клеток.
function board_geometry.delta_zone(board, neighbors_map, seeds, radius)
	local set = {}
	for i = 1, #seeds do
		local s = seeds[i]
		local cells = board_geometry.radius_neighbors(board, neighbors_map, s.x, s.y, radius)
		for j = 1, #cells do
			local c = cells[j]
			set[board_geometry.coord_key(c.x, c.y)] = c
		end
	end
	local list = {}
	for _, v in pairs(set) do list[#list + 1] = v end
	return list, set
end

-- ── BR-J01 §127: нижняя половина поля ─────────────

function board_geometry.collect_lower_half_cells(board)
	local cells = {}
	for x = 1, board.num_cols do
		local col_h = board.pattern[x]
		-- BR-J01 §127: при нечётной длине брать большую половину через ceil.
		local lower_start = col_h - math.ceil(col_h / 2) + 1
		for y = lower_start, col_h do
			cells[#cells + 1] = {x = x, y = y}
		end
	end
	return cells
end

-- ── BR-J01 §128: окна шириной W с шагом 1 по колонкам ─

-- Возвращает массив окон. Каждое окно: {cols = {x1,x2,x3}, cells = {{x,y},...}}.
-- only_lower_half=true ограничивает по BR-J01 §127.
function board_geometry.column_windows(board, width, only_lower_half)
	width = width or 3
	local windows = {}
	for start_x = 1, board.num_cols - width + 1 do
		local cols = {}
		local cells = {}
		for k = 0, width - 1 do
			local x = start_x + k
			cols[#cols + 1] = x
			local col_h = board.pattern[x]
			local y_from, y_to
			if only_lower_half then
				y_from = col_h - math.ceil(col_h / 2) + 1
				y_to = col_h
			else
				y_from, y_to = 1, col_h
			end
			for y = y_from, y_to do
				cells[#cells + 1] = {x = x, y = y}
			end
		end
		windows[#windows + 1] = {cols = cols, cells = cells, start_x = start_x}
	end
	return windows
end

-- ── BR-P02: веса колонок для размещения целей ─────

function board_geometry.target_column_weights(board, difficulty, cfg)
	cfg = cfg or {}
	local low_diff_split = cfg.target_low_diff_split or 0.4
	local center_power = cfg.target_low_diff_center_power or 3
	local edge_power = cfg.target_high_diff_edge_power or 4

	local center_x = (board.num_cols + 1) / 2.0
	local max_dist = math.max(1, math.floor(board.num_cols / 2))
	local cols, weights = {}, {}

	for x = 1, board.num_cols do
		local norm = math.abs(x - center_x) / max_dist
		local w
		if difficulty < low_diff_split then
			-- BR-P02 §119: вес центра выше.
			w = ((1.0 - norm) ^ center_power) * (1.0 - difficulty * 2.0) + 0.01
		else
			-- BR-P02 §120: вес края выше.
			w = (norm ^ edge_power) * difficulty + 0.01
		end
		cols[#cols + 1] = x
		weights[#weights + 1] = w
	end
	return cols, weights
end

-- Legacy alias.
board_geometry.column_spawn_weights = board_geometry.target_column_weights

-- ── Утилиты ──────────────────────────────────────

function board_geometry.foreach_cell(state, fn)
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			fn(x, y, state.grid[x][y])
		end
	end
end

return board_geometry
