--[[
joker_service.lua

Джокеры (BR-J01, BR-J02, BR-J03).

Содержит:
- analyze_random_joker(state, dictionary) — BR-J01, вызывается раз в 3 хода.
- try_mercy_joker(state, dictionary)      — BR-J02, по счётчику idle_moves.
- normalize(state)                        — BR-J03, после каждого обновления поля.
- stats(state) — текущие счётчики джокеров.

Опирается на:
- state.board.cfg
- state.dictionary
- state.move_count (для §124)
- state.idle_moves (для BR-J02)
- state.last_repair_cells, state.target_anchor_path — защищённые буквы
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local cell_factory = require("services.cell_factory")
local event_logger = require("services.event_logger")

local joker_service = {}

local CK = board_geometry.coord_key
local CONSTANTS = cell_factory.get_constants()

-- ── Статистика джокеров ─────────────────────────

function joker_service.stats(state)
	local s = {total = 0, random = 0, mercy = 0}
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.char == CONSTANTS.CHAR_JOKER then
				s.total = s.total + 1
				if cell.joker_type == CONSTANTS.JOKER_RANDOM then s.random = s.random + 1
				elseif cell.joker_type == CONSTANTS.JOKER_MERCY then s.mercy = s.mercy + 1
				else s.random = s.random + 1 end
			end
		end
	end
	return s
end

-- ── BR-J03: нормализация лимитов ────────────────

function joker_service.normalize(state)
	local cfg = state.board.cfg
	local max_total = cfg.max_total_jokers or 2
	local max_random = cfg.max_random_jokers or 1
	local max_mercy = cfg.max_mercy_jokers or 1

	local jokers = {}
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.char == CONSTANTS.CHAR_JOKER then
				local jt = cell.joker_type
				if jt ~= CONSTANTS.JOKER_RANDOM and jt ~= CONSTANTS.JOKER_MERCY then
					jt = CONSTANTS.JOKER_RANDOM
					cell.joker_type = jt
				end
				jokers[#jokers + 1] = {x = x, y = y, jt = jt}
			end
		end
	end

	-- BR-J03 §153-154.
	local keep_random_left = max_random
	local keep_mercy_left = max_mercy
	local kept = {}

	for i = 1, #jokers do
		local j = jokers[i]
		local keep = false
		if j.jt == CONSTANTS.JOKER_RANDOM and keep_random_left > 0 then
			keep = true; keep_random_left = keep_random_left - 1
		elseif j.jt == CONSTANTS.JOKER_MERCY and keep_mercy_left > 0 then
			keep = true; keep_mercy_left = keep_mercy_left - 1
		end
		if keep then kept[#kept + 1] = j end
	end

	-- Усечь до max_total.
	while #kept > max_total do table.remove(kept) end
	local keep_set = {}
	for i = 1, #kept do keep_set[CK(kept[i].x, kept[i].y)] = true end

	-- BR-J03 §155: при замене использовать spawn_service (без возможности немедленно создать новый джокер).
	local spawn_service = require("services.spawn_service")
	for i = 1, #jokers do
		local j = jokers[i]
		if not keep_set[CK(j.x, j.y)] then
			local letter = spawn_service.draw_for_cell(state, j.x, j.y)
			state.grid[j.x][j.y] = cell_factory.create_letter_cell(letter, {origin = "joker_replace"})
		end
	end
end

-- ── BR-J01: random joker как коррекция низкочастотного окна ──

-- joker_frequency_threshold(difficulty):
-- На низкой сложности — порог выше (легче активируется), на высокой — ниже.
local function joker_freq_threshold(difficulty, cfg)
	local low = cfg.random_joker_freq_threshold_low or 0.04
	local high = cfg.random_joker_freq_threshold_high or 0.02
	return low + (high - low) * math.max(0, math.min(1, difficulty))
end

local function letter_avg_in_cells(state, cells, dictionary)
	local sum, n = 0, 0
	for i = 1, #cells do
		local c = cells[i]
		local cell = state.grid[c.x][c.y]
		if cell and not cell.is_booster and cell.char ~= CONSTANTS.CHAR_JOKER and not cell.is_target then
			local w = dictionary.spawn_weights[cell.char] or 0
			sum = sum + w
			n = n + 1
		end
	end
	if n == 0 then return nil, 0 end
	return sum / n, n
end

-- Запрещённые для замены позиции (BR-J01 §137).
local function is_position_protected(state, x, y)
	local cell = state.grid[x][y]
	if not cell then return true end
	if cell.is_target then return true end
	if cell.is_booster then return true end
	if cell.char == CONSTANTS.CHAR_JOKER then return true end
	local key = CK(x, y)
	if state.last_repair_cells and state.last_repair_cells[key] then return true end
	if state.target_anchor_path_set and state.target_anchor_path_set[key] then return true end
	return false
end

function joker_service.analyze_random_joker(state, dictionary)
	local cfg = state.board.cfg
	-- BR-J01 §124: вызывается раз в N ходов. Сам тайминг — в move_resolver.
	local stats = joker_service.stats(state)
	-- BR-J01 §125-126.
	if stats.random >= (cfg.max_random_jokers or 1) then
		event_logger.log("random_joker_skip", {reason = "already_present"})
		return false
	end
	if stats.total >= (cfg.max_total_jokers or 2) then
		event_logger.log("random_joker_skip", {reason = "limit_total"})
		return false
	end

	-- BR-J01 §127-128: нижняя половина, окна шириной 3 с шагом 1.
	local windows = board_geometry.column_windows(
		state.board, cfg.random_joker_window_width or 3, true
	)
	if #windows == 0 then return false end

	-- BR-J01 §131-132: средняя частотность.
	local scored = {}
	for i = 1, #windows do
		local w = windows[i]
		local avg, count = letter_avg_in_cells(state, w.cells, dictionary)
		if avg and count >= 3 then
			scored[#scored + 1] = {window = w, avg = avg, count = count, idx = i}
		end
	end
	if #scored == 0 then
		event_logger.log("random_joker_skip", {reason = "no_window_letters"})
		return false
	end

	-- Сортировка по возрастанию средней частоты.
	table.sort(scored, function(a, b)
		if a.avg ~= b.avg then return a.avg < b.avg end
		-- BR-J01 §133: при равенстве — ближе к боковому краю.
		local center = (state.board.num_cols + 1) / 2
		local da = math.abs(a.window.start_x - center)
		local db = math.abs(b.window.start_x - center)
		if da ~= db then return da > db end
		return a.idx < b.idx
	end)

	-- BR-J01 §134-135: порог.
	local threshold = joker_freq_threshold(state.board.difficulty, cfg)

	for i = 1, #scored do
		local item = scored[i]
		if item.avg >= threshold then
			-- Все оставшиеся окна выше порога — выходим.
			event_logger.log("random_joker_skip", {
				reason = "above_threshold",
				best_window_avg = item.avg, threshold = threshold
			})
			return false
		end

		-- BR-J01 §136-137: найти буквы в окне с минимальной частотностью,
		-- исключив запрещённые позиции.
		local candidates = {}
		local min_w = math.huge
		for j = 1, #item.window.cells do
			local c = item.window.cells[j]
			if not is_position_protected(state, c.x, c.y) then
				local cell = state.grid[c.x][c.y]
				if cell and not cell.is_target and cell.char ~= CONSTANTS.CHAR_JOKER and not cell.is_booster then
					local w = dictionary.spawn_weights[cell.char] or 0
					if w < min_w then
						min_w = w
						candidates = {c}
					elseif w == min_w then
						candidates[#candidates + 1] = c
					end
				end
			end
		end

		if #candidates > 0 then
			local chosen = candidates[math.random(1, #candidates)]
			local old_char = state.grid[chosen.x][chosen.y].char
			state.grid[chosen.x][chosen.y] = cell_factory.create_joker_cell(
				CONSTANTS.JOKER_RANDOM, {origin = "joker_random"}
			)
			event_logger.log("random_joker", {
				window_start_x = item.window.start_x,
				window_avg = item.avg,
				threshold = threshold,
				replaced_letter = old_char,
				replaced_freq = dictionary.spawn_weights[old_char] or 0,
				x = chosen.x, y = chosen.y
			})
			joker_service.normalize(state)
			return true
		end
		-- BR-J01 §138: иначе перейти к следующему окну.
	end

	event_logger.log("random_joker_skip", {reason = "no_candidates"})
	return false
end

-- ── BR-J02: mercy joker ─────────────────────────

-- DFS, симулирующий замену клетки на джокер и поиск слова через цель.
local function dfs_for_mercy(state, dictionary, sx, sy, current_word, visited, path, found, max_len)
	if dictionary.valid_words[current_word] then
		found[#found + 1] = {word = current_word, path = utils.copy_path(path)}
	end
	if dictionary.utf8_len(current_word) >= max_len then return end

	local ns = state.neighbors_map[sx][sy]
	local alphabet = dictionary.alphabet
	for i = 1, #ns do
		local n = ns[i]
		local key = CK(n.x, n.y)
		if not visited[key] then
			local cell = state.grid[n.x][n.y]
			if cell and not cell.is_booster then
				visited[key] = true
				path[#path + 1] = {x = n.x, y = n.y}
				if cell.char == CONSTANTS.CHAR_JOKER then
					for a = 1, #alphabet do
						local nw = current_word .. alphabet[a]
						if dictionary.prefixes[nw] then
							dfs_for_mercy(state, dictionary, n.x, n.y, nw, visited, path, found, max_len)
						end
					end
				else
					local nw = current_word .. cell.char
					if dictionary.prefixes[nw] then
						dfs_for_mercy(state, dictionary, n.x, n.y, nw, visited, path, found, max_len)
					end
				end
				path[#path] = nil
				visited[key] = nil
			end
		end
	end
end

local function mercy_threshold(difficulty, cfg)
	local base = cfg.mercy_joker_base or 3
	local factor = cfg.mercy_joker_diff_factor or 10
	return base + math.floor(0.5 + (difficulty * difficulty) * factor)
end

function joker_service.try_mercy_joker(state, dictionary)
	local cfg = state.board.cfg
	if not cfg.use_mercy_joker and cfg.use_mercy_joker ~= nil then return false end

	local stats = joker_service.stats(state)
	if stats.mercy >= (cfg.max_mercy_jokers or 1) then return false end
	if stats.total >= (cfg.max_total_jokers or 2) then return false end

	local threshold = mercy_threshold(state.board.difficulty, cfg)
	if (state.idle_moves or 0) < threshold then return false end

	-- Найти активные цели.
	local targets = {}
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			local cell = state.grid[x][y]
			if cell and cell.is_target then targets[#targets + 1] = {x = x, y = y} end
		end
	end
	if #targets == 0 then return false end

	local max_word_len = cfg.mercy_joker_max_word_len or 5
	local best = nil

	for ti = 1, #targets do
		local target = targets[ti]
		local nbrs = state.neighbors_map[target.x][target.y]
		for ni = 1, #nbrs do
			local n = nbrs[ni]
			if not is_position_protected(state, n.x, n.y) then
				local original = state.grid[n.x][n.y]
				state.grid[n.x][n.y] = cell_factory.create_joker_cell(
					CONSTANTS.JOKER_MERCY, {origin = "mercy_probe"}
				)

				local found = {}
				local visited = {[CK(n.x, n.y)] = true}
				local path = {{x = n.x, y = n.y}}
				for a = 1, #dictionary.alphabet do
					local start_word = dictionary.alphabet[a]
					if dictionary.prefixes[start_word] then
						dfs_for_mercy(state, dictionary, n.x, n.y, start_word, visited, path, found, max_word_len)
					end
				end
				state.grid[n.x][n.y] = original

				-- Скоринг по BR-J02 §147: Pool A, длина 3-5, через цель, без диагоналей.
				for k = 1, #found do
					local item = found[k]
					local pool = dictionary.word_pool[item.word]
					if pool == "A" or pool == "B" then
						local has_target, has_candidate = false, false
						for p = 1, #item.path do
							local pt = item.path[p]
							if pt.x == target.x and pt.y == target.y then has_target = true end
							if pt.x == n.x and pt.y == n.y then has_candidate = true end
						end
						if has_target and has_candidate then
							local len = dictionary.word_length[item.word]
							local freq = dictionary.word_frequencies[item.word] or 1
							local pool_bonus = (pool == "A") and 1.5 or 1.0
							local len_bonus = (len >= 3 and len <= 5) and 1.5 or 0.8
							local score = freq * pool_bonus * len_bonus
							if not best or score > best.score then
								best = {x = n.x, y = n.y, score = score, word = item.word, target = target}
							end
						end
					end
				end
			end
		end
	end

	if best then
		state.grid[best.x][best.y] = cell_factory.create_joker_cell(
			CONSTANTS.JOKER_MERCY, {origin = "joker_mercy"}
		)
		state.idle_moves = 0
		event_logger.log("mercy_joker", {
			x = best.x, y = best.y,
			anchor_word = best.word,
			target_x = best.target.x, target_y = best.target.y,
			idle_moves_was = threshold
		})
		joker_service.normalize(state)
		return true
	end
	return false
end

return joker_service
