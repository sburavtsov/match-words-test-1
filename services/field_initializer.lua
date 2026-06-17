--[[
field_initializer.lua

Anchor-first генерация стартового поля (BR-F01, BR-F02, BR-F03).

Алгоритм:
  1. Очистить grid (всё nil).
  2. Выбрать целевую букву уровня (первая из pending_targets).
  3. Разместить target-anchor word (BR-F02):
     - Найти слова Pool A длиной 3-4 (потом 5), содержащие целевую букву.
     - Выбрать позицию для целевого символа по сложности (центр/край).
     - Проложить маршрут через клетку: вертикальный > горизонтальный > 1-диаг.
     - Если не удалось — переместить целевой символ и повторить.
  4. Разместить entry words (BR-F01) для достижения целевого покрытия.
     - Слова не пересекаются, не соприкасаются по основным направлениям.
     - Предпочтения направлений: 60-70% вертикально, 20-30% горизонтально,
       до 10% с одним диагональным переходом (не в FTUE).
  5. Заполнить остальные клетки из letter_bag (BR-F01 §37).
  6. Sanity check (BR-F03):
     - target-anchor word на месте,
     - покрытие >= минимального,
     - нет пересечений, target cell — буква, не джокер/бустер.
     - Если ломается — пересборка с ослабленными правилами.

API:
  field_initializer.build(state, dictionary, options)
    options.ftue = bool
    options.level_id = number
  Возвращает: success(bool), info { coverage, anchor_word, attempts, sanity_ok }
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local cell_factory = require("services.cell_factory")
local letter_bag = require("services.letter_bag")
local spawn_service = require("services.spawn_service")
local event_logger = require("services.event_logger")

local field_initializer = {}

local CK = board_geometry.coord_key

-- ── Утилиты ──────────────────────────────────────

local function clear_grid(state)
	for x = 1, state.board.num_cols do
		state.grid[x] = {}
	end
end

local function cell_count(board)
	local n = 0
	for x = 1, board.num_cols do n = n + board.pattern[x] end
	return n
end

local function coverage_range(cfg, is_ftue)
	if is_ftue then
		return cfg.starter_coverage_ftue.min, cfg.starter_coverage_ftue.max
	end
	return cfg.starter_coverage_normal.min, cfg.starter_coverage_normal.max
end

-- Поиск кандидатов на позицию целевой буквы по BR-F02 §41.
-- На низкой сложности — ближе к центру (верхняя половина центральной зоны).
local function candidate_target_cells(board, difficulty)
	local center_x = (board.num_cols + 1) / 2.0
	local max_dist = math.max(1, math.floor(board.num_cols / 2))
	local out = {}
	for x = 1, board.num_cols do
		local norm = math.abs(x - center_x) / max_dist
		-- Веса.
		local w
		if difficulty < 0.4 then
			w = (1.0 - norm) ^ 3 + 0.01
		else
			w = norm ^ 4 * difficulty + 0.01
		end
		local half = math.ceil(board.pattern[x] / 2)
		for y = 1, half do
			out[#out + 1] = {x = x, y = y, w = w}
		end
	end
	-- Отсортировать по убыванию веса для попыток в порядке предпочтения.
	table.sort(out, function(a, b) return a.w > b.w end)
	return out
end

-- ── Поиск маршрутов слова на пустой/частично заполненной сетке ──

-- Проверка: можно ли занять клетку (учитывая claimed_set).
local function cell_available_for_route(state, x, y, claimed_set, allow_letter)
	if not board_geometry.in_field(state.board, x, y) then return false end
	local key = CK(x, y)
	if claimed_set[key] then return false end
	local cell = state.grid[x][y]
	if cell == nil then return true end -- пустая — берём
	if allow_letter and cell.char and (cell.char == allow_letter) and not cell.is_target then
		return true
	end
	-- Если клетка уже несёт другую букву — нельзя.
	return false
end

-- Направления для предпочтения маршрута (BR-F02 §43).
local DIR_VERTICAL = 1
local DIR_HORIZONTAL = 2
local DIR_DIAGONAL = 3

-- Сосед по направлению — варианты следующего шага из (x,y).
local function neighbors_by_direction(state, x, y, prev, dir, diagonals_used)
	local board = state.board
	local ns = state.neighbors_map[x][y]
	local res = {}
	for i = 1, #ns do
		local n = ns[i]
		if not (prev and n.x == prev.x and n.y == prev.y) then
			local dx = n.x - x
			local dy = n.y - y
			local is_vertical = (dx == 0)
			local is_horizontal = (dx ~= 0 and dy == 0)
			local is_diagonal = (dx ~= 0 and dy ~= 0)
			if dir == DIR_VERTICAL and is_vertical then
				res[#res + 1] = {x = n.x, y = n.y, kind = "v"}
			elseif dir == DIR_HORIZONTAL and (is_horizontal or is_vertical) then
				res[#res + 1] = {x = n.x, y = n.y, kind = is_vertical and "v" or "h"}
			elseif dir == DIR_DIAGONAL then
				if is_diagonal and diagonals_used < 1 then
					res[#res + 1] = {x = n.x, y = n.y, kind = "d"}
				else
					res[#res + 1] = {x = n.x, y = n.y, kind = is_vertical and "v" or "h"}
				end
			end
		end
	end
	-- Перемешать в пределах одного направления.
	for i = #res, 2, -1 do
		local j = math.random(1, i)
		res[i], res[j] = res[j], res[i]
	end
	return res
end

-- Найти маршрут для слова: подобрать последовательность клеток так,
-- чтобы последовательность букв совпадала со словом.
-- through: опц., {x, y} — клетка, через которую обязательно должен пройти маршрут.
-- through_char_idx: индекс символа слова, который попадает в through.
local function find_route_for_word(state, word_chars, dir, claimed_set, through, through_char_idx)
	local board = state.board

	-- Для каждой возможной стартовой клетки попробовать.
	local starts = {}
	if through and through_char_idx == 1 then
		starts[#starts + 1] = {x = through.x, y = through.y}
	elseif through then
		-- Стартовые клетки — все клетки на расстоянии (through_char_idx - 1) шагов от through,
		-- через которые можно дойти. Берём всё поле как fallback.
		for x = 1, board.num_cols do
			for y = 1, board.pattern[x] do
				starts[#starts + 1] = {x = x, y = y}
			end
		end
	else
		for x = 1, board.num_cols do
			for y = 1, board.pattern[x] do
				starts[#starts + 1] = {x = x, y = y}
			end
		end
	end
	-- Перемешать порядок стартов.
	for i = #starts, 2, -1 do
		local j = math.random(1, i)
		starts[i], starts[j] = starts[j], starts[i]
	end

	local function backtrack(idx, path, visited, diag_count, prev)
		if idx > #word_chars then
			-- Проверка через through.
			if through then
				local p = path[through_char_idx]
				if not p or p.x ~= through.x or p.y ~= through.y then return nil end
			end
			return path
		end
		local need_char = word_chars[idx]
		local x, y = path[#path].x, path[#path].y
		local nbrs = neighbors_by_direction(state, x, y, prev, dir, diag_count)
		for i = 1, #nbrs do
			local n = nbrs[i]
			local key = CK(n.x, n.y)
			if not visited[key] and cell_available_for_route(state, n.x, n.y, claimed_set, need_char) then
				-- Если through задан и индекс = through_char_idx — клетка должна совпадать.
				local ok_through = true
				if through and idx == through_char_idx then
					ok_through = (n.x == through.x and n.y == through.y)
				end
				if ok_through then
					visited[key] = true
					path[#path + 1] = {x = n.x, y = n.y}
					local nd = diag_count + (n.kind == "d" and 1 or 0)
					local r = backtrack(idx + 1, path, visited, nd, {x = x, y = y})
					if r then return r end
					path[#path] = nil
					visited[key] = nil
				end
			end
		end
		return nil
	end

	for i = 1, math.min(#starts, 30) do -- ограничим попытки
		local s = starts[i]
		-- Первая клетка должна нести нужную первую букву (если through_char_idx==1 — через through).
		if cell_available_for_route(state, s.x, s.y, claimed_set, word_chars[1]) then
			local through_ok = true
			if through and through_char_idx == 1 then
				through_ok = (s.x == through.x and s.y == through.y)
			end
			if through_ok then
				local visited = {[CK(s.x, s.y)] = true}
				local path = {{x = s.x, y = s.y}}
				local diag = 0
				local r = backtrack(2, path, visited, diag, nil)
				if r then return r end
			end
		end
	end
	return nil
end

-- Запись слова на сетку по маршруту.
local function write_word_path(state, word_chars, path, is_anchor)
	for i = 1, #path do
		local p = path[i]
		local cell = state.grid[p.x][p.y]
		if cell == nil then
			-- На стартовом поле джокеров/бустеров не ставим (BR-F01 §38).
			state.grid[p.x][p.y] = cell_factory.create_letter_cell(word_chars[i], {
				origin = is_anchor and "anchor" or "starter"
			})
		end
	end
end

-- Проверка "не соприкасается по основным направлениям" с уже занятыми клетками.
local function touches_existing(state, path, occupied_set)
	for i = 1, #path do
		local p = path[i]
		local ns = state.neighbors_map[p.x][p.y]
		for j = 1, #ns do
			local n = ns[j]
			local key = CK(n.x, n.y)
			-- Если соседняя клетка — занята другим словом (и не наша же клетка в пути).
			if occupied_set[key] and not (function()
				for k = 1, #path do
					if path[k].x == n.x and path[k].y == n.y then return true end
				end
				return false
			end)() then
				local dx = n.x - p.x
				local dy = n.y - p.y
				if dx == 0 or dy == 0 then -- вертикаль/горизонталь
					return true
				end
			end
		end
	end
	return false
end

-- Выбрать направление по предпочтениям из cfg (BR-F01 §32).
local function pick_direction(cfg, is_ftue)
	local pref = cfg.starter_direction_pref or {vertical = 0.7, horizontal = 0.25, diagonal = 0.05}
	local r = math.random()
	local v, h = pref.vertical, pref.horizontal
	if r < v then return DIR_VERTICAL end
	if r < v + h then return DIR_HORIZONTAL end
	if is_ftue then return DIR_HORIZONTAL end -- BR-F01 §32: диагонали не в FTUE
	return DIR_DIAGONAL
end

-- ── Размещение target-anchor word (BR-F02) ────────

local function find_anchor_word_candidates(dictionary, target_letter, max_len, extended_len)
	local results = {}
	local function gather(len)
		local pool = dictionary.words_by_length[len]
		if not pool then return end
		for i = 1, #pool do
			local w = pool[i]
			if dictionary.word_pool[w] == "A" then
				local chars = dictionary.utf8_chars(w)
				for ci = 1, #chars do
					if chars[ci] == target_letter then
						results[#results + 1] = {word = w, chars = chars, target_idx = ci, len = len}
						break
					end
				end
			end
		end
	end
	for L = 3, max_len do gather(L) end
	if #results == 0 and extended_len then
		for L = max_len + 1, extended_len do gather(L) end
	end
	-- Перемешать.
	for i = #results, 2, -1 do
		local j = math.random(1, i)
		results[i], results[j] = results[j], results[i]
	end
	return results
end

local function place_anchor(state, dictionary, target_letter, cfg, is_ftue)
	local target_candidates = candidate_target_cells(state.board, state.board.difficulty)
	local word_candidates = find_anchor_word_candidates(
		dictionary, target_letter,
		cfg.starter_max_word_len or 4,
		cfg.starter_extended_max_len or 5
	)
	if #word_candidates == 0 then return nil end

	local directions = {DIR_VERTICAL, DIR_HORIZONTAL}
	if not is_ftue then directions[#directions + 1] = DIR_DIAGONAL end

	for ti = 1, math.min(#target_candidates, 20) do
		local tc = target_candidates[ti]
		for wi = 1, math.min(#word_candidates, 12) do
			local wc = word_candidates[wi]
			for di = 1, #directions do
				local dir = directions[di]
				local route = find_route_for_word(
					state, wc.chars, dir, {}, tc, wc.target_idx
				)
				if route then
					-- Кладём слово; target-клетка делается is_target=true.
					for i = 1, #route do
						local p = route[i]
						local is_t = (i == wc.target_idx)
						if is_t then
							state.grid[p.x][p.y] = cell_factory.create_target_cell(wc.chars[i], {origin = "anchor"})
						else
							state.grid[p.x][p.y] = cell_factory.create_letter_cell(wc.chars[i], {origin = "anchor"})
						end
					end
					return {word = wc.word, route = route, target_idx = wc.target_idx, target_pos = tc}
				end
			end
		end
	end
	return nil
end

-- ── Размещение entry words (BR-F01) ───────────────

local function place_entry_words(state, dictionary, cfg, is_ftue, occupied_set, target_coverage_max)
	local placed_paths = {}
	local total_letters = 0
	for k, _ in pairs(occupied_set) do total_letters = total_letters + 1 end

	local total_cells = cell_count(state.board)
	local max_letters = math.floor(total_cells * target_coverage_max)

	-- Кандидаты — короткие слова Pool A.
	local lengths = {}
	for L = cfg.starter_min_word_len or 3, cfg.starter_max_word_len or 4 do
		lengths[#lengths + 1] = L
	end

	local attempts = 0
	local max_attempts = (cfg.starter_max_attempts or 6) * 20

	while total_letters < max_letters and attempts < max_attempts do
		attempts = attempts + 1
		local len = lengths[math.random(1, #lengths)]
		local pool = dictionary.words_by_length[len]
		if pool and #pool > 0 then
			local w = pool[math.random(1, #pool)]
			if dictionary.word_pool[w] == "A" then
				local chars = dictionary.utf8_chars(w)
				local dir = pick_direction(cfg, is_ftue)
				local route = find_route_for_word(state, chars, dir, {}, nil, nil)
				if route then
					-- Проверки BR-F01 §33-34.
					local intersects = false
					for i = 1, #route do
						local p = route[i]
						if occupied_set[CK(p.x, p.y)] then intersects = true; break end
					end
					if not intersects and not touches_existing(state, route, occupied_set) then
						write_word_path(state, chars, route, false)
						for i = 1, #route do
							local p = route[i]
							occupied_set[CK(p.x, p.y)] = true
							total_letters = total_letters + 1
						end
						placed_paths[#placed_paths + 1] = {word = w, route = route}
					end
				end
			end
		end
	end

	return placed_paths, total_letters
end

-- ── Заполнение оставшихся клеток (BR-F01 §37) ─────

local function fill_remaining(state)
	-- Используем spawn_service.fill_empty_cells для согласованности с BR-G01.
	return spawn_service.fill_empty_cells(state)
end

-- ── BR-F03: sanity check ─────────────────────────

local function sanity_check(state, anchor_info, total_letters, min_letters)
	if not anchor_info then return false, "no_anchor" end
	-- Anchor target cell on field.
	local ap = anchor_info.route[anchor_info.target_idx]
	local cell = state.grid[ap.x][ap.y]
	if not cell or not cell.is_target then return false, "anchor_lost" end
	if cell.char == cell_factory.get_constants().CHAR_JOKER then return false, "anchor_joker" end
	if cell.is_booster then return false, "anchor_booster" end
	if total_letters < min_letters then return false, "low_coverage" end
	return true, "ok"
end

-- ── Главный билдер ───────────────────────────────

function field_initializer.build(state, dictionary, options)
	options = options or {}
	local cfg = state.board.cfg
	local is_ftue = options.ftue == true or
		(cfg.ftue and cfg.ftue.level_id and cfg.ftue.level_id <= (cfg.ftue.ftue_max_level or 0))
	local total_cells = cell_count(state.board)
	local cov_min, cov_max = coverage_range(cfg, is_ftue)
	local min_letters = math.floor(total_cells * cov_min)

	local max_attempts = cfg.starter_max_attempts or 6
	local relaxed = false

	for attempt = 1, max_attempts do
		clear_grid(state)

		-- Целевая буква — первая в очереди (не вынимаем).
		local target_letter = state.pending_targets[1]
		if not target_letter then
			event_logger.log("init_no_target", {})
			return false, {reason = "no_target"}
		end

		-- 1) target-anchor word.
		local anchor_info = place_anchor(state, dictionary, target_letter, cfg, is_ftue)
		if not anchor_info then
			event_logger.log("anchor_fail", {target_letter = target_letter, attempt = attempt})
			-- Попробуем ещё раз.
		else
			-- 2) entry words.
			local occupied = {}
			for i = 1, #anchor_info.route do
				local p = anchor_info.route[i]
				occupied[CK(p.x, p.y)] = true
			end
			local placed, total_letters = place_entry_words(
				state, dictionary, cfg, is_ftue, occupied, cov_max
			)

			-- При недостатке — ослабляем «не соприкасаться» (BR-F03 §48).
			if total_letters < min_letters and not relaxed then
				relaxed = true
				-- Прогон без проверки соприкосновений.
				local lengths = {3, 4}
				local extra_attempts = 80
				while total_letters < min_letters and extra_attempts > 0 do
					extra_attempts = extra_attempts - 1
					local len = lengths[math.random(1, #lengths)]
					local pool = dictionary.words_by_length[len]
					if pool and #pool > 0 then
						local w = pool[math.random(1, #pool)]
						if dictionary.word_pool[w] == "A" then
							local chars = dictionary.utf8_chars(w)
							local route = find_route_for_word(state, chars, DIR_VERTICAL, {}, nil, nil)
							if route then
								local intersects = false
								for i = 1, #route do
									if occupied[CK(route[i].x, route[i].y)] then intersects = true; break end
								end
								if not intersects then
									write_word_path(state, chars, route, false)
									for i = 1, #route do
										occupied[CK(route[i].x, route[i].y)] = true
										total_letters = total_letters + 1
									end
									placed[#placed + 1] = {word = w, route = route}
								end
							end
						end
					end
				end
			end

			-- 3) Заполнить остальное.
			fill_remaining(state)

			-- BR-F03: цель уже учтена как часть anchor_info; убедимся, что счётчик
			-- pending не двинулся (мы не должны были вынимать букву — только посмотрели).
			-- target letter — это chars[target_idx]. Удаляем её из pending_targets.
			-- (Считается, что цель размещена — игрок собирёт её, когда соберёт anchor слово
			-- или соответствующее.)
			table.remove(state.pending_targets, 1)
			state.target_anchor_path = anchor_info.route
			state.target_anchor_word = anchor_info.word

			local ok, why = sanity_check(state, anchor_info, total_letters, min_letters)
			if ok then
				event_logger.log("init_ok", {
					attempt = attempt,
					anchor_word = anchor_info.word,
					coverage = total_letters / total_cells,
					placed_count = #placed,
					ftue = is_ftue
				})
				return true, {
					coverage = total_letters / total_cells,
					anchor_word = anchor_info.word,
					attempts = attempt,
					sanity_ok = true,
					placed_count = #placed,
					ftue = is_ftue
				}
			else
				event_logger.log("sanity_fail", {
					attempt = attempt, reason = why,
					coverage = total_letters / total_cells
				})
				-- Возвращаем цель обратно в очередь и идём на пересборку.
				table.insert(state.pending_targets, 1, target_letter)
			end
		end
	end

	-- BR-F03 §49: финальный fallback — снизить целевое покрытие до cov_min и заполнить как есть.
	clear_grid(state)
	-- Если даже anchor не получилось — просто заполняем поле и оставляем target в очереди.
	spawn_service.fill_empty_cells(state)
	event_logger.log("init_fallback", {coverage = 0, reason = "exhausted_attempts"})
	return false, {reason = "exhausted_attempts", coverage = 0}
end

return field_initializer
