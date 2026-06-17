--[[
delta_repair.lua

Delta-zone и always-on delta-repair (BR-D01, BR-D02, BR-D03).

Идея: после каждого хода система знает, какие клетки изменились
(removed/moved/new). Из них формируется delta-zone (BR-D01) — локальная
область радиусом 1-2. В этой зоне выполняется delta-repair: создать
1 короткое слово Pool A длиной 3-4, минимально меняя клетки.

Защита от Pool-C only (BR-D03): если в локальной области не находится
короткое слово Pool A/B — repair обязан создать слово Pool A.

API:
  delta_repair.collect_delta_zone(state, deltas) -> zone_cells_list, zone_set
    deltas = {removed = {{x,y},...}, moved = {{x,y},...}, new = {{x,y},...}}

  delta_repair.run(state, dictionary, deltas) -> result
    result = {
      created_words = {{word, path, pool, len}, ...},
      destroyed_paths = {{word, path}, ...},
      replaced_cells = {{x, y, old_char, new_char}, ...},
      c_only_protection = bool,
      zone_size = number
    }
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local cell_factory = require("services.cell_factory")
local event_logger = require("services.event_logger")

local delta_repair = {}

local CK = board_geometry.coord_key
local CONSTANTS = cell_factory.get_constants()

local function copy_replacements(reps)
	local out = {}
	for i = 1, #reps do
		local r = reps[i]
		out[i] = {x = r.x, y = r.y, old_char = r.old_char, new_char = r.new_char}
	end
	return out
end

-- ── BR-D01: delta-zone ────────────────────────────

function delta_repair.collect_delta_zone(state, deltas)
	local seeds = {}
	local function add_all(list)
		if not list then return end
		for i = 1, #list do
			local p = list[i]
			if board_geometry.in_field(state.board, p.x, p.y) then
				seeds[#seeds + 1] = {x = p.x, y = p.y}
			end
		end
	end
	add_all(deltas.removed)
	add_all(deltas.moved)
	add_all(deltas.new)

	local radius = (state.board.cfg.repair_delta_radius or 2)
	local list, set = board_geometry.delta_zone(state.board, state.neighbors_map, seeds, radius)
	return list, set
end

-- ── Поиск коротких слов в зоне ────────────────────

-- DFS по сетке внутри zone_set, начиная от каждой клетки.
-- target_pools: множество пулов ("A"/"B"), которые засчитываются.
-- max_len: ограничение длины слова.
-- Возвращает массив: {{word, path, pool, len}, ...}, не более max_results.
local function find_words_in_zone(state, dictionary, zone_set, target_pools, min_len, max_len, max_results)
	max_results = max_results or 30
	local results = {}
	local result_keys = {}

	local alphabet = dictionary.alphabet
	local prefixes = dictionary.prefixes
	local valid_words = dictionary.valid_words

	local function dfs(x, y, current_word, visited, path)
		if #current_word >= min_len and valid_words[current_word] then
			local pool = dictionary.word_pool[current_word]
			if target_pools[pool] and not result_keys[current_word] then
				result_keys[current_word] = true
				results[#results + 1] = {
					word = current_word,
					path = utils.copy_path(path),
					pool = pool,
					len = dictionary.word_length[current_word]
				}
				if #results >= max_results then return true end
			end
		end
		if dictionary.word_length and dictionary.utf8_len then
			if dictionary.utf8_len(current_word) >= max_len then return false end
		end

		local ns = state.neighbors_map[x][y]
		for i = 1, #ns do
			local n = ns[i]
			local key = CK(n.x, n.y)
			if not visited[key] and zone_set[key] then
				local cell = state.grid[n.x][n.y]
				if cell and not cell.is_booster then
					visited[key] = true
					path[#path + 1] = {x = n.x, y = n.y}
					local ch = cell.char
					if ch == CONSTANTS.CHAR_JOKER then
						for a = 1, #alphabet do
							local nw = current_word .. alphabet[a]
							if prefixes[nw] then
								if dfs(n.x, n.y, nw, visited, path) then return true end
							end
						end
					else
						local nw = current_word .. ch
						if prefixes[nw] then
							if dfs(n.x, n.y, nw, visited, path) then return true end
						end
					end
					path[#path] = nil
					visited[key] = nil
				end
			end
		end
		return false
	end

	for key, _ in pairs(zone_set) do
		local cells = zone_set[key]
		local x, y = cells.x, cells.y
		local cell = state.grid[x][y]
		if cell and not cell.is_booster then
			local visited = {[key] = true}
			local path = {{x = x, y = y}}
			local start_word
			if cell.char == CONSTANTS.CHAR_JOKER then
				for a = 1, #alphabet do
					start_word = alphabet[a]
					if prefixes[start_word] then
						if dfs(x, y, start_word, visited, path) then break end
					end
				end
			else
				start_word = cell.char
				if prefixes[start_word] then
					if dfs(x, y, start_word, visited, path) then break end
				end
			end
		end
		if #results >= max_results then break end
	end

	return results
end

-- ── Защищённые клетки: слова Pool A длиной ≤ 5 (BR-D02 §91-92) ──

local function compute_protected_cells(state, dictionary, zone_set, max_len)
	local protect = find_words_in_zone(state, dictionary, zone_set, {A = true}, 3, max_len or 5, 60)
	local protected = {}
	for i = 1, #protect do
		local p = protect[i]
		for j = 1, #p.path do
			local k = CK(p.path[j].x, p.path[j].y)
			protected[k] = (protected[k] or 0) + 1
		end
	end
	return protected, protect
end

-- ── Поиск маршрута для нового слова с минимальными заменами ──

-- Возвращает {route, replacements} где replacements — список клеток,
-- которые потребуется заменить (старая буква != нужная).
local function find_repair_route(state, dictionary, target_word, zone_set, deltas_new_set, deltas_moved_set, protected_set, max_replacements)
	local chars = dictionary.utf8_chars(target_word)
	local wlen = #chars
	if wlen == 0 then
		return nil
	end

	local function try_from(start_x, start_y)
		local visited = {}
		local path = {}
		local replacements = {}

		local function recurse(idx, x, y)
			if idx > wlen then
				return {route = utils.copy_path(path), replacements = copy_replacements(replacements)}
			end
			local key = CK(x, y)
			if visited[key] then return nil end
			if not zone_set[key] then return nil end
			local cell = state.grid[x][y]
			if not cell then return nil end
			if cell.is_booster or cell.is_target then return nil end -- цели не трогаем; бустеры не используются
			if cell.char == CONSTANTS.CHAR_JOKER then return nil end -- джокеры не заменяем здесь

			local need = chars[idx]
			local same = (cell.char == need)
			local replace_cost = 0
			local rep_record = nil
			if not same then
				-- BR-D02 §92: запрещаем замену в protected клетках.
				if protected_set[key] then return nil end
				-- BR-D02 §89: сначала новые, затем перемещённые.
				if deltas_new_set[key] then
					replace_cost = 1
				elseif deltas_moved_set[key] then
					replace_cost = 2
				else
					replace_cost = 4 -- стабильная клетка — дороже
				end
				rep_record = {x = x, y = y, old_char = cell.char, new_char = need}
			end

			if #replacements + (rep_record and 1 or 0) > max_replacements then return nil end

			visited[key] = true
			path[#path + 1] = {x = x, y = y}
			if rep_record then replacements[#replacements + 1] = rep_record end

			if idx == wlen then
				local r = {route = utils.copy_path(path), replacements = copy_replacements(replacements)}
				visited[key] = nil
				path[#path] = nil
				if rep_record then replacements[#replacements] = nil end
				return r
			end

			-- Соседи.
			local ns = state.neighbors_map[x][y]
			-- BR-D02 §88: предпочитаем маршруты, которые используют новые клетки и ближе к цели.
			-- Сортируем соседей: новые > перемещённые > старые.
			local sorted = {}
			for i = 1, #ns do
				local n = ns[i]
				local k = CK(n.x, n.y)
				local rank = 3
				if deltas_new_set[k] then rank = 1
				elseif deltas_moved_set[k] then rank = 2 end
				sorted[#sorted + 1] = {n = n, rank = rank}
			end
			table.sort(sorted, function(a, b) return a.rank < b.rank end)

			for i = 1, #sorted do
				local n = sorted[i].n
				local r = recurse(idx + 1, n.x, n.y)
				if r then
					visited[key] = nil
					path[#path] = nil
					if rep_record then replacements[#replacements] = nil end
					return r
				end
			end

			visited[key] = nil
			path[#path] = nil
			if rep_record then replacements[#replacements] = nil end
			return nil
		end

		return recurse(1, start_x, start_y)
	end

	-- Перебираем стартовые клетки в порядке: новые → перемещённые → старые в зоне.
	local order = {}
	for key, p in pairs(zone_set) do
		local rank = 3
		if deltas_new_set[key] then rank = 1
		elseif deltas_moved_set[key] then rank = 2 end
		order[#order + 1] = {key = key, x = p.x, y = p.y, rank = rank}
	end
	table.sort(order, function(a, b) return a.rank < b.rank end)

	for i = 1, math.min(#order, 40) do
		local s = order[i]
		local r = try_from(s.x, s.y)
		if r then return r end
	end
	return nil
end

-- ── Применить repair (заменить буквы) ────────────

local function apply_repair(state, repair)
	for i = 1, #repair.replacements do
		local r = repair.replacements[i]
		if r.new_char == nil then
			-- skip
		else
			state.grid[r.x][r.y] = cell_factory.create_letter_cell(r.new_char, {origin = "repair"})
		end
	end
end

-- ── Главная функция ──────────────────────────────

function delta_repair.run(state, dictionary, deltas)
	deltas = deltas or {}
	local _, zone_set = delta_repair.collect_delta_zone(state, deltas)
	local zone_size = 0
	for _ in pairs(zone_set) do zone_size = zone_size + 1 end

	if zone_size == 0 then
		event_logger.log("repair_skip", {reason = "empty_zone"})
		return {created_words = {}, replaced_cells = {}, zone_size = 0}
	end

	-- BR-D03: проверка наличия коротких слов Pool A/B.
	local short_existing = find_words_in_zone(state, dictionary, zone_set, {A = true, B = true}, 3, 5, 5)
	local c_only = (#short_existing == 0)

	-- Сеты delta для приоритета.
	local new_set, moved_set = {}, {}
	if deltas.new then
		for i = 1, #deltas.new do new_set[CK(deltas.new[i].x, deltas.new[i].y)] = true end
	end
	if deltas.moved then
		for i = 1, #deltas.moved do moved_set[CK(deltas.moved[i].x, deltas.moved[i].y)] = true end
	end

	-- Защищённые клетки (из существующих слов Pool A длиной ≤ 5).
	local cfg = state.board.cfg
	local protected_set = compute_protected_cells(
		state, dictionary, zone_set, cfg.repair_protect_word_max_len or 5
	)

	-- BR-D02 §85: создать 1 слово Pool A длиной 3-4.
	-- Кандидаты — слова Pool A нужной длины, отсортированные по freq.
	local min_len = cfg.repair_target_min_len or 3
	local max_len = cfg.repair_target_max_len or 4
	local max_repl = cfg.repair_max_letter_replacements or 2

	-- Соберём кандидатов.
	local candidates = {}
	for L = min_len, max_len do
		local pool = dictionary.words_by_length[L]
		if pool then
			for i = 1, math.min(#pool, 200) do
				local w = pool[i]
				if dictionary.word_pool[w] == "A" then
					candidates[#candidates + 1] = w
				end
			end
		end
	end
	-- Перемешаем для разнообразия.
	for i = #candidates, 2, -1 do
		local j = math.random(1, i)
		candidates[i], candidates[j] = candidates[j], candidates[i]
	end

	local created = {}
	local replaced = {}

	local function try_create(attempt_label)
		for i = 1, math.min(#candidates, 80) do
			local w = candidates[i]
			if w == nil or w == "" then
				-- skip
			else
				-- BR-D02 §94: не создавать слово, тривиализующее цель (вне FTUE).
				-- Эвристика: слово не должно полностью совпадать с активной целью соло
				-- (т.е. содержать только целевую букву подряд). Это редкий случай — пропускаем.
				local r = find_repair_route(
					state, dictionary, w, zone_set, new_set, moved_set, protected_set, max_repl
				)
				if r then
					apply_repair(state, r)
					created[#created + 1] = {word = w, path = r.route, pool = "A", len = dictionary.word_length[w]}
					for _, rep in ipairs(r.replacements) do replaced[#replaced + 1] = rep end
					-- Помечаем клетки repair-словом (BR-J01 §137: запретить им стать random_joker).
					state.last_repair_cells = state.last_repair_cells or {}
					for _, p in ipairs(r.route) do
						state.last_repair_cells[CK(p.x, p.y)] = true
					end
					return true
				end
			end
		end
		return false
	end

	local ok = try_create("first")
	if not ok and c_only then
		-- BR-D03 §97: обязаны создать. Повышаем бюджет замен.
		max_repl = max_repl + 2
		ok = try_create("c_only_retry")
	end

	-- BR-D02 §86: второе слово — условно.
	local cfg_ftue = cfg.ftue or {}
	local ftue_active = cfg_ftue.first_level_completed == false
	local low_diff = state.board.difficulty <= 0.35
	local no_progress = (state.idle_moves or 0) >= 2
	local should_try_second = ftue_active or low_diff or no_progress

	if ok and should_try_second then
		try_create("second")
	end

	event_logger.log("repair", {
		created_count = #created,
		created_words = (function()
			local t = {}
			for i = 1, #created do t[#t + 1] = created[i].word end
			return table.concat(t, ",")
		end)(),
		replaced_count = #replaced,
		zone_size = zone_size,
		c_only_protection = c_only,
		short_pool_ab_count = #short_existing
	})

	return {
		created_words = created,
		replaced_cells = replaced,
		zone_size = zone_size,
		c_only_protection = c_only,
		short_existing_count = #short_existing
	}
end

return delta_repair
